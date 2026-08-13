class_name AssaultField
extends RefCounted
## The map as an attacker reads it: a second cost surface where **a wall is
## expensive, not impossible**, and a [FlowField] flooded over it.
##
## Why a second surface at all. [P01]'s core field treats every structure as
## solid, which is exactly right for citizens and exactly wrong for a siege: the
## moment the player closes the last gap in the perimeter, that field says
## "unreachable" and five hundred attackers stand still. Here a wall costs
## [constant DIG_COST] instead of infinity, so the field always reaches the core
## and its gradient points at the cheapest way in. Sealed city, and the answer is
## "through the thinnest, most damaged panel"; a gap left open, and the open route
## is cheaper anyway, so nobody digs.
##
## That is also where "prefer weak points" stops being a special case: a wall
## that has taken half its hit points has its dig cost halved ([method weaken]),
## so the gradient bends toward the breach and the pack converges on it without a
## single line of squad AI.
##
## Cost control, in the order it matters:
##   * **Lazy.** Nothing here exists until the first enemy spawns. A scenario with
##     no combat in it pays exactly zero.
##   * **Version-gated.** The map is only re-scanned while [WorldGrid]'s
##     cost-change counter is moving. A quiet minute costs one integer compare.
##   * **Sliced.** A sweep looks at [constant SCAN_SLICE] cells per tick, and the
##     cells combat itself breaks are pushed in immediately, so the case that
##     matters — a breach opening — is reflected on the same tick it happens.
##   * **Repaired, never rebuilt.** [FlowField.update] re-floods only the shadow
##     of the change.

## Movement cost of a cell held by an intact player structure. Chosen against a
## hard constraint: [FlowField] is a Dial's-algorithm queue with a 512-wide
## bucket window, so no single edge may exceed 511. The worst edge is a diagonal
## step, cost * 14, which caps any cell at 36. Digging is therefore "about three
## and a half tiles of detour" and the open route wins whenever one exists —
## which is the correct reading anyway, because attackers only tunnel when the
## city has actually sealed itself in.
const DIG_COST: int = 34
## What a structure below CombatTypes.BREACH_HEALTH costs instead.
const WEAK_COST: int = 15
## What an open gate costs: roughly clear ground, so the siege prefers it to
## every wall around it and to every detour.
const GATE_OPEN_COST: int = 10
## Cells compared against the live grid per tick while a sweep is running. A
## 256x256 map is eight ticks end to end, so a wall the PLAYER takes down is in
## the field within half a second; a wall COMBAT takes down is in it immediately,
## through note_cells.
const SCAN_SLICE: int = 8192

var ready: bool = false
var field: FlowField = null
## Assault-side movement cost, cell for cell with [WorldGrid.cost].
var cost: PackedByteArray = PackedByteArray()

var full_rebuilds: int = 0
var repairs: int = 0
var cells_repaired: int = 0
var last_visited: int = 0

var _w: int = 0
var _h: int = 0
var _size: int = 0
## 1 where the ground itself refuses passage (ridge, chasm, the border ring).
## Those never become diggable, no matter what the player builds on them.
var _static_block: PackedByteArray = PackedByteArray()
## Last seen copy of the grid's cost array, so a sweep can spot what moved.
var _shadow: PackedByteArray = PackedByteArray()
var _pending: PackedInt32Array = PackedInt32Array()
var _scan_cursor: int = 0
var _sweep_target: int = -1
var _seen_version: int = -1
var _weakened: Dictionary[int, bool] = {}
var _open_gates: Dictionary[int, bool] = {}


## Builds the surface and floods it once. Call at the first spawn, not at world
## creation — see the class docs. Returns false when [P01] is absent.
func build(grid_system: SimSystem) -> bool:
	if ready:
		return true
	if grid_system == null or not grid_system.has_method("world"):
		return false
	var world: Object = grid_system.call("world")
	if world == null:
		return false
	_w = int(world.get("width"))
	_h = int(world.get("height"))
	_size = _w * _h
	if _size <= 0:
		return false
	var gc: PackedByteArray = world.get("cost")
	if gc.size() != _size:
		return false

	_static_block = PackedByteArray()
	_static_block.resize(_size)
	for i: int in range(_size):
		_static_block[i] = 1 if gc[i] == Grid.IMPASSABLE else 0
	# Everything a player put down is diggable; everything else that refuses
	# passage is terrain, and terrain stays refused.
	_unmark_buildings(grid_system)

	cost = PackedByteArray()
	cost.resize(_size)
	for i2: int in range(_size):
		var c: int = gc[i2]
		cost[i2] = c if (c != Grid.IMPASSABLE or _static_block[i2] == 1) else DIG_COST
	_shadow = gc.duplicate()

	field = FlowField.new()
	if not field.setup(_w, _h, &"assault"):
		return false
	var goals: PackedInt32Array = grid_system.call("core_goals")
	field.set_goals(goals)
	field.rebuild(cost)
	full_rebuilds += 1
	last_visited = field.last_visited
	_scan_cursor = 0
	_sweep_target = -1
	_seen_version = int(world.get("cost_changes_total"))
	ready = true
	return true


## Re-points the field at a new goal set and re-floods. Only for a moved core.
func set_goals(goals: PackedInt32Array) -> void:
	if not ready:
		return
	field.set_goals(goals)
	field.rebuild(cost)
	full_rebuilds += 1
	last_visited = field.last_visited


## One tick of upkeep. Cheap when the map is quiet: a single integer compare
## unless [WorldGrid] has actually changed a movement cost since the last sweep.
func maintain(grid_system: SimSystem) -> void:
	if not ready or grid_system == null:
		return
	var world: Object = grid_system.call("world")
	if world == null:
		return
	var version: int = int(world.get("cost_changes_total"))
	if _sweep_target < 0:
		if version == _seen_version:
			_flush()
			return
		_sweep_target = version
		_scan_cursor = 0
	var gc: PackedByteArray = world.get("cost")
	if gc.size() != _size:
		return
	var stop: int = mini(_scan_cursor + SCAN_SLICE, _size)
	var i: int = _scan_cursor
	while i < stop:
		var c: int = gc[i]
		if c != _shadow[i]:
			_shadow[i] = c
			_apply(i, c)
		i += 1
	_scan_cursor = stop
	if _scan_cursor >= _size:
		_scan_cursor = 0
		_seen_version = _sweep_target
		_sweep_target = -1
	_flush()


## Pushes a set of cells through immediately instead of waiting for the sweep to
## reach them. Combat calls this the instant it breaks a structure, because the
## one repath that must not lag is the breach the player just lost.
func note_cells(grid_system: SimSystem, cells: Array[Vector2i]) -> void:
	if not ready or grid_system == null or cells.is_empty():
		return
	var world: Object = grid_system.call("world")
	if world == null:
		return
	var gc: PackedByteArray = world.get("cost")
	if gc.size() != _size:
		return
	for cell: Vector2i in cells:
		if cell.x < 0 or cell.y < 0 or cell.x >= _w or cell.y >= _h:
			continue
		var idx: int = cell.y * _w + cell.x
		_shadow[idx] = gc[idx]
		_apply(idx, gc[idx])


## Marks a damaged structure as a soft spot: its cells become cheaper to dig, so
## the field itself starts pointing at the breach. Idempotent per building.
func weaken(building_id: int, cells: Array[Vector2i]) -> void:
	if not ready or _weakened.has(building_id):
		return
	_weakened[building_id] = true
	for cell: Vector2i in cells:
		if cell.x < 0 or cell.y < 0 or cell.x >= _w or cell.y >= _h:
			continue
		var idx: int = cell.y * _w + cell.x
		if cost[idx] != DIG_COST:
			continue
		cost[idx] = WEAK_COST
		_pending.append(idx)


func forget(building_id: int) -> void:
	_weakened.erase(building_id)
	_open_gates.erase(building_id)


## An OPEN gate is a hole as far as the siege is concerned: its cells cost what
## the ground under them costs, so the gradient runs straight through it and the
## pack walks in rather than digging. Closing it puts the dig cost back. That is
## the whole gate mechanic — the player decides, every dusk, whether the road
## their citizens use is worth the door being shut.
func set_gate_open(building_id: int, cells: Array[Vector2i], open: bool) -> void:
	if not ready:
		return
	if bool(_open_gates.get(building_id, false)) == open:
		return
	_open_gates[building_id] = open
	for cell: Vector2i in cells:
		if cell.x < 0 or cell.y < 0 or cell.x >= _w or cell.y >= _h:
			continue
		var idx: int = cell.y * _w + cell.x
		var want: int = GATE_OPEN_COST if open else DIG_COST
		if cost[idx] == want:
			continue
		cost[idx] = want
		_pending.append(idx)


func gate_is_open(building_id: int) -> bool:
	return bool(_open_gates.get(building_id, false))


## One step toward the core from a flat cell index, honouring dig routes.
## Grid.ZERO when the cell is off the field or already at the goal.
func step_at(cell: Vector2i) -> Vector2i:
	if not ready or cell.x < 0 or cell.y < 0 or cell.x >= _w or cell.y >= _h:
		return Grid.ZERO
	return field.step_at(cell.y * _w + cell.x)


## Accumulated dig-aware travel cost from a cell to the core. Turrets sort their
## targets on this: "first" means furthest along the way in, not nearest.
func distance_at(cell: Vector2i) -> int:
	if not ready or cell.x < 0 or cell.y < 0 or cell.x >= _w or cell.y >= _h:
		return FlowField.UNREACHABLE
	return field.integration_at(cell.y * _w + cell.x)


func pending_count() -> int:
	return _pending.size()


func stats() -> Dictionary:
	return {
		"ready": ready,
		"full_rebuilds": full_rebuilds,
		"repairs": repairs,
		"cells_repaired": cells_repaired,
		"weak_points": _weakened.size(),
		"open_gates": _open_gates.size(),
		"sweeping": _sweep_target >= 0,
	}


# ---------------------------------------------------------------- internals --

func _apply(idx: int, grid_cost: int) -> void:
	var want: int = grid_cost
	if grid_cost == Grid.IMPASSABLE and _static_block[idx] == 0:
		want = DIG_COST
	elif grid_cost == Grid.IMPASSABLE:
		want = Grid.IMPASSABLE
	if cost[idx] == want:
		return
	cost[idx] = want
	_pending.append(idx)


func _flush() -> void:
	if _pending.is_empty():
		return
	field.update(cost, _pending)
	repairs += 1
	cells_repaired += _pending.size()
	last_visited = field.last_visited
	_pending = PackedInt32Array()


## Every cell a player structure sits on stops counting as terrain. Runs once,
## over the building list rather than over the map, because a hundred buildings
## is cheaper to walk than sixty-five thousand tiles.
func _unmark_buildings(grid_system: SimSystem) -> void:
	var build: SimSystem = Sim.get_system(&"build")
	if build != null and build.has_method("all_buildings"):
		var raw: Variant = build.call("all_buildings")
		if typeof(raw) == TYPE_ARRAY:
			for entry: Variant in (raw as Array):
				var b: Object = entry
				if b == null:
					continue
				var cells: Variant = b.get("cells")
				if typeof(cells) != TYPE_ARRAY:
					continue
				for c: Vector2i in (cells as Array):
					if c.x < 0 or c.y < 0 or c.x >= _w or c.y >= _h:
						continue
					_static_block[c.y * _w + c.x] = 0
		return
	# No [P11] in this build: fall back to the grid's own occupancy record.
	if not grid_system.has_method("world"):
		return
	var world: Object = grid_system.call("world")
	if world == null or not world.has_method("building_ids"):
		return
	for id: int in (world.call("building_ids") as PackedInt32Array):
		var r: Rect2i = world.call("building_rect", id)
		for y: int in range(r.position.y, r.end.y):
			for x: int in range(r.position.x, r.end.x):
				if x < 0 or y < 0 or x >= _w or y >= _h:
					continue
				_static_block[y * _w + x] = 0
