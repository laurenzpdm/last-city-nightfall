extends Node
## [P11] Build & Construction — headless test suite.
##
##   Godot --headless --path . res://tests/build/test_build.tscn
##
## Exits non-zero and prints TESTS FAILED when anything is wrong, so tools/check.sh
## and any shared runner can gate on it. It runs as a SCENE rather than through
## `--script` on purpose: Godot compiles a `--script` file before it registers the
## autoload globals, so `Sim`, `Bus` and `Log` would not even resolve there.

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _current: String = ""
var _sys: BuildSystem = null


func _ready() -> void:
	Log.min_level = Log.Level.WARN
	SimClock.set_manual(true)

	var suite: Array[Array] = [
		["definitions load and validate", _test_definitions],
		["footprint geometry and rotation math", _test_geometry],
		["placement validity rules", _test_placement_rules],
		["cost deduction and refunds", _test_costs],
		["construction takes real time", _test_construction_time],
		["material delivery feeds ghosts over time", _test_ghost_delivery],
		["demolition timing and salvage", _test_demolition],
		["rotate a placed building", _test_rotate],
		["undo and redo correctness", _test_undo],
		["blueprint capture, transform and round-trip", _test_blueprint_roundtrip],
		["blueprint stamping and group undo", _test_blueprint_stamp],
		["a turned stamp still fits buildings that cannot turn", _test_blueprint_fixed_rotation],
		["line and area drags", _test_drags],
		["damage, repair and destruction", _test_damage],
		["command bus path through Sim", _test_command_path],
		["serialize / deserialize round-trip", _test_serialization],
		["determinism of a scripted build sequence", _test_determinism],
		["integration with the real world grid", _test_world_binding],
	]

	for entry: Array in suite:
		_current = String(entry[0])
		var before: int = _failures.size()
		var fn: Callable = entry[1]
		fn.call()
		var status: String = "ok  " if _failures.size() == before else "FAIL"
		print("  [%s] %s" % [status, _current])

	Sim.teardown()
	print("")
	if _failures.is_empty():
		print("TESTS PASSED — %d checks across %d cases" % [_checks, suite.size()])
		get_tree().quit(0)
		return
	print("TESTS FAILED — %d of %d checks" % [_failures.size(), _checks])
	for f: String in _failures:
		print("   x %s" % f)
	get_tree().quit(1)


# ------------------------------------------------------------------ helpers --

## A world for testing this part's rules. The grid is unbound by default: these
## cases are about placement logic, and they must not turn red because [P01]
## changed a noise octave and put a chasm where the test wanted a wall.
## _test_world_binding is the one case that runs against the real terrain.
func _fresh(world_seed: int = 11, isolated: bool = true) -> BuildSystem:
	Sim.create_world(world_seed)
	_sys = Sim.get_system(&"build") as BuildSystem
	_ok(_sys != null, "build system exists")
	if isolated:
		_sys.world.bind(null)
	return _sys


func _advance(n: int) -> void:
	SimClock.advance(n)


## Places something outright, paid and finished, so a test can set a scene up.
func _put(kind: StringName, cell: Vector2i, rot: int = 0) -> int:
	var r: Dictionary = _sys.execute({
		"op": &"place", "kind": kind, "cell": cell, "rot": rot, "free": true, "instant": true,
	})
	_ok(bool(r["ok"]), "placed %s at %s (%s)" % [String(kind), str(cell), String(r.get("reason", ""))])
	return int(r.get("id", 0))


func _ok(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures.append("%s :: %s" % [_current, msg])


func _eq(a: Variant, b: Variant, msg: String) -> void:
	_checks += 1
	if str(a) != str(b):
		_failures.append("%s :: %s (got %s, want %s)" % [_current, msg, str(a), str(b)])


func _near(a: float, b: float, msg: String) -> void:
	_checks += 1
	if absf(a - b) > 0.001:
		_failures.append("%s :: %s (got %f, want %f)" % [_current, msg, a, b])


# -------------------------------------------------------------------- tests --

func _test_definitions() -> void:
	_fresh()
	var defs: Array[BuildingDef] = _sys.all_defs()
	_ok(defs.size() >= 12, "at least twelve buildings shipped (%d)" % defs.size())
	var required: Array[StringName] = [
		&"geothermal_tap", &"coal_generator", &"heat_pipe", &"warmth_radiator",
		&"scrap_collector", &"ore_drill", &"smelter", &"workshop",
		&"housing_block", &"granary", &"wall", &"turret_mount",
	]
	for id: StringName in required:
		_ok(_sys.def_of(id) != null, "definition '%s' exists" % String(id))
	for d: BuildingDef in defs:
		_eq(d.validate().size(), 0, "definition '%s' is valid" % String(d.id))
		_ok(String(d.description) != "", "'%s' has description text" % String(d.id))
		_ok(d.cost.size() > 0 or d.max_count == 1, "'%s' costs something" % String(d.id))
	# Locked content must not be buildable before the research exists.
	var available: Array[BuildingDef] = _sys.available_defs()
	_ok(available.size() < defs.size(), "some buildings start locked")
	_ok(not _sys.is_unlocked(&"geothermal_tapping"), "geothermal tapping starts locked")
	_sys.execute({"op": &"grant_unlock", "unlock": &"geothermal_tapping"})
	_ok(_sys.is_unlocked(&"geothermal_tapping"), "unlock can be granted")


func _test_geometry() -> void:
	_fresh()
	var coal: BuildingDef = _sys.def_of(&"coal_generator")
	_eq(coal.effective_size(0), Vector2i(3, 2), "3x2 unrotated")
	_eq(coal.effective_size(1), Vector2i(2, 3), "3x2 turned once is 2x3")
	_eq(coal.effective_size(2), Vector2i(3, 2), "half turn keeps dimensions")
	_eq(coal.cells_at(Vector2i(10, 10), 0).size(), 6, "six cells covered")
	var cells: Array[Vector2i] = coal.cells_at(Vector2i(10, 10), 0)
	_ok(cells.has(Vector2i(12, 11)), "far corner covered")
	_ok(not cells.has(Vector2i(13, 10)), "nothing beyond the footprint")
	# Rotation is a proper quarter turn, not a dimension swap.
	_eq(BuildTypes.rotate_cell(Vector2i(0, 0), 1, Vector2i(3, 2)), Vector2i(1, 0), "corner rotates")
	_eq(BuildTypes.rotate_cell(Vector2i(2, 1), 1, Vector2i(3, 2)), Vector2i(0, 2), "opposite corner rotates")
	for r: int in 4:
		var set: Dictionary[Vector2i, bool] = {}
		for c: Vector2i in coal.cells_at(Vector2i.ZERO, r):
			_ok(not set.has(c), "no duplicate cell at rot %d" % r)
			set[c] = true
	_eq(BuildTypes.mirror_rot_x(1), 3, "right mirrors to left")
	_eq(BuildTypes.mirror_rot_x(0), 0, "up mirrors to up")
	_eq(BuildTypes.world_center(Vector2i(2, 2), Vector2i(2, 2)), Vector2(96, 96), "world centre in pixels")


func _test_placement_rules() -> void:
	_fresh()
	# Unknown kind.
	var unknown: Dictionary = _sys.can_place(&"nonsense_machine", Vector2i(1, 1))
	_ok(not bool(unknown["ok"]), "unknown kind refused")
	_eq(unknown["code"], BuildTypes.CODE_UNKNOWN_KIND, "unknown kind code")
	_ok(String(unknown["reason"]) != "", "refusal carries a reason string")

	# Out of the world.
	var far: Dictionary = _sys.can_place(&"wall", Vector2i(100000, 0))
	_eq(far["code"], BuildTypes.CODE_OUT_OF_BOUNDS, "out of bounds code")

	# Overlap.
	_put(&"wall", Vector2i(4, 4))
	var over: Dictionary = _sys.can_place(&"wall", Vector2i(4, 4))
	_eq(over["code"], BuildTypes.CODE_OCCUPIED, "overlap refused")
	_ok(String(over["reason"]).contains("Wall"), "refusal names the blocker")
	var over_big: Dictionary = _sys.can_place(&"coal_generator", Vector2i(2, 3))
	_eq(over_big["code"], BuildTypes.CODE_OCCUPIED, "multi-cell overlap refused")

	# Connection requirement.
	var lonely: Dictionary = _sys.can_place(&"warmth_radiator", Vector2i(40, 40))
	_eq(lonely["code"], BuildTypes.CODE_MUST_CONNECT, "radiator needs a heat connection")
	_put(&"heat_pipe", Vector2i(39, 40))
	var joined: Dictionary = _sys.can_place(&"warmth_radiator", Vector2i(40, 40))
	_ok(bool(joined["ok"]), "radiator accepts an adjacent pipe (%s)" % String(joined.get("reason", "")))
	var diagonal: Dictionary = _sys.can_place(&"warmth_radiator", Vector2i(37, 38))
	_eq(diagonal["code"], BuildTypes.CODE_MUST_CONNECT, "diagonal contact does not connect")

	# Ore requirement, with no grid to provide ore.
	var drill: Dictionary = _sys.can_place(&"ore_drill", Vector2i(60, 60))
	_eq(drill["code"], BuildTypes.CODE_NEEDS_ORE, "drill needs a vein")

	# Unique buildings.
	_put(&"the_hearth", Vector2i(100, 100))
	var second: Dictionary = _sys.can_place(&"the_hearth", Vector2i(120, 120))
	_eq(second["code"], BuildTypes.CODE_MAX_COUNT, "only one hearth")

	# Locked content.
	var locked: Dictionary = _sys.can_place(&"geothermal_tap", Vector2i(70, 70))
	_eq(locked["code"], BuildTypes.CODE_LOCKED, "locked building refused")

	# A ghost still blocks placement.
	_sys.execute({"op": &"place", "kind": &"wall", "cell": Vector2i(8, 8), "ghost": true})
	_eq(_sys.can_place(&"wall", Vector2i(8, 8))["code"], BuildTypes.CODE_OCCUPIED, "ghosts reserve their cells")


func _test_costs() -> void:
	_fresh()
	var scrap0: int = _sys.stock.count(&"scrap")
	var iron0: int = _sys.stock.count(&"iron_plate")
	_ok(scrap0 > 0 and iron0 > 0, "starting stock is not empty")

	var r: Dictionary = _sys.execute({"op": &"place", "kind": &"coal_generator", "cell": Vector2i(10, 10)})
	_ok(bool(r["ok"]), "coal generator placed (%s)" % String(r.get("reason", "")))
	_eq(_sys.stock.count(&"scrap"), scrap0 - 45, "scrap deducted at placement")
	_eq(_sys.stock.count(&"iron_plate"), iron0 - 20, "iron deducted at placement")
	var b: BuildingInstance = _sys.get_building(int(r["id"]))
	_eq(b.state, BuildTypes.State.CONSTRUCTING, "paid site starts building immediately")
	_ok(b.fully_supplied(), "site holds all its materials")

	# Cancelling an unfinished site returns everything.
	_sys.execute({"op": &"cancel", "id": b.id})
	_eq(_sys.stock.count(&"scrap"), scrap0, "cancel refunds scrap in full")
	_eq(_sys.stock.count(&"iron_plate"), iron0, "cancel refunds iron in full")
	_ok(_sys.get_building(b.id) == null, "cancelled site is gone")

	# Poverty is reported, not swallowed.
	_sys.execute({"op": &"set_stock", "items": {&"scrap": 3, &"iron_plate": 0}})
	var poor: Dictionary = _sys.execute({"op": &"place", "kind": &"coal_generator", "cell": Vector2i(20, 20)})
	_ok(not bool(poor["ok"]), "cannot build without materials")
	_eq(poor["code"], BuildTypes.CODE_MATERIALS, "shortfall code")
	_ok(String(poor["reason"]).contains("42"), "shortfall names the missing amount: %s" % String(poor["reason"]))
	_ok(_sys.building_at(Vector2i(20, 20)) == null, "nothing was placed")

	# Demolishing a finished building returns the stated fraction.
	_sys.execute({"op": &"set_stock", "items": {&"stone": 100}})
	var wall_id: int = _put(&"wall", Vector2i(30, 30))
	var stone_before: int = _sys.stock.count(&"stone")
	_sys.execute({"op": &"remove", "id": wall_id, "instant": true})
	_eq(_sys.stock.count(&"stone"), stone_before + 3, "demolition salvages half of 6 stone")


func _test_construction_time() -> void:
	_fresh()
	var r: Dictionary = _sys.execute({"op": &"place", "kind": &"wall", "cell": Vector2i(5, 5)})
	var b: BuildingInstance = _sys.get_building(int(r["id"]))
	var need: int = b.def.build_time_ticks
	_eq(b.state, BuildTypes.State.CONSTRUCTING, "starts as a site")
	_advance(need - 1)
	_eq(b.state, BuildTypes.State.CONSTRUCTING, "still building one tick short")
	_ok(b.progress_ratio() > 0.9, "progress is nearly complete")
	_advance(1)
	_eq(b.state, BuildTypes.State.OPERATIONAL, "finished on the expected tick")
	_near(b.hp, b.max_hp, "finished at full hp")
	_eq(_sys.metrics()["under_construction"], 0, "queue drained")

	# Four sites at once, no more: build power is a real constraint.
	_fresh()
	_sys.execute({"op": &"set_stock", "items": {&"stone": 999}})
	for i: int in 6:
		_sys.execute({"op": &"place", "kind": &"wall", "cell": Vector2i(i * 2, 50)})
	_advance(1)
	var progressing: int = 0
	for b2: BuildingInstance in _sys.pending_sites():
		if b2.progress > 0.0:
			progressing += 1
	_eq(progressing, 2, "build power feeds two sites per tick")
	_eq(_sys.metrics()["queued"], 6, "all six are queued")


func _test_ghost_delivery() -> void:
	_fresh()
	_sys.execute({"op": &"set_stock", "items": {&"scrap": 0, &"iron_plate": 0}})
	var r: Dictionary = _sys.execute({"op": &"place", "kind": &"coal_generator", "cell": Vector2i(12, 12), "ghost": true})
	_ok(bool(r["ok"]), "a ghost can be planned with empty pockets")
	var b: BuildingInstance = _sys.get_building(int(r["id"]))
	_eq(b.state, BuildTypes.State.GHOST, "ghost waits for materials")
	_advance(5)
	_eq(b.state, BuildTypes.State.GHOST, "still waiting")
	_eq(b.progress, 0.0, "no work done without materials")

	# Partial supply is accepted and remembered.
	_sys.execute({"op": &"add_stock", "items": {&"scrap": 20}})
	_advance(1)
	_eq(int(b.delivered.get(&"scrap", 0)), 20, "partial delivery is kept on site")
	_eq(b.state, BuildTypes.State.GHOST, "still short of iron")
	_sys.execute({"op": &"add_stock", "items": {&"scrap": 25, &"iron_plate": 20}})
	_advance(1)
	_eq(b.state, BuildTypes.State.CONSTRUCTING, "fully supplied site starts")
	_eq(_sys.stock.count(&"scrap"), 0, "materials moved from store to site")
	_advance(b.def.build_time_ticks)
	_eq(b.state, BuildTypes.State.OPERATIONAL, "ghost eventually becomes a building")


func _test_demolition() -> void:
	_fresh()
	var id: int = _put(&"housing_block", Vector2i(20, 20))
	var b: BuildingInstance = _sys.get_building(id)
	var timber0: int = _sys.stock.count(&"timber")
	_sys.execute({"op": &"remove", "id": id})
	_eq(b.state, BuildTypes.State.DECONSTRUCTING, "demolition takes time")
	_eq(_sys.stock.count(&"timber"), timber0, "nothing recovered until it is down")
	_advance(b.def.demolish_time_ticks - 1)
	_ok(_sys.get_building(id) != null, "still standing one tick short")
	_advance(1)
	_ok(_sys.get_building(id) == null, "gone when demolition completes")
	_eq(_sys.stock.count(&"timber"), timber0 + 44, "55 timber at 55%% salvage returns 44")
	_ok(_sys.is_cell_free(Vector2i(21, 21)), "footprint released")

	# A demolition can be called off before it finishes.
	var id2: int = _put(&"housing_block", Vector2i(40, 40))
	_sys.execute({"op": &"remove", "id": id2})
	_advance(5)
	_sys.execute({"op": &"cancel", "id": id2})
	_eq(_sys.get_building(id2).state, BuildTypes.State.OPERATIONAL, "demolition cancelled")
	_advance(400)
	_ok(_sys.get_building(id2) != null, "cancelled demolition never completes")


func _test_rotate() -> void:
	_fresh()
	var id: int = _put(&"coal_generator", Vector2i(20, 20))
	var b: BuildingInstance = _sys.get_building(id)
	_ok(_sys.building_at(Vector2i(22, 20)) != null, "3x2 covers x+2 unrotated")
	_ok(_sys.building_at(Vector2i(20, 22)) == null, "3x2 does not cover y+2 unrotated")
	var r: Dictionary = _sys.execute({"op": &"rotate", "id": id, "delta": 1})
	_ok(bool(r["ok"]), "rotate accepted (%s)" % String(r.get("reason", "")))
	_eq(b.rot, 1, "rotation applied")
	_ok(_sys.building_at(Vector2i(20, 22)) != null, "footprint is now 2x3")
	_ok(_sys.building_at(Vector2i(22, 20)) == null, "old cell released")
	_eq(_sys.building_count(), 1, "rotation does not duplicate the building")

	# Asking for the rotation it already has is a no-op, not an error.
	var same: Dictionary = _sys.execute({"op": &"rotate", "id": id, "rot": 1})
	_ok(bool(same["ok"]), "re-requesting the current rotation succeeds")
	_eq(b.rot, 1, "unchanged rotation stays put")

	# (22, 20) is free while the generator stands 2x3; a wall there blocks the
	# turn back to 3x2, and the refusal must leave the building exactly as it was.
	_put(&"wall", Vector2i(22, 20))
	var blocked: Dictionary = _sys.execute({"op": &"rotate", "id": id, "delta": 1})
	_ok(not bool(blocked["ok"]), "cannot turn into an occupied cell")
	_eq(blocked["code"], BuildTypes.CODE_OCCUPIED, "blocked rotation says what blocked it")
	_eq(b.rot, 1, "refused rotation left the building alone")
	_ok(_sys.building_at(Vector2i(20, 22)) != null, "footprint untouched after a refusal")
	_ok(_sys.building_at(Vector2i(22, 20)).kind == &"wall", "the blocker is still the wall")

	# Clear the blocker and the same turn goes through.
	_sys.execute({"op": &"remove", "cell": Vector2i(22, 20), "instant": true})
	_sys.execute({"op": &"rotate", "id": id, "delta": 1})
	_eq(b.rot, 2, "half turn back to 3x2")
	_ok(_sys.building_at(Vector2i(22, 21)) != null, "3x2 footprint restored")
	_ok(_sys.building_at(Vector2i(20, 22)) == null, "the tall footprint was released")

	# Buildings that are not rotatable say so.
	var wid: int = _put(&"housing_block", Vector2i(60, 60))
	var no: Dictionary = _sys.execute({"op": &"rotate", "id": wid})
	_eq(no["code"], BuildTypes.CODE_NOT_ROTATABLE, "square building refuses rotation")


func _test_undo() -> void:
	_fresh()
	var scrap0: int = _sys.stock.count(&"scrap")
	var iron0: int = _sys.stock.count(&"iron_plate")

	# Undo a placement: building gone, materials back, exactly.
	var r: Dictionary = _sys.execute({"op": &"place", "kind": &"coal_generator", "cell": Vector2i(10, 10)})
	var id: int = int(r["id"])
	_eq(_sys.stock.count(&"scrap"), scrap0 - 45, "cost taken")
	_ok(_sys.can_undo(), "undo is available")
	_eq(_sys.undo_label(), "Place Coal Generator", "undo is labelled for the player")
	_sys.execute({"op": &"undo"})
	_ok(_sys.get_building(id) == null, "building removed by undo")
	_eq(_sys.stock.count(&"scrap"), scrap0, "scrap restored exactly")
	_eq(_sys.stock.count(&"iron_plate"), iron0, "iron restored exactly")
	_ok(_sys.is_cell_free(Vector2i(11, 10)), "cells released by undo")

	# Redo puts it back, with the same id and the same price.
	_ok(_sys.can_redo(), "redo is available")
	_sys.execute({"op": &"redo"})
	_ok(_sys.get_building(id) != null, "redo restores the same building id")
	_eq(_sys.stock.count(&"scrap"), scrap0 - 45, "redo takes the cost again")
	_eq(_sys.building_count(), 1, "redo does not duplicate")

	# Undoing a removal restores the building and reverses the salvage.
	_sys.execute({"op": &"place", "kind": &"wall", "cell": Vector2i(3, 3)})
	_advance(80)
	var wall: BuildingInstance = _sys.building_at(Vector2i(3, 3))
	_eq(wall.state, BuildTypes.State.OPERATIONAL, "wall finished")
	var stone_before: int = _sys.stock.count(&"stone")
	_sys.execute({"op": &"remove", "cell": Vector2i(3, 3), "instant": true})
	_eq(_sys.stock.count(&"stone"), stone_before + 3, "salvage paid out")
	_sys.execute({"op": &"undo"})
	var back: BuildingInstance = _sys.building_at(Vector2i(3, 3))
	_ok(back != null, "demolished wall is restored")
	_eq(back.id, wall.id, "restored with its original id")
	_eq(back.state, BuildTypes.State.OPERATIONAL, "restored in its original state")
	_eq(_sys.stock.count(&"stone"), stone_before, "salvage handed back")

	# Undoing a rotation.
	var cid: int = _put(&"coal_generator", Vector2i(30, 30))
	_sys.execute({"op": &"rotate", "id": cid, "delta": 1})
	_eq(_sys.get_building(cid).rot, 1, "turned")
	_sys.execute({"op": &"undo"})
	_eq(_sys.get_building(cid).rot, 0, "rotation undone")
	_sys.execute({"op": &"redo"})
	_eq(_sys.get_building(cid).rot, 1, "rotation redone")

	# Undo stack has a floor.
	_fresh()
	var empty: Dictionary = _sys.execute({"op": &"undo"})
	_eq(empty["code"], BuildTypes.CODE_NOTHING_TO_UNDO, "empty stack reports itself")


func _test_blueprint_roundtrip() -> void:
	_fresh()
	_put(&"heat_pipe", Vector2i(30, 30))
	_put(&"heat_pipe", Vector2i(31, 30))
	_put(&"heat_pipe", Vector2i(32, 30))
	_put(&"warmth_radiator", Vector2i(31, 31))
	_put(&"coal_generator", Vector2i(29, 33))

	var r: Dictionary = _sys.execute({
		"op": &"capture_blueprint", "from": Vector2i(29, 29), "to": Vector2i(34, 35), "title": "Heat spur",
	})
	_ok(bool(r["ok"]), "capture succeeded (%s)" % String(r.get("reason", "")))
	_eq(r["entries"], 5, "captured every building in the region")
	var bp: Blueprint = _sys.book.get_bp(StringName(String(r["blueprint"])))
	_ok(bp != null, "blueprint is in the book")
	_eq(bp.total_cost().get(&"iron_plate", 0), 2 * 3 + 12 + 20, "blueprint totals its materials")

	# JSON round-trip must be lossless.
	var json: String = JSON.stringify(bp.to_dict())
	var parsed: Variant = JSON.parse_string(json)
	_ok(typeof(parsed) == TYPE_DICTIONARY, "blueprint serialises to plain JSON")
	var copy: Blueprint = Blueprint.from_dict(parsed)
	_eq(copy.signature(), bp.signature(), "JSON round-trip preserves the layout")
	_eq(copy.entry_count(), bp.entry_count(), "round-trip keeps every entry")

	# Disk round-trip.
	var path: String = "user://blueprints/test_spur.json"
	_eq(bp.save_to_file(path), OK, "blueprint written to disk")
	var from_disk: Blueprint = Blueprint.load_from_file(path)
	_ok(from_disk != null, "blueprint read back from disk")
	_eq(from_disk.signature(), bp.signature(), "disk round-trip preserves the layout")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	# Four quarter turns is the identity; two mirrors likewise.
	_eq(bp.rotated_cw(4).signature(), bp.signature(), "four turns return to the start")
	_eq(bp.mirrored_x().mirrored_x().signature(), bp.signature(), "mirroring twice is a no-op")
	_eq(bp.mirrored_y().mirrored_y().signature(), bp.signature(), "vertical mirror is its own inverse")
	var turned: Blueprint = bp.rotated_cw(1)
	_eq(turned.size, Vector2i(bp.size.y, bp.size.x), "the bounding box turns with it")
	_eq(turned.entry_count(), bp.entry_count(), "rotation keeps every building")
	for e: BlueprintEntry in turned.entries:
		_ok(e.offset.x >= 0 and e.offset.y >= 0, "rotated entry stays inside the stamp")
		_ok(e.offset.x + e.span.x <= turned.size.x, "rotated entry fits horizontally")
		_ok(e.offset.y + e.span.y <= turned.size.y, "rotated entry fits vertically")
	# A 3x2 generator must actually become 2x3 in the rotated stamp.
	var found: bool = false
	for e: BlueprintEntry in turned.entries:
		if e.kind == &"coal_generator":
			found = true
			_eq(e.span, Vector2i(2, 3), "rotated generator span")
			_eq(e.rot, 1, "rotated generator facing")
	_ok(found, "generator survived the rotation")


## workshop (4x3) and field_kitchen (3x2) are non-square AND non-rotatable. A
## turned stamp used to swap their declared span while the paste forced rot back
## to 0, so what landed did not match what the stamp had reserved — in a dense
## blueprint that silently overlaps and drops entries.
func _test_blueprint_fixed_rotation() -> void:
	_fresh()
	_put(&"workshop", Vector2i(30, 30))
	_put(&"field_kitchen", Vector2i(35, 30))
	_put(&"heat_pipe", Vector2i(30, 34))
	var cap: Dictionary = _sys.execute({
		"op": &"capture_blueprint", "from": Vector2i(29, 29), "to": Vector2i(39, 36),
		"title": "Works",
	})
	_ok(bool(cap["ok"]), "captured the works block")
	var bp: Blueprint = _sys.book.get_bp(StringName(String(cap["blueprint"])))
	for e: BlueprintEntry in bp.entries:
		if e.kind == &"workshop" or e.kind == &"field_kitchen":
			_ok(e.fixed, "%s is recorded as un-turnable" % String(e.kind))

	var turned: Blueprint = bp.rotated_cw(1)
	for e2: BlueprintEntry in turned.entries:
		if e2.kind == &"workshop":
			_eq(e2.span, Vector2i(4, 3), "a turned workshop keeps its 4x3 footprint")
			_eq(e2.rot, 0, "and keeps facing the only way it can")
		if e2.kind == &"field_kitchen":
			_eq(e2.span, Vector2i(3, 2), "a turned field kitchen keeps its 3x2 footprint")
	_eq(bp.rotated_cw(4).signature(), bp.signature(), "four turns are still the identity")

	# And the promise that matters: pasting the turned stamp places every entry.
	var paste: Dictionary = _sys.execute({
		"op": &"place_blueprint", "blueprint": String(cap["blueprint"]),
		"cell": Vector2i(80, 60), "rot": 1, "free": true, "instant": true,
	})
	_ok(bool(paste["ok"]), "the turned stamp pasted (%s)" % String(paste.get("reason", "")))
	_eq(paste["skipped"], 0, "a turned stamp must not collide with itself")
	_eq(paste["placed"], turned.entry_count(), "every entry in the turned stamp landed")


func _test_blueprint_stamp() -> void:
	_fresh()
	_put(&"heat_pipe", Vector2i(30, 30))
	_put(&"heat_pipe", Vector2i(31, 30))
	_put(&"heat_pipe", Vector2i(32, 30))
	_put(&"warmth_radiator", Vector2i(31, 31))
	var cap: Dictionary = _sys.execute({
		"op": &"capture_blueprint", "from": Vector2i(30, 30), "to": Vector2i(33, 33), "title": "Spur",
	})
	var bp_id: String = String(cap["blueprint"])
	var original: Blueprint = _sys.book.get_bp(StringName(bp_id)).normalized()
	var before: int = _sys.building_count()

	# Paste as ghosts: nothing is charged yet, everything is planned.
	var scrap0: int = _sys.stock.count(&"scrap")
	var paste: Dictionary = _sys.execute({
		"op": &"place_blueprint", "blueprint": bp_id, "cell": Vector2i(50, 50),
	})
	_ok(bool(paste["ok"]), "paste accepted (%s)" % String(paste.get("reason", "")))
	_eq(paste["placed"], 4, "four ghosts planned")
	_eq(_sys.building_count(), before + 4, "four new buildings exist")
	_eq(_sys.stock.count(&"scrap"), scrap0, "ghosts cost nothing up front")
	var ghost: BuildingInstance = _sys.building_at(Vector2i(50, 50))
	_ok(ghost != null and ghost.state == BuildTypes.State.GHOST, "pasted entries start as ghosts")

	# Construction fulfils the stamp over time.
	_advance(600)
	var done: int = 0
	for b: BuildingInstance in _sys.buildings_in_rect(Rect2i(50, 50, 4, 4)):
		if b.state == BuildTypes.State.OPERATIONAL:
			done += 1
	_eq(done, 4, "the whole stamp got built")

	# Re-capturing the pasted copy reproduces the original layout exactly.
	var recap: Dictionary = _sys.execute({
		"op": &"capture_blueprint", "from": Vector2i(50, 50), "to": Vector2i(53, 53), "title": "Copy",
	})
	var copy: Blueprint = _sys.book.get_bp(StringName(String(recap["blueprint"]))).normalized()
	_eq(copy.signature(), original.signature(), "pasted layout matches the source")

	# One undo removes the whole stamp.
	_fresh()
	_put(&"heat_pipe", Vector2i(30, 30))
	_put(&"heat_pipe", Vector2i(31, 30))
	_put(&"warmth_radiator", Vector2i(30, 31))
	var cap2: Dictionary = _sys.execute({
		"op": &"capture_blueprint", "from": Vector2i(30, 30), "to": Vector2i(32, 32),
	})
	var count_before: int = _sys.building_count()
	_sys.execute({"op": &"place_blueprint", "blueprint": String(cap2["blueprint"]), "cell": Vector2i(60, 60)})
	_eq(_sys.building_count(), count_before + 3, "stamp placed three")
	_sys.execute({"op": &"undo"})
	_eq(_sys.building_count(), count_before, "one undo removed the entire stamp")
	_sys.execute({"op": &"redo"})
	_eq(_sys.building_count(), count_before + 3, "one redo put it back")

	# Mirrored and rotated pastes land where they should.
	var rotated: Dictionary = _sys.execute({
		"op": &"place_blueprint", "blueprint": String(cap2["blueprint"]),
		"cell": Vector2i(80, 80), "rot": 1,
	})
	_ok(bool(rotated["ok"]), "rotated paste accepted")
	_eq(rotated["placed"], 3, "rotated paste placed everything")
	var mirrored: Dictionary = _sys.execute({
		"op": &"place_blueprint", "blueprint": String(cap2["blueprint"]),
		"cell": Vector2i(90, 90), "mirror_x": true,
	})
	_eq(mirrored["placed"], 3, "mirrored paste placed everything")

	# Pasting onto an identical layout is a no-op, not an error.
	var again: Dictionary = _sys.execute({
		"op": &"place_blueprint", "blueprint": String(cap2["blueprint"]), "cell": Vector2i(60, 60),
	})
	_ok(bool(again["ok"]), "re-pasting over itself succeeds")
	_eq(again["placed"], 0, "nothing was placed twice")
	_eq(again["matched"], 3, "existing buildings recognised")

	# An empty region cannot be copied.
	var empty: Dictionary = _sys.execute({
		"op": &"capture_blueprint", "from": Vector2i(300, 300), "to": Vector2i(310, 310),
	})
	_eq(empty["code"], BuildTypes.CODE_EMPTY_REGION, "empty capture refused")


func _test_drags() -> void:
	_fresh()
	_sys.execute({"op": &"set_stock", "items": {&"iron_plate": 999, &"stone": 999}})
	var line: Dictionary = _sys.execute({
		"op": &"place_line", "kind": &"heat_pipe", "from": Vector2i(10, 10), "to": Vector2i(14, 12),
	})
	_ok(bool(line["ok"]), "line drag accepted")
	_eq(line["placed"], 7, "L-shaped run covers 5 across and 2 down")
	_ok(_sys.building_at(Vector2i(12, 10)) != null, "horizontal leg placed")
	_ok(_sys.building_at(Vector2i(14, 12)) != null, "vertical leg reaches the end")
	_sys.execute({"op": &"undo"})
	_ok(_sys.building_at(Vector2i(12, 10)) == null, "one undo clears the whole run")

	var area: Dictionary = _sys.execute({
		"op": &"place_area", "kind": &"rubble_road", "from": Vector2i(20, 20), "to": Vector2i(23, 22),
	})
	_eq(area["placed"], 12, "area drag fills a 4x3 rectangle")
	var big: Dictionary = _sys.execute({
		"op": &"place_area", "kind": &"rubble_road", "from": Vector2i(0, 0), "to": Vector2i(999, 999),
	})
	_eq(big["code"], BuildTypes.CODE_REGION_TOO_LARGE, "absurd drags are refused")
	var bad: Dictionary = _sys.execute({
		"op": &"place_line", "kind": &"smelter", "from": Vector2i(0, 0), "to": Vector2i(5, 0),
	})
	_ok(not bool(bad["ok"]), "multi-tile buildings cannot be dragged in a line")

	# Area demolition.
	var removed: Dictionary = _sys.execute({
		"op": &"remove_area", "from": Vector2i(20, 20), "to": Vector2i(23, 22), "instant": true,
	})
	_eq(removed["removed"], 12, "area demolition removed the whole patch")
	_ok(_sys.is_cell_free(Vector2i(21, 21)), "patch is clear")


func _test_damage() -> void:
	_fresh()
	var id: int = _put(&"wall", Vector2i(7, 7))
	var b: BuildingInstance = _sys.get_building(id)
	var destroyed: bool = _sys.apply_damage(id, 104.0, &"test")
	_ok(not destroyed, "a wall survives one hit")
	_near(b.hp, 400.0, "armour absorbed 4 of 104 damage")
	_ok(b.health_ratio() < 1.0, "damage is visible in the health ratio")

	# Repair charges materials and restores the structure.
	_sys.execute({"op": &"set_stock", "items": {&"stone": 100}})
	var stone0: int = _sys.stock.count(&"stone")
	var rep: Dictionary = _sys.execute({"op": &"repair", "id": id})
	_ok(bool(rep["ok"]), "repair accepted (%s)" % String(rep.get("reason", "")))
	_near(b.hp, b.max_hp, "repaired to full")
	_ok(_sys.stock.count(&"stone") < stone0, "repair cost materials")

	# Salvage scales with condition: a wreck returns less.
	_sys.apply_damage(id, 254.0, &"test")
	var stone1: int = _sys.stock.count(&"stone")
	_sys.execute({"op": &"remove", "id": id, "instant": true})
	_eq(_sys.stock.count(&"stone"), stone1 + 1, "a half-wrecked wall salvages less")

	# Enough damage destroys it and frees the ground.
	var id2: int = _put(&"wall", Vector2i(9, 9))
	_ok(_sys.apply_damage(id2, 9999.0, &"test"), "overwhelming damage destroys")
	_ok(_sys.get_building(id2) == null, "destroyed building is removed")
	_ok(_sys.is_cell_free(Vector2i(9, 9)), "ground is free again")

	# Frozen and disabled states round-trip.
	var id3: int = _put(&"smelter", Vector2i(70, 70))
	_sys.set_frozen(id3, true)
	_eq(_sys.get_building(id3).state, BuildTypes.State.FROZEN, "heat can freeze a building")
	_ok(not _sys.is_running(id3), "frozen buildings do not run")
	_sys.set_frozen(id3, false)
	_eq(_sys.get_building(id3).state, BuildTypes.State.OPERATIONAL, "thawing restores it")
	_sys.set_enabled(id3, false)
	_eq(_sys.get_building(id3).state, BuildTypes.State.DISABLED, "player switch works")
	_sys.execute({"op": &"undo"})
	_eq(_sys.get_building(id3).state, BuildTypes.State.OPERATIONAL, "the switch is undoable")


func _test_command_path() -> void:
	_fresh()
	Sim.submit_command({"system": &"build", "op": &"place", "kind": &"wall", "cell": [15, 15]})
	_ok(_sys.building_at(Vector2i(15, 15)) == null, "commands are queued, not applied instantly")
	_advance(1)
	var b: BuildingInstance = _sys.building_at(Vector2i(15, 15))
	_ok(b != null, "command applied on the next tick")
	_eq(b.kind, &"wall", "the right building was placed")

	# JSON scenarios can only carry arrays, so cells must parse from them.
	Sim.submit_command({"system": &"build", "op": &"place", "kind": &"wall", "cell": [16, 15]})
	_advance(1)
	_ok(_sys.building_at(Vector2i(16, 15)) != null, "array cells parse")
	_eq(BuildTypes.to_cell("3,-4"), Vector2i(3, -4), "string cells parse")
	_eq(BuildTypes.to_cell({"x": 2, "y": 9}), Vector2i(2, 9), "dictionary cells parse")

	# A nonsense command must not take the system down.
	var bad: Dictionary = _sys.execute({"op": &"fly_to_the_moon"})
	_eq(bad["code"], BuildTypes.CODE_BAD_COMMAND, "unknown ops are refused politely")
	_sys.execute({"op": &"remove", "cell": [900, 900]})
	_sys.execute({"op": &"rotate"})
	_sys.execute({"op": &"place", "kind": &"", "cell": [1, 1]})
	_ok(true, "malformed commands do not crash the system")


func _test_serialization() -> void:
	_fresh()
	_put(&"the_hearth", Vector2i(0, 0))
	_put(&"heat_pipe", Vector2i(5, 2))
	_put(&"coal_generator", Vector2i(6, 2), 1)
	_sys.execute({"op": &"place", "kind": &"wall", "cell": Vector2i(10, 10)})
	_sys.execute({"op": &"capture_blueprint", "from": Vector2i(0, 0), "to": Vector2i(8, 8), "title": "Core"})
	_advance(20)

	var state: Dictionary = _sys.serialize()
	var json: String = JSON.stringify(state)
	_ok(json.length() > 0, "state stringifies to JSON")
	var reparsed: Variant = JSON.parse_string(json)
	_ok(typeof(reparsed) == TYPE_DICTIONARY, "state is JSON-safe (no Vector2i leaks)")

	var buildings_before: int = _sys.building_count()
	var scrap_before: int = _sys.stock.count(&"scrap")

	_fresh(99)
	_eq(_sys.building_count(), 0, "fresh world is empty")
	_sys.deserialize(reparsed)
	_eq(_sys.building_count(), buildings_before, "every building restored")
	_eq(_sys.stock.count(&"scrap"), scrap_before, "stock restored")
	_ok(_sys.building_at(Vector2i(2, 2)) != null, "hearth footprint restored")
	_ok(_sys.building_at(Vector2i(7, 2)) != null, "rotated generator footprint restored")
	_eq(_sys.book.size(), 1, "blueprint book restored")
	# Compared as sorted JSON, which is exactly what the harness diffs. Key
	# insertion order is not part of the state; the values are.
	_eq(JSON.stringify(_sys.serialize()), json, "serialize is stable across a round-trip")


func _test_determinism() -> void:
	var runs: Array[String] = []
	for attempt: int in 2:
		_fresh(1234)
		var script: Array[Dictionary] = [
			{"op": &"place", "kind": &"the_hearth", "cell": Vector2i(0, 0), "free": true, "instant": true},
			{"op": &"place_line", "kind": &"heat_pipe", "from": Vector2i(5, 2), "to": Vector2i(9, 2)},
			{"op": &"place", "kind": &"warmth_radiator", "cell": Vector2i(9, 3)},
			{"op": &"place", "kind": &"coal_generator", "cell": Vector2i(12, 2)},
			{"op": &"place_area", "kind": &"wall", "from": Vector2i(20, 0), "to": Vector2i(20, 6)},
			{"op": &"capture_blueprint", "from": Vector2i(5, 2), "to": Vector2i(10, 4), "title": "Spur"},
		]
		for cmd: Dictionary in script:
			_sys.execute(cmd)
			_advance(37)
		_sys.execute({"op": &"place_blueprint", "blueprint": "bp_1", "cell": Vector2i(5, 20)})
		_advance(400)
		_sys.execute({"op": &"undo"})
		_advance(50)
		runs.append(JSON.stringify(_sys.serialize()))
	_eq(runs[0].sha256_text(), runs[1].sha256_text(), "same inputs produce byte-identical state")
	_ok(runs[0].length() > 500, "the run actually built something")


## The only case that runs against [P01]'s real terrain. It proves the adapter
## actually bound to the grid that exists today — the failure mode this catches
## is the quiet one, where every probe misses and construction silently falls
## back to "anywhere is fine, there is no ore anywhere".
func _test_world_binding() -> void:
	_fresh(7, false)
	var grid: SimSystem = Sim.get_system(&"grid")
	if grid == null:
		_ok(true, "no grid system present yet; permissive fallback in use")
		return
	_ok(_sys.world.has_grid(), "adapter bound to the grid system")
	var wiring: String = _sys.world.describe()
	print("       grid binding: %s" % wiring)
	_ok(not wiring.contains("bounds=-"), "world bounds are answered by the grid")
	_ok(not wiring.contains("buildable=-"), "terrain buildability is answered by the grid")
	_ok(not wiring.contains("deposits=-"), "deposits are answered by the grid")
	_ok(not wiring.contains("claim=-"), "footprints can be claimed with the grid")

	# Terrain names must resolve to words, not raw enum indices.
	var core: Vector2i = Vector2i(int(grid.call("core_cell").x), int(grid.call("core_cell").y))
	var t: StringName = _sys.world.terrain_at(core)
	_ok(String(t) != "", "terrain at the core has a name")
	_ok(not String(t).begins_with("terrain_"), "terrain name resolved from the grid's table, got '%s'" % String(t))

	# What the adapter calls buildable is exactly what can_place accepts.
	var agreed: int = 0
	var checked: int = 0
	for dx: int in range(-30, 31, 5):
		for dy: int in range(-30, 31, 5):
			var c: Vector2i = core + Vector2i(dx, dy)
			checked += 1
			var allowed: bool = bool(_sys.can_place(&"wall", c, 0, false)["ok"])
			if allowed == _sys.world.is_buildable(c):
				agreed += 1
	_eq(agreed, checked, "placement agrees with the grid on every sampled cell")

	# A real map must actually accept a real drill somewhere. This is the check
	# that catches the quiet catastrophe: the ore rule refusing every cell in the
	# world because the deposit question never reached the grid.
	var kinds: Dictionary[StringName, int] = {}
	var drill_spots: int = 0
	var vent_tiles: int = 0
	for dx: int in range(-70, 71):
		for dy: int in range(-70, 71):
			var c: Vector2i = core + Vector2i(dx, dy)
			var ore: StringName = _sys.world.ore_at(c)
			if String(ore) == "":
				continue
			kinds[ore] = int(kinds.get(ore, 0)) + 1
			if ore == &"vent":
				vent_tiles += 1
			if bool(_sys.can_place(&"ore_drill", c, 0, false)["ok"]):
				drill_spots += 1
	print("       deposits within 70 tiles: %s" % str(kinds))
	_ok(kinds.size() > 0, "the map carries deposits near the core")
	for k: StringName in kinds:
		_ok(not String(k).begins_with("deposit_"), "deposit name '%s' resolved from the grid's table" % String(k))
	_ok(drill_spots > 0, "an ore drill fits over real deposits (%d valid origins)" % drill_spots)

	# The geothermal tap is gated on a vent, and vents must be findable.
	_sys.execute({"op": &"grant_unlock", "unlock": &"geothermal_tapping"})
	if vent_tiles > 0:
		var tap_spots: int = 0
		var why: Dictionary[String, int] = {}
		for dx: int in range(-70, 71):
			for dy: int in range(-70, 71):
				var c: Vector2i = core + Vector2i(dx, dy)
				if _sys.world.ore_at(c) != &"vent":
					continue
				# The vent may sit anywhere under the 3x3, so try every origin.
				for ox: int in range(-2, 1):
					for oy: int in range(-2, 1):
						var r: Dictionary = _sys.can_place(&"geothermal_tap", c + Vector2i(ox, oy), 0, false)
						if bool(r["ok"]):
							tap_spots += 1
						else:
							var code: String = String(r["code"])
							why[code] = int(why.get(code, 0)) + 1
		_ok(tap_spots > 0, "a geothermal tap fits over a real vent (%d valid origins over %d vent tiles, refusals: %s)" % [
			tap_spots, vent_tiles, str(why)])

	# Claiming a footprint must reach the grid, so pathing routes around walls.
	var spot: Vector2i = Vector2i(-1, -1)
	for dx: int in range(-20, 21):
		var c: Vector2i = core + Vector2i(dx, 6)
		if bool(_sys.can_place(&"wall", c, 0, false)["ok"]) and int(grid.call("building_at", c)) == 0:
			spot = c
			break
	_ok(spot.x >= 0, "found clear ground for a wall")
	if spot.x < 0:
		return
	var wid: int = _put(&"wall", spot)
	_eq(int(grid.call("building_at", spot)), wid, "the grid knows the finished wall is there")
	_sys.execute({"op": &"remove", "id": wid, "instant": true})
	_eq(int(grid.call("building_at", spot)), 0, "the grid learns when it comes down again")
