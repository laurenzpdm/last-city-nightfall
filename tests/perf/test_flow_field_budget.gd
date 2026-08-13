extends TestCase
## [PERF] A flood paid over several ticks must arrive at the same field.
##
## [P01]'s flow field is the only loop in the build with an unbounded worst case.
## A from-scratch Dijkstra over the 54 000 reachable cells of the stress map is
## ~75 ms — 435 000 edge relaxations, measured at GDScript's floor, so it cannot
## be made to fit inside one 50 ms tick. It can only be spread over ticks, which
## is what FlowField's `budget` / `resume()` do and what GridSystem.FLOW_BUDGET
## turns on.
##
## Spreading a Dijkstra is only safe if it CONVERGES. A wavefront suspended
## halfway and picked up next tick has to settle on exactly the integration and
## exactly the directions the unbudgeted flood would have produced — otherwise
## the game quietly ships two different pathfinders depending on how busy the
## tick was. That is what this suite measures, on the real generated map.

var world: SimFixture = null
var grid_sys: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["grid"])


func setup() -> void:
	world = SimFixture.new(4242).start()
	grid_sys = world.system(&"grid")


func teardown() -> void:
	if world != null:
		world.stop()


## The core field, addressed through Object so this file never names a
## `class_name` — see the note in tools/bench_flowfield.gd for why that matters
## in the wrong context, and because it costs nothing to be consistent.
func _core_field() -> Object:
	return grid_sys.call("get_field", &"core")


func _cost() -> PackedByteArray:
	return (grid_sys.get("grid") as Object).get("cost")


func test_a_budgeted_flood_converges_on_the_unbudgeted_answer() -> void:
	var f: Object = _core_field()
	assert_ne(f, null, "the grid has to have a core field to measure")
	if f == null:
		return
	var cost: PackedByteArray = _cost()

	f.call("rebuild", cost, 0)
	var want_integration: PackedInt32Array = (f.get("integration") as PackedInt32Array).duplicate()
	var want_direction: PackedByteArray = (f.get("direction") as PackedByteArray).duplicate()
	assert_gt(int(f.get("last_visited")), 10000,
		"the map has to be big enough for this to be a real flood")

	# Same flood, 2000 cells at a time.
	f.call("rebuild", cost, 2000)
	var slices: int = 1
	assert_true(bool(f.get("unfinished")),
		"a 2000-cell budget must not finish a 50 000-cell map in one call")
	while bool(f.get("unfinished")) and slices < 200:
		f.call("resume", cost, 2000)
		slices += 1
	assert_false(bool(f.get("unfinished")), "the flood has to finish eventually")
	assert_gt(slices, 5, "and it has to have actually been split (%d slice(s))" % slices)

	assert_eq(f.get("integration"), want_integration,
		"a flood paid over %d ticks must reach the same integration field" % slices)
	assert_eq(f.get("direction"), want_direction,
		"...and the same directions, or the game has two pathfinders")


func test_a_budgeted_repair_converges_too() -> void:
	var f: Object = _core_field()
	if f == null:
		return
	var cost: PackedByteArray = _cost()
	f.call("rebuild", cost, 0)

	# Wall off a patch well away from the border and repair both ways.
	var w: int = int((grid_sys.get("grid") as Object).get("width"))
	var changed: PackedInt32Array = PackedInt32Array()
	var core: Vector2i = grid_sys.get("core")
	for dy: int in range(-6, 7):
		var idx: int = (core.y + dy) * w + core.x + 12
		changed.append(idx)
	var saved: PackedByteArray = PackedByteArray()
	for idx: int in changed:
		saved.append(cost[idx])
		cost[idx] = 255

	f.call("update", cost, changed, 0)
	var want_integration: PackedInt32Array = (f.get("integration") as PackedInt32Array).duplicate()
	var want_direction: PackedByteArray = (f.get("direction") as PackedByteArray).duplicate()

	# Put the wall back, re-flood clean, then knock it through again in slices.
	for i: int in changed.size():
		cost[changed[i]] = saved[i]
	f.call("rebuild", cost, 0)
	for idx: int in changed:
		cost[idx] = 255
	f.call("update", cost, changed, 500)
	var slices: int = 1
	while bool(f.get("unfinished")) and slices < 400:
		f.call("resume", cost, 500)
		slices += 1
	assert_false(bool(f.get("unfinished")), "the repair has to finish")

	assert_eq(f.get("integration"), want_integration,
		"a repair split over %d slices must equal the repair done in one" % slices)
	assert_eq(f.get("direction"), want_direction,
		"...directions included")

	for i: int in changed.size():
		cost[changed[i]] = saved[i]


## The budget is a performance knob, not a correctness one: with it at zero
## nothing may ever report itself unfinished, which is the state the rest of the
## build was written against.
func test_no_budget_never_suspends() -> void:
	var f: Object = _core_field()
	if f == null:
		return
	f.call("rebuild", _cost(), 0)
	assert_false(bool(f.get("unfinished")), "an unbudgeted rebuild always completes")
	assert_false(f.call("resume", _cost(), 0), "and there is nothing to resume")
