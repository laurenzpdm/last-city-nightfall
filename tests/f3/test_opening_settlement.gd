extends TestCase
## The opening settlement must be WHOLE. Not "mostly placed" — whole.
##
## The build this replaces opened every run with three heat networks: the city on
## net 1, and a watchtower and a turret mount alone on nets 2 and 3, one node
## each, supply 0.0, permanently `unreachable`, both `frozen: true` by t=600. The
## city itself was healthy the entire time (125 supply against 92 demand at
## t=100, still solvent at t=6000), which is exactly why nobody caught it: every
## aggregate number was fine and two buildings on the first screen were dead.
##
## So these tests do not ask whether the settlement is healthy. They ask whether
## every single thing that draws heat can be reached by heat, and they ask it
## three ways — from the layout, from the network graph, and from the state of
## the buildings after ten minutes of play.

const OPENING_SEED: int = 7

var world: SimFixture = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["build", "grid", "heat"])


func setup() -> void:
	world = SimFixture.new(OPENING_SEED).start()
	var grid: SimSystem = world.system(&"grid")
	for cmd: Dictionary in load("res://game/boot.gd").call("opening_commands", grid.call("core_cell")):
		world.cmd(cmd)
	world.run(1)


func teardown() -> void:
	if world != null:
		world.stop()


## The check boot runs on every launch, run here against the same layout. This is
## the one that has to be impossible to get wrong: if a future edit puts a heat
## consumer anywhere a pipe does not reach, this prints the building, the cell
## and the reason, and the whole gate goes red.
func test_no_consumer_is_left_off_the_grid() -> void:
	var boot: Script = load("res://game/boot.gd")
	# Asked before it is called: a missing gate returns null, and `assert_empty`
	# on a null is a green that means "the check does not exist".
	assert_true(boot.has_method("opening_defects"), "boot.opening_defects() exists to be run")
	if not boot.has_method("opening_defects"):
		return
	var raw: Variant = boot.call("opening_defects")
	assert_eq(typeof(raw), TYPE_PACKED_STRING_ARRAY, "and answers with a list of defects")
	assert_empty(raw as PackedStringArray,
			"every heat consumer in the opening settlement is on a network with a source of heat")


## Boot itself runs the same check and turns a defect into a Log.error, which
## fails the harness run. Proven by calling it, not by trusting the comment.
func test_boot_gates_on_it() -> void:
	var boot: Script = load("res://game/boot.gd")
	assert_true(boot.has_method("opening_defects"),
			"boot exposes the gate it runs on launch")
	var seeder: String = _source_of(boot, "_seed_opening_settlement")
	assert_true(seeder.contains("opening_defects"),
			"and _seed_opening_settlement actually calls it")
	assert_true(seeder.contains("Log.error"),
			"and reports a defect as an error, which is what fails a harness run")


## One city, one grid. Two heat networks on the opening screen is not a layout,
## it is an island — and the HUD says so out loud ("3 grids"), which is the first
## thing a player reads.
func test_the_settlement_is_a_single_heat_network() -> void:
	var heat: SimSystem = world.system(&"heat")
	var nets: PackedInt32Array = heat.call("network_ids")
	assert_size(nets, 1, "the opening settlement is ONE heat network, got %s" % str(nets))


## The defence buildings specifically, because they are the two that were broken
## and because a turret that cannot draw heat cannot fire — heat is ammunition.
##
## Sampled at t=100 rather than t=1: on the first tick of a world NOTHING has a
## route yet and every consumer in the city reads `unreachable`, healthy ones
## included. Asserting at t=1 would have been a test that could not tell the two
## cases apart, which is the same mistake that shipped the bug.
func test_the_defences_are_on_the_city_grid() -> void:
	var build: SimSystem = world.system(&"build")
	var heat: SimSystem = world.system(&"heat")
	world.run(99)
	var hearth: Array = build.call("buildings_of_kind", &"the_hearth")
	assert_not_empty(hearth, "the hearth stands")
	if hearth.is_empty():
		return
	var city: int = int(heat.call("network_of", (hearth[0] as BuildingInstance).id))

	for kind: StringName in [&"watchtower", &"turret_mount"]:
		var found: Array = build.call("buildings_of_kind", kind)
		assert_not_empty(found, "%s was placed at all" % kind)
		for b: BuildingInstance in found:
			var nid: int = int(heat.call("network_of", b.id))
			assert_eq(nid, city, "%s at %s is on the hearth's network, got %d" % [
					kind, str(b.cell), nid])
			assert_near(float(heat.call("served_of", b.id)), 1.0, 0.001,
					"%s at %s is served the heat it asked for" % [kind, str(b.cell)])
			assert_near(float(heat.call("power_factor", b.id)), 1.0, 0.001,
					"%s at %s runs at full rate" % [kind, str(b.cell)])
			var bn: Dictionary = heat.call("bottleneck_of", b.id)
			assert_ne(String(bn.get("kind", "")), "unreachable",
					"%s at %s is not 'unreachable' — that word is the whole bug" % [kind, str(b.cell)])


## The seeded opening, unattended, across the first day. Nothing the game placed
## for the player may freeze WHILE THE GRID CAN PAY FOR IT.
##
## The condition matters. An unattended settlement eventually burns its starting
## coal and goes dark — that is the game, and every building on a dead grid
## freezes, correctly. So this asserts the implication "solvent ⇒ nothing frozen"
## AND asserts separately that the grid really is solvent at the two moments the
## critic named, so the implication can never pass vacuously.
func test_nothing_freezes_while_the_grid_can_pay() -> void:
	var build: SimSystem = world.system(&"build")
	var heat: SimSystem = world.system(&"heat")
	var solvent_samples: int = 0
	for at: int in [600, 2000, 4000]:
		world.run(at - world.tick())
		var totals: Dictionary = heat.call("totals")
		var supply: float = float(totals.get("supply", 0.0))
		var demand: float = float(totals.get("demand", 0.0))
		if supply < demand:
			continue          # the grid is broke; freezing is the correct outcome
		solvent_samples += 1
		var frozen: PackedStringArray = PackedStringArray()
		for b: BuildingInstance in build.call("all_buildings"):
			if bool(heat.call("is_frozen", b.id)):
				frozen.append("%s at %s" % [b.kind, str(b.cell)])
		assert_empty(frozen, "nothing is frozen at t=%d, where supply %.1f covers demand %.1f" % [
				at, supply, demand])
	assert_eq(solvent_samples, 3,
			"the opening grid is solvent at every sample — otherwise the assertion above proved nothing")


## The specific number that made the watchtower a lie: it declared heat_consumed,
## which opts a building into the ACTIVE freeze threshold (-10 C), and then drew
## 1.0 — worth 2.4 C of internal warmth against a day-1 plain at -20 to -27. It
## could not survive anywhere on the map, connected or not, and connecting it to
## the trunk would have hidden that instead of fixing it.
##
## Held to the model rather than to a magic number: internal target temperature
## is `ambient + 1.6 * demand * (1 + insulation * 1.5)` (HeatSystem._thermal), so
## a heat consumer standing outdoors must buy itself more than the gap between
## the coldest ambient it will meet on day 1 and its own freeze threshold.
func test_an_outdoor_consumer_can_afford_its_own_freeze_threshold() -> void:
	var short: PackedStringArray = PackedStringArray()
	var checked: int = 0
	for kind: StringName in [&"watchtower", &"turret_mount"]:
		var def: BuildingDef = Registry.get_item("buildings", kind) as BuildingDef
		assert_not_null(def, "%s exists in the registry" % kind)
		if def == null:
			continue
		checked += 1
		var lift: float = 1.6 * def.heat_consumed * (1.0 + def.heat_insulation * 1.5)
		# -22 C is a fair day-1 night on the shipped climate curve; -10 C is
		# HeatDef.ACTIVE_FREEZE_C, which every heat_consumed > 0 building inherits.
		if lift < 12.0:
			short.append("%s lifts itself %.1f C on %.1f heat — it needs 12 C to clear -22 C ambient against a -10 C freeze line" % [
					def.display_name, lift, def.heat_consumed])
	assert_eq(checked, 2, "both defensive buildings were actually read from the registry")
	assert_empty(short, "every defensive heat consumer can keep itself above freezing outdoors")


## The layout is only as good as the rule that produced it. Every consumer's
## origin is derived from the last tile of the pipe run that feeds it, so this
## asserts the geometric consequence: a consumer's footprint always touches a
## conduit. A typed coordinate that drifts one tile shows up here even if some
## other pipe happens to keep it connected.
func test_every_consumer_touches_a_conduit() -> void:
	var build: SimSystem = world.system(&"build")
	var stranded: PackedStringArray = PackedStringArray()
	for b: BuildingInstance in build.call("all_buildings"):
		if b.def == null or b.def.heat_consumed <= 0.0:
			continue
		var touching: bool = false
		for cell: Vector2i in b.cells:
			for step: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var other: BuildingInstance = build.call("building_at", cell + step)
				if other != null and other.def != null and other.def.is_heat_conduit:
					touching = true
					break
			if touching:
				break
		if not touching:
			stranded.append("%s at %s" % [b.kind, str(b.cell)])
	assert_empty(stranded, "every heat consumer's footprint touches a pipe")


## Source text of one function, so a test can assert that boot WIRED the gate in
## rather than merely exposing it. Reading the script is the only way to prove a
## call site exists without booting the whole view.
func _source_of(script: Script, fn: String) -> String:
	var src: String = script.source_code
	var at: int = src.find("func %s(" % fn)
	if at < 0:
		return ""
	var end: int = src.find("\nfunc ", at + 1)
	return src.substr(at, (end - at) if end > at else -1)
