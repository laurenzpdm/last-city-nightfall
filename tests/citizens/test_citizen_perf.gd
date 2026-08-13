extends TestCase
## [P05] The performance contract, measured rather than asserted.
##
## The tick budget is 50 ms and citizens are one of eleven systems in it. This
## suite builds a city of a thousand people, walks them through a shift change,
## and fails if a tick of the population costs more than BUDGET_US.
##
## It measures `metrics()["step_us"]`, which is the system timing ITSELF from
## the first line of step() to the last — not the harness timing the whole
## world — so the number in the failure message is the number a profiler would
## show. The numbers are printed on every run, passing or failing, because a
## budget you only see when it breaks is a budget nobody is managing.

## Mean cost of one tick of a thousand citizens. Four percent of the frame.
const BUDGET_US: float = 2000.0
## Worst single tick, which includes an A* search and a job-market pass.
const SPIKE_BUDGET_US: float = 9000.0
const POPULATION: int = 1000
const SETTLE_TICKS: int = 400
const MEASURE_TICKS: int = 600

var world: SimFixture = null
var cit: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["citizens"])


var buildings_placed: int = 0


func before_all() -> void:
	world = SimFixture.new(4242).start()
	cit = world.system(&"citizens")
	_found_a_real_city()


## A thousand people idling in a field is not the stress case. They need beds to
## sleep in and benches to work at, because that is what makes them walk, route
## and change state — which is where the cost actually is.
func _found_a_real_city() -> void:
	var build: SimSystem = world.system(&"build")
	if build == null or not world.alive():
		return
	var grid: SimSystem = world.system(&"grid")
	var core: Vector2i = grid.call("core_cell") if grid != null else Vector2i(128, 128)
	_place(&"the_hearth", core)
	for j: int in 9:
		for i: int in 10:
			_place(&"housing_block", core + Vector2i(-34 + i * 6, -24 + j * 6))
	for j2: int in 5:
		for i2: int in 4:
			_place(&"workshop", core + Vector2i(30 + i2 * 6, -24 + j2 * 6))
	world.run(40)


func _place(kind: StringName, cell: Vector2i) -> void:
	var build: SimSystem = world.system(&"build")
	var result: Dictionary = build.call("execute", {
		"op": "place", "kind": String(kind), "cell": [cell.x, cell.y],
		"free": true, "instant": true,
	})
	if bool(result.get("ok", false)):
		buildings_placed += 1


func setup() -> void:
	# A sibling part that fails to compile aborts Sim.create_world before it
	# reaches citizens. That is their red build, not ours.
	if cit == null or not world.alive():
		skip("the world did not come up in this build")


func after_all() -> void:
	if world != null:
		world.stop()


func _step_us() -> float:
	return float(cit.call("step_micros"))


func test_a_thousand_citizens_fit_in_the_tick_budget() -> void:
	world.cmd_now({"system": &"citizens", "op": "add", "count": POPULATION})
	cit.call("give_food", 100000.0)
	assert_ge(float(cit.call("population")), float(POPULATION),
		"the city really does hold a thousand people")

	world.run(SETTLE_TICKS)

	var samples: Array[float] = []
	var wall0: int = Time.get_ticks_usec()
	for i: int in MEASURE_TICKS:
		world.run(1)
		samples.append(_step_us())
	var wall: int = Time.get_ticks_usec() - wall0

	samples.sort()
	var total: float = 0.0
	for v: float in samples:
		total += v
	var mean: float = total / float(samples.size())
	var p95: float = samples[int(float(samples.size()) * 0.95)]
	var worst: float = samples[samples.size() - 1]
	var pop: int = int(cit.call("population"))

	# Printed on every run, pass or fail: the runner filters Log below WARN, and
	# a budget you only see when it breaks is a budget nobody is managing.
	print("    [P05] %d citizens: mean %.0f us, p95 %.0f us, max %.0f us per tick"
		% [pop, mean, p95, worst]
		+ "  (whole world %.2f ms/tick over %d ticks)"
		% [float(wall) / float(MEASURE_TICKS) / 1000.0, MEASURE_TICKS])

	assert_lt(mean, BUDGET_US,
		"mean tick cost of %d citizens (%.0f us) is inside the budget" % [pop, mean])
	assert_lt(worst, SPIKE_BUDGET_US,
		"worst tick of %d citizens (%.0f us) does not spike the frame" % [pop, worst])


func test_a_shift_change_does_not_spike_the_frame() -> void:
	# Everybody retargets at once: the pathological case for routing. The router
	# budget is what has to absorb it, so measure the ticks around the switch.
	var worst: float = 0.0
	world.cmd_now({"system": &"citizens", "op": "set_shift", "shift": "night"})
	for i: int in 120:
		world.run(1)
		worst = maxf(worst, _step_us())
	world.cmd_now({"system": &"citizens", "op": "set_shift", "shift": "day"})
	for i: int in 120:
		world.run(1)
		worst = maxf(worst, _step_us())
	print("    [P05] whole-city shift change, worst tick: %.0f us" % worst)
	assert_lt(worst, SPIKE_BUDGET_US,
		"a whole-city shift change costs %.0f us at its worst" % worst)


func test_pathing_work_is_shared_not_repeated() -> void:
	var router: CitizenRouter = cit.get("router")
	var stats: Dictionary = router.stats()
	var searches: float = float(stats["searches"])
	var hits: float = float(stats["hits"])
	print("    [P05] routes cached %d, A* searches %d, cache hits %d, failed %d" % [
		int(stats["routes"]), int(searches), int(hits), int(stats["failures"])])
	assert_le(float(stats["routes"]), float(CitizenRouter.MAX_ROUTES),
		"the route cache stays inside its cap")
	if buildings_placed > 4:
		assert_gt(hits + searches, 0.0,
			"a city with beds and benches actually makes people walk somewhere")
		assert_gt(hits, searches,
			"most walks reuse a path somebody else already paid for")


func test_the_population_is_still_coherent_at_scale() -> void:
	var report: Dictionary = cit.call("report")
	assert_ge(float(report["population"]), float(POPULATION) * 0.9,
		"a thousand people survived six hundred ticks of being alive")
	assert_between(float(report["avg_morale"]), 0.0, 100.0, "morale stayed a percentage")
	var seen: Dictionary = {}
	for id: int in (cit.call("citizen_ids") as PackedInt32Array):
		assert_has_not(seen, id, "no duplicate citizen ids at scale")
		seen[id] = true
	assert_eq(seen.size(), int(report["population"]), "the roster matches the headcount")
