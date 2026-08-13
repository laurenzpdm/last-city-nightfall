extends TestCase
## [P12] The intended experience, and the machine that grades a run against it.
##
## The DifficultyCurve is the design statement ("day three should hurt") turned
## into bands, and EconomyReport is the only thing allowed to decide whether a
## run agrees with it. Both are tested here on synthetic series, so a failure
## points at the grader rather than at whichever system last changed.


func before_all() -> void:
	Balance.reload()


func after_all() -> void:
	Balance.reload()


# --- the curve is real content and internally sane ---------------------------

func test_the_shipped_curve_comes_from_content() -> void:
	assert_true(Registry.has("economy", &"first_week"),
		"game/content/economy/difficulty_curve.tres must be in the registry")
	assert_eq(String(Balance.curve().id), "first_week")


func test_the_curve_needs_no_repair() -> void:
	var fresh: DifficultyCurve = Registry.get_item("economy", &"first_week") as DifficultyCurve
	assert_not_null(fresh)
	assert_true(fresh.validate(), "the shipped curve validates untouched")


func test_the_curve_designs_the_whole_first_week() -> void:
	var c: DifficultyCurve = Balance.curve()
	for day: int in range(1, 8):
		var targets: Dictionary = c.targets_for(day)
		assert_not_empty(targets, "day %d has no designed intent" % day)
		assert_not_empty(String(targets["intent"]),
			"day %d has bands but no sentence saying what they are for" % day)
		assert_lt(float(targets["margin_min"]), float(targets["margin_max"]))
		assert_lt(float(targets["trough_min"]), float(targets["trough_max"]))
		assert_le(float(targets["trough_min"]), float(targets["margin_min"]),
			"the worst moment of a night cannot be designed to beat its average")


func test_the_design_gets_harder_across_the_week() -> void:
	var c: DifficultyCurve = Balance.curve()
	assert_gt(float(c.targets_for(1)["margin_min"]), float(c.targets_for(7)["margin_min"]),
		"the seventh night must be allowed to run thinner than the first")
	assert_lt(float(c.targets_for(1)["frozen_max"]), float(c.targets_for(7)["frozen_max"]),
		"day one tolerates almost no freezing; the Second Frost tolerates a district")


func test_the_storm_days_are_the_ones_the_climate_actually_schedules() -> void:
	# The curve says day 3 and day 7 are storms. If [P09]'s calendar disagrees,
	# every band on those two rows is describing a night that never happens.
	if not need_system(&"climate"):
		return
	var c: DifficultyCurve = Balance.curve()
	var profile: Resource = null
	for id: StringName in Registry.ids("biomes"):
		var res: Resource = Registry.get_item("biomes", id)
		if res != null and "frost_day" in res:
			profile = res
			break
	if profile == null:
		skip("no ClimateProfile in game/content/biomes/ to cross-check against")
		return
	var frost: PackedInt32Array = profile.get("frost_day")
	if frost.is_empty():
		skip("the climate profile ships no frost calendar")
		return
	for day: int in c.storm_day:
		assert_true(frost.has(day),
			"the curve calls day %d a storm night, but [P09]'s calendar does not" % day)


func test_the_curve_makes_no_promises_past_the_week_it_designed() -> void:
	assert_empty(Balance.curve().targets_for(40),
		"an undesigned day must return nothing rather than an extrapolation "
		+ "nobody wrote down")


# --- the grader ---------------------------------------------------------------

func test_a_run_inside_every_band_passes() -> void:
	var report: Dictionary = EconomyReport.analyse(_series(1, 1.0, 0.02, 0.5),
		Balance.curve())
	assert_eq(String(report["verdict"]), String(EconomyDefs.VERDICT_PASS),
		"a comfortable, non-freezing first night is a pass")
	assert_empty(report["failures"])


func test_a_night_far_outside_its_band_fails() -> void:
	# Day one at a margin of 0.2 is a city that died. It must not grade as a pass.
	var report: Dictionary = EconomyReport.analyse(_series(1, 0.2, 0.5, 0.0),
		Balance.curve())
	assert_eq(String(report["verdict"]), String(EconomyDefs.VERDICT_FAIL))
	assert_not_empty(report["failures"])


func test_a_near_miss_is_soft_not_a_failure() -> void:
	var c: DifficultyCurve = Balance.curve()
	var low: float = float(c.targets_for(1)["margin_min"])
	# A whisker under the floor: the design drifted, the build is not broken.
	var report: Dictionary = EconomyReport.analyse(_series(1, low - 0.01, 0.0, 0.5), c)
	assert_ne(String(report["verdict"]), String(EconomyDefs.VERDICT_FAIL),
		"a one-percent drift must not turn the gate red, or the gate gets disabled")


func test_a_day_with_no_night_samples_is_no_data_not_a_pass() -> void:
	# THE trap. An empty night graded as a pass is how a broken scenario reports
	# green: no dark-phase rows, no checks, no complaints.
	var rows: Array = []
	for i: int in 20:
		rows.append({"tick": i * 20, "climate.day": 1, "climate.phase": "morning",
			"heat.total_supply": 100.0, "heat.total_demand": 100.0})
	var report: Dictionary = EconomyReport.analyse(rows, Balance.curve())
	assert_eq(String((report["days"] as Array)[0]["verdict"]),
		String(EconomyDefs.VERDICT_NO_DATA))
	assert_ne(String(report["verdict"]), String(EconomyDefs.VERDICT_PASS),
		"a day the run never reached must not read as a day the run passed")


func test_the_report_measures_what_it_says_it_measures() -> void:
	var rows: Array = []
	for i: int in 10:
		# Margin walks 1.0 down to 0.55 across the night; the trough is the last.
		var supply: float = 100.0 - float(i) * 5.0
		rows.append({"tick": 6400 + i * 20, "climate.day": 1, "climate.phase": "night",
			"heat.total_supply": supply, "heat.total_demand": 100.0,
			"heat.buildings": 100.0, "heat.frozen_buildings": float(i),
			"heat.buffer": 500.0 - float(i) * 50.0})
	var day: Dictionary = (EconomyReport.analyse(rows, Balance.curve())["days"] as Array)[0]
	assert_near(float(day["trough"]), 0.55, 0.001, "trough is the worst sample")
	assert_near(float(day["margin"]), 0.775, 0.001, "margin is the mean of the night")
	assert_near(float(day["frozen_fraction"]), 0.09, 0.001, "frozen is the worst fraction")
	assert_near(float(day["buffer_floor"]), 0.1, 0.001,
		"buffer floor is the lowest store against the most ever banked")


func test_daylight_samples_never_enter_the_night_measurement() -> void:
	var rows: Array = []
	for i: int in 10:
		rows.append({"tick": i * 20, "climate.day": 1, "climate.phase": "morning",
			"heat.total_supply": 1000.0, "heat.total_demand": 10.0})
	for i: int in 10:
		rows.append({"tick": 6400 + i * 20, "climate.day": 1, "climate.phase": "deep_night",
			"heat.total_supply": 80.0, "heat.total_demand": 100.0})
	var day: Dictionary = (EconomyReport.analyse(rows, Balance.curve())["days"] as Array)[0]
	assert_near(float(day["margin"]), 0.8, 0.001,
		"a fat afternoon must not paper over a thin night")


func test_the_report_survives_a_series_with_half_the_columns_missing() -> void:
	# Twelve parts are being written in parallel; a metrics.csv without citizens
	# or combat columns has to produce a report, not a crash.
	var rows: Array = [{"tick": 6400, "climate.phase": "night",
		"heat.total_supply": 90.0, "heat.total_demand": 100.0}]
	var report: Dictionary = EconomyReport.analyse(rows, Balance.curve())
	assert_not_empty(report["days"])
	assert_not_empty(EconomyReport.render(report))


func test_a_report_of_nothing_is_not_a_pass() -> void:
	var report: Dictionary = EconomyReport.analyse([], Balance.curve())
	assert_empty(report["days"], "no rows, no days")
	assert_eq(int((report["summary"] as Dictionary)["samples"]), 0)


func test_margin_and_band_helpers_behave_at_the_edges() -> void:
	assert_near(EconomyDefs.margin(50.0, 0.0), 1.0, 0.001,
		"a city asking for nothing is not in trouble")
	assert_near(EconomyDefs.margin(50.0, 100.0), 0.5, 0.001)
	assert_near(EconomyDefs.band_offset(0.5, 0.4, 0.6), 0.0, 0.001, "inside is zero")
	assert_near(EconomyDefs.band_offset(0.3, 0.4, 0.6), -0.5, 0.001, "half a band low")
	assert_eq(String(EconomyDefs.verdict_for(0.5, 0.4, 0.6)),
		String(EconomyDefs.VERDICT_PASS))
	assert_eq(String(EconomyDefs.verdict_for(0.0, 0.4, 0.6)),
		String(EconomyDefs.VERDICT_FAIL))


# --- helpers ------------------------------------------------------------------

## A night of `samples` dark rows at a fixed margin, frozen fraction and buffer.
func _series(day: int, at_margin: float, frozen: float, buffer_share: float) -> Array:
	var rows: Array = []
	for i: int in 24:
		rows.append({
			"tick": (day - 1) * 9600 + 6400 + i * 20,
			"climate.day": day,
			"climate.phase": "night",
			"heat.total_supply": 100.0 * at_margin,
			"heat.total_demand": 100.0,
			"heat.buildings": 100.0,
			"heat.frozen_buildings": 100.0 * frozen,
			"heat.buffer": 1000.0 * buffer_share,
		})
	# One daylight row before it, holding the buffer peak the floor is measured
	# against, so buffer_share reads as a fraction of 1000.
	rows.push_front({
		"tick": (day - 1) * 9600 + 100, "climate.day": day, "climate.phase": "morning",
		"heat.total_supply": 100.0, "heat.total_demand": 100.0,
		"heat.buildings": 100.0, "heat.frozen_buildings": 0.0, "heat.buffer": 1000.0,
	})
	return rows
