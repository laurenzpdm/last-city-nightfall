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
## How many bodies the fixture puts in town. Comfortably more than the crews
## need, so anything left unstaffed is unstaffed because of the rotation.
const CITY_HANDS: int = 40

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
	for spot: Array in [["workshop", Vector2i(5, -3)], ["workshop", Vector2i(10, -3)],
			["workshop", Vector2i(15, -3)], ["smelter", Vector2i(5, 2)],
			["smelter", Vector2i(10, 2)], ["field_kitchen", Vector2i(15, 2)]]:
		var id: int = _place(String(spot[0]), core + (spot[1] as Vector2i))
		if id > 0:
			_machines.append(id)
	_restock()
	# Hands last, so the job board hires into buildings that already exist.
	world.cmd_now({"system": &"citizens", "op": "add", "count": CITY_HANDS})
	world.run(1200 + SYNC_GRACE)
	return _machines.size() >= 4


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


## Crews standing in the machines this fixture placed, right now.
func _crewed() -> int:
	var n: int = 0
	for i: int in _machines.size():
		if float(cit.call("staffing_of", _machines[i])) > 0.0:
			n += 1
	return n


## Machines of this fixture that are actually turning right now.
func _running() -> int:
	var n: int = 0
	for i: int in _machines.size():
		var m: ProdMachine = _machine(_machines[i])
		if m != null and m.rate > 0.0:
			n += 1
	return n


## What every machine says about itself, for a failure message that names the
## cause instead of the symptom.
func _why() -> String:
	var bits: PackedStringArray = PackedStringArray()
	for i: int in _machines.size():
		var m: ProdMachine = _machine(_machines[i])
		if m == null:
			continue
		bits.append("%s: %s staff=%.2f power=%.2f cold=%.2f" % [String(m.kind),
			"running" if String(m.reason) == "" else String(m.reason),
			m.staffing, m.power, m.cold])
	return "; ".join(bits)


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
	assert_gt(float(_crewed()), 0.0,
		"precondition: the machines are crewed in the daylight to begin with")

	var empty: Array[String] = []
	for name: String in ["dusk", "night", "deep_night"]:
		_phase(name)
		var crewed: int = _crewed()
		if crewed <= 0:
			empty.append("%s: 0 of %d machines have anybody in them (%d employed)"
				% [name, _machines.size(), _employed()])
	assert_empty(empty,
		("the factory is abandoned after dark, which is the hour the game is named "
		+ "after — %s") % ", ".join(empty))


## The same claim in [P04]'s own words: no machine reports `unstaffed` in the
## dark. The reason string is what a player reads off the machine, and eight
## machines all saying `unstaffed` at midnight is the sentence this whole wave
## exists to delete.
func test_no_machine_reports_no_crew_at_midnight() -> void:
	if not _factory():
		skip("this map would not take the factory fixture")
		return
	_phase("deep_night")
	var says: Array[String] = []
	for i: int in _machines.size():
		var m: ProdMachine = prod.machine(_machines[i])
		if m == null:
			continue
		if String(m.reason) == "unstaffed":
			says.append("%s(%d)" % [String(m.kind), _machines[i]])
	assert_lt(float(says.size()), float(_machines.size()),
		("every machine in the city reads `unstaffed` in deep night while %d "
		+ "citizens are employed: %s") % [_employed(), ", ".join(says)])
	assert_empty(says,
		"machines with nobody in them at midnight: %s" % ", ".join(says))


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
	_phase("afternoon")
	var by_day: int = _running()
	assert_gt(float(by_day), 0.0,
		("precondition: the factory turns in the daylight (%d of %d running) — "
		+ "without that this test measures nothing") % [by_day, _machines.size()])

	var dead: Array[String] = []
	for name: String in ["dusk", "night", "deep_night"]:
		_phase(name)
		var active: int = _running()
		if active <= 0:
			dead.append("%s: 0 of %d, against %d in the afternoon [%s]"
				% [name, _machines.size(), by_day, _why()])
	assert_empty(dead,
		"nothing in the city is making anything after dark — %s" % ", ".join(dead))


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
	_phase("deep_night")
	assert_eq(_crewed(), 0,
		("under Night Curfew the works stop at dusk — that is what the law BUYS, "
		+ "and %d machines still have somebody in them") % _crewed())
	assert_true(bool(cit.call("set_shift_law", CitizenDefs.LAW_STANDARD)),
		"and the city may repeal it")
	_phase("deep_night")
	assert_gt(float(_crewed()), 0.0,
		"repealing it puts the night crew back on the floor")
