class_name LcnVfxPointField
extends GPUParticles2D
## One pooled GPU emitter serving MANY sources. [P14]
##
## The naive shape of "embers from every generator" is one GPUParticles2D per
## generator. At a 1700-building city that is hundreds of nodes, hundreds of
## draw calls and hundreds of particle buffers, and it is why particle layers
## are the first thing to eat a frame budget.
##
## This is the pooled form. ONE node owns ONE fixed particle buffer and emits
## from up to [constant LcnVfxTuning.POINTS_MAX] world positions at once, using
## `EMISSION_SHAPE_POINTS` with an emission texture that is rewritten in place
## every time the source list changes. The cost of adding the fortieth chimney
## to the city is three floats in a 48-pixel image — no node, no buffer, no
## draw call.
##
## Two consequences that matter, both deliberate:
##   * particles are shared out across the sources, so a hundred chimneys each
##     smoke a little rather than the frame cost multiplying by a hundred;
##   * density is scaled with `amount_ratio`, never with `amount`, because
##     writing `amount` reallocates the buffer and restarts every live particle.
##
## Verified against the GL Compatibility backend this project ships with, which
## is the backend where GPU particles were historically unsupported: see
## tests/vfx/vfx_gpu.tscn, which asserts pixels on screen rather than trusting
## the class reference.

## The emission texture is one pixel per source. RGB carries (x, y, 0) in the
## emitter's local space, and this node sits at the world origin, so local space
## and world space are the same thing.
var _points_img: Image = null
var _points_tex: ImageTexture = null
var _mat: ParticleProcessMaterial = null
var _live_points: int = 0
var _base_ratio: float = 1.0
var _cap: int = 0


## `cfg` keys, all optional except `amount`:
##   amount, lifetime, texture, additive, z,
##   speed_min, speed_max, spread_deg, direction (Vector2),
##   gravity (Vector2), damping, scale_min, scale_max, scale_curve (Curve),
##   ramp (Gradient), turbulence, turb_scale, spin
func configure(cfg: Dictionary) -> void:
	_cap = maxi(1, int(cfg.get("amount", 64)))
	amount = _cap
	lifetime = float(cfg.get("lifetime", 2.0))
	one_shot = false
	preprocess = float(cfg.get("preprocess", 0.0))
	randomness = 0.7
	# 30 Hz simulation with interpolation: half the GPU work of a 60 Hz emitter
	# and, at the sizes these particles are drawn, indistinguishable.
	fixed_fps = 30
	interpolate = true
	local_coords = false
	draw_order = GPUParticles2D.DRAW_ORDER_LIFETIME
	texture = cfg.get("texture", LcnVfxArt.texture("dot"))
	z_index = int(cfg.get("z", 20))
	z_as_relative = false
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	if bool(cfg.get("additive", false)):
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		m.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		material = m

	_points_img = Image.create(LcnVfxTuning.POINTS_MAX, 1, false, Image.FORMAT_RGBF)
	_points_img.fill(Color(0, 0, 0))
	_points_tex = ImageTexture.create_from_image(_points_img)

	_mat = ParticleProcessMaterial.new()
	_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	_mat.emission_point_count = 1
	_mat.emission_point_texture = _points_tex
	var dir: Vector2 = cfg.get("direction", Vector2.UP)
	_mat.direction = Vector3(dir.x, dir.y, 0.0)
	_mat.spread = float(cfg.get("spread_deg", 25.0))
	_mat.set_param_min(ParticleProcessMaterial.PARAM_INITIAL_LINEAR_VELOCITY,
		float(cfg.get("speed_min", 20.0)))
	_mat.set_param_max(ParticleProcessMaterial.PARAM_INITIAL_LINEAR_VELOCITY,
		float(cfg.get("speed_max", 45.0)))
	var g: Vector2 = cfg.get("gravity", Vector2.ZERO)
	_mat.gravity = Vector3(g.x, g.y, 0.0)
	_mat.set_param_min(ParticleProcessMaterial.PARAM_DAMPING, float(cfg.get("damping", 0.0)))
	_mat.set_param_max(ParticleProcessMaterial.PARAM_DAMPING, float(cfg.get("damping", 0.0)))
	_mat.set_param_min(ParticleProcessMaterial.PARAM_SCALE, float(cfg.get("scale_min", 1.0)))
	_mat.set_param_max(ParticleProcessMaterial.PARAM_SCALE, float(cfg.get("scale_max", 1.6)))
	var spin: float = float(cfg.get("spin", 0.0))
	if spin > 0.0:
		_mat.set_param_min(ParticleProcessMaterial.PARAM_ANGULAR_VELOCITY, -spin)
		_mat.set_param_max(ParticleProcessMaterial.PARAM_ANGULAR_VELOCITY, spin)
		_mat.set_param_min(ParticleProcessMaterial.PARAM_ANGLE, 0.0)
		_mat.set_param_max(ParticleProcessMaterial.PARAM_ANGLE, 360.0)
	var curve: Curve = cfg.get("scale_curve", null)
	if curve != null:
		var ct := CurveTexture.new()
		ct.curve = curve
		_mat.scale_curve = ct
	var ramp: Gradient = cfg.get("ramp", null)
	if ramp != null:
		var gt := GradientTexture1D.new()
		gt.gradient = ramp
		_mat.color_ramp = gt
	if bool(cfg.get("turbulence", false)):
		_mat.turbulence_enabled = true
		_mat.turbulence_noise_strength = float(cfg.get("turb_strength", 1.4))
		_mat.turbulence_noise_scale = float(cfg.get("turb_scale", 2.2))
		_mat.turbulence_noise_speed = Vector3(0.4, 0.2, 0.0)
	process_material = _mat
	emitting = false
	amount_ratio = 0.0


## Points must be world positions, already culled and already capped by the
## caller. Returns how many were actually taken.
func set_points(pts: PackedVector2Array) -> int:
	var n: int = mini(pts.size(), LcnVfxTuning.POINTS_MAX)
	_live_points = n
	if n == 0:
		emitting = false
		return 0
	for i: int in n:
		_points_img.set_pixel(i, 0, Color(pts[i].x, pts[i].y, 0.0))
	# Pad the tail with the last real point rather than the origin: an unwritten
	# pixel is (0,0), and a stray ember at world origin is the kind of artefact
	# that survives three screenshots before anyone notices what it is.
	for i: int in range(n, LcnVfxTuning.POINTS_MAX):
		_points_img.set_pixel(i, 0, Color(pts[n - 1].x, pts[n - 1].y, 0.0))
	_points_tex.update(_points_img)
	_mat.emission_point_count = n
	emitting = _base_ratio > 0.0
	return n


## 0 stops emission without destroying the particles already in flight, which is
## what a fire going out should look like.
func set_density(ratio: float) -> void:
	_base_ratio = clampf(ratio, 0.0, 1.0)
	amount_ratio = _base_ratio
	emitting = _base_ratio > 0.0 and _live_points > 0


## GPU particles are culled as one node, so the rect has to contain everything
## that could be on screen. Keeping it tight to the view is what stops the whole
## layer being drawn while the camera is looking at empty plain.
func set_view(view: Rect2) -> void:
	if view.size.x <= 1.0:
		return
	visibility_rect = view.grow(320.0)


## Retargets the drift of a stream already in flight — smoke bending as the wind
## turns, without restarting a single particle.
func set_wind(wind: Vector2, susceptibility: float, base: Vector2 = Vector2.ZERO) -> void:
	if _mat == null:
		return
	var g: Vector2 = base + wind * susceptibility
	_mat.gravity = Vector3(g.x, g.y, 0.0)


func live_points() -> int:
	return _live_points


func density() -> float:
	return _base_ratio


func capacity() -> int:
	return _cap
