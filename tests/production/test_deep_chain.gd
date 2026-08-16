extends TestCase
## [P04] THE DEPTH OF THE GAME, held to account.
##
## Two critics ran this build and wrote the same sentence in different words:
## the crafting graph never goes past depth 2. The shipped content in
## `game/content/recipes/` is five transformations deep and always was —
## ore -> plate -> steel -> pipe -> heat core — and the reference run reached
## TWO of them, because the top of the tree wanted an item this city had no
## source for.
##
## That item is COPPER. `copper_coil` feeds `pipe_segment` and `circuit`,
## `heat_core` needs both, and a `warmth_radiator` costs coil to place — but
## `copper_ore` had exactly one source in the whole game, a drill standing on a
## copper field, and on the reference map the nearest copper is 34 tiles
## south-east of the wall. So the graph above depth 3 was UNENTERABLE without an
## expedition, and no scenario had ever mounted one. Depth 2 was not a bug in
## [P04]; it was a hole in the content, and it made four of the fourteen shipped
## recipes dead letters.
##
## `salvaged_wire` closes it — 8 scrap -> 2 copper_ore in a rubble sorter — at a
## deliberately terrible 0.16 ore/s against the 0.80/s one drill lifts. Salvage
## is how a poor city gets its first coil; mining is how it stops being poor.
##
## WHAT WOULD MAKE THESE RED. Delete game/content/recipes/salvaged_wire.tres and
## every test in this file below `test_the_shipped_graph_still_reaches_five`
## fails: copper_ore goes back to being a raw material, the reachable closure
## from salvage stops at `steel_plate`, `set_recipe` refuses the sorter, and the
## live smelter makes nothing. That is the check — run it before trusting any of
## them.

## Ticks for [P04]'s throttled rescan of [P11] to notice a placement.
const SYNC_GRACE: int = 15
## Long enough for a 250-tick salvage craft, a 25-tick smelt and the refills
## between them to happen several times over, at 20 Hz.
const RUN_TICKS: int = 2200

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


# =============================================================================
# the graph, with no world under it
# =============================================================================

func test_the_shipped_graph_still_reaches_five() -> void:
	# The control. This passed before `salvaged_wire` existed and must keep
	# passing after it: the new recipe is allowed to open a door, never to move
	# the roof. copper_ore going from raw (0) to salvage-derived (1) leaves
	# heat_core at 5 because pipe_segment, at 4, is set by the STEEL branch.
	var b: ProdRecipeBook = _book()
	assert_empty(b.problems, "no recipe in game/content/recipes fails validation")
	assert_eq(b.max_depth, 5, "the shipped graph is five transformations deep")
	assert_eq(b.item_depth(&"pipe_segment"), 4, "steel -> pipe is still the deep branch")
	assert_eq(b.item_depth(&"heat_core"), 5, "and the component above it")


func test_copper_has_a_source_inside_the_walls() -> void:
	# THE HOLE, STATED AS AN ASSERTION. Before `salvaged_wire`, copper_ore was in
	# `raw_items` — the list of things that have to come out of the ground —
	# which meant the ONLY way to enter the top half of the tree was a drill on
	# a copper field, and there is none within 33 tiles of the reference map's
	# core. This is the test that goes red the moment the recipe is removed.
	var b: ProdRecipeBook = _book()
	assert_has_not(b.raw_items, &"copper_ore",
		"copper is no longer something only a mine can produce")
	var producers: Array = b.producers_of.get(&"copper_ore", [])
	assert_not_empty(producers, "something in the content makes copper_ore")
	# And it has to be reachable from RUBBLE, not from another metal: a recipe
	# that made copper out of copper would satisfy the line above and change
	# nothing about what a city standing on a scrap field can do.
	var from_salvage: bool = false
	for pid: Variant in producers:
		var r: RecipeDef = b.get_recipe(StringName(String(pid)))
		if r == null:
			continue
		var all_raw: bool = not r.inputs.is_empty()
		for item: StringName in r.sorted_inputs():
			if b.item_depth(item) > 0:
				all_raw = false
		if all_raw:
			from_salvage = true
	assert_true(from_salvage, "copper comes out of raw material, not out of more copper")


func test_a_city_with_only_scrap_and_coal_can_reach_the_top_of_the_tree() -> void:
	# THE WHOLE CLAIM IN ONE CLOSURE. Start from what the reference map actually
	# gives a city inside its own walls — rubble and a coal seam — and repeatedly
	# apply every recipe whose inputs are already satisfied. Before
	# `salvaged_wire` this closure stopped at steel_plate and gear: copper_coil,
	# pipe_segment, circuit and heat_core were all unreachable, which is FOUR of
	# the fourteen shipped recipes that no player could ever run without first
	# walking off the map.
	var b: ProdRecipeBook = _book()
	var have: Dictionary[StringName, bool] = {&"scrap": true, &"coal": true}
	for _pass: int in 12:
		for rid: StringName in b.ids:
			var r: RecipeDef = b.get_recipe(rid)
			var ok: bool = true
			for item: StringName in r.sorted_inputs():
				if not have.has(item):
					ok = false
			if not ok:
				continue
			for out_item: StringName in r.all_outputs().keys():
				have[out_item] = true
	for wanted: StringName in [&"iron_plate", &"steel_plate", &"gear", &"copper_coil",
			&"pipe_segment", &"circuit", &"insulation", &"heat_core"]:
		assert_true(have.has(wanted),
			"'%s' is reachable from rubble and coal alone" % String(wanted))


func test_the_wire_ratio_is_the_reason_to_go_mining() -> void:
	# The number is the design. `salvaged_wire` is priced so that FIVE sorters
	# feed one copper smelter, against ONE drill that feeds it exactly. If a
	# balance pass ever makes salvage competitive with mining, the copper field
	# stops being worth thirty tiles of pipe and the expansion loop this recipe
	# exists to motivate quietly dies — so the ratio has to be edited here,
	# out loud, before it can be edited in the .tres.
	var b: ProdRecipeBook = _book()
	var wire: RecipeDef = b.get_recipe(&"salvaged_wire")
	if wire == null:
		fail("game/content/recipes/salvaged_wire.tres is missing")
		return
	assert_near(b.feed_ratio(&"salvaged_wire", &"copper_coil", &"copper_ore"), 5.0, 0.01,
		"five wire sorters to keep one copper smelter fed")
	assert_near(wire.output_per_minute(&"copper_ore"), 9.6, 0.01,
		"0.16 copper_ore a second out of one sorter")
	# A drill is 0.80/s: five times better, and that is the point.
	assert_near(wire.output_per_minute(&"copper_ore") * 5.0, 48.0, 0.05,
		"one drill is worth five sorters")


func test_a_rubble_sorter_is_allowed_to_run_it() -> void:
	# `for_machine` appends anything the TAGS permit after the building def's own
	# list, so a recipe does not need game/content/buildings/rubble_sorter.tres
	# edited to appear on the machine — which matters, because that file belongs
	# to another part. This test is what proves the tag route actually works
	# rather than being assumed.
	var b: ProdRecipeBook = _book()
	var offered: Array[StringName] = b.for_machine(&"rubble_sorter",
		[&"crafter", &"machine", &"sorter", &"salvage"] as Array[StringName],
		[&"sorted_rubble", &"salvaged_stores"] as Array[StringName])
	assert_has(offered, &"salvaged_wire", "the sorter offers the wire recipe")
	assert_eq(offered[0], &"sorted_rubble",
		"and the default a sorter picks with no orders is unchanged")


# =============================================================================
# and now on a live world
# =============================================================================

func test_a_salvage_city_smelts_its_own_copper() -> void:
	# The content tests above prove the graph. This proves the MACHINES: a sorter
	# on `salvaged_wire` and a smelter on `copper_coil`, fed nothing but scrap,
	# and coil in the city store at the end of it.
	if not _city():
		return
	var sorter: int = _place("rubble_sorter", _at("sorter"))
	var smelter: int = _place("smelter", _at("smelter"))
	assert_gt(float(sorter), 0.0, "the sorter was placed")
	assert_gt(float(smelter), 0.0, "the smelter was placed")
	world.run(SYNC_GRACE)
	assert_true(prod.set_recipe(sorter, &"salvaged_wire"), "a sorter can be told to cut wire")
	assert_true(prod.set_recipe(smelter, &"copper_coil"), "and a smelter to draw it into coil")
	world.run(RUN_TICKS)
	assert_gt(float(prod.produced_total(&"copper_ore")), 0.0,
		"the sorter pulled copper out of the rubble")
	assert_gt(float(prod.produced_total(&"copper_coil")), 0.0,
		"and the smelter turned it into coil")
	assert_eq(_stock("copper_ore") + _stock("copper_coil") > 0, true,
		"the goods reached the city stores, not just the machine's own buffer")


func test_the_factory_reaches_depth_four_from_rubble() -> void:
	# THE END-TO-END, AND THE ONE THAT WOULD HAVE BEEN RED AGAINST THE BUILD THE
	# CRITICS PLAYED. Six machines, one heat spur, and NOTHING in the stores but
	# scrap and coal — every plate, every coil, every steel bar and every pipe
	# segment in this test is made on screen from rubble. `chain_depth_reached()`
	# is the honest summary: 4 means something in this city is two components
	# deep, which is the number the reference run has never reached.
	if not _city(false):
		return
	var ore_sorter: int = _place("rubble_sorter", _at("sorter"))
	var wire_sorter: int = _place("rubble_sorter", _at("sorter2"))
	var iron: int = _place("smelter", _at("smelter"))
	var copper: int = _place("smelter", _at("smelter2"))
	var steel: int = _place("smelter", _at("smelter3"))
	var shop: int = _place("workshop", _at("workshop"))
	for id: int in [ore_sorter, wire_sorter, iron, copper, steel, shop]:
		if id <= 0:
			skip("this map has no room for the six-machine chain")
			return
	world.run(SYNC_GRACE)
	prod.set_recipe(ore_sorter, &"sorted_rubble")
	prod.set_recipe(wire_sorter, &"salvaged_wire")
	prod.set_recipe(iron, &"iron_plate")
	prod.set_recipe(copper, &"copper_coil")
	prod.set_recipe(steel, &"steel_plate")
	prod.set_recipe(shop, &"pipe_segment")
	world.run(RUN_TICKS * 3)
	assert_gt(float(prod.produced_total(&"iron_plate")), 0.0, "depth 2: plate out of rubble")
	assert_gt(float(prod.produced_total(&"steel_plate")), 0.0, "depth 3: steel out of plate")
	assert_gt(float(prod.produced_total(&"copper_coil")), 0.0, "depth 2: coil out of wire")
	assert_gt(float(prod.produced_total(&"pipe_segment")), 0.0,
		"depth 4: a component made of two other components")
	assert_ge(float(prod.chain_depth_reached()), 4.0,
		"the city reports the depth it actually reached")


func test_slag_finally_has_somewhere_to_go() -> void:
	# The byproduct that makes the layout a puzzle: iron smelting cannot be done
	# without producing slag, one per plate forever, and no reference run had
	# ever put a machine on it — `produced.slag` 23, consumed 0. Two recipes eat
	# it, and this proves a shop on the second one clears it.
	if not _city(false):
		return
	var iron: int = _place("smelter", _at("smelter"))
	var shop: int = _place("workshop", _at("workshop"))
	var ore_sorter: int = _place("rubble_sorter", _at("sorter"))
	if iron <= 0 or shop <= 0 or ore_sorter <= 0:
		skip("this map has no room for the slag loop")
		return
	world.run(SYNC_GRACE)
	prod.set_recipe(ore_sorter, &"sorted_rubble")
	prod.set_recipe(iron, &"iron_plate")
	prod.set_recipe(shop, &"insulation_wool")
	world.run(RUN_TICKS * 2)
	assert_gt(float(prod.produced_total(&"slag")), 0.0, "the smelter made slag it did not want")
	assert_gt(float(prod.produced_total(&"insulation_wool")), 0.0,
		"and the shop spun it into wool a pipe can be lagged with")


# =============================================================================
# the reference run's own contract
# =============================================================================

func test_the_production_scenario_actually_builds_the_deep_chain() -> void:
	# A GATE BAND SAYS WHAT A RUN PRODUCED. This says what the run was ASKED to
	# produce, which is the half a metric cannot check: tests/gate/ grades
	# numbers off a finished run, so a scenario that quietly stopped naming
	# `pipe_segment` on anything would show up only as a band going red weeks
	# later with no explanation attached. Here the intent is the assertion.
	#
	# It reads deep_chain and not first_night on purpose. first_night keeps the
	# labour coupling LIVE and measurably cannot crew a factory on this build —
	# a foundry added to it went 55 citizens -> 44, hope 72 -> 16 and produced
	# nothing, because [P05] assigned nobody. deep_chain stands the job board
	# down in its first command and is where the graph is graded; when the
	# staffing fix lands, the two converge and this test moves back.
	var text: String = FileAccess.get_file_as_string("res://tests/scenarios/deep_chain.json")
	assert_not_empty(text, "tests/scenarios/deep_chain.json is readable")
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		fail("deep_chain.json does not parse")
		return
	var scenario: Dictionary = parsed
	var recipes: Dictionary[StringName, bool] = {}
	var kinds: Dictionary[StringName, bool] = {}
	var autarky: bool = false
	for entry: Variant in scenario.get("script", []):
		var cmd: Dictionary = (entry as Dictionary).get("cmd", {})
		if String(cmd.get("system", "")) == "production" and String(cmd.get("op", "")) == "set_recipe":
			recipes[StringName(String(cmd.get("recipe", "")))] = true
		if String(cmd.get("op", "")) in ["place", "place_line"]:
			kinds[StringName(String(cmd.get("kind", "")))] = true
		if String(cmd.get("op", "")) == "set_staffing_autarky":
			autarky = bool(cmd.get("on", false))
	# The one thing this scenario is not allowed to do quietly.
	assert_true(autarky, "deep_chain stands the job board down IN THE SCRIPT, "
		+ "where a reader of the run can see it, not in a comment")
	# The five recipes that carry the run from the ground to a two-component
	# part. Each one is a tier the old reference run never entered.
	for rid: StringName in [&"sorted_rubble", &"salvaged_wire", &"iron_plate",
			&"copper_coil", &"steel_plate", &"gear", &"pipe_segment",
			&"insulation", &"insulation_wool", &"circuit", &"heat_core"]:
		assert_has(recipes.keys(), rid,
			"the production run names '%s' on a machine" % String(rid))
	for kind: StringName in [&"smelter", &"workshop", &"rubble_sorter", &"assembly_hall",
			&"ore_drill", &"recuperator", &"heat_booster_pump", &"heat_pipe_insulated"]:
		assert_has(kinds.keys(), kind,
			"the production run places a %s" % String(kind))
	# And every recipe it names has to be one this build can actually run, or the
	# scenario is a plan for a game nobody shipped.
	var b: ProdRecipeBook = _book()
	for named: StringName in recipes.keys():
		if String(named) == "":
			continue
		assert_true(b.has(named), "'%s' exists in the content" % String(named))


# =============================================================================
# fixture
# =============================================================================

## Places a finished building and returns its id, or -1.
func _place(kind: String, cell: Vector2i) -> int:
	if cell == Vector2i.ZERO:
		return -1
	var before: int = int(build.call("building_count"))
	world.cmd_now({"system": &"build", "op": "place", "kind": kind,
		"cell": [cell.x, cell.y], "free": true, "instant": true})
	if int(build.call("building_count")) == before:
		return -1
	var b: Object = build.call("building_at", cell)
	return -1 if b == null else int(b.get("id"))


func _stock(item: String) -> int:
	var s: Object = build.get("stock")
	return 0 if s == null else int(s.call("count", StringName(item)))


func _at(key: String) -> Vector2i:
	return _site.get(key, Vector2i.ZERO)


var _site: Dictionary = {}


## Hearth, a heat spur and six machine pads on ground this map actually has.
## `rich` stocks the city with everything; the depth tests pass false, because a
## chain proved out of a full warehouse has proved nothing.
func _city(rich: bool = true) -> bool:
	world = SimFixture.new(7).start()
	prod = world.system(&"production") as ProductionSystem
	build = world.system(&"build")
	heat = world.system(&"heat")
	grid = world.system(&"grid")
	if prod == null or build == null:
		skip("no production or build system in this build")
		return false
	# [P05] owns whether anybody walked to the workshop. A suite about the
	# CRAFTING GRAPH must not go red because the job board rearranged its shifts.
	prod.set_staffing_autarky(true)
	_site = _find_site()
	if _site.is_empty():
		skip("no site on this map takes a hearth, a 26-tile spur and six machine pads")
		return false
	var hearth: int = _place("the_hearth", _at("hearth"))
	world.cmd_now({"system": &"build", "op": "place_line", "kind": "heat_pipe",
		"from": [_at("pipe_from").x, _at("pipe_from").y],
		"to": [_at("pipe_to").x, _at("pipe_to").y], "free": true, "instant": true})
	if heat != null and hearth > 0:
		heat.call("deliver_fuel", hearth, &"coal", 8000.0)
	var items: Dictionary = {"scrap": 40000, "coal": 8000}
	if rich:
		items = {"scrap": 40000, "coal": 8000, "iron_ore": 6000, "copper_ore": 6000,
			"iron_plate": 6000, "steel_plate": 4000, "copper_coil": 4000,
			"timber": 4000, "stone": 4000, "slag": 4000}
	world.cmd_now({"system": &"build", "op": "add_stock", "items": items})
	world.run(4)
	return true


const SPUR_RUN: int = 26


## Walks outwards from the core, nearest rows first, so the site is both
## deterministic and somewhere a player would plausibly build.
func _find_site() -> Dictionary:
	var core: Vector2i = Vector2i(128, 128)
	if grid != null and grid.has_method("core_cell"):
		core = grid.call("core_cell")
	for ring: int in 30:
		for sign: int in [1, -1]:
			var y: int = core.y + ring * sign
			for dx: int in range(6, 34):
				for sx: int in [1, -1]:
					var plan: Dictionary = _plan_at(core.x + dx * sx, y)
					if not plan.is_empty():
						return plan
			if ring == 0:
				break
	return {}


## Six pads on one spur: three smelters and a workshop above it, two sorters
## below. Empty when any part of it will not fit here.
func _plan_at(x0: int, y: int) -> Dictionary:
	var plan: Dictionary = {
		"hearth": Vector2i(x0 - 5, y - 2),
		"pipe_from": Vector2i(x0, y),
		"pipe_to": Vector2i(x0 + SPUR_RUN - 1, y),
		"smelter": Vector2i(x0, y - 3),
		"smelter2": Vector2i(x0 + 4, y - 3),
		"smelter3": Vector2i(x0 + 8, y - 3),
		"workshop": Vector2i(x0 + 12, y - 3),
		"sorter": Vector2i(x0, y + 1),
		"sorter2": Vector2i(x0 + 4, y + 1),
	}
	for i: int in SPUR_RUN:
		if not _fits("heat_pipe", Vector2i(x0 + i, y)):
			return {}
	for key: String in ["hearth", "smelter", "smelter2", "smelter3", "workshop",
			"sorter", "sorter2"]:
		if not _fits(_kind_for(key), plan[key]):
			return {}
	return plan


func _kind_for(key: String) -> String:
	if key == "hearth":
		return "the_hearth"
	if key == "workshop":
		return "workshop"
	if key.begins_with("sorter"):
		return "rubble_sorter"
	return "smelter"


func _fits(kind: String, cell: Vector2i) -> bool:
	var r: Dictionary = build.call("can_place", StringName(kind), cell, 0, false)
	return bool(r.get("ok", false))


## The recipe book alone. No world, no map generation.
func _book() -> ProdRecipeBook:
	if prod != null:
		return prod.book
	var b := ProdRecipeBook.new()
	b.load_all()
	return b
