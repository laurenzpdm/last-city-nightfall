class_name BuildSystem
extends SimSystem
## [P11] Build & Construction — placement, ghosts, the construction queue,
## blueprints and undo.
##
## Everything the player builds passes through here, so this system is also the
## registry of what physically exists in the city: heat asks it for conduits,
## combat asks it for turrets, citizens ask it for housing. Read through the
## public API at the bottom of this file; never poke the private dictionaries.
##
## Commands arrive via `Sim.submit_command({"system": &"build", "op": ..., ...})`.
## Every rejection carries a reason string the UI can put in front of the player —
## a placement never fails silently.

const CATEGORY: String = "buildings"

## Sites that can receive build power on one tick. Everything else waits, which
## is what makes a long build queue feel like a decision instead of a formality.
const MAX_CONCURRENT_SITES: int = 4
## Sites considered for a materials delivery per tick, from the front of the queue.
## Materials concentrate on the head of the queue instead of smearing over 200 ghosts.
const DELIVERY_LOOKAHEAD: int = 8
## Build work per tick before any citizens help.
const BASE_BUILD_POWER: float = 2.0
## Extra build work per idle citizen assigned to construction.
const POWER_PER_BUILDER: float = 0.5
## Demolition sites progressed per tick.
const MAX_CONCURRENT_DEMOLITIONS: int = 4
## Fraction of full hp a fresh ghost starts with.
const GHOST_HP_FRACTION: float = 0.05
## Ticks a site may sit unfed before it complains to the player.
const STALL_WARN_TICKS: int = 120
## Fraction of the build cost a full repair charges.
const REPAIR_COST_FACTOR: float = 0.6

## Bootstrap materials so minute one is playable. Ignored the moment another
## system claims the city inventory — see BuildStock's provider contract.
const STARTING_STOCK: Dictionary = {
	&"scrap": 320,
	&"iron_plate": 140,
	&"stone": 220,
	&"timber": 180,
	&"copper_coil": 40,
	&"gear": 36,
	&"coal": 200,
}

## Systems asked, in order, whether they own the city inventory.
const STOCK_PROVIDER_CANDIDATES: Array[StringName] = [&"logistics", &"production", &"economy"]

# --------------------------------------------------------------- state ------

## Materials ledger, or the façade over whichever system owns them.
var stock: BuildStock = BuildStock.new()
## Terrain / bounds / ore questions.
var world: BuildWorldQuery = BuildWorldQuery.new()
## The player's blueprint library.
var book: BlueprintBook = BlueprintBook.new()
## Construction order.
var queue: ConstructionQueue = ConstructionQueue.new()

var _defs: Dictionary[StringName, BuildingDef] = {}
var _buildings: Dictionary[int, BuildingInstance] = {}
var _ids: Array[int] = []
var _occupancy: Dictionary[Vector2i, int] = {}
var _kind_counts: Dictionary[StringName, int] = {}
var _demolishing: Array[int] = []
var _pending_demolition: Dictionary[int, BuildAction] = {}
var _undo: BuildUndoStack = BuildUndoStack.new()
var _unlocked: Dictionary[StringName, bool] = {}
var _next_id: int = 1
var _tick: int = 0

## Cell -> connection tags a blueprint currently being stamped will provide.
## Transient, alive only for the duration of one paste: a stamp has to validate
## as a whole, or the first radiator of a pasted heat spur would be refused for
## not touching a pipe that is two entries further down the same stamp.
var _planned_conn: Dictionary[Vector2i, Array] = {}

var _research: SimSystem = null
var _has_tech: bool = false
## [P10] build.speed_mult, refreshed once a second. 1.0 without research.
var _tech_speed: float = 1.0
var _m_unlocked: String = ""
var _citizens: SimSystem = null
var _m_builders: String = ""

var _placed_total: int = 0
var _removed_total: int = 0
var _completed_total: int = 0
var _rejected_total: int = 0
var _destroyed_total: int = 0
## Bumped whenever a finished building is switched on or off. Part of
## roster_version() — see that function for why the number exists at all.
var _switched_total: int = 0
## Nonzero while a sweep — a line drag, an area fill or a blueprint stamp — is
## walking its cells. A sweep is DEFINED to run through whatever already stands
## (a player dragging a belt across a wall lays the rest of the run), so a cell
## it declines is not a command that could never work. Counting both in
## _rejected_total made that number unbandable: the gate could not tell a
## deliberate overdraw from a placement generated at the wrong coordinates.
var _sweep_depth: int = 0
## Cells declined inside a sweep. Reported, never banded at zero.
var _sweep_skipped_total: int = 0


func _init() -> void:
	# Placement resolves before heat (20) so a building created this tick is
	# already part of the network graph the same tick.
	order = 15


func system_name() -> StringName:
	return &"build"


# ------------------------------------------------------------- lifecycle ----

func setup() -> void:
	_defs.clear()
	_buildings.clear()
	_ids.clear()
	_occupancy.clear()
	_kind_counts.clear()
	_demolishing.clear()
	_pending_demolition.clear()
	_unlocked.clear()
	_undo.clear()
	queue.clear()
	book.clear()
	_next_id = 1
	_tick = 0
	_placed_total = 0
	_removed_total = 0
	_completed_total = 0
	_rejected_total = 0
	_destroyed_total = 0
	_switched_total = 0
	_sweep_depth = 0
	_sweep_skipped_total = 0

	stock = BuildStock.new()
	for k: Variant in STARTING_STOCK:
		stock.set_amount(StringName(String(k)), int(STARTING_STOCK[k]))

	_load_defs()


func post_setup() -> void:
	world = BuildWorldQuery.new()
	world.bind(Sim.get_system(&"grid"))
	Log.info("build", "world query: %s" % world.describe())

	for candidate: StringName in STOCK_PROVIDER_CANDIDATES:
		var s: SimSystem = Sim.get_system(candidate)
		if s != null and s.has_method("stock_take") and s.has_method("stock_count") and s.has_method("stock_give"):
			stock.attach_provider(s, candidate)
			Log.info("build", "materials provided by '%s'" % candidate)
			break

	_research = Sim.get_system(&"research")
	if _research != null:
		_m_unlocked = BuildWorldQuery._find(_research, ["is_unlocked", "has_unlock", "unlocked"], 1)
	_citizens = Sim.get_system(&"citizens")
	if _citizens != null:
		_m_builders = BuildWorldQuery._find(_citizens, ["idle_builders", "available_builders", "builder_count"], 0)
	_has_tech = _research != null and _research.has_method("multiplier")

	Log.info("build", "ready: %d definitions, stock '%s', unlocks %s, builders %s" % [
		_defs.size(), String(stock.provider_name()),
		"research" if _m_unlocked != "" else "open",
		_m_builders if _m_builders != "" else "-",
	])


func _load_defs() -> void:
	var problems: int = 0
	for res: Resource in Registry.all(CATEGORY):
		var d := res as BuildingDef
		if d == null:
			Log.warn("build", "content item in %s is not a BuildingDef: %s" % [CATEGORY, res.resource_path])
			continue
		var issues: PackedStringArray = d.validate()
		if issues.size() > 0:
			problems += 1
			Log.warn("build", "definition '%s' — %s" % [String(d.id), ", ".join(issues)])
		_defs[d.id] = d
	Log.info("build", "loaded %d building definitions (%d with warnings)" % [_defs.size(), problems])


# ------------------------------------------------------------------ tick ----

func step(tick: int) -> void:
	_tick = tick
	if _has_tech and tick % 20 == 0:
		var v: Variant = _research.call("multiplier", ResearchDefs.E_BUILD_SPEED_MULT)
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			_tech_speed = clampf(float(v), 0.05, 20.0)
	var order_ids: Array[int] = queue.ids()
	_deliver_materials(order_ids)
	_advance_construction(order_ids)
	_advance_demolition()


## Feeds the head of the queue. A site only starts once it holds everything.
func _deliver_materials(order_ids: Array[int]) -> void:
	var served: int = 0
	for id: int in order_ids:
		if served >= DELIVERY_LOOKAHEAD:
			break
		var b: BuildingInstance = _buildings.get(id)
		if b == null:
			queue.remove(id)
			continue
		if b.state != BuildTypes.State.GHOST:
			continue
		served += 1
		var missing: Dictionary[StringName, int] = b.missing_items()
		if missing.is_empty():
			_begin_construction(b)
			continue
		var got: Dictionary[StringName, int] = stock.take_partial(missing)
		if not got.is_empty():
			BuildTypes.add_items(b.delivered, got)
			if b.fully_supplied():
				_begin_construction(b)
			continue
		if not bool(b.meta.get("stalled", false)) and _tick - b.placed_tick > STALL_WARN_TICKS:
			b.meta["stalled"] = true
			var text: String = "%s is waiting on %s." % [b.def.display_name, BuildTypes.describe_items(missing)]
			Bus.alert_raised.emit(1, &"build_stalled", text, b.world_center())
			Log.debug("build", "site %d stalled: %s" % [b.id, BuildTypes.describe_items(missing)])


## Spends build power down the queue. Sites finish in order, not all at once.
func _advance_construction(order_ids: Array[int]) -> void:
	var power: float = build_power()
	var sites: int = 0
	for id: int in order_ids:
		if sites >= MAX_CONCURRENT_SITES or power <= 0.0:
			break
		var b: BuildingInstance = _buildings.get(id)
		if b == null or b.state != BuildTypes.State.CONSTRUCTING:
			continue
		sites += 1
		var spent: float = minf(1.0, power)
		power -= spent
		b.progress += spent
		b.hp = maxf(b.hp, b.max_hp * maxf(GHOST_HP_FRACTION, b.progress_ratio()))
		if b.progress >= float(b.def.build_time_ticks):
			_complete(b)


func _advance_demolition() -> void:
	if _demolishing.is_empty():
		return
	var done: Array[int] = []
	var n: int = 0
	for id: int in _demolishing:
		if n >= MAX_CONCURRENT_DEMOLITIONS:
			break
		var b: BuildingInstance = _buildings.get(id)
		if b == null or b.state != BuildTypes.State.DECONSTRUCTING:
			done.append(id)
			continue
		n += 1
		b.deconstruct_progress += 1.0
		if b.deconstruct_progress >= float(maxi(1, b.def.demolish_time_ticks)):
			done.append(id)
			_finish_demolition(b)
	for id: int in done:
		_demolishing.erase(id)


## Ticks of build work available this tick. Citizens raise it once [P05] lands.
func build_power() -> float:
	var p: float = BASE_BUILD_POWER
	if _citizens != null and _m_builders != "":
		p += POWER_PER_BUILDER * float(_citizens.call(_m_builders))
	return p * _tech_speed


func _begin_construction(b: BuildingInstance) -> void:
	b.state = BuildTypes.State.CONSTRUCTING
	b.meta.erase("stalled")
	Bus.building_state_changed.emit(b.id, b.state)


func _complete(b: BuildingInstance) -> void:
	b.state = BuildTypes.State.OPERATIONAL
	b.progress = float(b.def.build_time_ticks)
	b.hp = b.max_hp
	b.completed_tick = _tick
	b.meta.erase("stalled")
	queue.remove(b.id)
	if b.def.blocks_movement:
		world.claim(b.rect(), b.id, b.def.blocks_movement)
	_completed_total += 1
	Bus.building_state_changed.emit(b.id, b.state)
	Log.debug("build", "completed %s #%d at %s" % [b.def.display_name, b.id, str(b.cell)])


func _finish_demolition(b: BuildingInstance) -> void:
	var refund: Dictionary[StringName, int] = BuildTypes.scale_items(b.def.refund_items(), b.health_ratio())
	stock.give(refund)
	var act: BuildAction = _pending_demolition.get(b.id)
	if act != null:
		act.payload["refunded"] = BuildTypes.items_to_json(refund)
		act.payload["done"] = true
		_pending_demolition.erase(b.id)
	Log.debug("build", "demolished %s #%d, recovered %s" % [b.def.display_name, b.id, BuildTypes.describe_items(refund)])
	_destroy(b)


# --------------------------------------------------------------- commands ---

## Sim dispatches here. Results go out as Bus signals; use execute() when you
## want the result dictionary back (the UI preview path and the tests do).
func handle_command(cmd: Dictionary) -> void:
	var result: Dictionary = execute(cmd)
	if not bool(result.get("ok", false)):
		# WARN, not debug. A refused command from a scenario or a script is
		# something a human reading log.txt has to be able to see; a player
		# misclick is the same line and costs nothing.
		Log.warn("build", "command '%s' refused: %s" % [String(cmd.get("op", "?")), String(result.get("reason", ""))])


## Runs one build command and reports what happened.
## Always returns {ok: bool, code: StringName, reason: String, ...}.
func execute(cmd: Dictionary) -> Dictionary:
	var op: StringName = StringName(String(cmd.get("op", "")))
	match op:
		&"place", &"build":
			return _op_place(cmd)
		&"place_line":
			return _op_place_line(cmd)
		&"place_area":
			return _op_place_area(cmd)
		&"remove", &"demolish":
			return _op_remove(cmd)
		&"remove_area", &"demolish_area":
			return _op_remove_area(cmd)
		&"cancel":
			return _op_cancel(cmd)
		&"rotate":
			return _op_rotate(cmd)
		&"set_enabled", &"toggle":
			return _op_set_enabled(cmd)
		&"set_priority":
			return _op_set_priority(cmd)
		&"repair":
			return _op_repair(cmd)
		&"capture_blueprint", &"copy":
			return _op_capture_blueprint(cmd)
		&"place_blueprint", &"paste", &"stamp":
			return _op_place_blueprint(cmd)
		&"transform_blueprint":
			return _op_transform_blueprint(cmd)
		&"delete_blueprint":
			return _op_delete_blueprint(cmd)
		&"save_blueprint":
			return _op_save_blueprint(cmd)
		&"load_blueprint":
			return _op_load_blueprint(cmd)
		&"undo":
			return _op_undo()
		&"redo":
			return _op_redo()
		&"add_stock":
			return _op_add_stock(cmd)
		&"set_stock":
			return _op_set_stock(cmd)
		&"grant_unlock":
			return _op_grant_unlock(cmd)
	return _fail(BuildTypes.CODE_BAD_COMMAND, "Unknown build command '%s'." % String(op))


func _op_place(cmd: Dictionary) -> Dictionary:
	var kind: StringName = StringName(String(cmd.get("kind", "")))
	var cell: Vector2i = BuildTypes.to_cell(cmd.get("cell", [0, 0]))
	var rot: int = int(cmd.get("rot", 0))
	var free: bool = bool(cmd.get("free", false))
	var instant: bool = bool(cmd.get("instant", false))
	var as_ghost: bool = bool(cmd.get("ghost", false))
	var meta: Dictionary = cmd.get("meta", {}) if typeof(cmd.get("meta", {})) == TYPE_DICTIONARY else {}

	var check: Dictionary = can_place(kind, cell, rot, not (free or as_ghost))
	if not bool(check["ok"]):
		_reject(cell, check)
		return check

	var def: BuildingDef = _defs[kind]
	var b: BuildingInstance = _create(def, cell, int(check["rot"]), meta)
	var paid: Dictionary[StringName, int] = {}
	if free:
		b.delivered = BuildTypes.to_items(def.cost)
		_begin_construction(b)
	elif not as_ghost:
		var cost: Dictionary[StringName, int] = BuildTypes.to_items(def.cost)
		if stock.take(cost):
			paid = cost
			b.delivered = cost.duplicate()
			_begin_construction(b)
	_undo.push(BuildAction.make(BuildAction.Kind.PLACE, "Place %s" % def.display_name, _tick, {
		"id": b.id, "kind": String(b.kind), "cell": BuildTypes.cell_to_json(b.cell), "rot": b.rot,
	}))
	if instant:
		_force_complete(b)
	return _ok({
		"id": b.id, "kind": String(b.kind), "cell": BuildTypes.cell_to_json(b.cell),
		"rot": b.rot, "paid": BuildTypes.items_to_json(paid), "state": b.state,
	})


## Drags a 1x1 building along an L-shaped path, the way pipes and walls want to
## be placed. Horizontal leg first, then vertical, matching what the cursor did.
func _op_place_line(cmd: Dictionary) -> Dictionary:
	var kind: StringName = StringName(String(cmd.get("kind", "")))
	var def: BuildingDef = def_of(kind)
	if def == null:
		return _fail(BuildTypes.CODE_UNKNOWN_KIND, "There is no building called '%s'." % String(kind))
	if def.size != Vector2i.ONE:
		return _fail(BuildTypes.CODE_BAD_COMMAND, "%s cannot be dragged in a line." % def.display_name)
	var from: Vector2i = BuildTypes.to_cell(cmd.get("from", [0, 0]))
	var to: Vector2i = BuildTypes.to_cell(cmd.get("to", [0, 0]))
	var path: Array[Vector2i] = []
	var step_x: int = signi(to.x - from.x)
	var x: int = from.x
	while x != to.x:
		path.append(Vector2i(x, from.y))
		x += step_x
	var step_y: int = signi(to.y - from.y)
	var y: int = from.y
	while y != to.y:
		path.append(Vector2i(to.x, y))
		y += step_y
	path.append(to)
	return _place_many(def, path, cmd, "Run of %s" % def.display_name)


## Fills a rectangle with a 1x1 building. Foundations, floors, minefields.
func _op_place_area(cmd: Dictionary) -> Dictionary:
	var kind: StringName = StringName(String(cmd.get("kind", "")))
	var def: BuildingDef = def_of(kind)
	if def == null:
		return _fail(BuildTypes.CODE_UNKNOWN_KIND, "There is no building called '%s'." % String(kind))
	if def.size != Vector2i.ONE:
		return _fail(BuildTypes.CODE_BAD_COMMAND, "%s cannot be dragged over an area." % def.display_name)
	var rect: Rect2i = BuildTypes.region_rect(
		BuildTypes.to_cell(cmd.get("from", [0, 0])), BuildTypes.to_cell(cmd.get("to", [0, 0])))
	if rect.size.x * rect.size.y > BuildTypes.MAX_REGION_CELLS:
		return _fail(BuildTypes.CODE_REGION_TOO_LARGE, "That area is too large to fill in one go.")
	var cells: Array[Vector2i] = []
	for cy: int in range(rect.position.y, rect.end.y):
		for cx: int in range(rect.position.x, rect.end.x):
			cells.append(Vector2i(cx, cy))
	return _place_many(def, cells, cmd, "Field of %s" % def.display_name)


func _place_many(def: BuildingDef, cells: Array[Vector2i], cmd: Dictionary, label: String) -> Dictionary:
	var rot: int = int(cmd.get("rot", 0))
	var as_ghost: bool = bool(cmd.get("ghost", false))
	var placed: int = 0
	var skipped: int = 0
	var first_reason: String = ""
	_undo.begin_group(label, _tick)
	_sweep_depth += 1
	for c: Vector2i in cells:
		var sub: Dictionary = cmd.duplicate()
		sub["cell"] = c
		sub["rot"] = rot
		sub["ghost"] = as_ghost
		var r: Dictionary = _op_place(sub)
		if bool(r["ok"]):
			placed += 1
		else:
			skipped += 1
			if first_reason == "":
				first_reason = String(r.get("reason", ""))
	_sweep_depth -= 1
	_undo.end_group()
	if placed == 0:
		return _fail(BuildTypes.CODE_OCCUPIED, first_reason if first_reason != "" else "Nothing could be placed there.")
	Log.info("build", "%s: %d placed, %d skipped" % [label, placed, skipped])
	return _ok({"placed": placed, "skipped": skipped, "reason": first_reason})


func _op_remove(cmd: Dictionary) -> Dictionary:
	var b: BuildingInstance = _resolve_target(cmd)
	if b == null:
		return _fail(BuildTypes.CODE_NO_SUCH_BUILDING, "There is nothing to remove there.")
	return _remove_building(b, bool(cmd.get("instant", false)))


func _op_remove_area(cmd: Dictionary) -> Dictionary:
	var rect: Rect2i = BuildTypes.region_rect(
		BuildTypes.to_cell(cmd.get("from", [0, 0])), BuildTypes.to_cell(cmd.get("to", [0, 0])))
	if rect.size.x * rect.size.y > BuildTypes.MAX_REGION_CELLS:
		return _fail(BuildTypes.CODE_REGION_TOO_LARGE, "That area is too large to demolish in one go.")
	var targets: Array[BuildingInstance] = buildings_in_rect(rect)
	var filter: Array = cmd.get("kinds", [])
	var instant: bool = bool(cmd.get("instant", false))
	if targets.is_empty():
		return _fail(BuildTypes.CODE_EMPTY_REGION, "Nothing to demolish in that area.")
	_undo.begin_group("Demolish %d buildings" % targets.size(), _tick)
	var n: int = 0
	for b: BuildingInstance in targets:
		if filter.size() > 0 and not filter.has(String(b.kind)):
			continue
		if bool(_remove_building(b, instant)["ok"]):
			n += 1
	_undo.end_group()
	if n == 0:
		return _fail(BuildTypes.CODE_EMPTY_REGION, "Nothing in that area could be demolished.")
	return _ok({"removed": n})


func _remove_building(b: BuildingInstance, instant: bool) -> Dictionary:
	var snapshot: Dictionary = b.to_dict()
	var name: String = b.def.display_name

	if not b.is_complete():
		# Cancelling a site always returns everything delivered — the player is
		# undoing an intention, not salvaging a wreck.
		var refund: Dictionary[StringName, int] = b.delivered.duplicate()
		stock.give(refund)
		_undo.push(BuildAction.make(BuildAction.Kind.REMOVE, "Cancel %s" % name, _tick, {
			"snapshot": snapshot, "refunded": BuildTypes.items_to_json(refund), "done": true,
		}))
		_destroy(b)
		return _ok({"id": snapshot["id"], "cancelled": true, "refunded": BuildTypes.items_to_json(refund)})

	if instant or b.def.demolish_time_ticks <= 0:
		var refund2: Dictionary[StringName, int] = BuildTypes.scale_items(b.def.refund_items(), b.health_ratio())
		stock.give(refund2)
		_undo.push(BuildAction.make(BuildAction.Kind.REMOVE, "Demolish %s" % name, _tick, {
			"snapshot": snapshot, "refunded": BuildTypes.items_to_json(refund2), "done": true,
		}))
		_destroy(b)
		return _ok({"id": snapshot["id"], "refunded": BuildTypes.items_to_json(refund2)})

	if b.state == BuildTypes.State.DECONSTRUCTING:
		return _fail(BuildTypes.CODE_BAD_COMMAND, "%s is already being taken apart." % name)

	b.state = BuildTypes.State.DECONSTRUCTING
	b.deconstruct_progress = 0.0
	_insert_sorted(_demolishing, b.id)
	var act: BuildAction = BuildAction.make(BuildAction.Kind.REMOVE, "Demolish %s" % name, _tick, {
		"snapshot": snapshot, "refunded": {}, "done": false,
	})
	_pending_demolition[b.id] = act
	_undo.push(act)
	Bus.building_state_changed.emit(b.id, b.state)
	return _ok({"id": b.id, "deconstructing": true})


func _op_cancel(cmd: Dictionary) -> Dictionary:
	var b: BuildingInstance = _resolve_target(cmd)
	if b == null:
		return _fail(BuildTypes.CODE_NO_SUCH_BUILDING, "There is nothing to cancel there.")
	if b.state == BuildTypes.State.DECONSTRUCTING:
		b.state = BuildTypes.State.OPERATIONAL
		b.deconstruct_progress = 0.0
		_demolishing.erase(b.id)
		var act: BuildAction = _pending_demolition.get(b.id)
		if act != null:
			# The demolition never happened; its undo entry must become inert.
			act.payload["cancelled"] = true
			_pending_demolition.erase(b.id)
		Bus.building_state_changed.emit(b.id, b.state)
		return _ok({"id": b.id, "restored": true})
	if b.is_complete():
		return _fail(BuildTypes.CODE_BAD_COMMAND, "%s is already finished — demolish it instead." % b.def.display_name)
	return _remove_building(b, true)


func _op_rotate(cmd: Dictionary) -> Dictionary:
	var b: BuildingInstance = _resolve_target(cmd)
	if b == null:
		return _fail(BuildTypes.CODE_NO_SUCH_BUILDING, "There is nothing to turn there.")
	if not b.def.rotatable:
		return _fail(BuildTypes.CODE_NOT_ROTATABLE, "%s cannot be turned." % b.def.display_name)
	var target: int = int(cmd["rot"]) if cmd.has("rot") else b.rot + int(cmd.get("delta", 1))
	var new_rot: int = b.def.normalize_rot(target)
	if new_rot == b.rot:
		return _ok({"id": b.id, "rot": b.rot})
	var check: Dictionary = can_place(b.kind, b.cell, new_rot, false, b.id)
	if not bool(check["ok"]):
		_reject(b.cell, check)
		return check
	var from_rot: int = b.rot
	_apply_rotation(b, new_rot)
	_undo.push(BuildAction.make(BuildAction.Kind.ROTATE, "Turn %s" % b.def.display_name, _tick, {
		"id": b.id, "from": from_rot, "to": new_rot,
	}))
	return _ok({"id": b.id, "rot": b.rot})


func _op_set_enabled(cmd: Dictionary) -> Dictionary:
	var b: BuildingInstance = _resolve_target(cmd)
	if b == null:
		return _fail(BuildTypes.CODE_NO_SUCH_BUILDING, "There is nothing there to switch.")
	var on: bool = bool(cmd["on"]) if cmd.has("on") else not b.enabled
	if on == b.enabled:
		return _ok({"id": b.id, "enabled": b.enabled})
	var was: bool = b.enabled
	b.enabled = on
	_switched_total += 1
	if b.is_complete():
		b.state = BuildTypes.State.OPERATIONAL if on else BuildTypes.State.DISABLED
		Bus.building_state_changed.emit(b.id, b.state)
	_undo.push(BuildAction.make(BuildAction.Kind.TOGGLE, "%s %s" % ["Enable" if on else "Disable", b.def.display_name], _tick, {
		"id": b.id, "from": was, "to": on,
	}))
	return _ok({"id": b.id, "enabled": b.enabled})


func _op_set_priority(cmd: Dictionary) -> Dictionary:
	var b: BuildingInstance = _resolve_target(cmd)
	if b == null:
		return _fail(BuildTypes.CODE_NO_SUCH_BUILDING, "There is no construction site there.")
	if not queue.has(b.id):
		return _fail(BuildTypes.CODE_BAD_COMMAND, "%s is not waiting to be built." % b.def.display_name)
	queue.set_priority(b.id, int(cmd.get("priority", 0)))
	return _ok({"id": b.id})


func _op_repair(cmd: Dictionary) -> Dictionary:
	var b: BuildingInstance = _resolve_target(cmd)
	if b == null:
		return _fail(BuildTypes.CODE_NO_SUCH_BUILDING, "There is nothing to repair there.")
	if not b.is_complete():
		return _fail(BuildTypes.CODE_BAD_COMMAND, "%s is not finished yet." % b.def.display_name)
	var deficit: float = 1.0 - b.health_ratio()
	if deficit <= 0.001:
		return _ok({"id": b.id, "repaired": 0.0})
	var price: Dictionary[StringName, int] = BuildTypes.scale_items_up(
		BuildTypes.to_items(b.def.cost), deficit * REPAIR_COST_FACTOR)
	if not stock.take(price):
		return _fail(BuildTypes.CODE_MATERIALS, "Repairing %s needs %s." % [
			b.def.display_name, BuildTypes.describe_items(price)])
	var healed: float = b.max_hp - b.hp
	b.hp = b.max_hp
	Bus.building_state_changed.emit(b.id, b.state)
	return _ok({"id": b.id, "repaired": healed, "paid": BuildTypes.items_to_json(price)})


# ------------------------------------------------------------- blueprints ---

func _op_capture_blueprint(cmd: Dictionary) -> Dictionary:
	var rect: Rect2i = BuildTypes.region_rect(
		BuildTypes.to_cell(cmd.get("from", [0, 0])), BuildTypes.to_cell(cmd.get("to", [0, 0])))
	if rect.size.x * rect.size.y > BuildTypes.MAX_REGION_CELLS:
		return _fail(BuildTypes.CODE_REGION_TOO_LARGE, "That area is too large to copy in one go.")
	var title: String = String(cmd.get("title", "Blueprint"))
	var bp: Blueprint = capture_blueprint(rect, title)
	if bp.entries.is_empty():
		return _fail(BuildTypes.CODE_EMPTY_REGION, "There is nothing to copy in that area.")
	if cmd.has("blueprint_id"):
		bp.id = StringName(String(cmd["blueprint_id"]))
	var id: StringName = book.add(bp)
	Log.info("build", "captured blueprint '%s': %d buildings over %dx%d" % [
		String(id), bp.entry_count(), bp.size.x, bp.size.y])
	return _ok({
		"blueprint": String(id), "entries": bp.entry_count(),
		"size": BuildTypes.cell_to_json(bp.size),
		"cost": BuildTypes.items_to_json(bp.total_cost()),
	})


func _op_place_blueprint(cmd: Dictionary) -> Dictionary:
	var bp: Blueprint = _resolve_blueprint(cmd)
	if bp == null:
		return _fail(BuildTypes.CODE_UNKNOWN_BLUEPRINT, "That blueprint is not in the book.")
	var gone: Array[StringName] = bp.missing_kinds()
	if not gone.is_empty():
		# Quoting a price for content that no longer exists is worse than
		# refusing: the stamp would charge for what it can place and quietly
		# drop the rest.
		return _fail(BuildTypes.CODE_UNKNOWN_BLUEPRINT,
			"Blueprint '%s' refers to buildings that no longer exist: %s." % [
				bp.title, ", ".join(PackedStringArray(gone.map(func(k: StringName) -> String:
					return String(k))))])
	var t: Blueprint = bp.rotated_cw(int(cmd.get("rot", 0)))
	if bool(cmd.get("mirror_x", false)):
		t = t.mirrored_x()
	if bool(cmd.get("mirror_y", false)):
		t = t.mirrored_y()
	var anchor: Vector2i = BuildTypes.to_cell(cmd.get("cell", [0, 0]))
	var solid: bool = bool(cmd.get("instant", false))
	var free: bool = bool(cmd.get("free", false))

	var placed: int = 0
	var skipped: int = 0
	var matched: int = 0
	var first_reason: String = ""
	_plan_connections(t, anchor)
	_undo.begin_group("Paste %s" % t.title, _tick)
	_sweep_depth += 1
	for e: BlueprintEntry in t.entries:
		var target: Vector2i = anchor + e.offset
		var existing: BuildingInstance = building_at(target)
		if existing != null and existing.kind == e.kind and existing.cell == target:
			matched += 1
			continue
		var sub: Dictionary = {
			"op": &"place", "kind": e.kind, "cell": target, "rot": e.rot,
			"ghost": not free, "free": free, "instant": solid, "meta": e.meta,
		}
		var r: Dictionary = _op_place(sub)
		if bool(r["ok"]):
			placed += 1
		else:
			skipped += 1
			if first_reason == "":
				first_reason = String(r.get("reason", ""))
	_sweep_depth -= 1
	_undo.end_group()
	_planned_conn.clear()

	if placed == 0 and matched == 0:
		return _fail(BuildTypes.CODE_OCCUPIED, first_reason if first_reason != "" else "The blueprint does not fit there.")
	var text: String = "Blueprint '%s': %d planned%s." % [
		t.title, placed, ", %d blocked" % skipped if skipped > 0 else ""]
	Bus.alert_raised.emit(1 if skipped > 0 else 0, &"blueprint_stamped", text,
		BuildTypes.world_center(anchor, t.size))
	Log.info("build", text)
	return _ok({"placed": placed, "skipped": skipped, "matched": matched, "reason": first_reason,
		"cost": BuildTypes.items_to_json(t.total_cost())})


## Records what the stamp about to be pasted will offer its own members, so a
## connection rule is judged against the finished layout rather than the order
## the entries happen to be iterated in.
func _plan_connections(bp: Blueprint, anchor: Vector2i) -> void:
	_planned_conn.clear()
	for e: BlueprintEntry in bp.entries:
		var d: BuildingDef = _defs.get(e.kind)
		if d == null or d.connects_as.is_empty():
			continue
		for c: Vector2i in d.cells_at(anchor + e.offset, e.rot):
			_planned_conn[c] = d.connects_as


## Rotates or mirrors a stamp in the book itself, so the player can keep a
## turned version rather than re-applying the transform on every paste.
func _op_transform_blueprint(cmd: Dictionary) -> Dictionary:
	var id: StringName = StringName(String(cmd.get("blueprint", "")))
	var bp: Blueprint = book.get_bp(id)
	if bp == null:
		return _fail(BuildTypes.CODE_UNKNOWN_BLUEPRINT, "That blueprint is not in the book.")
	var gone: Array[StringName] = bp.missing_kinds()
	if not gone.is_empty():
		# Quoting a price for content that no longer exists is worse than
		# refusing: the stamp would charge for what it can place and quietly
		# drop the rest.
		return _fail(BuildTypes.CODE_UNKNOWN_BLUEPRINT,
			"Blueprint '%s' refers to buildings that no longer exist: %s." % [
				bp.title, ", ".join(PackedStringArray(gone.map(func(k: StringName) -> String:
					return String(k))))])
	var t: Blueprint = bp.rotated_cw(int(cmd.get("rot", 0)))
	if bool(cmd.get("mirror_x", false)):
		t = t.mirrored_x()
	if bool(cmd.get("mirror_y", false)):
		t = t.mirrored_y()
	t.id = bp.id
	book.put(t)
	return _ok({"blueprint": String(t.id), "size": BuildTypes.cell_to_json(t.size)})


func _op_delete_blueprint(cmd: Dictionary) -> Dictionary:
	var id: StringName = StringName(String(cmd.get("blueprint", "")))
	if not book.remove(id):
		return _fail(BuildTypes.CODE_UNKNOWN_BLUEPRINT, "That blueprint is not in the book.")
	return _ok({"blueprint": String(id)})


func _op_save_blueprint(cmd: Dictionary) -> Dictionary:
	var id: StringName = StringName(String(cmd.get("blueprint", "")))
	var bp: Blueprint = book.get_bp(id)
	if bp == null:
		return _fail(BuildTypes.CODE_UNKNOWN_BLUEPRINT, "That blueprint is not in the book.")
	var path: String = String(cmd.get("path", "%s/%s.json" % [BlueprintBook.DISK_DIR, String(id)]))
	var err: int = bp.save_to_file(path)
	if err != OK:
		return _fail(BuildTypes.CODE_IO, "Could not write the blueprint to %s (error %d)." % [path, err])
	Log.info("build", "saved blueprint '%s' to %s" % [String(id), path])
	return _ok({"blueprint": String(id), "path": path})


func _op_load_blueprint(cmd: Dictionary) -> Dictionary:
	if cmd.has("dir"):
		var n: int = book.import_dir(String(cmd["dir"]))
		return _ok({"loaded": n})
	var path: String = String(cmd.get("path", ""))
	var id: StringName = book.import_from_disk(path)
	if String(id) == "":
		return _fail(BuildTypes.CODE_IO, "No readable blueprint at %s." % path)
	Log.info("build", "loaded blueprint '%s' from %s" % [String(id), path])
	return _ok({"blueprint": String(id)})


func _resolve_blueprint(cmd: Dictionary) -> Blueprint:
	var raw: Variant = cmd.get("blueprint", null)
	if typeof(raw) == TYPE_DICTIONARY:
		return Blueprint.from_dict(raw)
	var id: StringName = StringName(String(raw if raw != null else ""))
	return book.get_bp(id)


## Copies every building fully inside `rect` into a fresh stamp.
## Partially covered buildings are left out — half a smelter is not a blueprint.
func capture_blueprint(rect: Rect2i, title: String = "Blueprint") -> Blueprint:
	var bp := Blueprint.new()
	bp.title = title
	bp.size = rect.size
	bp.created_tick = _tick
	var entries: Array[BlueprintEntry] = []
	for id: int in _ids:
		var b: BuildingInstance = _buildings[id]
		if b.state == BuildTypes.State.DESTROYED:
			continue
		var r: Rect2i = b.rect()
		if not rect.encloses(r):
			continue
		var e := BlueprintEntry.new()
		e.kind = b.kind
		e.offset = b.cell - rect.position
		e.rot = b.rot
		e.span = b.def.effective_size(b.rot)
		e.fixed = b.def.normalize_rot(1) == b.def.normalize_rot(0)
		e.meta = b.meta.duplicate(true)
		e.meta.erase("stalled")
		entries.append(e)
	bp.entries = entries
	bp.canonicalize()
	return bp


# ------------------------------------------------------------ undo / redo ---

func _op_undo() -> Dictionary:
	var a: BuildAction = _undo.pop_undo()
	if a == null:
		return _fail(BuildTypes.CODE_NOTHING_TO_UNDO, "There is nothing to undo.")
	_invert(a)
	_undo.push_redo(a)
	Log.debug("build", "undo: %s" % a.label)
	return _ok({"label": a.label, "affected": a.affected_count()})


func _op_redo() -> Dictionary:
	var a: BuildAction = _undo.pop_redo()
	if a == null:
		return _fail(BuildTypes.CODE_NOTHING_TO_REDO, "There is nothing to redo.")
	_replay(a)
	_undo.push_undo_silent(a)
	Log.debug("build", "redo: %s" % a.label)
	return _ok({"label": a.label, "affected": a.affected_count()})


func _invert(a: BuildAction) -> void:
	match a.kind:
		BuildAction.Kind.GROUP:
			for i: int in range(a.children.size() - 1, -1, -1):
				_invert(a.children[i])
		BuildAction.Kind.PLACE:
			var b: BuildingInstance = _buildings.get(int(a.payload.get("id", 0)))
			if b == null:
				return
			a.payload["snapshot"] = b.to_dict()
			var refund: Dictionary[StringName, int] = b.delivered.duplicate()
			if b.is_complete():
				refund = BuildTypes.scale_items(refund, b.health_ratio())
			stock.give(refund)
			a.payload["refunded"] = BuildTypes.items_to_json(refund)
			_destroy(b)
		BuildAction.Kind.REMOVE:
			if bool(a.payload.get("cancelled", false)):
				return
			var snap: Dictionary = a.payload.get("snapshot", {})
			var sid: int = int(snap.get("id", 0))
			var existing: BuildingInstance = _buildings.get(sid)
			if existing != null:
				# Still standing, so the demolition had not finished: rewind it.
				existing.state = int(snap.get("state", BuildTypes.State.OPERATIONAL))
				existing.deconstruct_progress = 0.0
				_demolishing.erase(sid)
				_pending_demolition.erase(sid)
				a.payload["cancelled"] = true
				Bus.building_state_changed.emit(sid, existing.state)
				return
			var restored: BuildingInstance = _restore(snap)
			if restored != null:
				stock.take_partial(BuildTypes.to_items(a.payload.get("refunded", {})))
		BuildAction.Kind.ROTATE:
			var rb: BuildingInstance = _buildings.get(int(a.payload.get("id", 0)))
			if rb != null:
				_apply_rotation(rb, int(a.payload.get("from", rb.rot)))
		BuildAction.Kind.TOGGLE:
			var tb: BuildingInstance = _buildings.get(int(a.payload.get("id", 0)))
			if tb != null:
				tb.enabled = bool(a.payload.get("from", true))
				if tb.is_complete():
					tb.state = BuildTypes.State.OPERATIONAL if tb.enabled else BuildTypes.State.DISABLED
					Bus.building_state_changed.emit(tb.id, tb.state)


func _replay(a: BuildAction) -> void:
	match a.kind:
		BuildAction.Kind.GROUP:
			for c: BuildAction in a.children:
				_replay(c)
		BuildAction.Kind.PLACE:
			var snap: Dictionary = a.payload.get("snapshot", {})
			if snap.is_empty():
				return
			var b: BuildingInstance = _restore(snap)
			if b != null:
				stock.take_partial(BuildTypes.to_items(a.payload.get("refunded", {})))
		BuildAction.Kind.REMOVE:
			var rsnap: Dictionary = a.payload.get("snapshot", {})
			var rid: int = int(rsnap.get("id", 0))
			var target: BuildingInstance = _buildings.get(rid)
			if target == null:
				return
			a.payload["cancelled"] = false
			stock.give(BuildTypes.to_items(a.payload.get("refunded", {})))
			_destroy(target)
		BuildAction.Kind.ROTATE:
			var rb: BuildingInstance = _buildings.get(int(a.payload.get("id", 0)))
			if rb != null:
				_apply_rotation(rb, int(a.payload.get("to", rb.rot)))
		BuildAction.Kind.TOGGLE:
			var tb: BuildingInstance = _buildings.get(int(a.payload.get("id", 0)))
			if tb != null:
				tb.enabled = bool(a.payload.get("to", true))
				if tb.is_complete():
					tb.state = BuildTypes.State.OPERATIONAL if tb.enabled else BuildTypes.State.DISABLED
					Bus.building_state_changed.emit(tb.id, tb.state)


# ------------------------------------------------------------- validation ---

## Can this building go here? Pure — call it every frame for the ghost preview.
## Returns {ok, code, reason, rot, cells, cost, missing}. `reason` is written for
## the player, `code` for logic. `ignore_id` excludes one building from the
## overlap test, which is how rotation revalidates itself.
func can_place(kind: StringName, cell: Vector2i, rot: int = 0, check_cost: bool = true, ignore_id: int = -1) -> Dictionary:
	var def: BuildingDef = _defs.get(kind)
	if def == null:
		return _fail(BuildTypes.CODE_UNKNOWN_KIND, "There is no building called '%s'." % String(kind))

	var r: int = def.normalize_rot(rot)
	var cells: Array[Vector2i] = def.cells_at(cell, r)
	var cost: Dictionary[StringName, int] = BuildTypes.to_items(def.cost)
	var base: Dictionary = {"rot": r, "cells": cells, "cost": BuildTypes.items_to_json(cost)}

	if String(def.unlock_id) != "" and not is_unlocked(def.unlock_id):
		return _fail(BuildTypes.CODE_LOCKED, "%s is still locked — research %s first." % [
			def.display_name, String(def.unlock_id).replace("_", " ")], base)

	if def.max_count > 0:
		var have: int = count_of(kind)
		if ignore_id >= 0:
			var ig: BuildingInstance = _buildings.get(ignore_id)
			if ig != null and ig.kind == kind:
				have -= 1
		if have >= def.max_count:
			return _fail(BuildTypes.CODE_MAX_COUNT, "The city can only support %d %s." % [
				def.max_count, def.display_name], base)

	for c: Vector2i in cells:
		if not world.in_bounds(c):
			return _fail(BuildTypes.CODE_OUT_OF_BOUNDS, "That reaches past the edge of the world.", base)

	for c: Vector2i in cells:
		if not world.is_buildable(c):
			return _fail(BuildTypes.CODE_TERRAIN, "The ground at (%d, %d) will not take a foundation." % [c.x, c.y], base)

	if def.allowed_terrain.size() > 0 or def.forbidden_terrain.size() > 0:
		for c: Vector2i in cells:
			var t: StringName = world.terrain_at(c)
			if String(t) == "":
				continue
			if def.forbidden_terrain.has(t):
				return _fail(BuildTypes.CODE_TERRAIN, "%s cannot stand on %s." % [
					def.display_name, String(t).replace("_", " ")], base)
			if def.allowed_terrain.size() > 0 and not def.allowed_terrain.has(t):
				return _fail(BuildTypes.CODE_TERRAIN, "%s needs %s underneath." % [
					def.display_name, BuildTypes.describe_items({}) if def.allowed_terrain.is_empty()
					else String(def.allowed_terrain[0]).replace("_", " ")], base)

	if def.needs_flat and not world.is_flat(cells):
		return _fail(BuildTypes.CODE_NOT_FLAT, "%s needs level ground." % def.display_name, base)

	for c: Vector2i in cells:
		var occ: int = int(_occupancy.get(c, 0))
		if occ != 0 and occ != ignore_id:
			var other: BuildingInstance = _buildings.get(occ)
			var other_name: String = other.def.display_name if other != null else "something"
			return _fail(BuildTypes.CODE_OCCUPIED, "%s is in the way at (%d, %d)." % [other_name, c.x, c.y], base)

	if String(def.needs_ore) != "":
		var want: int = clampi(def.ore_coverage, 1, cells.size())
		var covered: int = 0
		var wrong: StringName = &""
		for c: Vector2i in cells:
			var ore: StringName = world.ore_at(c)
			if String(ore) == "":
				continue
			if def.needs_ore == BuildTypes.ANY_ORE or ore == def.needs_ore:
				covered += 1
			elif String(wrong) == "":
				wrong = ore
		if covered < want:
			var wanted: String = "a deposit" if def.needs_ore == BuildTypes.ANY_ORE \
				else "%s" % String(def.needs_ore).replace("_", " ")
			var tail: String = " (there is only %s here)" % String(wrong).replace("_", " ") if String(wrong) != "" else ""
			if want > 1:
				return _fail(BuildTypes.CODE_NEEDS_ORE, "%s needs %d tiles of %s under it%s." % [
					def.display_name, want, wanted, tail], base)
			return _fail(BuildTypes.CODE_NEEDS_ORE, "%s must cover %s%s." % [
				def.display_name, wanted, tail], base)

	if def.min_spacing > 0:
		var blocker: BuildingInstance = _same_kind_within(kind, cells, def.min_spacing, ignore_id)
		if blocker != null:
			return _fail(BuildTypes.CODE_SPACING, "%s must stand at least %d tiles from another one." % [
				def.display_name, def.min_spacing], base)

	if def.must_connect.size() > 0:
		var offered: Dictionary[StringName, bool] = _connections_around(cells, ignore_id)
		var found: bool = false
		for t2: StringName in def.must_connect:
			if offered.has(t2):
				found = true
				break
		if not found:
			return _fail(BuildTypes.CODE_MUST_CONNECT, "%s must touch %s." % [
				def.display_name, _describe_tags(def.must_connect)], base)

	if check_cost:
		var missing: Dictionary[StringName, int] = stock.missing(cost)
		if not missing.is_empty():
			var m: Dictionary = base.duplicate()
			m["missing"] = BuildTypes.items_to_json(missing)
			return _fail(BuildTypes.CODE_MATERIALS, "Not enough materials — %s short." % BuildTypes.describe_items(missing), m)

	return _ok(base)


## Convenience for the ghost renderer: the cells a placement would cover.
func preview_cells(kind: StringName, cell: Vector2i, rot: int = 0) -> Array[Vector2i]:
	var def: BuildingDef = _defs.get(kind)
	if def == null:
		return []
	return def.cells_at(cell, def.normalize_rot(rot))


func _same_kind_within(kind: StringName, cells: Array[Vector2i], spacing: int, ignore_id: int) -> BuildingInstance:
	var seen: Dictionary[int, bool] = {}
	for c: Vector2i in cells:
		for dy: int in range(-spacing, spacing + 1):
			for dx: int in range(-spacing, spacing + 1):
				var occ: int = int(_occupancy.get(c + Vector2i(dx, dy), 0))
				if occ == 0 or occ == ignore_id or seen.has(occ):
					continue
				seen[occ] = true
				var b: BuildingInstance = _buildings.get(occ)
				if b != null and b.kind == kind:
					return b
	return null


func _connections_around(cells: Array[Vector2i], ignore_id: int) -> Dictionary[StringName, bool]:
	var out: Dictionary[StringName, bool] = {}
	var own: Dictionary[Vector2i, bool] = {}
	for c: Vector2i in cells:
		own[c] = true
	for c: Vector2i in cells:
		for n: Vector2i in BuildTypes.neighbors4(c):
			if own.has(n):
				continue
			for t: StringName in _planned_conn.get(n, []):
				out[t] = true
			var occ: int = int(_occupancy.get(n, 0))
			if occ == 0 or occ == ignore_id:
				continue
			var b: BuildingInstance = _buildings.get(occ)
			if b == null:
				continue
			for t: StringName in b.def.connects_as:
				out[t] = true
	return out


static func _describe_tags(tags: Array[StringName]) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for t: StringName in tags:
		parts.append("a %s connection" % String(t).replace("_", " "))
	if parts.size() == 1:
		return parts[0]
	return " or ".join(parts)


# ---------------------------------------------------------- instance churn --

func _create(def: BuildingDef, cell: Vector2i, rot: int, meta: Dictionary, forced_id: int = -1) -> BuildingInstance:
	var b := BuildingInstance.new()
	b.id = forced_id if forced_id > 0 else _next_id
	if b.id >= _next_id:
		_next_id = b.id + 1
	b.kind = def.id
	b.def = def
	b.cell = cell
	b.rot = rot
	b.state = BuildTypes.State.GHOST
	b.max_hp = def.hp
	b.hp = def.hp * GHOST_HP_FRACTION
	b.placed_tick = _tick
	b.meta = meta.duplicate(true)
	b.refresh_cells()
	_register(b)
	queue.add(b.id, def.build_priority, _tick)
	_placed_total += 1
	Bus.building_placed.emit(b.id, b.kind, b.cell)
	return b


## Rebuilds an instance from a snapshot, id and all. Undo depends on the id
## surviving: another system may be holding it.
func _restore(snap: Dictionary) -> BuildingInstance:
	var kind: StringName = StringName(String(snap.get("kind", "")))
	var def: BuildingDef = _defs.get(kind)
	if def == null:
		Log.warn("build", "cannot restore unknown building '%s'" % String(kind))
		return null
	var b: BuildingInstance = BuildingInstance.from_dict(snap, def)
	if _buildings.has(b.id):
		return null
	for c: Vector2i in b.cells:
		if int(_occupancy.get(c, 0)) != 0:
			Log.warn("build", "cannot restore %s #%d — %s is occupied" % [def.display_name, b.id, str(c)])
			return null
	if b.id >= _next_id:
		_next_id = b.id + 1
	_register(b)
	if not b.is_complete():
		queue.add(b.id, def.build_priority, b.placed_tick)
	elif def.blocks_movement:
		world.claim(b.rect(), b.id, b.def.blocks_movement)
	if b.state == BuildTypes.State.DECONSTRUCTING:
		_insert_sorted(_demolishing, b.id)
	Bus.building_placed.emit(b.id, b.kind, b.cell)
	Bus.building_state_changed.emit(b.id, b.state)
	return b


func _register(b: BuildingInstance) -> void:
	_buildings[b.id] = b
	_insert_sorted(_ids, b.id)
	for c: Vector2i in b.cells:
		_occupancy[c] = b.id
	_kind_counts[b.kind] = int(_kind_counts.get(b.kind, 0)) + 1


func _destroy(b: BuildingInstance) -> void:
	for c: Vector2i in b.cells:
		if int(_occupancy.get(c, 0)) == b.id:
			_occupancy.erase(c)
	world.unclaim(b.rect(), b.id)
	_buildings.erase(b.id)
	_ids.erase(b.id)
	_demolishing.erase(b.id)
	_pending_demolition.erase(b.id)
	queue.remove(b.id)
	var n: int = int(_kind_counts.get(b.kind, 0)) - 1
	if n <= 0:
		_kind_counts.erase(b.kind)
	else:
		_kind_counts[b.kind] = n
	_removed_total += 1
	Bus.building_removed.emit(b.id, b.cell)


func _apply_rotation(b: BuildingInstance, new_rot: int) -> void:
	for c: Vector2i in b.cells:
		if int(_occupancy.get(c, 0)) == b.id:
			_occupancy.erase(c)
	world.unclaim(b.rect(), b.id)
	b.rot = new_rot
	b.refresh_cells()
	for c: Vector2i in b.cells:
		_occupancy[c] = b.id
	if b.is_complete() and b.def.blocks_movement:
		world.claim(b.rect(), b.id, b.def.blocks_movement)
	Bus.building_state_changed.emit(b.id, b.state)


func _force_complete(b: BuildingInstance) -> void:
	if b.state == BuildTypes.State.GHOST:
		b.delivered = BuildTypes.to_items(b.def.cost)
		_begin_construction(b)
	b.progress = float(b.def.build_time_ticks)
	_complete(b)


func _resolve_target(cmd: Dictionary) -> BuildingInstance:
	if cmd.has("id"):
		return _buildings.get(int(cmd["id"]))
	if cmd.has("cell"):
		return building_at(BuildTypes.to_cell(cmd["cell"]))
	return null


func _reject(cell: Vector2i, result: Dictionary) -> void:
	# Same signal either way — the player gets the same red ghost on the cell.
	# Only the bookkeeping splits, because only the bookkeeping is banded.
	if _sweep_depth > 0:
		_sweep_skipped_total += 1
	else:
		_rejected_total += 1
	Bus.placement_rejected.emit(cell, String(result.get("reason", "")))


static func _insert_sorted(arr: Array[int], value: int) -> void:
	var lo: int = 0
	var hi: int = arr.size()
	while lo < hi:
		var mid: int = (lo + hi) >> 1
		if arr[mid] < value:
			lo = mid + 1
		else:
			hi = mid
	arr.insert(lo, value)


func _ok(extra: Dictionary = {}) -> Dictionary:
	var d: Dictionary = {"ok": true, "code": BuildTypes.CODE_OK, "reason": ""}
	d.merge(extra, true)
	return d


func _fail(code: StringName, reason: String, extra: Dictionary = {}) -> Dictionary:
	var d: Dictionary = {"ok": false, "code": code, "reason": reason}
	d.merge(extra, false)
	return d


# ------------------------------------------------------------- stock/unlock -

func _op_add_stock(cmd: Dictionary) -> Dictionary:
	var items: Dictionary[StringName, int] = BuildTypes.to_items(cmd.get("items", {}))
	stock.give(items)
	return _ok({"added": BuildTypes.items_to_json(items)})


func _op_set_stock(cmd: Dictionary) -> Dictionary:
	# to_amounts, not to_items: "set scrap to 0" is a real instruction here.
	var items: Dictionary[StringName, int] = BuildTypes.to_amounts(cmd.get("items", {}))
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		stock.set_amount(k, items[k])
	return _ok({"set": BuildTypes.items_to_json(items)})


func _op_grant_unlock(cmd: Dictionary) -> Dictionary:
	var id: StringName = StringName(String(cmd.get("unlock", "")))
	if String(id) == "":
		return _fail(BuildTypes.CODE_BAD_COMMAND, "No unlock id given.")
	_unlocked[id] = true
	Bus.unlocked.emit(id)
	return _ok({"unlock": String(id)})


## Is a research gate open? Defers to [P10] research when it exists, and to the
## locally granted set otherwise, so content can be gated before the tech tree lands.
func is_unlocked(id: StringName) -> bool:
	if String(id) == "":
		return true
	if _unlocked.has(id):
		return true
	if _research != null and _m_unlocked != "":
		return bool(_research.call(_m_unlocked, id))
	return false


# ----------------------------------------------------------- public API -----

## Definition for a kind, or null.
func def_of(kind: StringName) -> BuildingDef:
	return _defs.get(kind)


## Every definition, sorted by id. The build menu iterates this.
func all_defs() -> Array[BuildingDef]:
	var keys: Array = _defs.keys()
	keys.sort()
	var out: Array[BuildingDef] = []
	for k: StringName in keys:
		out.append(_defs[k])
	return out


## Definitions the player may build right now.
func available_defs() -> Array[BuildingDef]:
	var out: Array[BuildingDef] = []
	for d: BuildingDef in all_defs():
		if is_unlocked(d.unlock_id):
			out.append(d)
	return out


## One building by id, or null.
func get_building(id: int) -> BuildingInstance:
	return _buildings.get(id)


## Whatever occupies a cell, or null.
func building_at(cell: Vector2i) -> BuildingInstance:
	var id: int = int(_occupancy.get(cell, 0))
	return _buildings.get(id) if id != 0 else null


## True when a cell is free of buildings.
func is_cell_free(cell: Vector2i) -> bool:
	return not _occupancy.has(cell)


## Every building, ascending by id — a stable order every system can rely on.
func all_buildings() -> Array[BuildingInstance]:
	var out: Array[BuildingInstance] = []
	for id: int in _ids:
		out.append(_buildings[id])
	return out


## Monotonic counter of every change to the roster another system pulls: a
## building placed, completed, removed, destroyed or switched. Nothing else in
## this file needs it — it exists so a puller can ask "did anything move?" for
## the price of one integer compare.
##
## [P02] heat re-reads all_buildings() every tick through Object.get()/call()
## reflection, which is ~12k dynamic dispatches over a 1700-building city and
## cost 1.9 ms of a 7 ms heat budget for a roster that changes a few times a
## minute. Same number, no rescan.
func roster_version() -> int:
	return _placed_total + _removed_total + _completed_total \
		+ _destroyed_total + _switched_total


## Finished, switched-on buildings only. What heat, production and combat want.
func running_buildings() -> Array[BuildingInstance]:
	var out: Array[BuildingInstance] = []
	for id: int in _ids:
		var b: BuildingInstance = _buildings[id]
		if b.is_running():
			out.append(b)
	return out


## --- selection contract ([P16] SimEntityProvider duck-types these) ---------

## Building id under a tile, or -1. Read-only: selection never mutates the world.
func entity_at_cell(cell: Vector2i) -> int:
	var b: BuildingInstance = building_at(cell)
	return -1 if b == null else b.id


## Every building id intersecting a tile rectangle, ascending. -1 for none.
func entities_in_cell_rect(rect: Rect2i) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for b: BuildingInstance in buildings_in_rect(rect):
		out.append(b.id)
	return out


## Every building carrying a tag: &"turret", &"conduit", &"housing", ...
func buildings_with_tag(tag: StringName) -> Array[BuildingInstance]:
	var out: Array[BuildingInstance] = []
	for id: int in _ids:
		var b: BuildingInstance = _buildings[id]
		if b.def.has_tag(tag):
			out.append(b)
	return out


func buildings_of_kind(kind: StringName) -> Array[BuildingInstance]:
	var out: Array[BuildingInstance] = []
	for id: int in _ids:
		var b: BuildingInstance = _buildings[id]
		if b.kind == kind:
			out.append(b)
	return out


## Buildings whose footprint intersects a rectangle, ascending by id.
func buildings_in_rect(rect: Rect2i) -> Array[BuildingInstance]:
	var seen: Dictionary[int, bool] = {}
	var out: Array[BuildingInstance] = []
	for y: int in range(rect.position.y, rect.end.y):
		for x: int in range(rect.position.x, rect.end.x):
			var id: int = int(_occupancy.get(Vector2i(x, y), 0))
			if id == 0 or seen.has(id):
				continue
			seen[id] = true
	var ids: Array = seen.keys()
	ids.sort()
	for id: int in ids:
		out.append(_buildings[id])
	return out


## Orthogonally adjacent buildings, each listed once, ascending by id.
## [P02] builds the heat network graph out of this.
func neighbors_of(b: BuildingInstance) -> Array[BuildingInstance]:
	var seen: Dictionary[int, bool] = {}
	for c: Vector2i in b.cells:
		for n: Vector2i in BuildTypes.neighbors4(c):
			var id: int = int(_occupancy.get(n, 0))
			if id != 0 and id != b.id:
				seen[id] = true
	var ids: Array = seen.keys()
	ids.sort()
	var out: Array[BuildingInstance] = []
	for id: int in ids:
		out.append(_buildings[id])
	return out


func count_of(kind: StringName) -> int:
	return int(_kind_counts.get(kind, 0))


func building_count() -> int:
	return _ids.size()


## Applies damage. Returns true when the building was destroyed by it.
## [P07] combat is the intended caller.
func apply_damage(id: int, amount: float, source: StringName = &"unknown") -> bool:
	var b: BuildingInstance = _buildings.get(id)
	if b == null or amount <= 0.0:
		return false
	var taken: float = maxf(1.0, amount - b.def.armor)
	b.hp -= taken
	Bus.structure_damaged.emit(b.id, taken, b.world_center())
	if b.hp > 0.0:
		return false
	Log.info("build", "%s #%d destroyed by %s" % [b.def.display_name, b.id, String(source)])
	b.state = BuildTypes.State.DESTROYED
	_destroyed_total += 1
	Bus.building_state_changed.emit(b.id, b.state)
	_destroy(b)
	return true


## Heals a building without charging for it. Repair drones and events use this.
func heal(id: int, amount: float) -> void:
	var b: BuildingInstance = _buildings.get(id)
	if b == null:
		return
	b.hp = minf(b.max_hp, b.hp + amount)


## [P02] heat marks a building as starved. Frozen buildings stop working but
## keep their place, their crew and their construction progress.
func set_frozen(id: int, frozen: bool) -> void:
	var b: BuildingInstance = _buildings.get(id)
	if b == null or not b.is_complete():
		return
	var target: int = BuildTypes.State.OPERATIONAL if b.enabled else BuildTypes.State.DISABLED
	if frozen:
		target = BuildTypes.State.FROZEN
	if b.state == target or b.state == BuildTypes.State.DECONSTRUCTING:
		return
	b.state = target
	Bus.building_state_changed.emit(b.id, b.state)
	if frozen:
		Bus.building_froze.emit(b.id)


## Switches a finished building on or off without going through a command.
func set_enabled(id: int, on: bool) -> void:
	var cmd: Dictionary = {"op": &"set_enabled", "id": id, "on": on}
	execute(cmd)


func is_running(id: int) -> bool:
	var b: BuildingInstance = _buildings.get(id)
	return b != null and b.is_running()


## Construction sites still waiting or in progress.
func pending_sites() -> Array[BuildingInstance]:
	var out: Array[BuildingInstance] = []
	for id: int in queue.ids():
		var b: BuildingInstance = _buildings.get(id)
		if b != null:
			out.append(b)
	return out


func can_undo() -> bool:
	return _undo.can_undo()


func can_redo() -> bool:
	return _undo.can_redo()


func undo_label() -> String:
	return _undo.peek_undo_label()


func redo_label() -> String:
	return _undo.peek_redo_label()


# ------------------------------------------------------------ persistence ---

func serialize() -> Dictionary:
	var blds: Array = []
	for id: int in _ids:
		blds.append(_buildings[id].to_dict())
	var unlocks: Array = []
	var ukeys: Array = _unlocked.keys()
	ukeys.sort()
	for k: StringName in ukeys:
		unlocks.append(String(k))
	return {
		"next_id": _next_id,
		"buildings": blds,
		"stock": stock.to_dict(),
		"queue": queue.to_json(),
		"demolishing": _demolishing.duplicate(),
		"blueprints": book.to_dict(),
		"history": _undo.to_dict(),
		"unlocked": unlocks,
		"stats": {
			"placed": _placed_total,
			"removed": _removed_total,
			"completed": _completed_total,
			"rejected": _rejected_total,
			"sweep_skipped": _sweep_skipped_total,
			"destroyed": _destroyed_total,
		},
	}


func deserialize(data: Dictionary) -> void:
	_buildings.clear()
	_ids.clear()
	_occupancy.clear()
	_kind_counts.clear()
	_demolishing.clear()
	_pending_demolition.clear()
	_unlocked.clear()
	queue.clear()
	_next_id = int(data.get("next_id", 1))

	for raw: Variant in data.get("buildings", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var snap: Dictionary = raw
		var def: BuildingDef = _defs.get(StringName(String(snap.get("kind", ""))))
		if def == null:
			Log.warn("build", "save references unknown building '%s'" % String(snap.get("kind", "")))
			continue
		var b: BuildingInstance = BuildingInstance.from_dict(snap, def)
		_register(b)
		if b.state == BuildTypes.State.DECONSTRUCTING:
			_insert_sorted(_demolishing, b.id)
		elif not b.is_complete():
			queue.add(b.id, def.build_priority, b.placed_tick)
		elif def.blocks_movement:
			world.claim(b.rect(), b.id, b.def.blocks_movement)

	var q: Variant = data.get("queue", [])
	if typeof(q) == TYPE_ARRAY and (q as Array).size() > 0:
		queue.from_json(q)
	stock.from_dict(data.get("stock", {}))
	book.from_dict(data.get("blueprints", {}))
	_undo.from_dict(data.get("history", {}))
	for u: Variant in data.get("unlocked", []):
		_unlocked[StringName(String(u))] = true
	var stats: Dictionary = data.get("stats", {})
	_placed_total = int(stats.get("placed", 0))
	_removed_total = int(stats.get("removed", 0))
	_completed_total = int(stats.get("completed", 0))
	_rejected_total = int(stats.get("rejected", 0))
	_sweep_skipped_total = int(stats.get("sweep_skipped", 0))
	_destroyed_total = int(stats.get("destroyed", 0))

	# Deferred demolition refunds must find their undo entry again after a load.
	for a: BuildAction in _undo.remove_actions():
		if bool(a.payload.get("done", true)):
			continue
		var snap2: Dictionary = a.payload.get("snapshot", {})
		var sid: int = int(snap2.get("id", 0))
		var still: BuildingInstance = _buildings.get(sid)
		if still != null and still.state == BuildTypes.State.DECONSTRUCTING:
			_pending_demolition[sid] = a

	Log.info("build", "restored %d buildings, %d queued" % [_ids.size(), queue.size()])


func metrics() -> Dictionary:
	var under: int = 0
	var ghosts: int = 0
	var operational: int = 0
	var frozen: int = 0
	var disabled: int = 0
	for id: int in _ids:
		match _buildings[id].state:
			BuildTypes.State.GHOST:
				ghosts += 1
			BuildTypes.State.CONSTRUCTING:
				under += 1
			BuildTypes.State.OPERATIONAL:
				operational += 1
			BuildTypes.State.FROZEN:
				frozen += 1
			BuildTypes.State.DISABLED:
				disabled += 1
	return {
		"buildings_total": _ids.size(),
		"under_construction": under,
		"queued": queue.size(),
		"ghosts": ghosts,
		"operational": operational,
		"frozen": frozen,
		"disabled": disabled,
		"demolishing": _demolishing.size(),
		"blueprints": book.size(),
		"undo_depth": _undo.undo_depth(),
		"materials": stock.total_units(),
		"placed_total": _placed_total,
		"completed_total": _completed_total,
		"rejected_total": _rejected_total,
		"sweep_skipped_total": _sweep_skipped_total,
	}
