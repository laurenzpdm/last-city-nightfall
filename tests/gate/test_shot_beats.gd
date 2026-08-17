extends TestCase
## A BEAT NAMED `deep_night` CANNOT BE PHOTOGRAPHED AT MORNING.
##
## Every screenshot this project has shipped for four waves was taken by
## `LcnHarness` at a tick a scenario author wrote by hand, and six of the eleven
## beats of `first_night` were photographs of the wrong phase:
##
##     beat          asked at   photographed        (artifacts/G4_base, seed 7)
##     midday          t3400    DUSK
##     dusk            t5500    NIGHT
##     assault         t7200    DEEP NIGHT, the last enemy having died at t6800
##     deep_night      t8800    MORNING of day 2
##     second_dusk    t15200    NIGHT
##     second_night   t17600    DAWN of day 3
##
## The cause is `ClimateProfile.opening_tick`: a run begins 2016 ticks into day
## one, for good reasons, and every hand-written beat tick predates that change
## by a phase. Nothing anywhere compared a beat's NAME against the clock, so the
## frames went out labelled and every art and interface judgement made from them
## was made about the wrong moment.
##
## This suite is that comparison, and it is deliberately built out of the exact
## pieces the harness uses rather than a second copy of them:
##
##   `LcnHarness.beat_claim(name)`  what the name promises
##   `ClimateForecast.of(...)`      where the clock will be, profile + scripted jumps
##   `LcnHarness.aim(...)`          the tick the shutter will actually open at
##
## ...and then holds the answer against a REAL `ClimateSystem` stepped tick by
## tick. Checking a forecast against itself proves nothing; checking it against
## the weather is the whole point.
##
## HOW TO MAKE IT RED, which is the only way to know a green means anything:
## make `LcnHarness.aim` return `asked` (its behaviour before this wave) and
## `test_every_named_beat_is_photographed_in_the_phase_it_names` fails on six
## beats of first_night, five of careless_night and steady_hand, and all six of
## smoke. Verified in a scratch tree.

const SCENARIO_DIR: String = "res://tests/scenarios"
## The standing, owned, non-growing list of beats whose scenario never reaches
## the moment they are named for. See `misnamed_beats_why` in the file.
const REGISTRY: String = "res://tests/gate/screenshot_paths.json"
## Nothing shipped is longer than this, and a suite that walks a 43k-tick
## scenario tick by tick for every file is a suite people start skipping.
const MAX_WALK: int = 24000

## Phase and day per sim tick, from a live ClimateSystem. Keyed by scenario.
var _live: Dictionary[String, Array] = {}
var _registry: Dictionary = {}
## "<scenario>/<beat>" for every row of `misnamed_beats`.
var _excused: PackedStringArray = PackedStringArray()


func requires_files() -> PackedStringArray:
	return PackedStringArray([REGISTRY])


func before_all() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(REGISTRY))
	_registry = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	for row: Dictionary in _registry.get("misnamed_beats", []):
		_excused.append("%s/%s" % [String(row.get("scenario", "")), String(row.get("beat", ""))])


func _scenarios() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(SCENARIO_DIR)
	if dir == null:
		return out
	var names: Array[String] = []
	for f: String in dir.get_files():
		if f.ends_with(".json") and not f.begins_with("_"):
			names.append(f.get_basename())
	names.sort()
	return PackedStringArray(names)


func _scenario(scenario_name: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("%s/%s.json" % [SCENARIO_DIR, scenario_name]))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


static func _script_by_tick(scenario: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for entry: Dictionary in scenario.get("script", []):
		var t: int = int(entry.get("tick", 0))
		var arr: Array = out.get(t, [])
		arr.append(entry.get("cmd", {}))
		out[t] = arr
	return out


## THE WEATHER, not the forecast. A real ClimateSystem, set up and stepped one
## tick at a time, with the scenario's own clock commands delivered exactly where
## `Sim._advance` delivers them: drained at the top of the tick, before any
## system steps. Returns [phase_per_tick, day_per_tick], both 1-indexed.
func _walk(scenario_name: String) -> Array:
	if _live.has(scenario_name):
		return _live[scenario_name]
	var scenario: Dictionary = _scenario(scenario_name)
	var ticks: int = mini(int(scenario.get("ticks", 0)), MAX_WALK)
	var script: Dictionary = _script_by_tick(scenario)
	Rng.reset(int(scenario.get("seed", 7)))
	var climate := ClimateSystem.new()
	climate.setup()
	var phases: PackedByteArray = PackedByteArray()
	var days: PackedInt32Array = PackedInt32Array()
	phases.resize(ticks + 1)
	days.resize(ticks + 1)
	for t: int in range(1, ticks + 1):
		for cmd: Variant in script.get(t, []):
			if String((cmd as Dictionary).get("system", "")) == "climate":
				climate.handle_command(cmd as Dictionary)
		climate.step(t)
		phases[t] = climate.phase_index()
		days[t] = climate.day()
	var out: Array = [phases, days, ticks]
	_live[scenario_name] = out
	return out


func _forecast(scenario_name: String) -> ClimateForecast:
	var scenario: Dictionary = _scenario(scenario_name)
	var ticks: int = mini(int(scenario.get("ticks", 0)), MAX_WALK)
	Rng.reset(int(scenario.get("seed", 7)))
	var climate := ClimateSystem.new()
	climate.setup()
	return ClimateForecast.of(climate.profile(), _script_by_tick(scenario), ticks)


# --- 1. the forecast is not a horoscope --------------------------------------

## Every tick, every scenario: what `ClimateForecast` predicts must be what a
## running `ClimateSystem` does. This is the assertion that would have caught
## `opening_tick` on the day it landed, and it is the one that keeps every rig
## downstream honest without each of them needing a world.
func test_the_forecast_matches_a_running_climate_tick_for_tick() -> void:
	for scenario_name: String in _scenarios():
		var walked: Array = _walk(scenario_name)
		var phases: PackedByteArray = walked[0]
		var days: PackedInt32Array = walked[1]
		var ticks: int = walked[2]
		if ticks <= 0:
			continue
		var f: ClimateForecast = _forecast(scenario_name)
		var first_bad: int = -1
		for t: int in range(1, ticks + 1):
			if f.phase_at(t) != int(phases[t]) or f.day_at(t) != days[t]:
				first_bad = t
				break
		assert_eq(first_bad, -1,
			("%s: the forecast and the running climate part company at t%d — "
			+ "forecast says %s of day %d, the simulation says %s of day %d. "
			+ "Every beat aimed by the forecast from here on is aimed at a lie.")
			% [scenario_name, first_bad,
				ClimateDefs.phase_label(f.phase_at(maxi(first_bad, 1))),
				f.day_at(maxi(first_bad, 1)),
				ClimateDefs.phase_label(int(phases[maxi(first_bad, 1)])),
				days[maxi(first_bad, 1)]])


# --- 2. the deliverable ------------------------------------------------------

## THE ONE THIS SUITE EXISTS FOR. For every shot in every shipped scenario whose
## name claims a phase or a day, the tick the harness will actually open the
## shutter at must BE that phase and that day in the running simulation.
func test_every_named_beat_is_photographed_in_the_phase_it_names() -> void:
	var checked: int = 0
	for scenario_name: String in _scenarios():
		var scenario: Dictionary = _scenario(scenario_name)
		var shots: Array = scenario.get("shots", [])
		if shots.is_empty():
			continue
		var walked: Array = _walk(scenario_name)
		var phases: PackedByteArray = walked[0]
		var days: PackedInt32Array = walked[1]
		var ticks: int = walked[2]
		var f: ClimateForecast = _forecast(scenario_name)
		for shot: Dictionary in shots:
			var beat: String = String(shot.get("name", ""))
			var claim: Dictionary = LcnHarness.beat_claim(beat)
			if shot.has("phase"):
				claim["phase"] = ClimateDefs.PHASE_NAMES.find(
					StringName(String(shot.get("phase", ""))))
			if shot.has("day"):
				claim["day"] = int(shot.get("day", -1))
			if int(claim["phase"]) < 0 and int(claim["day"]) < 0:
				continue
			checked += 1
			var asked: int = int(shot.get("tick", 0))
			var t: int = LcnHarness.aim(f, claim, asked)
			var excused: bool = _excused.has("%s/%s" % [scenario_name, beat])
			assert_true(t >= 1 and t <= ticks or excused,
				("%s/%s claims %s and this scenario never gets there in %d tick(s) — "
				+ "rename the beat, lengthen the run, or script a skip_to_phase. Do not "
				+ "photograph it anyway. If the fix genuinely belongs to another part, "
				+ "add a row to misnamed_beats in %s saying whose it is.")
				% [scenario_name, beat, _claim_text(claim), ticks, REGISTRY])
			if t < 1 or t > ticks:
				continue
			if int(claim["phase"]) >= 0:
				assert_eq(int(phases[t]), int(claim["phase"]),
					("%s/%s is named for %s and the shutter opens at t%d, which is %s "
					+ "(the scenario asked for t%d, which is %s)")
					% [scenario_name, beat,
						ClimateDefs.phase_label(int(claim["phase"])), t,
						ClimateDefs.phase_label(int(phases[t])), asked,
						ClimateDefs.phase_label(int(phases[clampi(asked, 1, ticks)]))])
			if int(claim["day"]) >= 0:
				assert_eq(days[t], int(claim["day"]),
					"%s/%s is named for day %d and the shutter opens at t%d, which is day %d"
					% [scenario_name, beat, int(claim["day"]), t, days[t]])
	assert_true(checked >= 20,
		("only %d beat(s) in tests/scenarios/ made a claim this suite could check — "
		+ "the assertions above ran on almost nothing, which is not a pass")
		% checked)


# --- 3. the vocabulary itself ------------------------------------------------

## `deep_night` is two tokens with `night` as the second one, so a parser that
## scans left to right and stops at the first phase word reads DEEP NIGHT
## correctly and a parser that does not reads NIGHT — silently, for every
## deep-night beat in the repository. Pinned here because it is the exact shape
## of one-word slip that produced the other two defects in this wave.
func test_the_beat_vocabulary_reads_what_it_says() -> void:
	var cases: Array[Array] = [
		["deep_night", ClimateDefs.Phase.DEEP_NIGHT, -1, false],
		["deep_night_zoomout", ClimateDefs.Phase.DEEP_NIGHT, -1, false],
		["second_night", ClimateDefs.Phase.NIGHT, 2, false],
		["night_perimeter", ClimateDefs.Phase.NIGHT, -1, false],
		["midday", ClimateDefs.Phase.AFTERNOON, -1, false],
		["second_dusk", ClimateDefs.Phase.DUSK, 2, false],
		["third_day_city", -1, 3, false],
		["second_day_factory", -1, 2, false],
		["dawn", ClimateDefs.Phase.DAWN, -1, false],
		["assault", -1, -1, true],
		["opening", -1, -1, false],
		["build", -1, -1, false],
		["the_east_road", -1, -1, false],
	]
	for c: Array in cases:
		var got: Dictionary = LcnHarness.beat_claim(String(c[0]))
		assert_eq(int(got["phase"]), int(c[1]),
			"beat '%s' should claim phase %d, reads %d" % [String(c[0]), int(c[1]), int(got["phase"])])
		assert_eq(int(got["day"]), int(c[2]),
			"beat '%s' should claim day %d, reads %d" % [String(c[0]), int(c[2]), int(got["day"])])
		assert_eq(bool(got["live"]), bool(c[3]),
			"beat '%s' live claim should be %s" % [String(c[0]), str(c[3])])


## A beat already standing in the moment it names must NOT be moved: a scenario
## author's tick carries intent this vocabulary does not have, and a rig that
## re-aims a correct shot is a rig that quietly overrides every deliberate
## choice in the file.
func test_a_beat_already_in_its_phase_does_not_move() -> void:
	var f: ClimateForecast = _forecast("first_night")
	assert_true(f.ticks() > 0, "no forecast for first_night — nothing was checked")
	var windows: Array[Vector2i] = f.windows(ClimateDefs.Phase.NIGHT, 1)
	assert_false(windows.is_empty(), "first_night never reaches night on day one")
	var inside: int = (windows[0].x + windows[0].y) / 2 + 37
	var claim: Dictionary = {"phase": ClimateDefs.Phase.NIGHT, "day": 1, "live": false}
	assert_eq(LcnHarness.aim(f, claim, inside), inside,
		"a beat already standing in night of day one was moved off the tick it asked for")


## An excuse that has stopped being true is worse than no excuse: it is a row
## the next author copies. Each one must still name a real scenario, a real beat
## of that scenario, and a claim that scenario genuinely never reaches.
func test_every_excused_beat_is_still_genuinely_unreachable() -> void:
	var rows: Array = _registry.get("misnamed_beats", [])
	assert_true(rows.size() <= int(_registry.get("max_misnamed_beats", 0)),
		("%d beat(s) excused, cap %d — a new one has to displace an old one, or this "
		+ "list becomes the place mislabelled screenshots go to live")
		% [rows.size(), int(_registry.get("max_misnamed_beats", 0))])
	for row: Dictionary in rows:
		var scenario_name: String = String(row.get("scenario", ""))
		var beat: String = String(row.get("beat", ""))
		assert_true(String(row.get("owner", "")) != "" and String(row.get("fix", "")) != "",
			"the excuse for %s/%s does not say who owns it and how to fix it" % [scenario_name, beat])
		var scenario: Dictionary = _scenario(scenario_name)
		var found: Dictionary = {}
		for shot: Dictionary in scenario.get("shots", []):
			if String(shot.get("name", "")) == beat:
				found = shot
		assert_false(found.is_empty(),
			"%s/%s is excused and no longer exists — delete the row" % [scenario_name, beat])
		if found.is_empty():
			continue
		var claim: Dictionary = LcnHarness.beat_claim(beat)
		var f: ClimateForecast = _forecast(scenario_name)
		assert_eq(LcnHarness.aim(f, claim, int(found.get("tick", 0))), -1,
			("%s/%s is excused as unreachable and this scenario DOES reach %s now — "
			+ "delete the row; the beat is aimed correctly without it")
			% [scenario_name, beat, _claim_text(claim)])


static func _claim_text(claim: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if int(claim["phase"]) >= 0:
		parts.append(ClimateDefs.phase_label(int(claim["phase"])))
	if int(claim["day"]) >= 0:
		parts.append("day %d" % int(claim["day"]))
	return " on ".join(parts)
