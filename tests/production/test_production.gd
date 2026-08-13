extends TestCase
## [P04] Production & Recipes.
##
## Written against BEHAVIOUR, not implementation: every test states a rule a
## player can feel — "one drill feeds one smelter", "a cold shop works slower",
## "a machine tells you what it is short of" — and then measures it on a live
## world with a real heat grid under it.
##
## Machines are placed through [P11]'s own command surface with `free` and
## `instant`, so what is under test is the same path the game uses, not a
## private back door.
##
## Staffing autarky is ON in most tests. [P05] owns whether anybody walked to
## the workshop, and a suite about production must not go red because the job
## board rearranged its shifts. `test_the_labour_market_is_actually_wired_in`
## is the one test that leaves the coupling live and proves it is connected.

const ORIGIN: Vector2i = Vector2i(60, 60)
## Ticks to let [P04]'s throttled rescan of [P11] notice a placement or a removal.
const SYNC_GRACE: int = 15

var world: SimFixture = null
var prod: ProductionSystem = null
var build: SimSystem = null
var heat: SimSystem = null
var grid: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["production", "build"])


func setup() -> void:
	world = null
	prod = null
	build = null
	heat = null
	grid = null


func teardown() -> void:
	if world != null:
		world.stop()


# --- fixture -----------------------------------------------------------------

## Creates the world. Called only by the tests that need one, because world
## creation runs the whole map generator and this suite has thirty tests.
func _world() -> void:
	if world != null:
		return
	world = SimFixture.new(7).start()
	prod = world.system(&"production") as ProductionSystem
	build = world.system(&"build")
	heat = world.system(&"heat")
	grid = world.system(&"grid")
	if prod != null:
		prod.set_staffing_autarky(true)
	if build != null:
		# Enough of everything that no test is ever measuring the stockpile
		# instead of the thing it means to measure.
		world.cmd_now({"system": &"build", "op": "add_stock", "items": {
			"iron_ore": 4000, "copper_ore": 2000, "iron_plate": 4000,
			"steel_plate": 2000, "copper_coil": 2000, "coal": 4000,
			"scrap": 4000, "timber": 2000, "stone": 2000, "slag": 2000,
			"sulfur": 2000, "grain": 2000, "gear": 2000,
		}})


## The recipe book alone. No world, no map generation.
func _book() -> ProdRecipeBook:
	if prod != null:
		return prod.book
	var b := ProdRecipeBook.new()
	b.load_all()
	return b


# --- helpers -----------------------------------------------------------------

## Places a finished building and returns its id, or -1.
func _place(kind: String, cell: Vector2i, meta: Dictionary = {}) -> int:
	var before: int = int(build.call("building_count"))
	world.cmd_now({"system": &"build", "op": "place", "kind": kind,
		"cell": [cell.x, cell.y], "free": true, "instant": true, "meta": meta})
	if int(build.call("building_count")) == before:
		return -1
	var b: Object = build.call("building_at", cell)
	return -1 if b == null else int(b.get("id"))


func _line(kind: String, from: Vector2i, to: Vector2i) -> void:
	world.cmd_now({"system": &"build", "op": "place_line", "kind": kind,
		"from": [from.x, from.y], "to": [to.x, to.y], "free": true, "instant": true})


## A lit hearth with a pipe spur, so machines hung off it are actually powered.
## Returns the cell the spur ends on; the caller builds against it.
func _grid_at(o: Vector2i) -> Vector2i:
	var hearth: int = _place("the_hearth", o)
	_line("heat_pipe", o + Vector2i(5, 2), o + Vector2i(16, 2))
	if heat != null and hearth > 0:
		heat.call("deliver_fuel", hearth, &"coal", 2000.0)
	world.run(4)
	return o + Vector2i(16, 2)


func _machine(id: int) -> ProdMachine:
	return prod.machines.get(id)


func _stock(item: String) -> int:
	var s: Object = build.get("stock")
	return 0 if s == null else int(s.call("count", StringName(item)))


# =============================================================================
# the content itself — no world needed
# =============================================================================

func test_every_shipped_recipe_is_valid_content() -> void:
	var b: ProdRecipeBook = _book()
	assert_empty(b.problems, "no recipe in game/content/recipes fails validation")
	assert_ge(float(b.size()), 12.0, "the shipped recipe set is not a stub")
	for rid: StringName in b.ids:
		var r: RecipeDef = b.get_recipe(rid)
		assert_empty(r.validate(), "recipe '%s' is valid" % String(rid))
		assert_gt(r.duration_seconds(), 0.0, "'%s' takes time" % String(rid))
		assert_not_empty(r.description, "'%s' has flavour text" % String(rid))


func test_the_chain_is_at_least_three_transformations_deep() -> void:
	var b: ProdRecipeBook = _book()
	assert_ge(float(b.max_depth), 4.0, "the crafting graph goes at least four deep")
	assert_eq(b.item_depth(&"scrap"), 0, "scrap comes out of the ground")
	assert_eq(b.item_depth(&"iron_plate"), 2, "ore -> plate")
	assert_eq(b.item_depth(&"gear"), 3, "ore -> plate -> gear")
	assert_eq(b.item_depth(&"pipe_segment"), 4, "ore -> plate -> steel -> pipe")
	assert_eq(b.item_depth(&"heat_core"), 5, "and one more for the component")
	assert_has(b.raw_items, &"scrap", "scrap is a raw material")
	assert_has_not(b.raw_items, &"iron_plate", "a plate is not a raw material")


func test_the_clean_ratios_really_are_clean() -> void:
	# The whole point of the recipe numbers: a player who works out the ratio is
	# rewarded with a whole number, not 1.37. If a balance pass breaks one of
	# these, it should have to say so out loud by editing this list.
	var b: ProdRecipeBook = _book()
	assert_near(b.feed_ratio(&"iron_plate", &"steel_plate", &"iron_plate"), 1.0, 0.0005,
		"one iron smelter feeds one steel smelter")
	assert_near(b.feed_ratio(&"iron_plate", &"gear", &"iron_plate"), 1.0, 0.0005,
		"one iron smelter feeds one gear shop")
	assert_near(b.feed_ratio(&"iron_plate", &"insulation", &"slag"), 1.0, 0.0005,
		"one iron smelter's slag feeds exactly one insulation shop")
	assert_near(b.feed_ratio(&"steel_plate", &"pipe_segment", &"steel_plate"), 1.0, 0.0005,
		"one steel smelter feeds one pipe shop")
	assert_near(b.feed_ratio(&"pipe_segment", &"heat_core", &"pipe_segment"), 0.5, 0.0005,
		"the top of the tree is the deliberate 2:1")
	assert_near(b.feed_ratio(&"insulation", &"heat_core", &"insulation"), 0.5, 0.0005,
		"...and so is its insulation line")
	# A drill runs at 0.80 ore/s = 48/min; one iron smelter draws exactly that.
	assert_near(b.get_recipe(&"iron_plate").input_per_minute(&"iron_ore"), 48.0, 0.001,
		"one drill, one smelter")


func test_iron_smelting_cannot_be_done_without_making_slag() -> void:
	var iron: RecipeDef = _book().get_recipe(&"iron_plate")
	assert_has(iron.byproducts, &"slag", "the byproduct is not optional")
	assert_near(iron.output_per_minute(&"slag"), iron.output_per_minute(&"iron_plate"), 0.001,
		"one slag per plate, forever")
	assert_has(_book().consumers_of.get(&"slag", []), "insulation",
		"and slag has somewhere to go")


func test_a_recipe_no_machine_can_run_is_refused_by_validate() -> void:
	var r := RecipeDef.new()
	r.id = &"nowhere"
	r.display_name = "Nowhere"
	r.description = "x"
	r.outputs = {&"thing": 1} as Dictionary[StringName, int]
	assert_has(" ".join(r.validate()), "no machine can run it",
		"content that nothing can execute is a content error, not silence")


func test_the_recipe_tree_is_json_safe_for_the_browser_to_read() -> void:
	var tree: Dictionary = _book().to_json()
	assert_ne(JSON.stringify(tree), "", "[P18] can serialize the whole tree")
	assert_ge(float(tree["max_depth"]), 4.0, "and it carries the depth to lay out on")
	for entry: Variant in tree["recipes"]:
		var e: Dictionary = entry
		assert_has(e, "inputs", "every node states its inputs")
		assert_has(e, "outputs", "and its outputs")
		assert_has(e, "depth", "and where it sits in the tree")


# =============================================================================
# machines
# =============================================================================

func test_every_recipe_a_machine_offers_actually_exists() -> void:
	_world()
	# A building def naming a recipe nobody shipped is a machine that silently
	# does nothing, which is exactly the failure this project keeps having.
	for d: Variant in build.call("all_defs"):
		var def: BuildingDef = d
		for rid: StringName in def.recipes:
			assert_true(_book().has(rid),
				"building '%s' offers recipe '%s', which does not exist" % [String(def.id), String(rid)])
			var r: RecipeDef = _book().get_recipe(rid)
			if r != null:
				assert_true(r.runs_on(def.id, def.tags),
					"'%s' lists '%s' but the recipe refuses that machine" % [String(def.id), String(rid)])


func test_a_smelter_turns_ore_into_plate_and_slag() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	assert_gt(float(id), 0.0, "the smelter was placed")
	world.run(20)
	var m: ProdMachine = _machine(id)
	assert_not_null(m, "production registered the smelter")
	assert_eq(String(m.recipe_id), "iron_plate", "it defaulted to the recipe its def lists first")

	world.run(400)
	var plates: int = prod.produced_total(&"iron_plate")
	assert_gt(float(plates), 0.0, "it made plate")
	assert_eq(prod.produced_total(&"slag"), plates,
		"iron smelting cannot be done without making exactly as much slag")
	assert_eq(String(_machine(id).reason), "", "and it is not stalled while doing it")


func test_a_starved_machine_names_the_item_it_is_short_of() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"iron_ore": 0}})
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(20)
	var s: Dictionary = prod.stall_of(id)
	assert_eq(s["reason"], "missing_input", "a smelter with no ore stalls")
	assert_eq(s["item"], "iron_ore", "and it says which item")
	assert_eq(int(s["state"]), ProdMachine.State.STALLED, "the state agrees with the reason")


func test_a_stall_is_announced_on_the_bus_for_the_overlay_to_render() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"iron_ore": 0}})
	var id: int = _place("smelter", end + Vector2i(1, -1))
	var seen: Dictionary = {"id": -1, "reason": ""}
	var cb: Callable = func(mid: int, reason: StringName) -> void:
		if mid == id:
			seen["id"] = mid
			seen["reason"] = String(reason)
	Bus.machine_stalled.connect(cb)
	world.run(30)
	Bus.machine_stalled.disconnect(cb)
	assert_eq(int(seen["id"]), id, "the stall named the machine")
	assert_eq(seen["reason"], "missing_input", "and carried a reason [P19] can render")


func test_a_machine_off_the_heat_grid_stalls_for_heat_not_for_cold() -> void:
	_world()
	if heat == null:
		skip("no heat system in this build")
		return
	# Deliberately nowhere near a pipe: the smelter is its own island, so the
	# solver serves it nothing and the recipe's heat rate cannot be met.
	var id: int = _place("smelter", ORIGIN + Vector2i(40, 40))
	world.run(20)
	var s: Dictionary = prod.stall_of(id)
	assert_eq(s["reason"], "no_heat", "an unconnected smelter is dark, not cold")
	assert_near(float(s["power"]), 0.0, 0.001, "the heat system served it nothing")
	assert_eq(_stock("iron_ore"), 4000, "and it did not eat a charge it could not smelt")

	var lit: Vector2i = _grid_at(ORIGIN)
	var id2: int = _place("smelter", lit + Vector2i(1, -1))
	world.run(30)
	assert_eq(prod.stall_of(id2)["reason"], "", "the same machine on the grid runs")


func test_the_output_buffer_backs_up_when_nothing_will_take_the_goods() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(20)
	# This is the switch [P03] closes when the belts and yards are full.
	prod.set_output_accepting(false)
	world.run(900)
	var m: ProdMachine = _machine(id)
	assert_eq(String(m.reason), "output_full", "a machine nobody unloads jams")
	assert_gt(float(m.output_total()), 0.0, "and it is holding the goods it made")
	prod.set_output_accepting(true)
	world.run(40)
	assert_eq(String(_machine(id).reason), "", "reopening the yard restarts it")
	assert_eq(_machine(id).output_total(), 0, "and the backlog goes to the city")


func test_a_switched_off_machine_is_idle_not_broken() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(20)
	world.cmd_now({"system": &"build", "op": "set_enabled", "id": id, "on": false})
	world.run(20)
	assert_eq(String(_machine(id).reason), "disabled", "the player's own switch reads as such")
	assert_eq(_machine(id).state, ProdMachine.State.IDLE, "and it is idle, not stalled")


func test_a_demolished_machine_hands_its_buffers_back() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(20)
	var held: int = _machine(id).held(&"iron_ore")
	assert_gt(float(held), 0.0, "the smelter is holding a charge")
	var before: int = _stock("iron_ore")
	world.cmd_now({"system": &"build", "op": "remove", "id": id, "instant": true})
	world.run(SYNC_GRACE)
	assert_false(prod.has_machine(id), "the machine is gone")
	assert_ge(float(_stock("iron_ore")), float(before + held),
		"and the ore in its hopper went back to the city instead of vanishing")


# =============================================================================
# the couplings that fuse the factory to the city
# =============================================================================

func test_what_a_machine_feels_is_the_heat_field_plus_its_own_shell() -> void:
	_world()
	if heat == null:
		skip("no heat system in this build")
		return
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(20)
	var m: ProdMachine = _machine(id)
	var tile: float = float(heat.call("temperature_at", m.center_cell))
	assert_near(m.felt_c, tile + m.def.insulation * ProductionSystem.SHELTER_C, 0.01,
		"felt temperature is the tile plus what the shell holds in")


func test_the_cold_factor_is_the_recipe_floor_read_off_the_warmth_field() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(20)
	var m: ProdMachine = _machine(id)
	var expected: float = clampf(
		(m.felt_c - m.recipe.min_temperature_c) / ProductionSystem.COLD_BAND_C, 0.0, 1.0)
	assert_near(m.cold, expected, 0.001, "cold is a slope off the recipe's own floor")


func test_a_great_frost_stops_the_outlying_machines_first() -> void:
	_world()
	if heat == null or world.system(&"climate") == null:
		skip("needs heat and climate")
		return
	var end: Vector2i = _grid_at(ORIGIN)
	var warm: int = _place("smelter", end + Vector2i(1, -1))
	# Far from every radiator and hung off nothing: only its own shell.
	var cold: int = _place("rubble_sorter", ORIGIN + Vector2i(44, 44))
	assert_gt(float(cold), 0.0, "the outlying machine was placed")
	world.run(20)
	var cold_before: float = _machine(cold).cold
	world.cmd_now({"system": &"climate", "op": "force_storm", "intensity": 1.0,
		"duration_ticks": 4000})
	world.run(1000)
	var cold_m: ProdMachine = _machine(cold)
	var warm_m: ProdMachine = _machine(warm)
	assert_lt(cold_m.felt_c, warm_m.felt_c,
		"the machine with no heat around it feels the frost first")
	assert_lt(cold_m.cold, cold_before, "and the frost actually slows it down")
	assert_le(cold_m.rate, warm_m.rate + 0.0001, "the warm one is never the slower one")


func test_a_heat_hungry_recipe_needs_more_of_the_grid_than_a_cheap_one() -> void:
	_world()
	# The coupling in one assertion: steel wants the smelter's whole rated draw,
	# copper coil wants a fraction of it, so a brownout kills steel and leaves
	# coil alone.
	var b: ProdRecipeBook = _book()
	var smelter: BuildingDef = build.call("def_of", &"smelter")
	assert_near(b.get_recipe(&"steel_plate").heat_rate(), smelter.heat_consumed, 0.001,
		"steel wants exactly what a smelter is rated for")
	assert_lt(b.get_recipe(&"copper_coil").heat_rate(), smelter.heat_consumed * 0.8,
		"copper coil is the cheap recipe")


func test_a_browned_out_machine_crafts_proportionally_slower() -> void:
	_world()
	if heat == null:
		skip("no heat system in this build")
		return
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1), {"recipe": "steel_plate"})
	world.run(30)
	var full: float = _machine(id).rate
	assert_gt(full, 0.0, "the steel smelter runs on a healthy grid")
	# Hang enough radiators off the same spur to out-draw the hearth, which is
	# how a player actually browns their own base out.
	for i: int in 12:
		_place("warmth_radiator", ORIGIN + Vector2i(5 + i * 2, 4))
	world.run(60)
	var m: ProdMachine = _machine(id)
	assert_lt(m.power, 1.0, "the solver is now shedding load onto the smelter")
	assert_lt(m.rate, full, "and the heat-hungriest recipe in the game slows down for it")


func test_the_labour_market_is_actually_wired_in() -> void:
	_world()
	var citizens: SimSystem = world.system(&"citizens")
	if citizens == null or not citizens.has_method("staffing_of"):
		skip("[P05] citizens is not built yet")
		return
	prod.set_staffing_autarky(false)
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(20)
	assert_near(_machine(id).staffing, float(citizens.call("staffing_of", id)), 0.0001,
		"the crew a machine runs on is the crew [P05] says is standing in it")
	if _machine(id).staffing <= 0.0:
		assert_eq(String(_machine(id).reason), "unstaffed",
			"and an empty shop says so rather than running on ghosts")


func test_research_gates_a_recipe_and_says_so() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("workshop", end + Vector2i(1, -4))
	assert_gt(float(id), 0.0, "the workshop was placed")
	world.run(20)
	assert_ne(String(_machine(id).recipe_id), "circuit",
		"a locked recipe is never auto-chosen")
	assert_true(prod.set_recipe(id, &"circuit"), "the player may still select it")
	world.run(30)
	assert_eq(String(_machine(id).reason), "locked", "and is told why it does not run")
	world.cmd_now({"system": &"build", "op": "grant_unlock", "unlock": "electrotechnics"})
	world.run(ProductionSystem.UNLOCK_RECHECK_TICKS + 20)
	assert_ne(String(_machine(id).reason), "locked", "granting the research opens it")


func test_the_chosen_recipe_is_written_where_a_blueprint_will_find_it() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(20)
	prod.set_recipe(id, &"copper_coil")
	var b: Object = build.call("get_building", id)
	var meta: Dictionary = b.get("meta")
	assert_eq(String(meta.get("recipe", "")), "copper_coil",
		"the choice lives in [P11]'s meta, which survives a blueprint round-trip")


func test_a_machine_placed_with_a_recipe_in_its_meta_starts_on_it() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1), {"recipe": "steel_plate"})
	world.run(20)
	assert_eq(String(_machine(id).recipe_id), "steel_plate",
		"a pasted blueprint comes back making what it was making")


func test_switching_recipe_gives_the_committed_charge_back() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(20)
	var m: ProdMachine = _machine(id)
	assert_true(m.committed, "a craft is under way")
	var charge: int = m.recipe.inputs[&"iron_ore"]
	var before: int = _stock("iron_ore")
	prod.set_recipe(id, &"copper_coil")
	assert_eq(_stock("iron_ore"), before + charge,
		"the ore in the furnace came back rather than being burned")


# =============================================================================
# extraction
# =============================================================================

func test_a_drill_works_the_seam_under_it_and_the_deposit_shrinks() -> void:
	_world()
	if grid == null:
		skip("no grid system in this build")
		return
	var seam: Vector2i = _find_deposit()
	if seam.x < 0:
		skip("this seed put no reachable deposit on the map")
		return
	var before: int = int(grid.call("resource_amount_at", seam))
	var id: int = _place("ore_drill", seam - Vector2i(1, 1))
	if id < 0:
		skip("the drill would not fit on this seam")
		return
	world.run(400)
	var m: ProdMachine = _machine(id)
	assert_gt(float(m.crafts_done), 0.0, "the drill pulled something out")
	assert_lt(float(grid.call("resource_amount_at", m.seam)), float(before),
		"and the deposit is smaller for it")
	assert_gt(float(prod.produced_total(m.seam_item)), 0.0,
		"the item it yields matches the deposit it is standing on")


func test_a_worked_out_seam_stalls_the_drill_and_raises_an_alert() -> void:
	_world()
	if grid == null:
		skip("no grid system in this build")
		return
	var seam: Vector2i = _find_deposit()
	if seam.x < 0:
		skip("this seed put no reachable deposit on the map")
		return
	var id: int = _place("ore_drill", seam - Vector2i(1, 1))
	if id < 0:
		skip("the drill would not fit on this seam")
		return
	world.run(30)
	var m: ProdMachine = _machine(id)
	for c: Vector2i in m.footprint:
		grid.call("harvest", c, 1000000)
	var alerts: Dictionary = {"n": 0}
	var cb: Callable = func(_sev: int, key: StringName, _text: String, _pos: Vector2) -> void:
		if key == &"seam_depleted":
			alerts["n"] = int(alerts["n"]) + 1
	Bus.alert_raised.connect(cb)
	world.run(60)
	Bus.alert_raised.disconnect(cb)
	assert_eq(String(_machine(id).reason), "depleted", "a drill on dead ground says so")
	assert_ge(float(alerts["n"]), 1.0, "and the city is told")


# =============================================================================
# the heat-recovery loop
# =============================================================================

func test_a_recuperator_next_to_a_smelter_turns_waste_into_grid_heat() -> void:
	_world()
	if heat == null:
		skip("no heat system in this build")
		return
	var end: Vector2i = _grid_at(ORIGIN)
	var smelter: int = _place("smelter", end + Vector2i(1, -1))
	var rec: int = _place("recuperator", end + Vector2i(1, 3))
	assert_gt(float(rec), 0.0, "the recuperator was placed")
	world.run(400)

	assert_gt(float(_machine(smelter).crafts_done), 0.0, "the smelter actually ran")
	assert_gt(prod.waste_recovered(), 0.0, "waste heat is coming back as grid heat")
	assert_gt(float(heat.call("fuel_stock_of", rec)), 0.0,
		"the recuperator is holding captured heat as fuel")
	assert_eq(String(_machine(rec).reason), "", "a fed recuperator is not stalled")


func test_a_recuperator_out_of_reach_gets_nothing() -> void:
	_world()
	if heat == null:
		skip("no heat system in this build")
		return
	var end: Vector2i = _grid_at(ORIGIN)
	_place("smelter", end + Vector2i(1, -1))
	# Well outside ProdMachineDef.DEFAULT_CAPTURE_RADIUS.
	var far: int = _place("recuperator", end + Vector2i(1, 14))
	assert_gt(float(far), 0.0, "the distant recuperator was placed")
	world.run(400)
	assert_near(float(heat.call("fuel_stock_of", far)), 0.0, 0.001,
		"heat you do not stand next to goes up the chimney")
	assert_eq(String(_machine(far).reason), "missing_input",
		"and it says it is starved of waste heat")


func test_uncaptured_waste_decays_instead_of_banking_forever() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var smelter: int = _place("smelter", end + Vector2i(1, -1))
	world.run(400)
	var iron: RecipeDef = _book().get_recipe(&"iron_plate")
	assert_lt(_machine(smelter).waste_bank, iron.waste_heat * 10.0,
		"a machine nobody collects from does not hoard an unbounded bank")
	assert_gt(prod.waste.vented_rate, 0.0, "the uncaptured heat is visibly going up the flue")


# =============================================================================
# throughput, and that the arithmetic in the design comment is true
# =============================================================================

func test_measured_throughput_matches_the_ratio_the_recipe_promises() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(60)
	var m: ProdMachine = _machine(id)
	if m.rate < 0.999:
		skip("this world is not warm enough to measure a clean rate (rate %.3f)" % m.rate)
		return
	var before: int = prod.produced_total(&"iron_plate")
	var ticks: int = 1200
	world.run(ticks)
	var made: int = prod.produced_total(&"iron_plate") - before
	var expected: float = _book().get_recipe(&"iron_plate").output_per_minute(&"iron_plate")
	var measured: float = float(made) * 60.0 / (float(ticks) * SimClock.DT)
	assert_near(measured, expected, expected * 0.06,
		"a smelter at full rate makes what the recipe says it makes")


func test_items_per_minute_reports_what_was_actually_made() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	_place("smelter", end + Vector2i(1, -1))
	world.run(ProductionSystem.RATE_WINDOW_TICKS * 2 + 100)
	assert_gt(prod.items_per_minute(&"iron_plate"), 0.0, "the rate window sees the output")
	assert_eq(prod.items_per_minute(&"heat_core"), 0.0, "and does not invent any")


func test_nothing_is_created_or_destroyed_across_a_craft() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	var id: int = _place("smelter", end + Vector2i(1, -1))
	world.run(20)
	var ore_before: int = _stock("iron_ore") + _machine(id).held(&"iron_ore")
	var plate_before: int = _stock("iron_plate")
	world.run(600)
	var m: ProdMachine = _machine(id)
	var ore_after: int = _stock("iron_ore") + m.held(&"iron_ore")
	var plates: int = _stock("iron_plate") - plate_before
	var ore_used: int = ore_before - ore_after
	# Two ore per plate, plus the charge committed to the craft in flight.
	assert_between(float(ore_used), float(plates * 2), float(plates * 2 + 2),
		"every plate cost exactly two ore, no more and no less")


func test_the_chain_depth_reached_climbs_as_the_city_builds_upward() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	assert_eq(prod.chain_depth_reached(), 0, "a city that has made nothing is at zero")
	_place("smelter", end + Vector2i(1, -1))
	world.run(300)
	assert_ge(float(prod.chain_depth_reached()), 2.0, "plate is two transformations in")
	var shop: int = _place("workshop", end + Vector2i(1, -5))
	prod.set_recipe(shop, &"gear")
	world.run(400)
	assert_ge(float(prod.chain_depth_reached()), 3.0, "and a gear is three")
	assert_le(float(prod.chain_depth_reached()), float(prod.chain_depth_max()),
		"it never claims more depth than the content has")


# =============================================================================
# the project's hard rules
# =============================================================================

func test_metric_columns_never_change_shape_mid_run() -> void:
	_world()
	var first: Array = prod.metrics().keys()
	first.sort()
	_grid_at(ORIGIN)
	_place("smelter", ORIGIN + Vector2i(17, 1))
	world.run(700)
	var later: Array = prod.metrics().keys()
	later.sort()
	assert_eq(later, first, "metrics.csv keeps the same columns for the whole run")
	assert_has(first, "active_machines", "the headline counters are there")
	assert_has(first, "stalled", "")
	assert_has(first, "chain_depth", "")
	assert_has(first, "ipm.iron_plate", "and a per-item rate column for the balance pass")


func test_serialize_round_trips_through_deserialize() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	_place("smelter", end + Vector2i(1, -1))
	_place("workshop", end + Vector2i(1, -5))
	world.run(400)
	var before: Dictionary = prod.serialize()
	prod.deserialize(before)
	var after: Dictionary = prod.serialize()
	assert_eq(after["machines"], before["machines"], "every machine survives a save")
	assert_eq(after["produced"], before["produced"], "and so does the ledger")


func test_the_serialized_state_is_sorted_and_json_safe() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	_place("workshop", end + Vector2i(1, -5))
	_place("smelter", end + Vector2i(1, -1))
	world.run(200)
	var s: Dictionary = prod.serialize()
	var ids: Array = []
	for entry: Variant in s["machines"]:
		ids.append(int((entry as Dictionary)["id"]))
	var sorted_ids: Array = ids.duplicate()
	sorted_ids.sort()
	assert_eq(ids, sorted_ids, "machines are dumped in id order, every time")
	assert_ne(JSON.stringify(s), "", "the whole dump is JSON-serializable")


func test_the_whole_production_system_replays_identically() -> void:
	var script: Dictionary = {
		1: [{"system": &"build", "op": "add_stock",
			"items": {"iron_ore": 2000, "coal": 2000, "iron_plate": 2000, "copper_ore": 800}}],
		2: [{"system": &"build", "op": "place", "kind": "the_hearth",
			"cell": [ORIGIN.x, ORIGIN.y], "free": true, "instant": true}],
		3: [{"system": &"build", "op": "place_line", "kind": "heat_pipe",
			"from": [ORIGIN.x + 5, ORIGIN.y + 2], "to": [ORIGIN.x + 16, ORIGIN.y + 2],
			"free": true, "instant": true}],
		6: [{"system": &"build", "op": "place", "kind": "smelter",
			"cell": [ORIGIN.x + 17, ORIGIN.y + 1], "free": true, "instant": true}],
		8: [{"system": &"build", "op": "place", "kind": "recuperator",
			"cell": [ORIGIN.x + 17, ORIGIN.y + 5], "free": true, "instant": true}],
		20: [{"system": &"production", "op": "set_recipe",
			"cell": [ORIGIN.x + 17, ORIGIN.y + 1], "recipe": "iron_plate"}],
	}
	var diff: PackedStringArray = SimFixture.replay_diff(11, 600, script)
	assert_empty(diff, "same seed, same script, byte-identical production state")


func test_a_command_naming_a_machine_that_is_not_there_is_refused_out_loud() -> void:
	_world()
	var lines: PackedStringArray = TestEnv.capture_log(func() -> void:
		world.cmd_now({"system": &"production", "op": "set_recipe",
			"cell": [3, 3], "recipe": "iron_plate"}), TestEnv.LOG_WARN)
	assert_has(" ".join(lines), "no machine at",
		"a command that hits nothing says so instead of being swallowed")
	assert_false(prod.set_recipe(999999, &"iron_plate"), "and the API returns false")
	assert_false(prod.set_recipe(1, &"no_such_recipe"), "as does an unknown recipe")


# =============================================================================
# performance
# =============================================================================

func test_a_tick_of_production_stays_inside_its_budget() -> void:
	_world()
	var end: Vector2i = _grid_at(ORIGIN)
	# Forty machines is more industry than a real base carries, laid out in a
	# block so the recuperators all have work to link against.
	var placed: int = 0
	for row: int in 8:
		for col: int in 5:
			var c: Vector2i = end + Vector2i(2 + col * 5, -9 + row * 5)
			var kind: String = "smelter" if (row + col) % 3 != 2 else "recuperator"
			if _place(kind, c) > 0:
				placed += 1
	world.run(40)
	if placed < 20:
		skip("only %d machines fit; not a meaningful perf sample" % placed)
		return

	var t0: int = Time.get_ticks_usec()
	var ticks: int = 400
	for _i: int in ticks:
		prod.step(world.tick())
	var per_tick_us: float = float(Time.get_ticks_usec() - t0) / float(ticks)
	Log.warn("production-perf", "%d machines cost %.0f us/tick" % [placed, per_tick_us])
	assert_lt(per_tick_us, 2000.0,
		"%d machines cost %.0f us/tick; the whole tick budget is 50,000" % [placed, per_tick_us])


# --- helpers -----------------------------------------------------------------

## A deposit tile with room around it for a 3x3 drill, or (-1,-1).
func _find_deposit() -> Vector2i:
	if grid == null or not grid.has_method("nearest_resource"):
		return Vector2i(-1, -1)
	var core: Vector2i = grid.call("core_cell") if grid.has_method("core_cell") else Vector2i(128, 128)
	for kind: int in [Grid.Res.IRON, Grid.Res.COAL, Grid.Res.COPPER, Grid.Res.SCRAP]:
		var c: Vector2i = grid.call("nearest_resource", core, kind, 90)
		if c.x >= 0:
			return c
	return Vector2i(-1, -1)
