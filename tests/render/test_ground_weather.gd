extends TestCase
## WHAT THE GROUND IS TOLD ABOUT THE WEATHER. [P13]
##
## DEFECT (two critics, two waves): "there is no visible weather in a still."
##
## The ground shader has had spindrift in it since the last pass and the frame
## lab's blizzard plate has passed the whole time — 48% of the frame changes at
## full storm. Both facts are true and the critic was still right, because the
## uniform was driven by `LcnWorldModel.storm()`, which returns [P09]'s GREAT
## FROST envelope: a scheduled campaign event.
##
## `artifacts/F4b_probe/metrics.csv` — first_night, seed 7, 9000 ticks — is the
## evidence. `climate.storm_intensity` is 0.000 on every one of its 450 rows.
## `climate.weather` reads `snowfall` for about 7000 of those ticks, the wind
## blows at 0.22–0.31 and visibility falls to 0.83. Every hour a critic has
## looked at was an hour with snow falling and a ground rendered dead calm.
##
## So these tests are about ONE question: does the weather a session is actually
## made of reach the ground. They stub [P09] exactly as it behaves — including
## the zero storm envelope — because a stub that answered the Great Frost would
## pass against the code that shipped.


class FakeClimate extends SimSystem:
	var kind: StringName = &"clear"
	var inten: float = 0.0
	var gust: float = 0.0
	var frost: float = 0.0

	func system_name() -> StringName:
		return &"climate"

	func storm_intensity() -> float:
		return frost

	func weather() -> StringName:
		return kind

	func weather_intensity() -> float:
		return inten

	func wind() -> float:
		return gust


## A climate from before the ordinary weather layer existed: the storm envelope
## and nothing else. The model must not fall over on it.
class FrostOnlyClimate extends SimSystem:
	var frost: float = 0.0

	func system_name() -> StringName:
		return &"climate"

	func storm_intensity() -> float:
		return frost


var _model: LcnWorldModel = null
var _sky: FakeClimate = null
var _saved: SimSystem = null


func suite_name() -> String:
	return "render/ground_weather"


func setup() -> void:
	_saved = Sim.get_system(&"climate")
	_sky = FakeClimate.new()
	Sim.by_name[&"climate"] = _sky
	_model = LcnWorldModel.new(LcnSpriteFactory.new())
	_model.attach()


func teardown() -> void:
	if _saved == null:
		Sim.by_name.erase(&"climate")
	else:
		Sim.by_name[&"climate"] = _saved


## THE TEST THAT WOULD HAVE CAUGHT IT. These are the run's own numbers.
func test_the_weather_a_real_run_has_reaches_the_ground() -> void:
	_sky.kind = &"snowfall"
	_sky.inten = 0.55
	_sky.gust = 0.28
	_sky.frost = 0.0
	assert_eq(_model.storm(), 0.0,
		"the Great Frost envelope on an ordinary snowing afternoon is exactly zero, "
		+ "which is what artifacts/F4b_probe says for all 9000 ticks")
	assert_gt(_model.ground_weather(), 0.18,
		"and the ground is still told it is snowing (%.3f)" % _model.ground_weather())


## A calm day is calm. If snowfall lifted the ground and clear weather did too,
## the term would be a constant haze rather than the weather.
func test_a_clear_still_day_leaves_the_ground_alone() -> void:
	_sky.kind = &"clear"
	_sky.inten = 0.0
	_sky.gust = 0.10
	assert_near(_model.ground_weather(), 0.0, 0.001, "clear and still is clear and still")
	_sky.kind = &"overcast"
	_sky.inten = 0.5
	_sky.gust = 0.14
	assert_lt(_model.ground_weather(), 0.12,
		"an overcast afternoon barely moves it (%.3f)" % _model.ground_weather())


## The four weather kinds arrive in the right order and the Great Frost is the
## TOP of the same scale, not a separate switch — otherwise a blizzard would
## look like weather and the campaign's storm would look like a different game.
func test_the_weather_scale_is_ordered_and_the_frost_tops_it() -> void:
	_sky.inten = 0.8
	_sky.gust = 0.5
	var read: Array[float] = []
	for kind: StringName in [&"clear", &"overcast", &"snowfall", &"blizzard"]:
		_sky.kind = kind
		read.append(_model.ground_weather())
	for i: int in range(1, read.size()):
		assert_gt(read[i], read[i - 1],
			"%s drives the ground harder than the kind below it (%.3f vs %.3f)"
				% [["clear", "overcast", "snowfall", "blizzard"][i], read[i], read[i - 1]])
	_sky.kind = &"great_frost"
	_sky.frost = 1.0
	assert_near(_model.ground_weather(), 1.0, 0.001, "a Great Frost is the whole of it")
	# ...and a frost still reads as a frost even if the ordinary layer under it
	# reports nothing, because the two are the same physical thing.
	_sky.kind = &"clear"
	_sky.inten = 0.0
	_sky.gust = 0.0
	assert_near(_model.ground_weather(), 1.0, 0.001,
		"the frost envelope alone still drives the ground at full")


## Spindrift is wind acting on loose snow. Snow falling straight down in still
## air puts nothing on the ground for a photograph to catch — [P14]'s flakes are
## the other half of that weather and they are not this term.
func test_the_wind_is_what_moves_the_snow_along_the_ground() -> void:
	_sky.kind = &"snowfall"
	_sky.inten = 0.7
	_sky.gust = 0.0
	var still: float = _model.ground_weather()
	_sky.gust = 0.6
	var blowing: float = _model.ground_weather()
	assert_gt(blowing, still * 1.6,
		"the same snowfall with wind in it drives the ground harder (%.3f vs %.3f)"
			% [blowing, still])
	assert_gt(still, 0.0, "though falling snow is never nothing")


## Every part in this build was written to tolerate the absence of every other
## part, and a climate that predates the weather layer must not crash the ground.
func test_a_climate_with_only_a_storm_envelope_still_works() -> void:
	var old := FrostOnlyClimate.new()
	Sim.by_name[&"climate"] = old
	var m := LcnWorldModel.new(LcnSpriteFactory.new())
	m.attach()
	old.frost = 0.0
	assert_near(m.ground_weather(), 0.0, 0.001, "no weather layer, no storm, calm ground")
	old.frost = 0.75
	assert_near(m.ground_weather(), 0.75, 0.001, "and its storm still reaches the ground")


## No climate at all is the harness's own case and must be silent, not stormy.
func test_no_climate_at_all_is_a_calm_plain() -> void:
	Sim.by_name.erase(&"climate")
	var m := LcnWorldModel.new(LcnSpriteFactory.new())
	m.attach()
	assert_eq(m.ground_weather(), 0.0, "a world with no weather system has no weather")


## The renderer must ask for the composed value. This is the wiring the whole
## defect was: a correct function nothing called.
func test_the_ground_renderer_asks_for_the_composed_weather() -> void:
	var code: String = FileAccess.get_file_as_string(
		"res://game/view/render/terrain_renderer.gd")
	assert_not_empty(code, "terrain_renderer source is readable")
	assert_true(code.contains("model.ground_weather()"),
		"the ground reads the composed weather")
	assert_false(code.contains("set_shader_parameter(\"storm\", model.storm())"),
		"and no longer drives the ground off the Great Frost envelope alone")
