class_name CitizenRouter
extends RefCounted
## [P05] Where people actually walk, and how a thousand of them afford it.
##
## A citizen walks from a door to a door. Two hundred workers leaving the same
## housing block for the same workshop walk the SAME path, so the expensive part
## — [P01]'s A* — is done once per route and shared, and the cheap part —
## following it — is a couple of floats per citizen per tick.
##
## Three cost controls, in the order they matter:
##
##  * **Deduplication.** Routes are keyed by (from cell, to cell). A shift
##    change of 300 people is a handful of distinct searches.
##  * **A budget.** At most REQUESTS_PER_TICK searches run per tick, so the
##    surge at dusk is smeared across half a second instead of spiking one tick
##    into the red. People visibly "work out where they are going".
##  * **A cache with a lifetime.** Routes are reused until they go stale, and
##    evicted least-recently-used once the cache is full. A route is dropped
##    immediately when the city is built on, because a wall across a path is
##    exactly the case that must not silently keep working.
##
## Determinism: requests are queued in slot order, served FIFO, and route ids
## come from a counter. Nothing here iterates an unordered container.

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
const REQUESTS_PER_TICK: int = 1
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

var _grid: SimSystem = null
var _has_find_path: bool = false
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
func step(tick: int) -> void:
	if not _has_find_path:
		_queue.clear()
		_queued.clear()
		return
	var done: int = 0
	while done < REQUESTS_PER_TICK and not _queue.is_empty():
		var key: int = _queue.pop_front()
		_queued.erase(key)
		done += 1
		_solve(key, tick)


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


func cached_routes() -> int:
	return _routes.size()


func pending() -> int:
	return _queue.size()


func stats() -> Dictionary:
	return {
		"routes": _routes.size(),
		"pending": _queue.size(),
		"searches": searches,
		"hits": hits,
		"failures": failures,
	}


# =========================================================================
#  internals
# =========================================================================

func _solve(key: int, tick: int) -> void:
	var from := Vector2i(key & 0xFFFF, (key >> 16) & 0xFFFF)
	var to := Vector2i((key >> 32) & 0xFFFF, (key >> 48) & 0xFFFF)
	searches += 1
	var path: Array = _grid.call("find_path", from, to, _node_budget(from, to))
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
