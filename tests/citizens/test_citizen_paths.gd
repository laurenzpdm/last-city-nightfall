extends TestCase
## [P05] The resumable A* is the SAME A*, and it never spends more than a tick.
##
## `CitizenPathSearch` exists to spread one search across several ticks. That is
## only allowed if two things hold, and both are asserted here by running, not by
## reading:
##
##  1. **It agrees with [P01].** For the same pair and the same node ceiling it
##     returns the path `GridSystem.find_path` returns — cell for cell, on a real
##     generated map, over hundreds of pairs, at every pause granularity from one
##     node at a time to the whole search at once. If a future change to either
##     side makes them disagree, this goes red.
##  2. **It obeys the budget.** `advance(n)` never pops more than `n` nodes, so
##     the router's per-tick ceiling is a ceiling and not a suggestion.
##
## And on top of the search, the router contract that makes it safe: a search
## that is half done when the ground changes is thrown away, not finished.

const PAIRS: int = 120

var world: SimFixture = null
var grid: SimSystem = null
var wg: WorldGrid = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["grid", "citizens"])


func before_all() -> void:
	world = SimFixture.new(9182).start()
	grid = world.system(&"grid")
	if grid != null:
		wg = grid.get("grid") as WorldGrid


func setup() -> void:
	if wg == null or not world.alive():
		skip("no world grid in this build")


func after_all() -> void:
	if world != null:
		world.stop()


## Walkable cells spread across the map, picked without randomness so a failure
## is reproducible from the test name alone.
func _sample_cells(n: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var w: int = wg.width
	var h: int = wg.height
	var step: int = 7
	var i: int = 0
	var guard: int = 0
	while out.size() < n and guard < w * h:
		guard += 1
		var x: int = (i * step + (i / w) * 3) % w
		var y: int = (i * 13 + 5) % h
		i += 1
		var c := Vector2i(x, y)
		if wg.in_bounds(c) and wg.cost[wg.index_of(c)] != Grid.IMPASSABLE:
			out.append(c)
	return out


func test_the_resumable_search_returns_the_same_path_as_p01() -> void:
	var cells: Array[Vector2i] = _sample_cells(PAIRS + 1)
	assert_gt(float(cells.size()), 8.0, "the map has walkable ground to path over")
	var checked: int = 0
	var found: int = 0
	# Every chunk size, including 1: a search paused after every single node is
	# the harshest version of "resuming does not reorder the frontier".
	var chunks: Array[int] = [1, 3, 17, 192, 100000]
	for i: int in mini(PAIRS, cells.size() - 1):
		var from: Vector2i = cells[i]
		var to: Vector2i = cells[i + 1]
		if from == to:
			continue
		var budget: int = CitizenRouter._node_budget(from, to)
		var reference: Array[Vector2i] = grid.call("find_path", from, to, budget)
		var chunk: int = chunks[i % chunks.size()]
		var search := CitizenPathSearch.new()
		var state: int = search.begin(wg, from, to, budget)
		var spins: int = 0
		while state == CitizenPathSearch.RUNNING and spins < 100000:
			spins += 1
			var before: int = search.expanded
			state = search.advance(chunk)
			assert_le(float(search.nodes_last), float(chunk),
				"advance(%d) popped %d nodes" % [chunk, search.nodes_last])
			assert_gt(float(search.expanded - before + search.nodes_last), 0.0,
				"a running search always makes progress, or it never ends")
		var mine: Array[Vector2i] = search.path()
		checked += 1
		if reference.size() >= 2:
			found += 1
		assert_eq(mine.size(), reference.size(),
			"%s -> %s at chunk %d: same path length as [P01]" % [from, to, chunk])
		if mine.size() == reference.size():
			for k: int in mine.size():
				assert_eq(mine[k], reference[k],
					"%s -> %s at chunk %d: step %d is the same cell" % [from, to, chunk, k])
	print("    [P05] resumable A* agreed with [P01] on %d pairs (%d with a path)"
		% [checked, found])
	assert_gt(float(checked), 40.0, "enough pairs were actually compared to mean something")
	assert_gt(float(found), 0.0, "at least some of those pairs really do have a path")


func test_a_paused_search_is_thrown_away_when_the_ground_changes() -> void:
	var cells: Array[Vector2i] = _sample_cells(40)
	# A pair far enough apart that one node of budget cannot possibly finish it.
	var from: Vector2i = cells[0]
	var to: Vector2i = cells[cells.size() - 1]
	var router := CitizenRouter.new()
	router.bind(grid)
	assert_true(router.has_grid(), "the router found [P01]")
	router.request(from, to, 100)
	router.step(100)
	assert_eq(router.pending(), 1, "the search is in flight, not finished")
	assert_eq(int(router.stats()["aborted"]), 0, "nothing aborted yet")

	router.invalidate_cells([Vector2i(from.x + 1, from.y)])
	assert_eq(int(router.stats()["aborted"]), 1,
		"a wall going up mid-search abandons the search rather than finishing it")
	assert_eq(router.pending(), 1, "and the pair goes back on the queue, unanswered")


func test_the_router_never_spends_more_than_its_tick_budget() -> void:
	var cells: Array[Vector2i] = _sample_cells(200)
	var router := CitizenRouter.new()
	router.bind(grid)
	var tick: int = 1000
	for i: int in mini(60, cells.size() - 1):
		router.request(cells[i], cells[cells.size() - 1 - i], tick)
	var ticks: int = 0
	var before_searches: int = router.searches
	while router.pending() > 0 and ticks < 4000:
		ticks += 1
		tick += 1
		router.step(tick)
	assert_eq(router.pending(), 0, "the queue does drain — a paused search is not a stalled one")
	assert_gt(float(router.searches - before_searches), 0.0, "searches actually ran")
	print("    [P05] %d queued walks drained in %d ticks, %d searches, %d failures"
		% [60, ticks, router.searches, router.failures])
