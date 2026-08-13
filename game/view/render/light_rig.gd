class_name LcnLightRig
extends Node2D
## Night tint plus a pool of warm Light2Ds. [P13]
##
## The art direction lives here. A CanvasModulate drops the entire world to the
## cold tone of the current hour; every warm thing then has to buy its light back
## with a real Light2D. That is why the city reads as islands of heat in the dark
## instead of a uniformly lit map, and it is why the player can feel temperature
## by looking: bright means someone is burning fuel there.
##
## Lights are pooled and reassigned to the strongest sources in view each frame,
## so a thousand-building city still costs a fixed, small number of light passes.

## GL Compatibility gets expensive past a few dozen 2D lights.
const MAX_LIGHTS: int = 26

var tint: CanvasModulate = null

var _pool: Array[PointLight2D] = []
var _active: int = 0
var _cookie: ImageTexture = null


func setup() -> void:
	_cookie = LcnSpriteFactory.glow_texture(256)
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
		# 0.55, not 0.85: with the heat system finally feeding real intensities the
		# old coefficient blew every radiator out to a white disc and took the
		# building underneath it with it. Warm light has to stay warm.
		l2.energy = clampf(0.55 * intensity * energy * flicker, 0.0, 1.8)
		l2.enabled = true
	_active = n


func active_lights() -> int:
	return _active
