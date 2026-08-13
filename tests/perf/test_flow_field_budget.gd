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
	_assert_directions_descend(f)


## A repair whose shadow is bigger than the map is worth is DELIBERATELY turned
## into a full rebuild (FlowField.RAISE_LIMIT), because invalidating a shadow is
## the one phase that cannot be suspended safely: half an invalidation leaves
## stale-low integrations that the following flood refuses to improve, which is
## wrong rather than merely slow.
##
## So the claim here is not "same bytes as the repair". A rebuild and a repair
## settle equal-cost ties in different orders, and which of two equally good
## neighbours a tile steps toward is a free choice. The claims that matter are
## that the COST SURFACE is identical — that is what every path length, every
## reachability test and every chokepoint is derived from — and that the
## directions still form a valid descent to the goal.
func test_a_big_budgeted_repair_falls_back_and_still_agrees_on_cost() -> void:
	var f: Object = _core_field()
	if f == null:
		return
	var cost: PackedByteArray = _cost()
	f.call("rebuild", cost, 0)

	# Wall off a column close to the core: the shadow it casts is most of the map.
	var w: int = int((grid_sys.get("grid") as Object).get("width"))
	var core: Vector2i = grid_sys.get("core")
	var changed: PackedInt32Array = PackedInt32Array()
	for dy: int in range(-6, 7):
		changed.append((core.y + dy) * w + core.x + 12)
	var saved: PackedByteArray = PackedByteArray()
	for idx: int in changed:
		saved.append(cost[idx])
		cost[idx] = 255

	f.call("update", cost, changed, 0)
	var want_integration: PackedInt32Array = (f.get("integration") as PackedInt32Array).duplicate()

	for i: int in changed.size():
		cost[changed[i]] = saved[i]
	f.call("rebuild", cost, 0)
	var full_before: int = int(f.get("rebuilds_full"))
	for idx: int in changed:
		cost[idx] = 255
	f.call("update", cost, changed, 500)
	var slices: int = 1
	while bool(f.get("unfinished")) and slices < 500:
		f.call("resume", cost, 500)
		slices += 1
	assert_false(bool(f.get("unfinished")), "the repair has to finish")
	assert_eq(int(f.get("rebuilds_full")) - full_before, 1,
		"a shadow this big must give up on repairing and re-flood instead")
	assert_gt(slices, 5, "and the re-flood must have been spread over ticks (%d)" % slices)

	assert_eq(f.get("integration"), want_integration,
		"the cost surface after %d budgeted slices must equal the unbudgeted repair" % slices)
	_assert_directions_descend(f)

	for i: int in changed.size():
		cost[changed[i]] = saved[i]


## Every reachable non-goal tile must step to a neighbour that is strictly closer
## to the goal. A field can have the right costs and still be unwalkable if a
## direction was left pointing at a wall or into a cycle.
func _assert_directions_descend(f: Object) -> void:
	var integ: PackedInt32Array = f.get("integration")
	var dirs: PackedByteArray = f.get("direction")
	var w: int = int(f.get("width"))
	var h: int = int(f.get("height"))
	var unreachable: int = 0x3FFFFFFF
	var offs: PackedInt32Array = PackedInt32Array([1, 1 + w, w, -1 + w, -1, -1 - w, -w, 1 - w])
	var bad: int = 0
	var checked: int = 0
	var first: String = ""
	for y: int in range(1, h - 1):
		for x: int in range(1, w - 1):
			var i: int = y * w + x
			if integ[i] == unreachable or integ[i] == 0:
				continue
			checked += 1
			var d: int = dirs[i]
			if d >= 8:
				bad += 1
				if first == "":
					first = "(%d,%d) cost %d has no step" % [x, y, integ[i]]
				continue
			var n: int = i + offs[d]
			if integ[n] >= integ[i]:
				bad += 1
				if first == "":
					first = "(%d,%d) cost %d steps to cost %d" % [x, y, integ[i], integ[n]]
	assert_gt(checked, 10000, "the descent check has to actually cover the map")
	assert_eq(bad, 0, "every routed tile must step downhill — %d did not, e.g. %s" % [bad, first])


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
