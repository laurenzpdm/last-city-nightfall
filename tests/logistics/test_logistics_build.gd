extends TestCase
## [P03] THE AUTOMATION PILLAR IS REACHABLE.
##
## Every case here goes through the command a player's click produces —
## `{"system": "build", "op": "place"/"place_line"/"remove"}` — and never through
## the logistics command surface, because the thing this suite exists to catch
## is precisely the difference between the two.
##
## The build it was written against had a complete, tested, fast transport
## system that no human could touch: belts were not BuildingDefs, so
## BuildCatalog never listed one, so the palette never offered one, so
## `logistics.belt_lines` was 0 for twenty-four thousand ticks of the reference
## run while 768 tests stayed green. A test that only ever calls
## `LogisticsSystem.place()` cannot see that, and did not.

## Where the world generator leaves flat ground. Verified per test rather than
## assumed: a hard-coded cell that quietly stops being buildable is how a suite
## turns into a suite of skips.
const SEARCH_FROM: int = 30
const SEARCH_TO: int = 210

var world: SimFixture = null
var logi: LogisticsSystem = null
var build: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["logistics", "build"])


func setup() -> void:
	world = SimFixture.new(7).start()
	logi = world.system(&"logistics") as LogisticsSystem
	build = world.system(&"build")
	world.cmd({"system": &"build", "op": "grant_unlock", "unlock": "splitters_and_balancers"})
	world.cmd({"system": &"build", "op": "grant_unlock", "unlock": "logistic_scheduling"})
	world.cmd_now({"system": &"build", "op": "add_stock", "items": {
		"iron_plate": 900, "gear": 400, "timber": 300, "scrap": 400,
		"steel_plate": 300, "stone": 400, "circuit": 100}})


func teardown() -> void:
	if world != null:
		world.stop()


# --- helpers -----------------------------------------------------------------

func _can(kind: StringName, cell: Vector2i, rot: int = 0) -> bool:
	return bool((build.call("can_place", kind, cell, rot, false, -1) as Dictionary).get("ok", false))


## West end of a clear east-running row of `length` buildable tiles.
func _run_of(length: int) -> Vector2i:
	for y: int in range(SEARCH_FROM, SEARCH_TO, 3):
		for x: int in range(SEARCH_FROM, SEARCH_TO - length, 3):
			var clear: bool = true
			for i: int in length:
				if not _can(&"belt_mk1", Vector2i(x + i, y)):
					clear = false
					break
			if clear:
				return Vector2i(x, y)
	return Vector2i.MAX


## A clear rectangle, so an L-shaped drag has room to turn.
func _area_of(size: Vector2i) -> Vector2i:
	for y: int in range(SEARCH_FROM, SEARCH_TO - size.y, 3):
		for x: int in range(SEARCH_FROM, SEARCH_TO - size.x, 3):
			var clear: bool = true
			for dy: int in size.y:
				for dx: int in size.x:
					if not _can(&"belt_mk1", Vector2i(x + dx, y + dy)):
						clear = false
						break
				if not clear:
					break
			if clear:
				return Vector2i(x, y)
	return Vector2i.MAX


func _place(kind: String, cell: Vector2i, rot: int = 0) -> void:
	world.cmd({"system": &"build", "op": "place", "kind": kind,
		"cell": [cell.x, cell.y], "rot": rot, "free": true, "instant": true})


func _drag(kind: String, from: Vector2i, to: Vector2i, rot: int = 0) -> void:
	world.cmd({"system": &"build", "op": "place_line", "kind": kind,
		"from": [from.x, from.y], "to": [to.x, to.y], "rot": rot, "free": true})


func _rot_at(cell: Vector2i) -> int:
	var e: LogiEntity = logi.entity_at(cell)
	return -1 if e == null else e.rot


func _id_at(cell: Vector2i) -> int:
	var e: LogiEntity = logi.entity_at(cell)
	return -1 if e == null else e.id


# --- 1. it is in the catalogue ------------------------------------------------

func test_every_transport_piece_is_a_building_a_player_can_choose() -> void:
	var missing: PackedStringArray = PackedStringArray()
	for def: LogiDef in logi.all_defs():
		if build.call("def_of", def.id) == null:
			missing.append(String(def.id))
	assert_empty(missing,
		"a transport piece with no BuildingDef can never appear in a build menu: %s"
		% ", ".join(missing))
	assert_ge(float(logi.all_defs().size()), 16.0,
		"the transport ladder is belts, tunnels, splitters, arms and containers")


func test_the_opening_hand_needs_no_research() -> void:
	var free_now: Dictionary[StringName, bool] = {}
	for d: BuildingDef in build.call("available_defs"):
		free_now[d.id] = true
	for kind: StringName in [&"belt_mk1", &"underground_mk1", &"splitter_mk1",
			&"inserter_mk1", &"crate"]:
		assert_has(free_now, kind,
			"%s must be placeable in the first minute — the automation genre's front door" % kind)


func test_belts_are_walkable_and_do_not_wall_the_city_in() -> void:
	for kind: StringName in [&"belt_mk1", &"underground_mk1", &"splitter_mk1", &"inserter_mk1"]:
		var def: BuildingDef = build.call("def_of", kind)
		assert_false(def.blocks_movement, "%s must not block pathing" % kind)
		assert_true(def.walkable, "%s must be walkable" % kind)


# --- 2. placing one through the build system ----------------------------------

func test_a_belt_placed_by_the_build_command_becomes_a_transport_line() -> void:
	var o: Vector2i = _run_of(4)
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	_place("belt_mk1", o, 0)
	world.run(40)
	var e: LogiEntity = logi.entity_at(o)
	assert_not_null(e, "the belt building must have a transport entity")
	assert_true(e.from_build, "and it must know [P11] owns the ground under it")
	assert_eq(e.id, _building_id(o), "the belt and the building are the same id")
	assert_not_null(logi.segment_at(o), "one belt is already a transport line")


func test_removing_the_building_removes_the_belt() -> void:
	var o: Vector2i = _run_of(4)
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	_place("belt_mk1", o, 0)
	world.run(40)
	assert_not_null(logi.entity_at(o), "placed")
	world.cmd({"system": &"build", "op": "remove", "cell": [o.x, o.y], "instant": true})
	world.run(40)
	assert_null(logi.entity_at(o), "a demolished belt is not still moving items")
	assert_null(logi.segment_at(o), "and its line is gone with it")


func test_rotating_the_building_turns_the_belt() -> void:
	var o: Vector2i = _run_of(4)
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	_place("belt_mk1", o, 0)
	world.run(40)
	assert_eq(_rot_at(o), 0, "placed facing east")
	world.cmd({"system": &"build", "op": "rotate", "cell": [o.x, o.y], "rot": 1})
	world.run(40)
	assert_eq(_rot_at(o), 1, "R on a placed belt has to turn the belt, not just the sprite")
	var seg: LogiSegment = logi.segment_at(o)
	assert_not_null(seg, "and it is still a line")
	assert_eq(seg.dir, Vector2i(0, 1), "running south now")


# --- 3. the drag --------------------------------------------------------------

func test_a_dragged_run_faces_the_way_the_cursor_went() -> void:
	var o: Vector2i = _run_of(9)
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	# Dragged west-to-east, but the palette was left holding "north". The drag
	# has to win: nobody rotates a belt eight times to lay a line.
	_drag("belt_mk1", o, o + Vector2i(7, 0), 3)
	world.run(60)
	for i: int in 8:
		assert_eq(_rot_at(o + Vector2i(i, 0)), 0,
			"tile %d of the run must face east" % i)
	assert_eq(logi.world.segment_ids.size(), 1,
		"eight belts in a row are ONE transport line, not eight")


func test_a_dragged_corner_turns() -> void:
	var o: Vector2i = _area_of(Vector2i(9, 9))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	var corner: Vector2i = o + Vector2i(6, 0)
	_drag("belt_mk1", o, o + Vector2i(6, 6), 0)
	world.run(80)
	for i: int in 6:
		assert_eq(_rot_at(o + Vector2i(i, 0)), 0, "the east leg faces east")
	assert_eq(_rot_at(corner), 1,
		"THE corner tile: it must turn south, or the line dead-ends into itself")
	for j: int in range(1, 7):
		assert_eq(_rot_at(corner + Vector2i(0, j)), 1, "the south leg faces south")
	assert_eq(logi.world.segment_ids.size(), 2, "a corner cuts the run into two lines")


func test_a_dragged_corner_actually_carries_items_round_it() -> void:
	var o: Vector2i = _area_of(Vector2i(9, 10))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	_drag("belt_mk1", o, o + Vector2i(6, 6), 0)
	_place("crate", o + Vector2i(6, 7))
	world.run(80)
	var crate: LogiStore = logi.store_of(_id_at(o + Vector2i(6, 7)))
	assert_not_null(crate, "the crate at the end of the run has a store")
	for _i: int in 200:
		logi.world.push_onto_belt(o, 0, &"coal")
		logi.world.push_onto_belt(o, 1, &"coal")
		world.run(1)
	world.run(400)
	assert_gt(float(crate.count(&"coal")), 100.0,
		"coal put on the west end has to come out at the south end")


func test_a_row_of_arms_all_face_the_way_the_player_was_holding_them() -> void:
	var o: Vector2i = _area_of(Vector2i(6, 3))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	# Dragged east, held facing south. A drag re-aims BELTS, because a belt is a
	# path; it must not re-aim arms, because chaining them would point every arm
	# at the next arm instead of into the machine the player is feeding.
	_drag("inserter_mk1", o + Vector2i(0, 1), o + Vector2i(4, 1), 1)
	world.run(80)
	for i: int in 5:
		assert_eq(_rot_at(o + Vector2i(i, 1)), 1,
			"arm %d must still face south" % i)


func test_a_single_click_keeps_the_rotation_the_player_chose() -> void:
	var o: Vector2i = _run_of(4)
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	_place("belt_mk1", o, 2)
	world.run(40)
	assert_eq(_rot_at(o), 2, "one belt is a run of one and keeps what R said")


func test_a_drag_that_steps_over_something_splits_into_two_runs() -> void:
	var o: Vector2i = _area_of(Vector2i(10, 4))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	# A crate parked in the middle of the intended path.
	_place("crate", o + Vector2i(4, 0))
	world.run(40)
	_drag("belt_mk1", o, o + Vector2i(8, 0), 0)
	world.run(60)
	assert_eq(_rot_at(o + Vector2i(3, 0)), 0,
		"the belt before the obstacle still faces the way the drag went")
	assert_eq(_rot_at(o + Vector2i(5, 0)), 0,
		"and so does the one after it")
	var blocked: LogiEntity = logi.entity_at(o + Vector2i(4, 0))
	assert_not_null(blocked, "the crate is still standing where the drag stepped over it")
	assert_eq(String(blocked.kind), "crate", "nothing was built on top of the crate")


# --- 4. splitters ------------------------------------------------------------

func test_a_splitter_stands_on_the_same_two_tiles_both_systems_think_it_does() -> void:
	var o: Vector2i = _area_of(Vector2i(3, 3))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	for rot: int in 4:
		var anchor: Vector2i = o + Vector2i(1, 1)
		_place("splitter_mk1", anchor, rot)
		world.run(40)
		var b: Object = build.call("building_at", anchor)
		assert_not_null(b, "rot %d: the splitter building exists" % rot)
		var sp: LogiSplitter = logi.entity_at(anchor) as LogiSplitter
		assert_not_null(sp, "rot %d: and it has a splitter entity" % rot)
		if sp == null or b == null:
			continue
		assert_eq(sp.rot, rot, "rot %d: facing agrees" % rot)
		var theirs: Array = b.get("cells")
		assert_size(theirs, 2, "rot %d: a splitter is two tiles" % rot)
		for c: Vector2i in sp.footprint():
			assert_has(theirs, c,
				"rot %d: the splitter thinks it stands on %s and the build system does not"
				% [rot, str(c)])
		world.cmd({"system": &"build", "op": "remove", "cell": [anchor.x, anchor.y],
			"instant": true})
		world.run(40)


# --- 5. fuel comes down the belt, and stops when the belt is cut --------------

func test_an_arm_feeds_a_generator_and_cutting_the_belt_starves_it() -> void:
	var heat: SimSystem = world.system(&"heat")
	if heat == null:
		skip("no heat system in this build")
		return
	var g: Vector2i = _generator_site()
	if g == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	world.cmd({"system": &"build", "op": "set_stock", "items": {"coal": 0}})
	_place("coal_generator", g)
	_place("heat_pipe", g + Vector2i(3, 0))
	_place("warmth_radiator", g + Vector2i(4, 0))
	_place("crate", g - Vector2i(10, 0))
	_place("inserter_mk1", g - Vector2i(9, 0), 0)
	_drag("belt_mk1", g - Vector2i(8, 0), g - Vector2i(2, 0), 0)
	_place("inserter_mk1", g - Vector2i(1, 0), 0)
	world.run(60)
	world.cmd_now({"system": &"logistics", "op": "insert",
		"cell": [g.x - 10, g.y], "item": "coal", "count": 400})

	var gen: int = _building_id(g)
	assert_gt(float(gen), 0.0, "the generator is standing")
	world.run(600)
	assert_gt(float(logi.metrics()["fuel_by_machine"]), 0.0,
		"the arm has to have physically shovelled coal into the bunker")
	assert_eq(int(logi.metrics()["line_fed_burners"]), 1,
		"and the burner has to know it is on a line")
	assert_gt(float(heat.call("fuel_stock_of", gen)), 3.0, "the bunker filled")
	assert_gt(float((heat.call("totals") as Dictionary)["supply"]), 1.0,
		"and the city is warm because of it")
	var hauled_before: int = int(logi.metrics()["hauled_total"])

	# ✂ — one belt tile, exactly the way a player presses X.
	world.cmd({"system": &"build", "op": "remove",
		"cell": [g.x - 5, g.y], "instant": true})
	world.run(4600)
	assert_near(float(heat.call("fuel_stock_of", gen)), 0.0, 0.51,
		"the bunker has to run dry — nothing is arriving")
	assert_near(float((heat.call("totals") as Dictionary)["supply"]), 0.0, 0.01,
		"and the city goes cold BECAUSE the belt was cut")
	assert_eq(int(logi.metrics()["hauled_total"]), hauled_before,
		"no porter is allowed to quietly cover for a cut belt")
	assert_ge(float(logi.metrics()["lines_dry"]), 1.0,
		"and the player is told which failure this is")


func test_a_burner_with_no_line_is_still_fed_by_hand() -> void:
	var heat: SimSystem = world.system(&"heat")
	if heat == null:
		skip("no heat system in this build")
		return
	var g: Vector2i = _generator_site()
	if g == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	_place("coal_generator", g)
	_place("heat_pipe", g + Vector2i(3, 0))
	_place("warmth_radiator", g + Vector2i(4, 0))
	world.run(300)
	var gen: int = _building_id(g)
	assert_eq(int(logi.metrics()["line_fed_burners"]), 0, "nobody built a line")
	assert_gt(float(heat.call("fuel_stock_of", gen)), 0.0,
		"a generator with no belt is still hauled to — the interlock must not "
		+ "break the game for a player who has not automated yet")


# --- 6. throughput matches the tooltip, on the player's own path -------------

func test_a_dragged_belt_delivers_exactly_what_it_claims() -> void:
	for kind: String in ["belt_mk1", "belt_mk2", "belt_mk3"]:
		world.restart()
		logi = world.system(&"logistics") as LogisticsSystem
		build = world.system(&"build")
		world.cmd({"system": &"build", "op": "grant_unlock", "unlock": "splitters_and_balancers"})
		world.cmd_now({"system": &"build", "op": "grant_unlock", "unlock": "logistic_scheduling"})
		var o: Vector2i = _run_of(13)
		if o == Vector2i.MAX:
			skip("no clear ground on this seed")
			return
		_drag(kind, o, o + Vector2i(11, 0), 0)
		_place("bunker_chest", o + Vector2i(12, 0))
		# A belt is a construction site like anything else, and a driven belt is
		# three seconds of work a tile. Measure a FINISHED line or the number is
		# the queue's, not the belt's.
		assert_true(_await_line(o, 12), "%s: the whole run finished building" % kind)
		var sink: LogiStore = logi.store_of(_id_at(o + Vector2i(12, 0)))
		assert_not_null(sink, "%s: the crate at the end has a store" % kind)
		if sink == null:
			continue
		_saturate(o, sink, 200)
		var measured: int = _saturate(o, sink, 1200)
		var declared: float = logi.def_of(StringName(kind)).belt_rate() * 60.0
		assert_near(float(measured), declared, declared * 0.02,
			"%s claims %.0f items a minute and delivered %d" % [kind, declared, measured])


## Ticks until every tile of a run of `length` belts east of `entry` is standing.
func _await_line(entry: Vector2i, length: int) -> bool:
	for _wait: int in 200:
		var done: bool = true
		for i: int in length:
			if logi.entity_at(entry + Vector2i(i, 0)) == null:
				done = false
				break
		if done:
			return true
		world.run(20)
	return false


## Fills the back of the line every tick and empties the sink every tick, so
## neither end can be the bottleneck. Returns what crossed.
func _saturate(entry: Vector2i, sink: LogiStore, ticks: int) -> int:
	var delivered: int = 0
	for _i: int in ticks:
		for lane: int in LogiTypes.LANES:
			var guard: int = 0
			while logi.world.push_onto_belt(entry, lane, &"coal") and guard < 4:
				guard += 1
		world.run(1)
		delivered += sink.take(&"coal", 1 << 20)
	return delivered


# --- 7. it stays deterministic ------------------------------------------------

func test_the_same_drag_twice_produces_the_same_world() -> void:
	assert_deterministic(_replay_a_drag, "a dragged run replays byte for byte")


func _replay_a_drag() -> Variant:
	var w := SimFixture.new(11).start()
	w.cmd_now({"system": &"build", "op": "add_stock", "items": {"iron_plate": 400}})
	var o := Vector2i(40, 40)
	w.cmd({"system": &"build", "op": "place_line", "kind": "belt_mk1",
		"from": [o.x, o.y], "to": [o.x + 6, o.y + 6], "rot": 0, "free": true})
	w.run(120)
	var out: Dictionary = (w.system(&"logistics") as LogisticsSystem).serialize()
	w.stop()
	return JSON.stringify(out)


# --- shared ------------------------------------------------------------------

func _building_id(cell: Vector2i) -> int:
	var b: Object = build.call("building_at", cell)
	return -1 if b == null else int(b.get("id"))


## A generator origin with ten clear tiles west of it and room for a pipe and a
## radiator east of it, so the burner has both a supply line and a load.
func _generator_site() -> Vector2i:
	for y: int in range(SEARCH_FROM, SEARCH_TO, 3):
		for x: int in range(SEARCH_FROM + 12, SEARCH_TO, 3):
			var g := Vector2i(x, y)
			if not _can(&"coal_generator", g):
				continue
			var clear: bool = true
			for i: int in range(1, 11):
				if not _can(&"belt_mk1", g - Vector2i(i, 0)):
					clear = false
					break
			for c: Vector2i in [Vector2i(3, 0), Vector2i(4, 0), Vector2i(4, 1),
					Vector2i(5, 0), Vector2i(5, 1)]:
				if not clear:
					break
				if not _can(&"heat_pipe", g + c):
					clear = false
			if clear:
				return g
	return Vector2i.MAX
