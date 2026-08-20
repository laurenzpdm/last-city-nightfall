class_name CitizenRouter
extends RefCounted
## [P05] Where people actually walk, and how a thousand of them afford it.
##
## A citizen walks from a door to a door. Two hundred workers leaving the same
## housing block for the same workshop walk the SAME path, so the expensive part
## — [P01]'s A* — is done once per route and shared, and the cheap part —
## following it — is a couple of floats per citizen per tick.
##
## Four cost controls, in the order they matter:
##
##  * **Deduplication.** Routes are keyed by (from cell, to cell). A shift
##    change of 300 people is a handful of distinct searches.
##  * **A budget per TICK, not per search.** At most NODES_PER_TICK nodes of A*
##    are expanded per tick and at most REQUESTS_PER_TICK new searches are
##    started, so the surge at dusk is smeared across half a second instead of
##    spiking one tick into the red. People visibly "work out where they are
##    going".
##  * **A cache with a lifetime.** Routes are reused until they go stale, and
##    evicted least-recently-used once the cache is full. A route is dropped
##    immediately when the city is built on, because a wall across a path is
##    exactly the case that must not silently keep working.
##  * **A cooldown on failure**, because a "no" costs the full ceiling.
##
## ## Why the tick budget is a NODE budget
##
## Capping searches per tick caps the wrong quantity. Measured on the
## shift-change fixture (`tests/citizens/test_citizen_perf.gd`), a tick holding
## ONE search cost 10 499 µs, of which the search alone was 10 346 µs — the whole
## spike, from a single request, inside the old cap of one request per tick. The
## searches that found their goal cost 124–925 µs; the two that ran to the 1600
## node ceiling and failed cost 10.3 ms and 10.0 ms, 88 % of all pathfinding time
## in that run. A cap of one search per tick cannot see that difference, because
## the unit it counts is not the unit that costs.
##
## So the ceiling on a search stays where it was — a walk still gets its full
## MAX_NODES to be proven impossible, and no floor moves — but it may now be paid
## over as many ticks as it takes. [CitizenPathSearch] holds the open set between
## ticks; `step` spends NODES_PER_TICK on it and stops mid-search if it must.
##
## Determinism: requests are queued in slot order, served FIFO, and route ids
## come from a counter. Nothing here iterates an unordered container. A paused
## search resumes at the exact heap state it was paused at, so it expands the
## same nodes in the same order and returns the same path as an uninterrupted
## one — asserted directly in `tests/citizens/test_citizen_paths.gd`.

const MAX_ROUTES: int = 512
## Node ceiling for one A* search, scaled by distance — see _node_budget. The
## scaling is QUADRATIC because [P01]'s octile heuristic is weighted in tile
## steps while its g-cost is weighted in terrain cost (six and up per tile), so
## the heuristic under-estimates by roughly six to one and the search behaves
## much more like Dijkstra than like A*: it clears a disc, not a corridor. A
## linear budget silently failed four walks in five, and a failed walk is a
## citizen taking the straight line through a wall.
const MAX_NODES: int = 1600
const NODES_PER_CELL2: int = 3
const MIN_NODES: int = 700
## New searches STARTED per tick. Unchanged: the queue is nowhere near saturated
## (nine distinct searches across the 240 ticks of a whole-city shift change),
## so this paces how fast a crowd works out where it is going, and never was the
## thing bounding the cost.
const REQUESTS_PER_TICK: int = 1
## A* nodes the router may expand in one tick, across all searches. This is the
## number that actually bounds the spike. At the measured ~6.5 µs per node of a
## deep search, 192 nodes is ~1.2 ms — a seventh of the 9 ms the whole citizen
## system is allowed for its worst tick, leaving the rest to the thousand people
## the system is really for. Raising it buys nothing: the queue empties anyway.
const NODES_PER_TICK: int = 768
## Ticks a cached route is trusted for. Half an in-world day: staleness is
## handled by invalidate_cells when the ground actually changes, so a route has
## no reason to expire while the city around it stands still.
const ROUTE_TTL: int = 6000
## After a failed search, do not try that pair again for this long. Long on
## purpose: a failed search costs a FULL node budget, and the thing that would
## make it succeed is the city changing — which clears these verdicts anyway
## (see invalidate_cells). Retrying on a timer is paying full price for the
## same "no" every twenty seconds.
const FAIL_COOLDOWN: int = 3000
const QUEUE_CAP: int = 512

var searches: int = 0            ## diagnostic: A* runs since world creation
var hits: int = 0                ## diagnostic: requests served from the cache
var failures: int = 0
## diagnostic: searches abandoned because the ground moved under them
var aborted: int = 0

var _grid: SimSystem = null
var _has_find_path: bool = false
## ONE search object for the life of the world, reused for every walk. It owns a
## megabyte of flat scratch sized to the map (see CitizenPathSearch), and only one
## search is ever in flight, so building a new one per request would be a
## megabyte of allocation per request for no gain.
var _search: CitizenPathSearch = null
## Key of the search in flight, or -1 when there is none.
var _active_key: int = -1
var _routes: Dictionary[int, PackedInt32Array] = {}
var _by_key: Dictionary[int, int] = {}
var _key_of: Dictionary[int, int] = {}
var _used: Dictionary[int, int] = {}
var _failed: Dictionary[int, int] = {}
## packed cell -> route ids crossing it. Lets a new wall drop exactly the paths
## that walked through it instead of the entire cache.
var _by_cell: Dictionary[int, PackedInt32Array] = {}
var _queue: Array[int] = []
var _queued: Dictionary[int, bool] = {}
var _next_id: int = 1


func bind(grid: SimSystem) -> void:
	_grid = grid
	_has_find_path = grid != null and grid.has_method("find_path")


func has_grid() -> bool:
	return _has_find_path


## Route id for a walk, or -1 while none is known yet. A -1 is not a refusal:
## the caller walks toward the destination in a straight line meanwhile and asks
## again, which is why a citizen never stands still waiting for a path.
func request(from: Vector2i, to: Vector2i, tick: int) -> int:
	if not _has_find_path or from == to:
		return -1
	var key: int = _key(from, to)
	var existing: int = _by_key.get(key, -1)
	if existing >= 0:
		if tick - int(_used.get(existing, 0)) < ROUTE_TTL:
			_used[existing] = tick
			hits += 1
			return existing
		_drop(existing)
	var failed_at: int = int(_failed.get(key, -1000000))
	if tick - failed_at < FAIL_COOLDOWN:
		return -1
	if not _queued.has(key) and _queue.size() < QUEUE_CAP:
		_queued[key] = true
		_queue.append(key)
	return -1


## Runs the search budget for this tick. Called once per tick by the system.
##
## Spends NODES_PER_TICK on the half-finished search first and only then looks at
## the queue, so a hard walk is finished rather than abandoned and restarted.
func step(tick: int) -> void:
	if not _has_find_path:
		_queue.clear()
		_queued.clear()
		return
	var world: WorldGrid = _world_grid()
	if world == null:
		# [P01] is present but not the real grid — a stub in a sibling's test, or
		# a build where WorldGrid moved. Fall back to the one-shot search, which
		# is what this router did before it could pause: correct, and spiky.
		var done: int = 0
		while done < REQUESTS_PER_TICK and not _queue.is_empty():
			var key: int = _queue.pop_front()
			_queued.erase(key)
			done += 1
			_solve_oneshot(key, tick)
		return
	var budget: int = NODES_PER_TICK
	var started: int = 0
	while budget > 0:
		if _active_key < 0:
			if started >= REQUESTS_PER_TICK or _queue.is_empty():
				return
			var key2: int = _queue.pop_front()
			_queued.erase(key2)
			started += 1
			if not _begin(world, key2, tick):
				continue      # answered for free; the request slot is still spent
		var state: int = _search.advance(budget)
		budget -= _search.nodes_last
		if state == CitizenPathSearch.RUNNING:
			return
		_finish(tick)


## Cell `step` along a route, or (-1, -1) past the end.
func waypoint(route_id: int, index: int) -> Vector2i:
	var cells: PackedInt32Array = _routes.get(route_id, PackedInt32Array())
	if index < 0 or index >= cells.size():
		return Vector2i(-1, -1)
	var packed: int = cells[index]
	return Vector2i(packed & 0xFFFF, (packed >> 16) & 0xFFFF)


func route_length(route_id: int) -> int:
	return (_routes.get(route_id, PackedInt32Array()) as PackedInt32Array).size()


## Index of the waypoint nearest a position, so a walker who picks up a shared
## path halfway along joins it where they are standing instead of walking back
## to somebody else's front door.
func entry_index(route_id: int, x: float, y: float) -> int:
	var cells: PackedInt32Array = _routes.get(route_id, PackedInt32Array())
	var n: int = cells.size()
	if n == 0:
		return 0
	var best: int = 0
	var best_d: float = 1.0e20
	for i: int in n:
		var packed: int = cells[i]
		var dx: float = float(packed & 0xFFFF) + 0.5 - x
		var dy: float = float((packed >> 16) & 0xFFFF) + 0.5 - y
		var d: float = dx * dx + dy * dy
		if d < best_d:
			best_d = d
			best = i
	return best


## Drops only the paths that walked through cells the city just built on, and
## forgets every "no path exists" verdict, because a demolition can open one.
##
## Wiping the whole cache on every placement is the obvious version and it is
## wrong: a city lays hundreds of pipe segments an hour, and a cache that is
## cleared hundreds of times an hour is not a cache. Nine tenths of the cost of
## walking a thousand people is paid right here.
func invalidate_cells(cells: Array) -> void:
	for c: Variant in cells:
		var cell: Vector2i = c
		var packed: int = (cell.x & 0xFFFF) | ((cell.y & 0xFFFF) << 16)
		# Copy before dropping: _drop edits the very list we are walking.
		var users: PackedInt32Array = (_by_cell.get(packed, PackedInt32Array()) as PackedInt32Array).duplicate()
		if users.is_empty():
			continue
		for i: int in users.size():
			_drop(users[i])
		_by_cell.erase(packed)
	_failed.clear()
	# A search that is only half done read the OLD ground for the half it has
	# already expanded. Finishing it would hand back a path that is part before
	# and part after the wall went up — the one thing this whole function exists
	# to prevent — so it goes back on the queue and starts again on the new map.
	_abort_active(true)


## Throws away every cached route. Save loading and tests only.
func invalidate() -> void:
	_routes.clear()
	_by_key.clear()
	_key_of.clear()
	_used.clear()
	_failed.clear()
	_by_cell.clear()
	_queue.clear()
	_queued.clear()
	_abort_active(false)


func cached_routes() -> int:
	return _routes.size()


## Requests still waiting, including the one being worked on right now. A search
## in progress is not a search that is done.
func pending() -> int:
	return _queue.size() + (1 if _active_key >= 0 else 0)


func stats() -> Dictionary:
	return {
		"routes": _routes.size(),
		"pending": pending(),
		"searches": searches,
		"hits": hits,
		"failures": failures,
		"aborted": aborted,
	}


# =========================================================================
#  internals
# =========================================================================

## [P01]'s WorldGrid, or null when the bound system is not the real thing.
## Re-read rather than cached: `Sim.create_world` builds a new grid per world and
## a stale reference here would path across a map that no longer exists.
func _world_grid() -> WorldGrid:
	if _grid == null:
		return null
	var g: Variant = _grid.get("grid")
	return g as WorldGrid


## Opens a search on `key`. False means it was answered without expanding a
## single node — same cell, out of bounds, or an endpoint standing in a wall —
## and the verdict has already been recorded.
func _begin(world: WorldGrid, key: int, tick: int) -> bool:
	var from := Vector2i(key & 0xFFFF, (key >> 16) & 0xFFFF)
	var to := Vector2i((key >> 32) & 0xFFFF, (key >> 48) & 0xFFFF)
	searches += 1
	if _search == null:
		_search = CitizenPathSearch.new()
	_active_key = key
	var state: int = _search.begin(world, from, to, _node_budget(from, to))
	if state != CitizenPathSearch.RUNNING:
		_finish(tick)
		return false
	return true


## Files the finished search: a route in the cache, or a "no" with a cooldown.
func _finish(tick: int) -> void:
	var key: int = _active_key
	_active_key = -1
	var path: Array[Vector2i] = _search.path()
	_search.release()
	_commit(key, path, tick)


## Drops the half-finished search. `requeue` puts its pair back at the head of
## the queue: the request has not been answered, and the citizen who asked is
## still walking in a straight line waiting for it.
func _abort_active(requeue: bool) -> void:
	if _active_key < 0:
		return
	var key: int = _active_key
	_active_key = -1
	if _search != null:
		_search.release()
	aborted += 1
	if requeue and not _queued.has(key) and _queue.size() < QUEUE_CAP:
		_queued[key] = true
		_queue.push_front(key)


## The pre-resumable search, kept for grids that are not a real WorldGrid.
func _solve_oneshot(key: int, tick: int) -> void:
	var from := Vector2i(key & 0xFFFF, (key >> 16) & 0xFFFF)
	var to := Vector2i((key >> 32) & 0xFFFF, (key >> 48) & 0xFFFF)
	searches += 1
	var raw: Array = _grid.call("find_path", from, to, _node_budget(from, to))
	var path: Array[Vector2i] = []
	for c: Variant in raw:
		path.append(c)
	_commit(key, path, tick)


func _commit(key: int, path: Array[Vector2i], tick: int) -> void:
	if path.size() < 2:
		failures += 1
		_failed[key] = tick
		return
	var cells := PackedInt32Array()
	cells.resize(path.size())
	for i: int in path.size():
		var c: Vector2i = path[i]
		cells[i] = (c.x & 0xFFFF) | ((c.y & 0xFFFF) << 16)
	var id: int = _next_id
	_next_id += 1
	_routes[id] = cells
	_by_key[key] = id
	_key_of[id] = key
	_used[id] = tick
	for i2: int in cells.size():
		var packed: int = cells[i2]
		var users: PackedInt32Array = _by_cell.get(packed, PackedInt32Array())
		users.append(id)
		_by_cell[packed] = users
	if _routes.size() > MAX_ROUTES:
		_evict()


## Least-recently-used, ties broken by the lower route id so two identical runs
## evict the same entry. The keys are sorted before the scan for that reason.
func _evict() -> void:
	var keys: Array = _used.keys()
	keys.sort()
	var worst: int = -1
	var worst_tick: int = 0x7FFFFFFF
	for id: int in keys:
		var t: int = _used[id]
		if t < worst_tick:
			worst_tick = t
			worst = id
	if worst >= 0:
		_drop(worst)


func _drop(route_id: int) -> void:
	var key: int = int(_key_of.get(route_id, -1))
	if key != -1:
		_by_key.erase(key)
	var cells: PackedInt32Array = _routes.get(route_id, PackedInt32Array())
	for i: int in cells.size():
		var packed: int = cells[i]
		var users: PackedInt32Array = _by_cell.get(packed, PackedInt32Array())
		var at: int = users.find(route_id)
		if at < 0:
			continue
		users.remove_at(at)
		if users.is_empty():
			_by_cell.erase(packed)
		else:
			_by_cell[packed] = users
	_key_of.erase(route_id)
	_routes.erase(route_id)
	_used.erase(route_id)


## Node ceiling for one walk, scaled by how far it is. A short trip that cannot
## find its way is a trip through a wall, and expanding eight hundred nodes to
## prove it costs more than the walk is worth.
static func _node_budget(from: Vector2i, to: Vector2i) -> int:
	var d: int = maxi(absi(to.x - from.x), absi(to.y - from.y))
	return clampi(NODES_PER_CELL2 * d * d, MIN_NODES, MAX_NODES)


## Two cells packed into one int. The map is 256x256 (see [P01] WorldGrid), so
## sixteen bits per axis leaves the sign bit alone at any size we will ship.
static func _key(from: Vector2i, to: Vector2i) -> int:
	return (from.x & 0xFFFF) | ((from.y & 0xFFFF) << 16) \
		| ((to.x & 0xFFFF) << 32) | ((to.y & 0xFFFF) << 48)
