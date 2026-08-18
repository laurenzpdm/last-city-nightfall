extends TestCase
## [P03] THE FACTORY IS ON THE BELT, OR IT IS NOT A FACTORY.
##
## Everything here is about the seam between transport and production, and it
## exists because that seam was OPEN for the whole life of this project while
## every suite on either side of it passed.
##
## ProductionSystem has published `offer_input()` and `take_output()` since the
## first wave with "[P03] logistics hands items to a machine's input buffer"
## written over them. Nothing in game/sim/logistics/ ever called either one, and
## `_has_accept_output` resolved to false in every run ever made. So a machine
## took its ingredients out of the city stockpile and put its output straight
## back into it — no carrier, no distance, no cost, in the same tick — and the
## only thing ever seen on a belt in the reference run was coal, because a
## burner's bunker was the single destination in the game that was wired up.
##
## The three rules these cases hold, each of which is a thing a player does:
##
##   1. A BELT THAT RUNS INTO A MACHINE FEEDS THE MACHINE. Not "backs up against
##      it", which is what it did: _resolve_sink knew about chests, splitters and
##      other belts, and a machine was none of those, so the line resolved to
##      Sink.NONE and then this same system reported it as a belt to nowhere.
##   2. AN ARM ON A MACHINE CARRIES ITS OUTPUT AWAY. Production hands its craft
##      to the transport layer instead of to the city stores.
##   3. AND ONLY THEN. A machine with no arm on it behaves exactly as it did
##      before any of this existed, which is why turning it on could not move a
##      single number in the reference run.
##
## Read case 3 as the teeth of cases 1 and 2: it is the assertion that would
## have gone red if the interlock had been written as "always on", which is the
## version that would have quietly rerouted every machine in every scenario.

const SEARCH_FROM: int = 30
const SEARCH_TO: int = 200

var world: SimFixture = null
var logi: LogisticsSystem = null
var prod: SimSystem = null
var build: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["logistics", "production", "build"])


func setup() -> void:
	world = SimFixture.new(7).start()
	logi = world.system(&"logistics") as LogisticsSystem
	prod = world.system(&"production")
	build = world.system(&"build")
	world.cmd_now({"system": &"build", "op": "add_stock", "items": {
		"iron_plate": 2000, "gear": 400, "timber": 400, "scrap": 600,
		"steel_plate": 400, "stone": 600, "coal": 400}})
	# The machines under test are graded on TRANSPORT, not on the labour market
	# or the weather, so both are taken out of the question the same way
	# tests/production/ does it. Every assertion below is about where an item
	# physically went.
	if prod.has_method("set_staffing_autarky"):
		prod.call("set_staffing_autarky", true)
	if prod.has_method("set_heat_autarky"):
		prod.call("set_heat_autarky", true)


func teardown() -> void:
	if world != null:
		world.stop()


# --- helpers -----------------------------------------------------------------

func _can(kind: StringName, cell: Vector2i) -> bool:
	return bool((build.call("can_place", kind, cell, 0, false, -1) as Dictionary).get("ok", false))


## West end of a clear rectangle of buildable ground, or Vector2i.MAX.
func _area_of(size: Vector2i) -> Vector2i:
	for y: int in range(SEARCH_FROM, SEARCH_TO - size.y, 4):
		for x: int in range(SEARCH_FROM, SEARCH_TO - size.x, 4):
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
	world.cmd_now({"system": &"build", "op": "place", "kind": kind,
		"cell": [cell.x, cell.y], "rot": rot, "free": true, "instant": true})


func _drag(kind: String, from: Vector2i, to: Vector2i, rot: int = 0) -> void:
	world.cmd_now({"system": &"build", "op": "place_line", "kind": kind,
		"from": [from.x, from.y], "to": [to.x, to.y], "rot": rot, "free": true,
		"instant": true})


func _recipe(cell: Vector2i, id: String) -> void:
	world.cmd_now({"system": &"production", "op": "set_recipe",
		"cell": [cell.x, cell.y], "recipe": id})


func _building_at(cell: Vector2i) -> int:
	var b: Object = build.call("building_at", cell)
	return -1 if b == null else int(b.get("id"))


## Pours `kind` onto the back of a line every tick while the world runs, so the
## belt under test is never the thing that ran out.
func _feed(entry: Vector2i, ticks: int, kind: String) -> void:
	for _i: int in ticks:
		logi.world.give_to_cell(entry, StringName(kind), 2, entry - Vector2i(1, 0))
		world.run(1)


# --- 1. a belt that runs into a machine feeds it ------------------------------

func test_a_line_ending_at_a_smelter_is_a_sink_and_not_a_dead_end() -> void:
	var o: Vector2i = _area_of(Vector2i(12, 5))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	# A smelter three tiles east of the end of a six-tile belt run.
	var belt_from: Vector2i = o + Vector2i(0, 1)
	var belt_to: Vector2i = o + Vector2i(5, 1)
	var smelter: Vector2i = o + Vector2i(6, 0)      # 3x3, so its west face is x+6
	_drag("belt_mk1", belt_from, belt_to, 0)
	_place("smelter", smelter)
	_recipe(smelter, "iron_plate")
	world.run(4)

	var seg: LogiSegment = logi.world.segments.get(
		int(logi.world.seg_at.get(belt_to, -1)))
	assert_not_null(seg, "the drag did not make a line")
	assert_eq(seg.sink, LogiTypes.Sink.STORE,
		("a belt whose next tile is a smelter has a sink. Sink.NONE here is the bug "
		+ "this case exists for: the line backs up and the system then calls it a "
		+ "belt to nowhere, while the smelter beside it starves"))
	assert_eq(seg.sink_id, _building_at(smelter),
		"and the sink is that smelter, not some other store")
	assert_eq(logi.world.lines_to_nowhere().size(), 0,
		"a line feeding a machine is not a line to nowhere")


func test_ore_carried_by_a_belt_is_smelted_into_plate() -> void:
	var o: Vector2i = _area_of(Vector2i(12, 5))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	var belt_from: Vector2i = o + Vector2i(0, 1)
	var belt_to: Vector2i = o + Vector2i(5, 1)
	var smelter: Vector2i = o + Vector2i(6, 0)
	_drag("belt_mk1", belt_from, belt_to, 0)
	_place("smelter", smelter)
	_recipe(smelter, "iron_plate")
	world.run(4)

	# The city holds no ore at all, so every plate made here rode the belt.
	var before: int = int(prod.call("produced_total", &"iron_plate"))
	_feed(belt_from, 400, "iron_ore")

	# THE ORDER OF THESE TWO IS LOAD-BEARING. The plate count exists in every
	# version of this build; `machine_fed` is a counter this wave added. Asserting
	# the new counter first meant that against the reverted code the property read
	# aborted the method and the runner logged `pass — 0 assert(s)`, which is the
	# exact shape of green this project has already been burned by three times.
	assert_gt(float(int(prod.call("produced_total", &"iron_plate")) - before), 0.0,
		("the smelter made no plate off a saturated ore belt. There is no ore in the "
		+ "city stores in this fixture, so a plate here can only have come off the "
		+ "belt: this is the whole claim of the transport layer"))
	assert_gt(float(logi.world.machine_fed), 0.0,
		("nothing reached the smelter's mouth. The ore is not lost — it is sitting in "
		+ "the machine's buffer store, which production does not read, which is "
		+ "exactly what made a belt worthless to a factory"))


# --- 2. an arm on a machine carries its output away ---------------------------

func test_an_arm_standing_on_a_smelter_takes_the_plate_off_it() -> void:
	var o: Vector2i = _area_of(Vector2i(12, 6))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	var smelter: Vector2i = o + Vector2i(0, 0)              # 3x3 at x..x+2
	var arm: Vector2i = o + Vector2i(3, 1)                  # reaches back into it
	var chest: Vector2i = o + Vector2i(4, 1)
	_place("smelter", smelter)
	_recipe(smelter, "iron_plate")
	_place("inserter_mk1", arm, 0)                          # rot 0: source is west
	_place("crate", chest)
	world.cmd_now({"system": &"build", "op": "add_stock", "items": {"iron_ore": 400}})
	world.run(600)

	# The crate first, for the reason written over the pair in the case above:
	# it is the assertion that exists on both sides of the revert.
	var st: LogiStore = logi.world.stores.get(_building_at(chest))
	assert_not_null(st, "the crate has no store")
	assert_gt(float(st.count(&"iron_plate")), 0.0,
		("the arm moved no plate into the crate. A smelter with an arm on its face has "
		+ "to put what it makes where the arm can reach it, or the arm is decoration"))
	assert_gt(float(logi.world.machine_taken), 0.0,
		("production offered its plate to [P03] and [P03] took none of it. "
		+ "accept_output() is the hook; an arm standing on the machine is what arms it"))


# --- 3. AND ONLY THEN — the opt-in, which is the teeth of the two above -------

func test_a_machine_with_no_arm_on_it_still_hands_everything_to_the_city() -> void:
	var o: Vector2i = _area_of(Vector2i(8, 6))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	var smelter: Vector2i = o + Vector2i(0, 0)
	_place("smelter", smelter)
	_recipe(smelter, "iron_plate")
	world.cmd_now({"system": &"build", "op": "add_stock", "items": {"iron_ore": 400}})
	var stock_before: int = int(build.get("stock").call("count", &"iron_plate"))
	world.run(600)

	var made: int = int(prod.call("produced_total", &"iron_plate"))
	assert_gt(float(made), 0.0, "the smelter did not run at all, so this proves nothing")
	assert_gt(float(int(build.get("stock").call("count", &"iron_plate")) - stock_before), 0.0,
		"and every plate it made went to the city stores, the way it always has")
	assert_eq(logi.world.machine_taken, 0,
		("NOBODY IS STANDING THERE. A machine with no arm on its face must behave "
		+ "exactly as it did before this interlock existed — that rule is the only "
		+ "reason turning it on could not move a number in the reference run"))


func test_the_buffer_a_belt_fills_is_bounded_so_nothing_can_vanish_into_it() -> void:
	var o: Vector2i = _area_of(Vector2i(12, 5))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	var belt_from: Vector2i = o + Vector2i(0, 1)
	var belt_to: Vector2i = o + Vector2i(5, 1)
	var smelter: Vector2i = o + Vector2i(6, 0)
	_drag("belt_mk1", belt_from, belt_to, 0)
	_place("smelter", smelter)
	_recipe(smelter, "iron_plate")
	world.run(4)
	# Timber is not an ingredient of anything a smelter makes. It must not
	# disappear, and it must not be eaten: it lands on the shelf, the shelf
	# fills, and then the belt backs up — which is the back-pressure a player
	# reads off a full belt.
	_feed(belt_from, 300, "timber")
	var id: int = _building_at(smelter)
	var st: LogiStore = logi.world.stores.get(id)
	assert_not_null(st, "the smelter has no buffer store")
	assert_le(float(st.total()), float(st.capacity),
		"a machine buffer that overflows its own capacity is an item duplicator")
	assert_eq(int(prod.call("produced_total", &"iron_plate")), 0,
		"a smelter fed nothing but timber must not produce plate")


func test_retooling_a_furnace_puts_what_the_belt_already_stacked_against_it_to_work() -> void:
	var o: Vector2i = _area_of(Vector2i(12, 5))
	if o == Vector2i.MAX:
		skip("no clear ground on this seed")
		return
	var belt_from: Vector2i = o + Vector2i(0, 1)
	var belt_to: Vector2i = o + Vector2i(5, 1)
	var furnace: Vector2i = o + Vector2i(6, 0)
	_drag("belt_mk1", belt_from, belt_to, 0)
	_place("smelter", furnace)
	_recipe(furnace, "copper_coil")                   # eats copper ore, not iron
	world.run(4)
	# The belt arrives with the wrong thing for the recipe that is loaded. It has
	# to stack against the wall, not vanish and not be eaten.
	_feed(belt_from, 200, "iron_ore")
	var st: LogiStore = logi.world.stores.get(_building_at(furnace))
	assert_not_null(st, "the furnace has no buffer store")
	assert_gt(float(st.count(&"iron_ore")), 0.0,
		("iron ore delivered to a furnace set to copper must sit on its dock. Anything "
		+ "else is either an item that vanished or a recipe that ate the wrong thing"))
	assert_eq(int(prod.call("produced_total", &"iron_plate")), 0,
		"nothing should have been made out of it yet")
	var stacked: int = st.count(&"iron_ore")

	# Now the player right-clicks the furnace and picks the recipe that uses it.
	_recipe(furnace, "iron_plate")
	world.run(600)
	# Not "empty": a machine's mouth only holds so much, so what is still on the
	# dock is the queue behind a furnace that is eating as fast as it can. What
	# must not happen is the stack sitting there untouched.
	assert_lt(float(st.count(&"iron_ore")), float(stacked) * 0.5,
		("the dock did not empty into the machine. A retool that strands everything "
		+ "already delivered is a retool no player would ever risk making"))
	assert_gt(float(int(prod.call("produced_total", &"iron_plate"))), 0.0,
		"and the furnace made plate out of the ore that was standing there waiting")
