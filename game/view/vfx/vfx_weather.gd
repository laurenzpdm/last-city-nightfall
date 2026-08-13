class_name LcnVfxWeather
extends Node2D
## Snow, wind and whiteout. [P14]
##
## Before this, "snow" was a tint in the ground shader and a number in
## [ClimateSystem]. A player could read the weather off the HUD and could not
## see it out of the window. This is the window.
##
## Three parallax layers of real falling flakes, driven by GPU particles and
## capped at a fixed buffer each, plus two things a tint cannot do:
##
##   **Whiteout.** A Great Frost puts a veil between the camera and the city
##   that genuinely costs the player sight — that is the entire threat of a
##   storm, and a storm you can see through perfectly is a colour filter.
##   The veil is bounded (WHITEOUT_MAX) so the city is never actually lost, and
##   the HUD, the lenses and the build menu all sit on canvas layers above it,
##   so the instruments never go dark with the world.
##
##   **Spindrift.** Wind tearing settled snow off the drifts and dragging it
##   across the ground. This is the read that tells a player the storm is
##   *ground level*, and it is what makes the settled snow [P01]/[P13] own look
##   like snow rather than like white paint.
##
## Density obeys `Settings.graphics.snow_density` and every layer is halved and
## calmed under `Settings.accessibility.reduce_motion`.

## Extra world pixels of emission box beyond the visible rect, so a flake is
## never born on camera.
const MARGIN: float = 220.0
## Ground points that can be shedding spindrift at once.
const DRIFT_POINTS: int = 28
## World-space spacing of the spindrift point lattice. Anchored to the world,
## not the camera, so the ribbons do not swim when the camera pans.
const DRIFT_STEP: float = 128.0
## Soft blobs painted into the whiteout veil.
const VEIL_BLOBS: int = 7
## Weather strength each snow layer waits for. Far haze arrives first, the big
## near flakes only in real weather; all three arriving together is what makes
## game snow read as a switch being thrown.
const LAYER_GATE: Array[float] = [0.0, 0.18, 0.45]

var layers: Array[GPUParticles2D] = []
var drift: LcnVfxPointField = null
var veil: Node2D = null

var _mats: Array[ParticleProcessMaterial] = []
var _view: Rect2 = Rect2()
var _whiteout: float = 0.0
var _whiteout_target: float = 0.0
var _fog: Color = Color(0.6, 0.7, 0.85)
var _wind: Vector2 = Vector2.ZERO
var _density: float = 0.0
var _gust: float = 0.0
var _calm: bool = false
var _t: float = 0.0
var _drift_pts: PackedVector2Array = PackedVector2Array()


func setup() -> void:
	var flake: ImageTexture = LcnVfxArt.texture("flake")
	for spec: Dictionary in LcnVfxTuning.SNOW_LAYERS:
		var p := GPUParticles2D.new()
		p.name = String(spec["name"])
		p.amount = int(spec["amount"])
		p.lifetime = 6.0
		p.preprocess = 5.0
		p.randomness = 0.85
		p.fixed_fps = 30
		p.interpolate = true
		p.local_coords = false
		p.texture = flake
		p.z_index = int(spec["z"])
		p.z_as_relative = false
		p.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		p.amount_ratio = 0.0
		p.emitting = false

		var m := ParticleProcessMaterial.new()
		m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		m.emission_box_extents = Vector3(600.0, 400.0, 1.0)
		m.direction = Vector3(0.0, 1.0, 0.0)
		m.spread = 12.0
		m.set_param_min(ParticleProcessMaterial.PARAM_INITIAL_LINEAR_VELOCITY, 6.0)
		m.set_param_max(ParticleProcessMaterial.PARAM_INITIAL_LINEAR_VELOCITY, 22.0)
		m.gravity = Vector3(0.0, float(spec["fall"]), 0.0)
		m.set_param_min(ParticleProcessMaterial.PARAM_SCALE, float(spec["size"]) * 0.6)
		m.set_param_max(ParticleProcessMaterial.PARAM_SCALE, float(spec["size"]))
		var spin: float = float(spec["spin"])
		if spin > 0.0:
			m.set_param_min(ParticleProcessMaterial.PARAM_ANGULAR_VELOCITY, -spin * 60.0)
			m.set_param_max(ParticleProcessMaterial.PARAM_ANGULAR_VELOCITY, spin * 60.0)
			m.set_param_min(ParticleProcessMaterial.PARAM_ANGLE, 0.0)
			m.set_param_max(ParticleProcessMaterial.PARAM_ANGLE, 360.0)
		m.turbulence_enabled = true
		m.turbulence_noise_strength = 0.9 + float(spec["drift"])
		m.turbulence_noise_scale = 1.8
		m.turbulence_noise_speed = Vector3(0.5, 0.15, 0.0)
		m.color = Color(LcnVfxTuning.SNOW_FLAKE.r, LcnVfxTuning.SNOW_FLAKE.g,
			LcnVfxTuning.SNOW_FLAKE.b, float(spec["alpha"]))
		p.process_material = m
		add_child(p)
		layers.append(p)
		_mats.append(m)

	drift = LcnVfxPointField.new()
	drift.name = "Spindrift"
	add_child(drift)
	drift.configure({
		"amount": 200, "lifetime": 1.5, "texture": LcnVfxArt.texture("mote"),
		"z": 12, "direction": Vector2.RIGHT, "spread_deg": 14.0,
		"speed_min": 40.0, "speed_max": 130.0,
		"scale_min": 0.35, "scale_max": 1.1, "damping": 6.0,
		"ramp": _fade_ramp(Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.55)),
		"turbulence": true, "turb_strength": 1.1, "turb_scale": 3.0,
	})

	veil = Veil.new()
	veil.name = "Whiteout"
	(veil as Veil).host = self
	veil.z_index = 58
	veil.z_as_relative = false
	veil.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(veil)


## Ramp from `a` at birth to `b` at half life and back to transparent.
static func _fade_ramp(a: Color, b: Color) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 1.0])
	g.colors = PackedColorArray([a, b, Color(b.r, b.g, b.b, 0.0)])
	return g


## Called once per frame by [LcnVfx].
## `weather` is [method ClimateSystem.weather], `intensity` its 0..1 strength,
## `storm` the Great Frost envelope and `visibility` what the sim says a player
## can see. The veil is driven by the sim's own visibility number, so what the
## screen shows and what the simulation believes cannot drift apart.
func update(dt: float, view: Rect2, wind: Vector2, weather: StringName, intensity: float,
		storm: float, visibility: float, snow_depth: float, grade: Dictionary,
		user_density: float, calm: bool) -> void:
	_view = view
	_wind = wind
	_calm = calm
	_t += dt

	var row: Dictionary = LcnVfxTuning.weather_row(weather)
	var fall: float = float(row["snow"]) * clampf(0.35 + intensity * 0.85, 0.0, 1.35)
	fall = clampf(fall * user_density, 0.0, 1.0)
	if calm:
		fall *= 0.5
	_density = fall
	_gust = clampf(float(row["gust"]) * (0.25 + snow_depth) * user_density, 0.0, 1.0)

	# The veil follows the sim's visibility, not the weather name: a storm that
	# the simulation has decided is mild must not white out the screen.
	var ceiling: float = LcnVfxTuning.WHITEOUT_MAX_CALM if calm else LcnVfxTuning.WHITEOUT_MAX
	_whiteout_target = clampf(
		maxf(float(row["whiteout"]) * intensity, (1.0 - visibility) * 0.85 + storm * 0.25),
		0.0, ceiling) * clampf(user_density, 0.15, 1.0)
	_whiteout = move_toward(_whiteout, _whiteout_target,
		dt / maxf(LcnVfxTuning.WHITEOUT_LERP, 0.05))

	if grade.has("fog"):
		_fog = grade["fog"] as Color

	var half: Vector3 = Vector3(view.size.x * 0.5 + MARGIN, view.size.y * 0.5 + MARGIN, 1.0)
	var centre: Vector2 = view.get_center()
	for i: int in layers.size():
		var spec: Dictionary = LcnVfxTuning.SNOW_LAYERS[i]
		var p: GPUParticles2D = layers[i]
		var m: ParticleProcessMaterial = _mats[i]
		p.position = centre
		p.visibility_rect = Rect2(-half.x, -half.y, half.x * 2.0, half.y * 2.0)
		m.emission_box_extents = half
		var lean: float = float(spec["drift"]) * (0.35 if calm else 1.0)
		m.gravity = Vector3(wind.x * lean, float(spec["fall"]) * (0.6 + intensity * 0.7)
			+ wind.y * lean * 0.5, 0.0)
		m.turbulence_noise_strength = (0.4 if calm else 0.9 + float(spec["drift"])) \
			* (0.6 + storm)
		var gate: float = LAYER_GATE[i] if i < LAYER_GATE.size() else 0.0
		var ratio: float = clampf((fall - gate) / maxf(1.0 - gate, 0.05), 0.0, 1.0)
		p.amount_ratio = ratio
		p.emitting = ratio > 0.004

	_update_drift(view)
	veil.queue_redraw()


## Spindrift points sit on a world-anchored lattice so the ribbons stay put
## while the camera moves. Only the ones nearest the middle of the screen are
## kept when the lattice overflows the cap.
func _update_drift(view: Rect2) -> void:
	if _gust < 0.03:
		drift.set_density(0.0)
		return
	_drift_pts.clear()
	var x0: float = floor(view.position.x / DRIFT_STEP) * DRIFT_STEP
	var y0: float = floor(view.position.y / DRIFT_STEP) * DRIFT_STEP
	var cols: int = int(view.size.x / DRIFT_STEP) + 2
	var rows: int = int(view.size.y / DRIFT_STEP) + 2
	# A dense lattice at low zoom would blow the cap on its own; stride it.
	var stride: int = maxi(1, int(sqrt(float(maxi(1, cols * rows)) / float(DRIFT_POINTS))))
	var i: int = 0
	for cy: int in rows:
		if cy % stride != 0:
			continue
		for cx: int in cols:
			if cx % stride != 0:
				continue
			if _drift_pts.size() >= DRIFT_POINTS:
				break
			var gx: int = int(x0 / DRIFT_STEP) + cx
			var gy: int = int(y0 / DRIFT_STEP) + cy
			# Hash-jittered so the lattice is never legible as a grid.
			var h: int = ((gx * 73856093) ^ (gy * 19349663)) & 0x7FFFFFFF
			var jx: float = float(h % 97) / 97.0 - 0.5
			var jy: float = float((h / 97) % 89) / 89.0 - 0.5
			_drift_pts.append(Vector2(
				float(gx) * DRIFT_STEP + jx * DRIFT_STEP,
				float(gy) * DRIFT_STEP + jy * DRIFT_STEP))
			i += 1
	drift.set_view(view)
	drift.set_points(_drift_pts)
	drift.set_wind(_wind, 1.4, Vector2(0.0, -6.0))
	drift.set_density(_gust * (0.4 if _calm else 1.0))


func whiteout() -> float:
	return _whiteout


func snow_density() -> float:
	return _density


func stats() -> Dictionary:
	var live: int = 0
	for p: GPUParticles2D in layers:
		if p.emitting:
			live += int(float(p.amount) * p.amount_ratio)
	return {
		"snow_particles": live,
		"snow_density": snappedf(_density, 0.001),
		"whiteout": snappedf(_whiteout, 0.001),
		"gust": snappedf(_gust, 0.001),
		"drift_points": drift.live_points(),
	}


## The veil is its own canvas item so it can sit at a different z from the
## flakes: snow falls in front of the city, the whiteout hangs between the
## camera and all of it.
class Veil extends Node2D:
	var host: LcnVfxWeather = null

	func _draw() -> void:
		if host == null or host._whiteout <= 0.004:
			return
		var view: Rect2 = host._view
		if view.size.x <= 1.0:
			return
		var w: float = host._whiteout
		var base: Color = host._fog.lerp(LcnVfxTuning.SNOW_FLAKE, 0.35)
		draw_rect(Rect2(view.position - Vector2(64, 64), view.size + Vector2(128, 128)),
			Color(base.r, base.g, base.b, w * 0.72))
		if host._calm:
			return
		# Torn sheets of snow crossing the frame. Four large soft blobs is the
		# difference between fog and a storm, and it costs four textured quads.
		var haze: ImageTexture = LcnVfxArt.texture("haze")
		var span: float = maxf(view.size.x, view.size.y)
		var wind: Vector2 = host._wind
		var speed: float = maxf(wind.length(), 40.0)
		var dir: Vector2 = wind.normalized() if wind.length_squared() > 1.0 else Vector2.RIGHT
		var perp: Vector2 = Vector2(-dir.y, dir.x)
		for i: int in VEIL_BLOBS:
			var phase: float = fmod(host._t * speed * (0.35 + 0.1 * float(i))
				+ float(i) * 613.0, span * 2.0) - span
			var lateral: float = sin(host._t * 0.23 + float(i) * 2.1) * view.size.y * 0.42
			var c: Vector2 = view.get_center() + dir * phase + perp * lateral
			var r: float = span * (0.30 + 0.12 * float(i % 3))
			draw_texture_rect(haze, Rect2(c - Vector2(r, r) * 0.5, Vector2(r, r)), false,
				Color(base.r, base.g, base.b, w * 0.30))
