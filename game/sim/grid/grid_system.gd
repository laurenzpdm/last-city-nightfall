class_name GridSystem
extends SimSystem
## [P01] The ground the whole game stands on.
##
## Owns the tile world, its generation, its occupancy, and the pathfinding
## surface every moving thing in the game reads. Other parts talk to it like this:
##
## [codeblock]
## var g: GridSystem = Sim.get_system(&"grid") as GridSystem
## if g.is_free(cell, Vector2i(2, 2)):
##     g.occupy(cell, Vector2i(2, 2), building_id)
## var step: Vector2i = g.flow_direction(enemy_cell)   # one step toward the city
## [/codeblock]
##
## Nothing here reads input, frame time or the view. Randomness comes from
## Rng.stream("mapgen") only, so the same seed always produces the same plain.

const ORDER: int = 20
const NAME: StringName = &"grid"
const CORE_FIELD: StringName = &"core"
## Cells of cost repair allowed per tick. Bounds worst-case work after a storm
## or a mass demolition; the remainder simply waits for the next tick.
const COST_BUDGET: int = 3000
## Cells a flow field may settle in one tick. A from-scratch flood over the
## 54 000 reachable cells of a 256x256 plain is 75 ms in GDScript — 435 000 edge
## relaxations, already at the language's floor, so it cannot be made to fit in
## a frame; it can only be PAID OVER SEVERAL of them. A single wall coming down
## next to the core improves the integration of half the map and triggers exactly
## that flood, which is why the worst tick in a stress run was 69 ms and it
## happened mid-assault. With this cap the same event costs ~11 ms a tick for
## seven ticks, and the field stays usable throughout: correct where the wave has
## passed, stale behind it, converging on the identical answer.
const FLOW_BUDGET: int = 8000
const SNOW_INTERVAL: int = 5
const SNOW_CHUNKS_PER_PASS: int = 4
const MAX_FIELDS: int = 8

## Biome the next world uses. Set before Sim.create_world() to change map.
static var requested_biome: StringName = &"frozen_basin"

var grid: WorldGrid
var core: Vector2i = Vector2i.ZERO
var biome_id: StringName = &""
var biome_name: String = ""
## Approach lanes: {entry:int, choke:int, width:int, heading:float, path:PackedInt32Array}
var lanes: Array[Dictionary] = []
var choke_cells: Array[Vector2i] = []
var mapgen_stats: Dictionary = {}

## Depth units per second falling on unsheltered ground. [P09] climate drives this.
var snowfall_rate: float = 0.30
var snow_cap: int = 235

var _fields: Dictionary[StringName, FlowField] = {}
var _field_order: Array[StringName] = []
var _snow_cursor: int = 0
var _snow_carry: float = 0.0
var _flush_us: int = 0
var _flush_cells: int = 0
var _flow_cells: int = 0
var _gen_ms: int = 0


func _init() -> void:
	order = ORDER


func system_name() -> StringName:
	return NAME


## Above this the flow-field repair is worth a line in the log.
const SLOW_REPAIR_US: int = 4000

# ---------------------------------------------------------------- lifecycle

func setup() -> void:
	var profile: BiomeProfile = _load_profile()
	biome_id = profile.id
	biome_name = profile.display_name
	snow_cap = profile.snow_cap

	var t0: int = Time.get_ticks_msec()
	var gen := MapGenerator.new(profile)
	grid = gen.generate()
	_gen_ms = Time.get_ticks_msec() - t0

	core = gen.core
	lanes = gen.lanes
	choke_cells = gen.chokepoints
	mapgen_stats = gen.stats

	_fields.clear()
	_field_order.clear()
	create_field(CORE_FIELD, core_goals())

	Log.info("grid", "biome '%s' %dx%d in %d ms, %d chunks, %d walkable, %d lanes, %d chokepoints, hash %d" % [
		biome_id, grid.width, grid.height, _gen_ms, grid.chunk_count(),
		grid.walkable_cells, lanes.size(), choke_cells.size(), grid.content_hash(),
	])
	var res: Dictionary = mapgen_stats.get("resources", {})
	var parts: PackedStringArray = PackedStringArray()
	var keys: Array = res.keys()
	keys.sort()
	for k: String in keys:
		parts.append("%s=%d" % [k, int(res[k])])
	Log.info("grid", "deposits: %s" % ", ".join(parts))
	if grid.walkable_cells < grid.width * grid.height / 5:
		Bus.alert_raised.emit(1, &"grid_cramped", "map is unusually closed in", Vector2.ZERO)


func step(tick: int) -> void:
	if tick % SNOW_INTERVAL == 0:
		_step_snow()
	_flush_cost_changes()


# ---------------------------------------------------------------- world access

## The tile store. Read freely; write only through this system's API.
func world() -> WorldGrid:
	return grid


func core_cell() -> Vector2i:
	return core


func map_hash() -> int:
	return grid.content_hash() if grid != null else 0


func map_size() -> Vector2i:
	return Vector2i(grid.width, grid.height) if grid != null else Vector2i.ZERO


## Narrowest crossing on each approach lane — where a defence line pays off.
func chokepoints() -> Array[Vector2i]:
	return choke_cells


## Where the dark comes in from: one record per old highway.
func approach_lanes() -> Array[Dictionary]:
	return lanes


## Cells an attacker walks toward by default: the warm ground at the centre.
func core_goals() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if grid == null:
		return out
	for c: Vector2i in Grid.disc(core, 4):
		if grid.is_walkable(c):
			out.append(grid.index_of(c))
	if out.is_empty():
		var w: Vector2i = grid.nearest_walkable(core, 40)
		if grid.is_walkable(w):
			out.append(grid.index_of(w))
	return out


# ---------------------------------------------------------------- occupancy

## True when the whole footprint is in bounds, buildable and unclaimed.
func is_free(cell: Vector2i, cell_size: Vector2i) -> bool:
	return grid != null and grid.is_free(cell, cell_size)


## Claims a footprint for a building id. Returns false and changes nothing on failure.
func occupy(cell: Vector2i, cell_size: Vector2i, id: int, blocks_movement: bool = true) -> bool:
	if grid == null:
		return false
	return grid.occupy(cell, cell_size, id, blocks_movement)


## Releases everything a building id claimed.
func release(id: int) -> bool:
	return grid != null and grid.release(id)


## Building id on a tile, or 0.
func building_at(cell: Vector2i) -> int:
	return grid.building_at(cell) if grid != null else 0


func building_rect(id: int) -> Rect2i:
	return grid.building_rect(id) if grid != null else Rect2i()


# ---------------------------------------------------------------- tiles

func terrain_at(cell: Vector2i) -> int:
	return grid.terrain_at(cell)


func elevation_at(cell: Vector2i) -> int:
	return grid.elevation_at(cell)


func snow_at(cell: Vector2i) -> int:
	return grid.snow_at(cell)


func is_walkable(cell: Vector2i) -> bool:
	return grid.is_walkable(cell)


func move_cost(cell: Vector2i) -> int:
	return grid.cost_at(cell)


func resource_kind_at(cell: Vector2i) -> int:
	return grid.resource_kind_at(cell)


func resource_amount_at(cell: Vector2i) -> int:
	return grid.resource_amount_at(cell)


## Takes up to `amount` from a deposit. Returns what was actually removed.
func harvest(cell: Vector2i, amount: int) -> int:
	return grid.harvest(cell, amount)


## Nearest tile of `kind` with something left, or Vector2i(-1,-1).
func nearest_resource(from: Vector2i, kind: int, max_radius: int = 64) -> Vector2i:
	return grid.find_nearest_resource(from, kind, max_radius)


func line_of_sight(a: Vector2i, b: Vector2i) -> bool:
	return grid.line_of_sight(a, b)


## Clears snow around a heat source. [P02] calls this for every warm building.
func melt(cell: Vector2i, radius: int, amount: int) -> void:
	for c: Vector2i in Grid.disc(cell, radius):
		if not grid.in_bounds(c):
			continue
		var s: int = grid.snow_at(c)
		if s <= 0:
			continue
		var falloff: int = maxi(amount - Grid.chebyshev(c, cell) * (amount / maxi(radius, 1)), 0)
		if falloff > 0:
			grid.set_snow(c, s - falloff)


## Snowfall in depth units per second. [P09] climate owns this value.
func set_snowfall(rate: float) -> void:
	snowfall_rate = maxf(rate, 0.0)


# ---------------------------------------------------------------- flow fields

## Adds a named field. Costs one full flood, so create these once, not per agent.
func create_field(field_id: StringName, goals: PackedInt32Array) -> bool:
	if grid == null:
		return false
	if _fields.has(field_id):
		return set_field_goals(field_id, goals)
	if _fields.size() >= MAX_FIELDS:
		Log.warn("grid", "refused flow field '%s': %d is the cap" % [field_id, MAX_FIELDS])
		return false
	var f := FlowField.new()
	if not f.setup(grid.width, grid.height, field_id):
		return false
	f.set_goals(goals)
	f.rebuild(grid.cost)
	_fields[field_id] = f
	# Insertion order, never a StringName sort: pointer ordering is not stable.
	_field_order.append(field_id)
	Log.debug("grid", "flow field '%s': %d goals, %d cells" % [field_id, goals.size(), f.last_visited])
	return true


## Points an existing field at new goals and re-floods it.
func set_field_goals(field_id: StringName, goals: PackedInt32Array) -> bool:
	var f: FlowField = _fields.get(field_id)
	if f == null:
		return false
	f.set_goals(goals)
	f.rebuild(grid.cost)
	return true


func has_field(field_id: StringName) -> bool:
	return _fields.has(field_id)


func get_field(field_id: StringName) -> FlowField:
	return _fields.get(field_id)


## One step toward the city core from this tile. ZERO means "already there or no path".
func flow_direction(cell: Vector2i) -> Vector2i:
	return flow_direction_for(CORE_FIELD, cell)


func flow_direction_for(field_id: StringName, cell: Vector2i) -> Vector2i:
	var f: FlowField = _fields.get(field_id)
	if f == null or not grid.in_bounds(cell):
		return Grid.ZERO
	return f.step_at(grid.index_of(cell))


## Blended flow at a world position — use this to move units smoothly.
func flow_steer(world_pos: Vector2, field_id: StringName = CORE_FIELD) -> Vector2:
	var f: FlowField = _fields.get(field_id)
	return Vector2.ZERO if f == null else f.steer(world_pos)


## Accumulated travel cost from a tile to the field's goal (tenths of a tile).
func flow_distance(cell: Vector2i, field_id: StringName = CORE_FIELD) -> int:
	var f: FlowField = _fields.get(field_id)
	if f == null or not grid.in_bounds(cell):
		return FlowField.UNREACHABLE
	return f.integration_at(grid.index_of(cell))


func is_reachable(cell: Vector2i, field_id: StringName = CORE_FIELD) -> bool:
	var f: FlowField = _fields.get(field_id)
	return f != null and grid.in_bounds(cell) and f.reachable(grid.index_of(cell))


## Forces a region back through cost recompute and flow repair. Call it after
## changing terrain behind the grid's back, or when a rebuild looks stale.
func request_rebuild(region: Rect2i) -> int:
	if grid == null:
		return 0
	return grid.mark_region_dirty(region)


## One-off A* for an agent walking to a specific door rather than following the
## crowd. Flow fields handle the many; this handles the one. Empty when no path.
func find_path(from: Vector2i, to: Vector2i, max_nodes: int = 6000) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if grid == null or not grid.in_bounds(from) or not grid.in_bounds(to):
		return out
	var start: int = grid.index_of(from)
	var goal: int = grid.index_of(to)
	if grid.cost[start] == Grid.IMPASSABLE or grid.cost[goal] == Grid.IMPASSABLE:
		return out
	if start == goal:
		out.append(from)
		return out

	var w: int = grid.width
	var offs: PackedInt32Array = PackedInt32Array([1, 1 + w, w, -1 + w, -1, -1 - w, -w, 1 - w])
	var open: Array[int] = []
	var g_score: Dictionary[int, int] = {start: 0}
	var came: Dictionary[int, int] = {}
	var closed: Dictionary[int, bool] = {}
	_heap_push(open, (Grid.octile_cost(from, to) << FlowField.IDX_BITS) | start)
	var expanded: int = 0

	while not open.is_empty() and expanded < max_nodes:
		var top: int = _heap_pop(open)
		var cur: int = top & FlowField.IDX_MASK
		if closed.has(cur):
			continue
		closed[cur] = true
		expanded += 1
		if cur == goal:
			var node: int = goal
			while node != start:
				out.append(grid.cell_of(node))
				node = came[node]
			out.append(from)
			out.reverse()
			return out
		var gc: int = int(g_score[cur])
		for d: int in range(8):
			var n: int = cur + offs[d]
			if n < 0 or n >= grid.cost.size():
				continue
			var cn: int = grid.cost[n]
			if cn == Grid.IMPASSABLE or closed.has(n):
				continue
			var diag: bool = (d & 1) == 1
			if diag:
				if grid.cost[cur + offs[(d + 1) & 7]] == Grid.IMPASSABLE:
					continue
				if grid.cost[cur + offs[(d - 1) & 7]] == Grid.IMPASSABLE:
					continue
			var ng: int = gc + cn * (FlowField.W_DIAG if diag else FlowField.W_ORTHO)
			if g_score.has(n) and ng >= int(g_score[n]):
				continue
			g_score[n] = ng
			came[n] = cur
			var f: int = ng + Grid.octile_cost(grid.cell_of(n), to)
			_heap_push(open, (f << FlowField.IDX_BITS) | n)
	return out


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


# ---------------------------------------------------------------- per tick

func _step_snow() -> void:
	if grid == null or snowfall_rate <= 0.0:
		return
	var total: int = grid.chunk_count()
	if total == 0:
		return
	var per_pass: int = mini(SNOW_CHUNKS_PER_PASS, total)
	# Seconds of weather each visited chunk has been waiting for.
	var elapsed: float = float(total) / float(per_pass) * float(SNOW_INTERVAL) * SimClock.DT
	_snow_carry += snowfall_rate * elapsed
	var delta: int = int(_snow_carry)
	if delta <= 0:
		return
	_snow_carry -= float(delta)
	for _i: int in range(per_pass):
		grid.accumulate_snow(_snow_cursor, delta, snow_cap)
		_snow_cursor = (_snow_cursor + 1) % total


func _flush_cost_changes() -> void:
	_flush_us = 0
	_flush_cells = 0
	_flow_cells = 0
	if grid == null or _field_order.is_empty():
		return
	# Wall-clock is read here and NOWHERE else. It is a LOG line only: it must
	# never reach metrics(), because tools/determinism.sh diffs metrics.csv and a
	# wall-clock column in a diffed artifact is a tripwire waiting for the first
	# scenario with pathfinding churn on a sampled tick.
	var t0: int = Time.get_ticks_usec()

	# A field mid-flood is finished before any new cost change is looked at.
	# Taking new dirty cells now would reset the wavefront it is standing on, and
	# the changes are perfectly happy to wait one more tick in grid's dirty set —
	# that back-pressure is the point.
	var still_flooding: bool = false
	for n: StringName in _field_order:
		var f: FlowField = _fields[n]
		if f.unfinished:
			f.resume(grid.cost, FLOW_BUDGET)
			_flow_cells += f.last_visited
			still_flooding = still_flooding or f.unfinished
	if still_flooding:
		_flush_us = Time.get_ticks_usec() - t0
		_flush_cells = 0
		if _flush_us > SLOW_REPAIR_US:
			Log.debug("grid", "flow flood continued: %d cells in %.2f ms" % [
				_flow_cells, float(_flush_us) / 1000.0])
		return
	if grid.dirty_count() == 0:
		return

	var dirty: PackedInt32Array = grid.take_dirty(COST_BUDGET)
	for n: StringName in _field_order:
		var f: FlowField = _fields[n]
		f.update(grid.cost, dirty, FLOW_BUDGET)
		_flow_cells += f.last_visited
	_flush_us = Time.get_ticks_usec() - t0
	_flush_cells = dirty.size()
	if _flush_us > SLOW_REPAIR_US:
		Log.debug("grid", "flow repair: %d cells over %d field(s) in %.2f ms" % [
			_flush_cells, _field_order.size(), float(_flush_us) / 1000.0])


# ---------------------------------------------------------------- commands

## Scenario / debug hooks. The real API above is what other systems call.
func handle_command(cmd: Dictionary) -> void:
	var op: String = String(cmd.get("op", ""))
	match op:
		"occupy":
			var c: Vector2i = _to_cell(cmd.get("cell", []))
			var s: Vector2i = _to_cell(cmd.get("size", [1, 1]))
			occupy(c, s, int(cmd.get("id", 0)), bool(cmd.get("blocks", true)))
		"release":
			release(int(cmd.get("id", 0)))
		"melt":
			melt(_to_cell(cmd.get("cell", [])), int(cmd.get("radius", 3)), int(cmd.get("amount", 60)))
		"snowfall":
			set_snowfall(float(cmd.get("rate", 0.3)))
		"rebuild":
			var r: Array = cmd.get("rect", [])
			if r.size() == 4:
				request_rebuild(Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3])))
		_:
			Log.warn("grid", "unknown command op '%s'" % op)


static func _to_cell(v: Variant) -> Vector2i:
	if typeof(v) == TYPE_ARRAY:
		var a: Array = v
		if a.size() >= 2:
			return Vector2i(int(a[0]), int(a[1]))
	return Vector2i.ZERO


# ---------------------------------------------------------------- persistence

func serialize() -> Dictionary:
	var lane_data: Array = []
	for l: Dictionary in lanes:
		lane_data.append({
			"entry": int(l.get("entry", -1)),
			"choke": int(l.get("choke", -1)),
			"width": int(l.get("width", 0)),
		})
	var choke_data: PackedInt32Array = PackedInt32Array()
	for c: Vector2i in choke_cells:
		choke_data.append(c.x)
		choke_data.append(c.y)
	var field_data: Array = []
	for n: StringName in _field_order:
		field_data.append({"name": String(n), "goals": Array(_fields[n].goals)})
	return {
		"biome": String(biome_id),
		"core": [core.x, core.y],
		"hash": map_hash(),
		"snowfall": snowfall_rate,
		"snow_cursor": _snow_cursor,
		"snow_carry": _snow_carry,
		"lanes": lane_data,
		"chokepoints": Array(choke_data),
		"stats": mapgen_stats,
		"world": grid.serialize(),
	}


func deserialize(data: Dictionary) -> void:
	biome_id = StringName(String(data.get("biome", "frozen_basin")))
	core = _to_cell(data.get("core", []))
	snowfall_rate = float(data.get("snowfall", 0.3))
	_snow_cursor = int(data.get("snow_cursor", 0))
	_snow_carry = float(data.get("snow_carry", 0.0))
	grid = WorldGrid.new()
	if not grid.deserialize(data.get("world", {})):
		Log.error("grid", "world payload rejected; keeping generated map")
		return
	lanes.clear()
	for l: Variant in data.get("lanes", []):
		var d: Dictionary = l
		lanes.append({
			"entry": int(d.get("entry", -1)),
			"choke": int(d.get("choke", -1)),
			"width": int(d.get("width", 0)),
			"heading": 0.0,
			"path": PackedInt32Array(),
		})
	choke_cells.clear()
	var raw: Array = data.get("chokepoints", [])
	var i: int = 0
	while i + 1 < raw.size():
		choke_cells.append(Vector2i(int(raw[i]), int(raw[i + 1])))
		i += 2
	mapgen_stats = data.get("stats", {})
	_fields.clear()
	_field_order.clear()
	create_field(CORE_FIELD, core_goals())
	Log.info("grid", "world restored: %dx%d, hash %d" % [grid.width, grid.height, map_hash()])


func metrics() -> Dictionary:
	if grid == null:
		return {"tiles_dirty": 0, "chunks": 0}
	# No wall-clock column here on purpose — see _flush_cost_changes.
	return {
		"tiles_dirty": grid.dirty_count(),
		"chunks": grid.chunk_count(),
		"cells_repaired": _flush_cells,
		"flow_cells": _flow_cells,
		"walkable": grid.walkable_cells,
		"buildings": grid.building_count(),
	}


# ---------------------------------------------------------------- internal

func _load_profile() -> BiomeProfile:
	var res: Resource = Registry.get_item("biomes", requested_biome)
	var p := res as BiomeProfile
	if p == null:
		var all: Array[Resource] = Registry.all("biomes")
		if all.size() > 0:
			p = all[0] as BiomeProfile
	if p == null:
		Log.warn("grid", "no biome '%s' in content; using built-in defaults" % requested_biome)
		return BiomeProfile.fallback()
	if p.deposits.is_empty():
		Log.warn("grid", "biome '%s' has no deposits authored" % p.id)
	return p
