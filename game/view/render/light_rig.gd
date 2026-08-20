class_name LcnLightRig
extends Node2D
## Warm point lights, plus the canvas's hour cast. [P13], second pass.
##
## WHAT CHANGED. In the first pass the CanvasModulate multiplied the whole world
## down to the hour's tone — 0.115 luminance at deep night — and every warm thing
## bought its light back with a Light2D. A critic looking at the actual frame saw
## the consequence: a black void with two blown-out white discs in it, 208
## buildings invisible between them.
##
## Darkness is now made per surface by the light rig in LcnPalette (the ground
## shader and the entity tint both evaluate it), so unlit things go dark and lit
## things do not, and the settlement keeps a moonlight floor while the plain
## beyond it does not. This class keeps the CanvasModulate only as a HUE cast so
## the whole canvas — including other parts' particles and ghosts — still shifts
## with the hour, and it drives the point lights that put real warm pools on the
## ground.
##
## Lights are pooled and reassigned to the strongest sources in view each frame,
## so a thousand-building city still costs a fixed, small number of light passes.

## GL Compatibility gets expensive past a few dozen 2D lights.
const MAX_LIGHTS: int = 26

var tint: CanvasModulate = null

var _pool: Array[PointLight2D] = []
var _active: int = 0
var _cookie: ImageTexture = null


## A falloff cookie, not a glow sprite. The glow texture has a deliberate hot
## core so a fire reads as hot; used as a LIGHT cookie that core is a flat
## saturated disc, which is exactly what made every radiator in the night frames
## resolve as a white blob. This one falls off smoothly from the first pixel.
static func _bake_cookie(size: int) -> Image:
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r: float = float(size) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) + 0.5 - r) / r
			var dy: float = (float(y) + 0.5 - r) / r
			var d: float = sqrt(dx * dx + dy * dy)
			# Physically-flavoured: 1/(1+kd^2) shaped, windowed to zero at the rim
			# so lights do not end in a visible circle.
			var a: float = clampf(1.0 / (1.0 + 7.5 * d * d), 0.0, 1.0)
			a *= clampf(1.0 - smoothstep(0.72, 1.0, d), 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return img


func setup() -> void:
	_cookie = LcnArtCache.get_texture("light_cookie_256", func() -> Image: return _bake_cookie(256))
	tint = CanvasModulate.new()
	tint.name = "NightTint"
	tint.color = Color(1, 1, 1)
	add_child(tint)
	for i: int in MAX_LIGHTS:
		var l := PointLight2D.new()
		l.name = "Heat%02d" % i
		l.texture = _cookie
		l.enabled = false
		l.blend_mode = Light2D.BLEND_MODE_ADD
		l.shadow_enabled = false
		l.z_index = 0
		add_child(l)
		_pool.append(l)


## Applies the hour's tint and re-points the light pool at the hottest sources
## currently on screen.
func update(grade: Dictionary, view: Rect2, model: LcnWorldModel, lights_on: bool) -> void:
	tint.color = grade["sky"]
	if not lights_on:
		for l: PointLight2D in _pool:
			l.enabled = false
		_active = 0
		return

	var energy: float = grade["light_energy"]
	var srcs: Array[Dictionary] = []
	for s: Dictionary in model.heat_sources():
		var radius: float = float(s["radius"])
		if view.grow(radius * 0.5).has_point(s["pos"]):
			srcs.append(s)
	# Strongest first, so when the pool runs out we drop the sources the player
	# is least likely to miss.
	var mid: Vector2 = view.get_center()
	srcs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa: float = float(a["intensity"]) * float(a["radius"]) - (a["pos"] as Vector2).distance_to(mid) * 0.35
		var sb: float = float(b["intensity"]) * float(b["radius"]) - (b["pos"] as Vector2).distance_to(mid) * 0.35
		return sa > sb)

	var t: float = SimClock.seconds()
	var n: int = mini(srcs.size(), MAX_LIGHTS)
	for i: int in MAX_LIGHTS:
		var l2: PointLight2D = _pool[i]
		if i >= n:
			l2.enabled = false
			continue
		var s2: Dictionary = srcs[i]
		var radius2: float = float(s2["radius"])
		var intensity: float = float(s2["intensity"])
		var seed_value: float = float(s2.get("seed", i * 37))
		# Two detuned sines read as fire; one reads as a pulsing UI element.
		var flicker: float = 1.0 \
			+ sin(t * 5.3 + seed_value * 0.41) * 0.045 \
			+ sin(t * 11.7 + seed_value * 1.13) * 0.025
		l2.position = s2["pos"]
		l2.texture_scale = (radius2 * 2.0) / 256.0
		l2.color = LcnPalette.heat_light_color(intensity)
		# 0.34 with a falloff cookie, down from 0.55 with a hot-cored glow sprite.
		# A critic looking at the deep-night frame saw two blown-out white blobs
		# and 206 invisible buildings; the readability now comes from the light
		# rig's bounce term, not from cranking the point lights until they clip.
		l2.energy = clampf(0.40 * intensity * energy * flicker, 0.0, 1.05)
		l2.enabled = true
	_active = n


func active_lights() -> int:
	return _active
