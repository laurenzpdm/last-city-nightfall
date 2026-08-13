extends TestCase
## The light rig. [P13]
##
## These are regression tests for named, verified visual defects, not for
## arithmetic. Each one encodes something a critic saw in an actual frame:
## radiator lights that resolved as pure white blobs, a deep night with no
## legibility floor, and a dusk that tinted snow forty tiles from any light.

const KEYS_COLOR: Array[String] = [
	"sky", "ambient", "shadow", "lift", "gain", "fog", "sun_col", "sky_col", "bounce_col",
]
const KEYS_FLOAT: Array[String] = [
	"shadow_alpha", "shadow_len", "sat", "fog_amt", "light_energy", "bloom", "chroma",
	"star_amt", "sun_energy", "sky_energy", "bounce", "wild",
]


func suite_name() -> String:
	return "render/palette"


func test_every_grade_carries_the_whole_rig() -> void:
	for i: int in 64:
		var t: float = float(i) / 64.0
		var g: Dictionary = LcnPalette.grade_at(t)
		for k: String in KEYS_COLOR:
			assert_true(g.has(k) and typeof(g[k]) == TYPE_COLOR, "grade_at(%.3f) colour key %s" % [t, k])
		for k2: String in KEYS_FLOAT:
			assert_true(g.has(k2) and typeof(g[k2]) == TYPE_FLOAT, "grade_at(%.3f) float key %s" % [t, k2])
		assert_true(g.has("sun_dir") and typeof(g["sun_dir"]) == TYPE_VECTOR2, "sun_dir at %.3f" % t)
		assert_near((g["sun_dir"] as Vector2).length(), 1.0, 0.001, "sun_dir is a unit vector")
		assert_near((g["shadow_dir"] as Vector2).length(), 1.0, 0.001, "shadow_dir is a unit vector")


func test_grade_wraps_across_midnight() -> void:
	var a: Dictionary = LcnPalette.grade_at(0.999)
	var b: Dictionary = LcnPalette.grade_at(0.001)
	assert_near(float(a["sun_energy"]), float(b["sun_energy"]), 0.05, "no discontinuity at midnight")
	assert_near((a["sky"] as Color).r, (b["sky"] as Color).r, 0.05, "sky is continuous at midnight")
	# fposmod, so out-of-range input is the same grade rather than a clamp.
	assert_near(float(LcnPalette.grade_at(2.35)["sun_energy"]),
		float(LcnPalette.grade_at(0.35)["sun_energy"]), 0.0001, "day 3 noon == day 1 noon")


## DEFECT: the memoised cache must not change what grade_at returns.
func test_grade_cache_is_transparent() -> void:
	var first: Dictionary = LcnPalette.grade_at(0.61)
	var second: Dictionary = LcnPalette.grade_at(0.61)
	assert_eq(float(second["sun_energy"]), float(first["sun_energy"]), "cached energy")
	assert_eq((second["sun_col"] as Color).r, (first["sun_col"] as Color).r, "cached colour")


## DEFECT (critic, deep_night.png): "208 buildings existed and the frame showed a
## dark void with two blown-out white blobs." The fix is that the CanvasModulate
## stops being the darkening mechanism, so it must stay bright at night.
func test_night_canvas_tint_is_a_cast_not_a_blackout() -> void:
	for t: float in [0.0, 0.05, 0.9, 0.95]:
		var g: Dictionary = LcnPalette.grade_at(t)
		var sky: Color = g["sky"]
		var lum: float = sky.r * 0.2126 + sky.g * 0.7152 + sky.b * 0.0722
		assert_gt(lum, 0.70, "night canvas tint at %.2f is a hue cast (lum %.2f), not a multiply" % [t, lum])
		assert_gt(sky.b, sky.r, "and it is still cold at %.2f" % t)


## DEFECT: unlit buildings vanished at night. The bounce term is the legibility
## floor, and it has to exist over the city and NOT over the wilderness.
func test_night_has_a_legibility_floor_only_over_the_city() -> void:
	var night: Dictionary = LcnPalette.grade_at(0.0)
	assert_gt(float(night["bounce"]), 0.6, "deep night carries a strong city bounce")
	assert_gt(float(night["wild"]), 0.4, "and darkens the wilderness")

	var in_city: Color = LcnPalette.light_at(night, 1.0, 0.0)
	var out_there: Color = LcnPalette.light_at(night, 0.0, 0.0)
	var lum_city: float = in_city.r + in_city.g + in_city.b
	var lum_wild: float = out_there.r + out_there.g + out_there.b
	assert_gt(lum_city, lum_wild * 2.0, "the city is at least twice as lit as the plain beyond it")
	assert_gt(lum_city, 0.6, "and a building inside it is never black")
	assert_lt(lum_wild, lum_city * 0.6, "while the plain genuinely goes dark")


func test_noon_has_no_bounce_and_no_wilderness_penalty() -> void:
	var noon: Dictionary = LcnPalette.grade_at(0.5)
	assert_near(float(noon["bounce"]), 0.0, 0.02, "daylight needs no bounce fake")
	assert_near(float(noon["wild"]), 0.0, 0.02, "and does not darken the plain")
	var a: Color = LcnPalette.light_at(noon, 1.0, 0.0)
	var b: Color = LcnPalette.light_at(noon, 0.0, 0.0)
	assert_near(a.r, b.r, 0.001, "at noon the city and the plain get the same light")


## DEFECT (critic, defect 4): "the day/night grade is a flat global multiply, so
## dusk tints snow 40 tiles from any light." The dusk key must be strongly
## directional — warm key, cold fill — rather than an orange wash.
func test_dusk_is_a_direction_not_a_wash() -> void:
	var dusk: Dictionary = LcnPalette.grade_at(0.74)
	var sun: Color = dusk["sun_col"]
	var sky: Color = dusk["sky_col"]
	assert_gt(sun.r - sun.b, 0.5, "the dusk key is strongly warm")
	assert_gt(sky.b - sky.r, 0.15, "and the fill it is set against is cold")
	var tint: Color = dusk["sky"]
	var spread: float = maxf(tint.r, maxf(tint.g, tint.b)) - minf(tint.r, minf(tint.g, tint.b))
	assert_lt(spread, 0.12, "the canvas tint itself is near-neutral: no global orange multiply")


## DEFECT (critic, defect 3a): "the radiator lights are pure white, which reads as
## a rendering bug rather than warmth."
func test_heat_light_never_goes_white() -> void:
	for i: int in 21:
		var f: float = float(i) / 20.0
		var c: Color = LcnPalette.heat_light_color(f)
		assert_gt(c.r - c.b, 0.25, "heat light at %.2f keeps a warm cast (got %s)" % [f, str(c)])
		assert_lt(c.b, 0.55, "heat light at %.2f never approaches white" % f)
		assert_ge(c.r, 0.99, "heat light at %.2f stays saturated in red" % f)
	# Hotter is warmer-but-brighter, never bluer.
	assert_gt(LcnPalette.heat_light_color(1.0).g, LcnPalette.heat_light_color(0.0).g,
		"hotter sources shift up the amber ramp")


func test_light_grows_with_heat_and_with_city() -> void:
	var night: Dictionary = LcnPalette.grade_at(0.0)
	var cold: Color = LcnPalette.light_at(night, 0.5, 0.0)
	var hot: Color = LcnPalette.light_at(night, 0.5, 1.0)
	assert_gt(hot.r, cold.r, "standing next to a fire makes a wall brighter")
	assert_gt(hot.r - hot.b, cold.r - cold.b, "and warmer, not just brighter")


func test_terrain_tables_cover_every_kind() -> void:
	for k: int in LcnPalette.TERRAIN_COUNT:
		var t: Dictionary = LcnPalette.terrain_tones(k)
		for key: String in ["base", "low", "high"]:
			assert_true(t.has(key), "terrain %d has %s" % [k, key])
		var lo: Color = t["low"]
		var hi: Color = t["high"]
		assert_gt(hi.r + hi.g + hi.b, lo.r + lo.g + lo.b, "terrain %d: high is lighter than low" % k)
		var p: Color = LcnPalette.terrain_params(k)
		assert_between(p.r, 0.0, 1.0, "terrain %d grain in range" % k)
		assert_between(p.a, 0.0, 1.0, "terrain %d relief in range" % k)


## The overlay ramp is the shared scale for heat, power and throughput. It has to
## be monotonic in BRIGHTNESS — that is what a player reads as "more" — and it has
## to leave the cold end and arrive at the warm end.
func test_flow_ramp_is_monotonic_in_brightness() -> void:
	var prev: float = -1.0
	for i: int in 21:
		var c: Color = LcnPalette.flow_ramp(float(i) / 20.0)
		var lum: float = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
		assert_ge(lum, prev - 0.001, "flow ramp keeps getting brighter at %.2f" % (float(i) / 20.0))
		prev = lum
	var cold: Color = LcnPalette.flow_ramp(0.0)
	var hot: Color = LcnPalette.flow_ramp(1.0)
	assert_lt(cold.r - cold.b, 0.0, "the empty end of the ramp is cold")
	assert_gt(hot.r - hot.b, 0.30, "the full end is warm")
