extends TestCase
## [P04]x[P05] **The factory in the dark.**
##
## The one thing two independent critics and one builder all named, measured over
## 24000 ticks of `first_night` before this wave:
##
##     production.active_machines, by climate phase, 1200 samples
##     morning 3.01 · afternoon 2.44 · dusk 0.34 · night 0.44 · deep night 0.35
##
## An 8.6x collapse holding for the entire dark, in a game called Nightfall, with
## all eight machines ending the run reading `unstaffed` while 44 citizens were
## employed. The cause was one line: the shift cut gave every crew wholly to the
## rotation its building was "for", so every workshop in the city was day-only.
##
## This suite is the guard on the decision that replaced it. It is written to go
## RED against that roster — the cheapest way to reproduce it is to set
## `"skeleton"` to 0.0 on every row of `CitizenDefs.SHIFT_LAWS`, which is
## precisely the old behaviour, and every test below then fails.
##
## Staffing autarky is OFF everywhere in this file. That is the whole point: this
## is the one suite that measures [P04] and [P05] joined together, so a machine
## here runs only if somebody actually walked to it in the dark.

## Ticks for [P04]'s throttled rescan of [P11] to notice a placement.
const SYNC_GRACE: int = 40
## How many bodies the fixture puts in town, on top of the founders.
##
## Tuned DOWN, deliberately, and this is the most important constant in the file.
## A city with hands to spare gives every crew depth, and a deep crew covers both
## rotations under the OLD rule as well as the new one — so a generous fixture
## goes green against the very roster this suite exists to forbid. Measured: at
## 40 extra hands three of these four tests passed against the pre-wave cut. The
## shipped reference run has every building sitting at exactly its requirement
## with nobody spare, and `_thin_crews()` below asserts this fixture is in that
## same state before any of it means anything.
const CITY_HANDS: int = 4

var world: SimFixture = null
var prod: ProductionSystem = null
var cit: SimSystem = null
var build: SimSystem = null
var heat: SimSystem = null
var grid: SimSystem = null
var _machines: PackedInt32Array = PackedInt32Array()
var _hearth: int = -1


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["production", "citizens", "build", "climate"])


func setup() -> void:
	world = SimFixture.new(7).start()
	prod = world.system(&"production") as ProductionSystem
	cit = world.system(&"citizens")
	build = world.system(&"build")
	heat = world.system(&"heat")
	grid = world.system(&"grid")
	_machines = PackedInt32Array()
	_hearth = -1
	if prod == null or cit == null or build == null or not world.alive():
		skip("the world did not come up in this build")
		return
	prod.set_staffing_autarky(false)


func teardown() -> void:
	if world != null:
		world.stop()


# --- fixture -----------------------------------------------------------------

func _place(kind: String, cell: Vector2i) -> int:
	var before: int = int(build.call("building_count"))
	world.cmd_now({"system": &"build", "op": "place", "kind": kind,
		"cell": [cell.x, cell.y], "free": true, "instant": true})
	if int(build.call("building_count")) == before:
		return -1
	var b: Object = build.call("building_at", cell)
	return -1 if b == null else int(b.get("id"))


func _line(kind: String, from: Vector2i, to: Vector2i) -> void:
	world.cmd_now({"system": &"build", "op": "place_line", "kind": kind,
		"from": [from.x, from.y], "to": [to.x, to.y], "free": true, "instant": true})


func _machine(id: int) -> ProdMachine:
	return prod.machines.get(id)


## A hearth, roofs, hands and a row of machines. Returns false when this map
## refuses the layout, in which case the caller skips rather than asserting on a
## city that was never built.
func _factory() -> bool:
	var core: Vector2i = Vector2i(128, 128)
	if grid != null and grid.has_method("core_cell"):
		core = grid.call("core_cell")
	_hearth = _place("the_hearth", core)
	if _hearth <= 0:
		skip("[P11] would not place a hearth on this map")
		return false
	if heat != null:
		heat.call("deliver_fuel", _hearth, &"coal", 8000.0)
	for h: int in 5:
		_place("housing_block", Vector2i(core.x - 12, core.y - 10 + h * 5))
	# A spur east of the hearth, and the machines hung off it, so the grid can
	# actually reach them. A factory that has no heat in the daylight either
	# cannot tell you anything about the dark.
	_line("heat_pipe", Vector2i(core.x + 4, core.y), Vector2i(core.x + 22, core.y))
	# Spread the machines out: a pad that is refused is simply not measured, and
	# the preconditions below say how many were found.
	_machines = PackedInt32Array()
	for spot: Array in [["workshop", Vector2i(5, -3)], ["smelter", Vector2i(10, -3)],
			["rubble_sorter", Vector2i(5, 2)], ["field_kitchen", Vector2i(10, 2)]]:
		var id: int = _place(String(spot[0]), core + (spot[1] as Vector2i))
		if id > 0:
			_machines.append(id)
	_restock()
	# Hands last, so the job board hires into buildings that already exist.
	world.cmd_now({"system": &"citizens", "op": "add", "count": CITY_HANDS})
	world.run(1200 + SYNC_GRACE)
	return _machines.size() >= 3


## Skips to a phase and gives the city time to WALK. A shift change is people
## finding out and crossing town, not a switch: measured at 120 ticks after the
## skip the factory reads empty at dusk and full at deep night, and the only
## thing that changed in between was that everybody arrived.
const SHIFT_WALK: int = 520


## Keeps raw material on the shelves. A machine that has eaten the city's whole
## stock says `missing_input`, which is a supply chain fact and not a shift fact,
## and a suite about the rotation must not go red for it.
func _restock() -> void:
	world.cmd_now({"system": &"build", "op": "add_stock", "items": {
		"iron_ore": 400, "copper_ore": 400, "iron_plate": 400, "scrap": 400,
		"grain": 400, "stone": 400, "timber": 400, "coal": 400,
	}})


func _phase(name: String) -> void:
	world.cmd_now({"system": &"climate", "op": "skip_to_phase", "phase": name})
	# Keep the fire fed. Whether a city can haul enough coal to run a factory
	# through a blizzard is [P02]'s and [P03]'s bargain and has its own suites;
	# what is under test here is whether anybody is standing at the bench.
	if heat != null and _hearth > 0:
		heat.call("deliver_fuel", _hearth, &"coal", 8000.0)
	_restock()
	world.run(SHIFT_WALK)
	var climate: SimSystem = world.system(&"climate")
	if climate != null and climate.has_method("phase_of_day"):
		assert_eq(String(climate.call("phase_of_day")), name,
			("the city is still in %s %d ticks after the skip — if it is not, this "
			+ "measurement is being taken at the wrong hour") % [name, SHIFT_WALK])


## The machines the old roster sent to bed: everything whose trade is NOT one of
## `CitizenDefs.NIGHT_TRADES`. A smelter or a kitchen may carry a `heat_source`
## tag and be a night building already, and counting those as evidence would let
## this whole suite pass on the strength of one machine that was never broken.
func _day_trade() -> PackedInt32Array:
	var board: CitizenJobBoard = cit.get("board")
	var out := PackedInt32Array()
	for i: int in _machines.size():
		var site: CitizenJobBoard.Site = board.site_of(_machines[i])
		if site == null or site.assigned <= 0:
			continue
		if not CitizenDefs.is_night_trade(site.trade):
			out.append(_machines[i])
	return out


## Day-trade machines that hold a roster and have nobody standing in them.
func _abandoned() -> Array[String]:
	var board: CitizenJobBoard = cit.get("board")
	var out: Array[String] = []
	var ids: PackedInt32Array = _day_trade()
	for i: int in ids.size():
		if float(cit.call("staffing_of", ids[i])) > 0.0:
			continue
		var site: CitizenJobBoard.Site = board.site_of(ids[i])
		out.append("%s(%d) holds %d on its roster and has nobody in it"
			% [String(site.kind), ids[i], site.assigned])
	return out


## Day-trade machines actually turning right now, by id.
func _running_ids() -> PackedInt32Array:
	var out := PackedInt32Array()
	var ids: PackedInt32Array = _day_trade()
	for i: int in ids.size():
		var m: ProdMachine = _machine(ids[i])
		if m != null and m.rate > 0.0:
			out.append(ids[i])
	return out


## Machines whose roster is no deeper than the job needs — the state the whole
## city is in in the shipped run, and the only state in which the rotation rule
## is the thing being measured rather than the size of the labour pool.
func _thin_crews() -> int:
	var board: CitizenJobBoard = cit.get("board")
	var n: int = 0
	for i: int in _machines.size():
		var site: CitizenJobBoard.Site = board.site_of(_machines[i])
		if site != null and site.assigned > 0 and site.assigned <= site.required:
			n += 1
	return n


func _employed() -> int:
	return int((cit.call("metrics") as Dictionary).get("employed", 0))


# =========================================================================
#  the dark
# =========================================================================

## THE ONE THAT MATTERS. A machine with a crew in it at 3am, on a live world,
## through the whole dark and not just the convenient end of it.
##
## Against the old roster every one of these reads `unstaffed` at every dark
## phase while the same citizens are employed and asleep, which is exactly the
## shape the reference run shipped in.
func test_the_machines_have_crews_through_the_whole_dark() -> void:
	if not _factory():
		skip("this map would not take the factory fixture")
		return
	assert_gt(float(_employed()), 8.0,
		"precondition: the city employs somebody (%d)" % _employed())
	assert_gt(float(_thin_crews()), 1.0,
		("precondition: the crews are AT their requirement with nothing spare "
		+ "(%d of %d) — a deep crew covers both rotations under the old rule too, "
		+ "so a generous fixture measures nothing")
		% [_thin_crews(), _machines.size()])
	assert_gt(float(_day_trade().size()), 1.0,
		("precondition: at least two of these machines are ordinary day trades "
		+ "(found %d) — those are the ones the old roster sent to bed")
		% _day_trade().size())
	_phase("afternoon")
	assert_empty(_abandoned(),
		"precondition: the factory is crewed in the daylight to begin with")

	var empty: Array[String] = []
	for name: String in ["dusk", "night", "deep_night"]:
		_phase(name)
		for line: String in _abandoned():
			empty.append("%s — %s" % [name, line])
	assert_empty(empty,
		("the factory is abandoned after dark, which is the hour the game is named "
		+ "after, while %d citizens are employed: %s")
		% [_employed(), ", ".join(empty)])


## The same claim in [P04]'s own words: no machine reports `unstaffed` in the
## dark. The reason string is what a player reads off the machine, and eight
## machines all saying `unstaffed` at midnight is the sentence this whole wave
## exists to delete.
func test_no_machine_reports_no_crew_at_midnight() -> void:
	if not _factory():
		skip("this map would not take the factory fixture")
		return
	assert_gt(float(_thin_crews()), 1.0,
		"precondition: the crews are at their requirement with nothing spare (%d of %d)"
		% [_thin_crews(), _machines.size()])
	var ids: PackedInt32Array = _day_trade()
	assert_gt(float(ids.size()), 1.0,
		"precondition: at least two ordinary day-trade machines to measure (%d)" % ids.size())
	# Walked into, not jumped to. A city reaches midnight through dusk, and a
	# measurement taken one skip after breakfast is measuring people still on
	# the road rather than a rotation.
	for name: String in ["dusk", "night", "deep_night"]:
		_phase(name)
	var says: Array[String] = []
	for i: int in ids.size():
		var m: ProdMachine = _machine(ids[i])
		if m != null and String(m.reason) == "unstaffed":
			says.append("%s(%d)" % [String(m.kind), ids[i]])
	assert_empty(says,
		("machines with nobody in them at midnight while %d citizens are "
		+ "employed: %s") % [_employed(), ", ".join(says)])


## And they are RUNNING, not merely staffed.
##
## The daylight is measured first and asserted as a PRECONDITION, because a
## factory that was never turning cannot tell you anything about the night: a
## suite whose precondition is never met is a suite that asserts nothing, and
## this project has already paid for that lesson once.
func test_the_factory_turns_in_the_dark() -> void:
	if not _factory():
		skip("this map would not take the factory fixture")
		return
	assert_gt(float(_thin_crews()), 1.0,
		"precondition: the crews are at their requirement with nothing spare (%d of %d)"
		% [_thin_crews(), _machines.size()])
	_phase("afternoon")
	var by_day: PackedInt32Array = _running_ids()
	assert_gt(float(by_day.size()), 1.0,
		("precondition: at least two day-trade machines turn in the daylight "
		+ "(%d of %d running) — without that this test measures nothing")
		% [by_day.size(), _day_trade().size()])

	# EVERY machine that turned in the daylight, not "at least one machine".
	# A count would let the whole factory be carried by one bench whose crew
	# happened to be deep enough to cover both rotations anyway, which is exactly
	# how the old roster looked healthy in an over-staffed test city.
	var seen: Dictionary[int, bool] = {}
	for name: String in ["dusk", "night", "deep_night"]:
		_phase(name)
		var live: PackedInt32Array = _running_ids()
		for i: int in live.size():
			seen[live[i]] = true
	var never: Array[String] = []
	for i: int in by_day.size():
		if not seen.has(by_day[i]):
			var m: ProdMachine = _machine(by_day[i])
			never.append("%s(%d): %s" % [String(m.kind), by_day[i],
				"running" if String(m.reason) == "" else String(m.reason)])
	assert_empty(never,
		("%d of %d machines that turn in the daylight never turn once in dusk, "
		+ "night or deep night: %s") % [never.size(), by_day.size(), ", ".join(never)])


## The lever, and the proof it is a lever and not a decoration: Night Curfew is
## the old behaviour, kept, as something somebody signs. This is the control for
## the three tests above — it is the only state in which an empty factory at
## midnight is the right answer.
func test_night_curfew_shuts_the_works_and_says_so() -> void:
	if not _factory():
		skip("this map would not take the factory fixture")
		return
	assert_true(bool(cit.call("set_shift_law", CitizenDefs.LAW_CURFEW)),
		"the city may sign a curfew")
	world.run(200)
	for name: String in ["dusk", "night", "deep_night"]:
		_phase(name)
	var still_up: int = _day_trade().size() - _abandoned().size()
	assert_eq(still_up, 0,
		("under Night Curfew the works stop at dusk — that is what the law BUYS, "
		+ "and %d machines still have somebody in them") % still_up)
	assert_true(bool(cit.call("set_shift_law", CitizenDefs.LAW_STANDARD)),
		"and the city may repeal it")
	_phase("deep_night")
	assert_lt(float(_abandoned().size()), float(_day_trade().size()),
		("repealing it puts the night crew back on the floor: %d of %d machines "
		+ "are still empty") % [_abandoned().size(), _day_trade().size()])
