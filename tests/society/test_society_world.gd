extends TestCase
## [P06] in the real world: wired to the real grid, climate, heat and build.
##
## test_society.gd proves the rules. This proves the wiring: that society finds
## the other systems, reads a city it did not invent, survives a thousand ticks
## of it without writing an error, replays byte identically, and costs a
## fraction of the tick budget while doing it.

const TICKS: int = 1200
const PERF_TICKS: int = 3000
## The whole sim gets 50 ms a tick. Society is the seventh system in the order
## and works off aggregates, so it has no business taking more than this.
const BUDGET_MS_PER_TICK: float = 0.35

var world: SimFixture = null
var soc: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["society"])


func setup() -> void:
	world = SimFixture.new(7).start()
	soc = world.system(&"society")


func teardown() -> void:
	if world != null:
		world.stop()


func test_society_is_wired_into_the_world() -> void:
	if not need_system(&"society"):
		return
	assert_not_null(soc, "society is in the world")
	assert_eq(String(soc.system_name()), "society", "under its own name")
	assert_eq(soc.order, 60, "at tick order 60, after citizens and before threat")


func test_the_book_reached_the_world() -> void:
	if not need_system(&"society"):
		return
	assert_ge(float(soc.call("laws_signed_count")), 0.0, "the book exists")
	var pages: Array = soc.call("book_view")
	assert_ge(float(pages.size()), 24.0, "with every law in it")
	var open_now: Array = soc.call("available_laws")
	assert_not_empty(open_now, "and something signable on the first day")


func test_it_runs_without_writing_an_error() -> void:
	if not need_system(&"society"):
		return
	assert_no_errors(func() -> void: world.run(TICKS),
		"a thousand ticks of society in the real world are quiet")


func test_it_reads_the_real_city() -> void:
	if not need_system(&"society"):
		return
	world.run(TICKS)
	var city: Dictionary = soc.call("city_reading")
	var sources: Array = city.get("sources", [])
	assert_has(sources, "build", "it can see the buildings")
	assert_gt(float(city.get("outdoor_c", 100.0)), -80.0, "it knows how cold it is")
	assert_lt(float(city.get("outdoor_c", 100.0)), 20.0, "and it is cold")


func test_the_meters_move_and_say_why() -> void:
	if not need_system(&"society"):
		return
	world.run(TICKS)
	var reasons: Array = soc.call("reasons")
	assert_not_empty(reasons, "the run produced reasons")
	for r: Variant in reasons:
		var d: Dictionary = r
		assert_gt(float(String(d["text"]).length()), 10.0,
			"reason '%s' is a sentence" % String(d["key"]))
	assert_ne(snappedf(float(soc.call("hope")), 0.01), SocietyDefs.HOPE_START,
		"and hope is not where it started")


func test_metrics_reach_the_harness() -> void:
	if not need_system(&"society"):
		return
	world.run(200)
	var m: Dictionary = world.metrics()
	for key: String in ["society.hope", "society.discontent", "society.laws_signed",
			"society.active_grievances"]:
		assert_has(m, key, "metrics.csv carries %s" % key)


func test_a_law_can_be_signed_through_a_command() -> void:
	if not need_system(&"society"):
		return
	world.cmd_now({"system": &"society", "op": "sign", "law": "care_house"})
	assert_eq(String(soc.call("pending_law")), "care_house", "it is being argued")
	world.run(int(4.0 * float(soc.call("hour_ticks"))) + 4)
	assert_true(bool(soc.call("has_law", &"care_house")), "and then it is in force")
	assert_gt(float(soc.call("policy_value", &"medical_care")), 1.0,
		"and the policy vector moved with it")


func test_a_refused_command_warns_and_does_not_break_the_run() -> void:
	if not need_system(&"society"):
		return
	assert_no_errors(func() -> void:
		world.cmd_now({"system": &"society", "op": "sign", "law": "new_order"})
		world.run(5),
		"asking for a law you cannot have is a warning, not an error")
	assert_false(bool(soc.call("has_law", &"new_order")), "and it is not signed")


## The claim this part lives or dies on: a law is not a number on a panel.
## [P05] exposes set_shift_law / set_child_labour so society can enact and it
## can obey, and the shift row it looks up carries real fatigue, output and
## morale coefficients. These two tests are the proof that the wire is live.
func test_a_labour_law_reaches_the_people() -> void:
	if not need_system(&"society"):
		return
	var cit: SimSystem = world.system(&"citizens")
	if cit == null or not cit.has_method("law_flags"):
		skip("[P05] citizens has no law surface in this build")
		return
	assert_eq(String((cit.call("law_flags") as Dictionary)["shift_law"]), "standard",
		"the city starts on standard shifts")
	world.cmd_now({"system": &"society", "op": "sign", "law": "emergency_shift"})
	world.run(int(4.0 * float(soc.call("hour_ticks"))) + 6)
	assert_true(bool(soc.call("has_law", &"emergency_shift")), "the law is in force")
	assert_near(float(soc.call("work_hours")), 14.0, 0.001, "society says fourteen hours")
	assert_eq(String((cit.call("law_flags") as Dictionary)["shift_law"]), "extended",
		"and [P05] is running longer shifts because of it, with real fatigue and morale costs")


func test_child_labour_reaches_the_people() -> void:
	if not need_system(&"society"):
		return
	var cit: SimSystem = world.system(&"citizens")
	if cit == null or not cit.has_method("law_flags"):
		skip("[P05] citizens has no law surface in this build")
		return
	assert_false(bool((cit.call("law_flags") as Dictionary)["child_labour"]), "not at first")
	world.cmd_now({"system": &"society", "op": "sign", "law": "child_labour"})
	world.run(int(4.0 * float(soc.call("hour_ticks"))) + 6)
	assert_true(bool((cit.call("law_flags") as Dictionary)["child_labour"]),
		"and then the children are on the roster, in [P05], for real")
	assert_lt(soc.call("approval_of", SocietyDefs.FACTION_FAMILIES), -20.0,
		"and their parents have noticed")


func test_serialize_lands_in_the_state_dump() -> void:
	if not need_system(&"society"):
		return
	world.run(400)
	var state: Dictionary = world.state()
	var systems: Dictionary = state.get("systems", {})
	assert_has(systems, "society", "society is in state.json")
	var mine: Dictionary = systems["society"]
	for key: String in ["hope", "discontent", "reasons", "forces", "book", "pages",
			"council", "people", "verdict", "city"]:
		assert_has(mine, key, "state.json carries society.%s" % key)


func test_replay_is_byte_identical() -> void:
	if not need_system(&"society"):
		return
	world.stop()
	var script: Dictionary = {
		60: [{"system": &"society", "op": "sign", "law": "double_bunks"}],
		900: [{"system": &"society", "op": "nudge", "meter": "discontent",
			"amount": 12.0, "reason": "A scripted grievance."}],
	}
	var diff: PackedStringArray = SimFixture.replay_diff(11, 1400, script)
	assert_empty(diff, "two identical runs of the whole world agree: %s" % ", ".join(diff))
	world = SimFixture.new(7).start()
	soc = world.system(&"society")


func test_it_fits_in_the_tick_budget_at_full_scale() -> void:
	if not need_system(&"society"):
		return
	# A base worth measuring, built instantly the way the stress scenario does.
	# Measuring society against an empty map would be measuring nothing: the only
	# thing in this part that scales with the city is the building scan.
	_build_a_real_city()
	world.run(120)
	var buildings: int = int((soc.call("city_reading") as Dictionary).get("buildings", 0))
	assert_gt(float(buildings), 600.0, "the measurement is taken against a real base")

	var t0: int = Time.get_ticks_usec()
	for t: int in range(1, PERF_TICKS + 1):
		soc.call("step", 100000 + t)
	var per_tick_ms: float = float(Time.get_ticks_usec() - t0) / float(PERF_TICKS) / 1000.0
	Log.info("society", "perf: society.step() is %.4f ms/tick over %d ticks, %d buildings, %d homes" % [
		per_tick_ms, PERF_TICKS, buildings,
		int((soc.call("city_reading") as Dictionary).get("homes", 0))])
	assert_lt(per_tick_ms, BUDGET_MS_PER_TICK,
		"society.step() stays well inside its share of the 50 ms tick")


## Roughly a thousand structures on one grid, in one tick, with `instant`.
func _build_a_real_city() -> void:
	var build: SimSystem = world.system(&"build")
	if build == null:
		return
	world.cmd({"system": &"build", "op": "add_stock", "items": {
		"iron_plate": 90000, "steel_plate": 90000, "stone": 90000, "timber": 90000,
		"scrap": 90000, "gear": 90000, "copper_coil": 90000, "coal": 90000,
	}})
	world.cmd({"system": &"build", "op": "place", "kind": "the_hearth",
		"cell": [126, 126], "free": true, "instant": true})
	for i: int in 12:
		var y: int = 98 + i * 6
		world.cmd({"system": &"build", "op": "place_line", "kind": "heat_pipe",
			"from": [88, y], "to": [168, y], "free": true, "instant": true})
	for i: int in 11:
		var x: int = 88 + i * 8
		world.cmd({"system": &"build", "op": "place_line", "kind": "heat_pipe",
			"from": [x, 96], "to": [x, 160], "free": true, "instant": true})
	# Housing is what society actually walks, so there has to be a lot of it.
	for row: int in 10:
		for col: int in 9:
			world.cmd({"system": &"build", "op": "place", "kind": "housing_block",
				"cell": [90 + col * 9, 99 + row * 6], "free": true, "instant": true})
	world.run(4)
