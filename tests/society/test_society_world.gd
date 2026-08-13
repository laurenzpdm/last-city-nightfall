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


func test_it_fits_in_the_tick_budget() -> void:
	if not need_system(&"society"):
		return
	# Warm the caches the same way a real run would before measuring.
	world.run(300)
	var t0: int = Time.get_ticks_usec()
	for t: int in range(1, PERF_TICKS + 1):
		soc.call("step", 100000 + t)
	var per_tick_ms: float = float(Time.get_ticks_usec() - t0) / float(PERF_TICKS) / 1000.0
	Log.info("society", "perf: society.step() is %.4f ms/tick over %d ticks (%d buildings)" % [
		per_tick_ms, PERF_TICKS, int((soc.call("city_reading") as Dictionary).get("buildings", 0))])
	assert_lt(per_tick_ms, BUDGET_MS_PER_TICK,
		"society.step() stays well inside its share of the 50 ms tick")
