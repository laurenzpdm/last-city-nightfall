class_name CitizenPathSearch
extends RefCounted
## [P05] One A* search that can be PUT DOWN AND PICKED UP AGAIN — and that costs
## about a third of what the same search costs [P01].
##
## ## Why this exists
##
## `GridSystem.find_path` is a fine search and a bad neighbour: it runs to its
## node ceiling inside a single call, so whichever tick happens to host a hard
## walk pays for all of it. Measured on the shift-change fixture, one search that
## hit the 1600-node ceiling cost **10 346 µs** — on its own more than the 9 000 µs
## the whole citizen system is allowed for its worst tick — while the searches
## that found their goal early cost 124–925 µs. Two failures were 88 % of every
## microsecond the router spent pathing in that run.
##
## The ceiling is not the problem, and it does not move. A walk that needs 1600
## expansions to be proven impossible must still be allowed to spend them, or
## citizens take the straight line through a wall (see `CitizenRouter.MAX_NODES`).
## What is wrong is that they were all spent in ONE TICK. So the open set, the
## g-scores and the came-from map are ordinary member state here, and `advance()`
## expands only as many nodes as the caller can afford right now. The search
## survives across ticks and finishes when it finishes.
##
## ## Why it is also faster
##
## [P01] keeps `g_score`, `came` and `closed` in Dictionaries, which is thirty to
## forty hash lookups per expansion. Here they are flat `PackedInt32Array`s the
## size of the map, indexed by cell, with a GENERATION STAMP instead of a clear:
## `_g_gen[n] == _gen` is what `g_score.has(n)` was, and starting a new search is
## an integer increment rather than three dictionary teardowns. The heuristic is
## inlined for the same reason — `Grid.octile_cost(grid.cell_of(n), to)` is two
## calls and a Vector2i per neighbour, eight times per expansion.
##
## This matters more than it looks. The per-tick budget is counted in NODES, so a
## node that costs a third as much is a budget that passes three times as many —
## the spike comes down AND the queue drains at the rate it used to. Chasing only
## the spike, by shrinking the budget, cost 20 % of the route cache's hit rate.
##
## The arrays are ~1 MB for a 256×256 map and are allocated ONCE. The router
## reuses a single instance of this class for every search it ever runs, which is
## why `begin()` is written to be cheap and `release()` deliberately does not free
## them.
##
## ## Why it may be trusted
##
## **It is a transcription of `GridSystem.find_path`, not a variation on it.**
## Same neighbour order, same octile heuristic, same `(f << IDX_BITS) | index`
## packing so ties break on the lower cell index, same corner-cut rule, same
## reconstruction. Pausing a sequential loop between two iterations cannot change
## which node it pops next. `tests/citizens/test_citizen_paths.gd` asserts that
## claim directly — same map, same pairs, cell for cell against [P01]'s own
## answer, at pause granularities from one node at a time to the whole search at
## once. That test is the reason a rewrite this invasive is safe, and it goes red
## against either half of this file being wrong.
##
## Determinism: no clock, no randomness, no unordered iteration. The only inputs
## are the cost array and the two endpoints.
##
## One hazard is inherent to being resumable: the ground can change between two
## ticks of the same search, and a path half-planned through a wall that has since
## gone up is exactly the silent breakage the route cache exists to prevent. The
## search does not police that itself — the router aborts it (see
## `CitizenRouter.invalidate_cells`), because the router is what gets told.

enum { RUNNING, FOUND, FAILED }

## Nodes popped by the most recent advance(), whether or not they expanded.
var nodes_last: int = 0
## Nodes EXPANDED across the whole search. Compared against the search ceiling,
## so it counts what [P01] counts: pops that were not already closed.
var expanded: int = 0

## [P01]'s grid. The cost array is deliberately NOT held as a member between
## ticks: `PackedByteArray` is copy-on-write, so a reference kept here would both
## force [P01] to duplicate 64 kB the next time it writes a single cell, and leave
## this search reading the map as it was when it started. It is re-read at the top
## of every advance(), which is one property access per tick rather than per node.
var _grid: WorldGrid = null
var _from: Vector2i = Vector2i.ZERO
var _to: Vector2i = Vector2i.ZERO
var _start: int = -1
var _goal: int = -1
var _width: int = 0
var _max_nodes: int = 0
var _state: int = FAILED
var _cost_size: int = 0
var _offs: PackedInt32Array = PackedInt32Array()
var _open: Array[int] = []

# --- the flat frontier, reused across every search this object ever runs ------
# A cell counts as reached or closed only while its stamp matches the CURRENT
# generation, so a new search costs one increment instead of clearing a megabyte.
var _gen: int = 0
var _g: PackedInt32Array = PackedInt32Array()
var _g_gen: PackedInt32Array = PackedInt32Array()
var _came: PackedInt32Array = PackedInt32Array()
var _closed_gen: PackedInt32Array = PackedInt32Array()


## Sets up a search and returns its state. FOUND or FAILED here means the answer
## was free — the endpoints are out of bounds, blocked, or the same cell — and
## advance() need never be called.
func begin(grid: WorldGrid, from: Vector2i, to: Vector2i, max_nodes: int) -> int:
	_grid = grid
	_from = from
	_to = to
	_max_nodes = max_nodes
	_state = FAILED
	expanded = 0
	nodes_last = 0
	_open.clear()
	if grid == null or not grid.in_bounds(from) or not grid.in_bounds(to):
		return _state
	var cost: PackedByteArray = grid.cost
	_cost_size = cost.size()
	_width = grid.width
	_ensure_scratch()
	_start = grid.index_of(from)
	_goal = grid.index_of(to)
	if cost[_start] == Grid.IMPASSABLE or cost[_goal] == Grid.IMPASSABLE:
		return _state
	if _start == _goal:
		_state = FOUND
		return _state
	var w: int = _width
	_offs = PackedInt32Array([1, 1 + w, w, -1 + w, -1, -1 - w, -w, 1 - w])
	_g[_start] = 0
	_g_gen[_start] = _gen
	_heap_push(_open, (Grid.octile_cost(from, to) << FlowField.IDX_BITS) | _start)
	_state = RUNNING
	return _state


func state() -> int:
	return _state


## Spends at most `pop_budget` heap pops and returns the state afterwards.
## Closed-node pops are charged too: they are the same heap work, and a tick that
## could be handed an unbounded run of them has no budget at all.
func advance(pop_budget: int) -> int:
	nodes_last = 0
	if _state != RUNNING:
		return _state
	# Locals, not members: a member lookup per array access, eight times per
	# expansion, is a measurable fraction of the inner loop in GDScript.
	var cost: PackedByteArray = _grid.cost
	var g: PackedInt32Array = _g
	var g_gen: PackedInt32Array = _g_gen
	var came: PackedInt32Array = _came
	var closed: PackedInt32Array = _closed_gen
	var offs: PackedInt32Array = _offs
	var gen: int = _gen
	var open: Array[int] = _open
	var size: int = _cost_size
	var w: int = _width
	var tx: int = _to.x
	var ty: int = _to.y
	while not open.is_empty() and expanded < _max_nodes and nodes_last < pop_budget:
		nodes_last += 1
		var top: int = _heap_pop(open)
		var cur: int = top & FlowField.IDX_MASK
		if closed[cur] == gen:
			continue
		closed[cur] = gen
		expanded += 1
		if cur == _goal:
			_state = FOUND
			return _state
		var gc: int = g[cur]
		for d: int in range(8):
			var n: int = cur + offs[d]
			if n < 0 or n >= size:
				continue
			var cn: int = cost[n]
			if cn == Grid.IMPASSABLE or closed[n] == gen:
				continue
			var ng: int = gc
			if (d & 1) == 1:
				# A diagonal may not cut a corner. The outer ring of the map is
				# impassable by WorldGrid contract, so a walkable cell always has
				# all eight neighbours in range and these two need no bounds test.
				if cost[cur + offs[(d + 1) & 7]] == Grid.IMPASSABLE:
					continue
				if cost[cur + offs[(d - 1) & 7]] == Grid.IMPASSABLE:
					continue
				ng += cn * FlowField.W_DIAG
			else:
				ng += cn * FlowField.W_ORTHO
			if g_gen[n] == gen and ng >= g[n]:
				continue
			g[n] = ng
			g_gen[n] = gen
			came[n] = cur
			# Grid.octile_cost(grid.cell_of(n), to), inlined: eight times per
			# expansion is where a call and a Vector2i stop being free.
			var dx: int = tx - (n % w)
			if dx < 0:
				dx = -dx
			var dy: int = ty - (n / w)
			if dy < 0:
				dy = -dy
			var lo: int = dx if dx < dy else dy
			var f: int = ng + 14 * lo + 10 * (dx + dy - 2 * lo)
			_heap_push(open, (f << FlowField.IDX_BITS) | n)
	if open.is_empty() or expanded >= _max_nodes:
		_state = FAILED
	return _state


## The walk, start cell first. Empty unless the state is FOUND.
func path() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _state != FOUND:
		return out
	if _start == _goal:
		out.append(_from)
		return out
	var node: int = _goal
	var guard: int = 0
	while node != _start and guard <= _cost_size:
		guard += 1
		out.append(Vector2i(node % _width, node / _width))
		node = _came[node]
	out.append(_from)
	out.reverse()
	return out


## Drops the frontier, not the scratch. The router keeps one of these objects for
## the life of the world, so freeing a megabyte of arrays between two searches
## would mean allocating it again a tick later.
func release() -> void:
	_open.clear()
	_grid = null
	_state = FAILED


## Sizes the flat frontier to the map and advances the generation, which is what
## makes "forget everything" cost one integer. The only case needing real work is
## the counter running out of range — once per two billion searches, where a
## single fill is cheap insurance against a stamp from a previous era matching.
func _ensure_scratch() -> void:
	if _g.size() != _cost_size:
		_g.resize(_cost_size)
		_g_gen.resize(_cost_size)
		_came.resize(_cost_size)
		_closed_gen.resize(_cost_size)
		_g_gen.fill(0)
		_closed_gen.fill(0)
		_gen = 0
	_gen += 1
	if _gen >= 0x7FFFFFFF:
		_g_gen.fill(0)
		_closed_gen.fill(0)
		_gen = 1


static func _heap_push(heap: Array[int], v: int) -> void:
	heap.append(v)
	var i: int = heap.size() - 1
	while i > 0:
		var p: int = (i - 1) >> 1
		if heap[p] <= heap[i]:
			break
		var tmp: int = heap[p]
		heap[p] = heap[i]
		heap[i] = tmp
		i = p


static func _heap_pop(heap: Array[int]) -> int:
	var top: int = heap[0]
	var last: int = int(heap.pop_back())
	var n: int = heap.size()
	if n == 0:
		return top
	heap[0] = last
	var i: int = 0
	while true:
		var l: int = i * 2 + 1
		var r: int = l + 1
		var m: int = i
		if l < n and heap[l] < heap[m]:
			m = l
		if r < n and heap[r] < heap[m]:
			m = r
		if m == i:
			break
		var tmp: int = heap[m]
		heap[m] = heap[i]
		heap[i] = tmp
		i = m
	return top
