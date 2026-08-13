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
## 256x256 map is sixteen ticks end to end, so a wall the PLAYER takes down is in
## the field within a second; a wall COMBAT takes down is in it immediately,
## through note_cells. Kept modest because a district going up keeps the cost
## counter moving, and a sweep that never completes runs every tick.
const SCAN_SLICE: int = 4096
## Cells repaired into the flow field per tick. Bounds the worst case when a
## whole district is placed or flattened on one tick.
const MAX_REPAIR_CELLS: int = 256

## Cells of setup work done per slice while the surface is being PREPARED, and
## cells the first flood may settle per slice.
##
## Building this surface in one call cost 83 ms on a 256x256 map — the largest
## single spike anywhere in the build, one and a half whole tick budgets, five
## dropped frames. It is not urgent work: the trigger is "dusk is coming", not
## "something is standing on it". So it is paid in slices instead, starting two
## minutes before nightfall, and the peak becomes a rounding error. The
## synchronous path still exists ([method build]) and is taken only when a body
## appears on a map that has no surface yet, because a wrong answer now is worse
## than a slow one.
## Measured, not guessed: a settled cell costs about 1.4 us here, so 9000 cells
## in a slice was still a 13 ms tick. 2500 keeps every slice inside a third of a
## millisecond of the rest of combat's budget and finishes a 256x256 map in about
## a second and a half — against two minutes of warning.
const SETUP_SLICE: int = 16384
const FLOOD_SLICE: int = 2500
## Cells the in-night repair may settle per tick. Same reasoning: repairing a
## breach in one unbudgeted call cost 24 ms, three times in one night, because
## `update` only honours its own RAISE_LIMIT escape hatch when it is given a
## budget. With one, a repair whose shadow is bigger than a fresh flood becomes
## a budgeted full rebuild behind the shadow buffer, which is exactly what
## [FlowField] built that buffer for.
const REPAIR_BUDGET: int = 2500

enum Phase { IDLE, TERRAIN, COST, FLOOD }

var ready: bool = false
## True while the surface is being prepared in slices. Queries must not use it.
var building: bool = false
var field: FlowField = null
## Assault-side movement cost, cell for cell with [WorldGrid.cost].
var cost: PackedByteArray = PackedByteArray()

var full_rebuilds: int = 0
var repairs: int = 0
var cells_repaired: int = 0
var last_visited: int = 0
## Slices the current (or last) preparation took. Log and metrics only.
var build_slices: int = 0

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
var _phase: int = Phase.IDLE
var _cursor: int = 0
var _grid: SimSystem = null


## Builds the surface and floods it in ONE call. The synchronous path: correct
## the instant it returns, and expensive. Everything that can see dusk coming
## uses [method begin] + [method advance] instead.
func build(grid_system: SimSystem) -> bool:
	if ready:
		return true
	if not begin(grid_system):
		return false
	# 0 = no limit on either phase, so this finishes inside one call.
	while not advance(0, 0):
		if not building:
			return false
	return ready


## Starts preparing the surface. Cheap: allocates the arrays and snapshots the
## grid, then leaves the work to [method advance]. Returns false when [P01] is
## absent, in which case nothing was started.
func begin(grid_system: SimSystem) -> bool:
	if ready or building:
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

	_grid = grid_system
	# A snapshot, not a live read: every slice below must see ONE version of the
	# map or the cost array and the terrain mask disagree about the same cell.
	# Anything the grid changes mid-preparation is picked up by the ordinary
	# sweep afterwards, because _seen_version is stamped here.
	_shadow = gc.duplicate()
	_static_block = PackedByteArray()
	_static_block.resize(_size)
	cost = PackedByteArray()
	cost.resize(_size)
	field = FlowField.new()
	if not field.setup(_w, _h, &"assault"):
		return false
	_scan_cursor = 0
	_sweep_target = -1
	_seen_version = int(world.get("cost_changes_total"))
	_phase = Phase.TERRAIN
	_cursor = 0
	build_slices = 0
	building = true
	return true


## One slice of preparation. Returns true once the surface is usable.
## A slice size of 0 means "no limit", which is what [method build] passes.
func advance(setup_slice: int = SETUP_SLICE, flood_slice: int = FLOOD_SLICE) -> bool:
	if ready:
		return true
	if not building:
		return false
	build_slices += 1
	match _phase:
		Phase.TERRAIN:
			var stop: int = _size if setup_slice <= 0 else mini(_cursor + setup_slice, _size)
			var i: int = _cursor
			while i < stop:
				_static_block[i] = 1 if _shadow[i] == Grid.IMPASSABLE else 0
				i += 1
			_cursor = stop
			if _cursor >= _size:
				# Everything a player put down is diggable; everything else that
				# refuses passage is terrain, and terrain stays refused.
				_unmark_buildings(_grid)
				_phase = Phase.COST
				_cursor = 0
		Phase.COST:
			var stop2: int = _size if setup_slice <= 0 else mini(_cursor + setup_slice, _size)
			var j: int = _cursor
			while j < stop2:
				var c: int = _shadow[j]
				cost[j] = c if (c != Grid.IMPASSABLE or _static_block[j] == 1) else DIG_COST
				j += 1
			_cursor = stop2
			if _cursor >= _size:
				field.set_goals(_grid.call("core_goals"))
				field.rebuild(cost, maxi(0, flood_slice))
				full_rebuilds += 1
				last_visited = field.last_visited
				_phase = Phase.FLOOD
		Phase.FLOOD:
			if field.unfinished:
				field.resume(cost, maxi(0, flood_slice))
				last_visited = field.last_visited
		_:
			building = false
			return false
	if _phase == Phase.FLOOD and not field.unfinished:
		_phase = Phase.IDLE
		building = false
		ready = true
	return ready


## True while the surface is neither ready nor being prepared.
func idle() -> bool:
	return not ready and not building


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
		"building": building,
		"build_slices": build_slices,
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


## Repairs the field for the cells that changed, in bounded batches.
##
## A flood is proportional to the SHADOW of the change, not to the number of
## cells handed in, so a mass placement — a hundred metres of wall going up in
## one tick — can cost tens of milliseconds if it is repaired in one go. Capping
## the batch spreads that over a few ticks the way [P01] caps its own cost flush;
## the cells still waiting are already stale, so nothing is lost by making them
## wait one tick longer.
func _flush() -> void:
	# A flood still in flight is finished before any new change is fed in:
	# raising cells on top of a suspended wavefront would leave stale-low
	# integrations the resumed flood refuses to improve, which is silently wrong
	# rather than merely late. The cells waiting in _pending are already applied
	# to `cost`, so nothing is lost by making them wait a tick.
	if field.unfinished:
		field.resume(cost, REPAIR_BUDGET)
		last_visited = field.last_visited
		return
	if _pending.is_empty():
		return
	var batch: PackedInt32Array = _pending
	if _pending.size() > MAX_REPAIR_CELLS:
		batch = _pending.slice(0, MAX_REPAIR_CELLS)
		_pending = _pending.slice(MAX_REPAIR_CELLS)
	else:
		_pending = PackedInt32Array()
	field.update(cost, batch, REPAIR_BUDGET)
	repairs += 1
	cells_repaired += batch.size()
	last_visited = field.last_visited


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
