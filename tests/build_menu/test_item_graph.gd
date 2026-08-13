extends TestCase
## [P18] The recipe browser's graph.
##
## Two halves are tested separately, on purpose:
##   * against the REAL building content, which already describes an economy
##     (costs, fuel, extraction, upkeep) even with zero recipes authored;
##   * against a fake recipe registry, which proves the [P04] path works before
##     [P04] exists and would keep working if it authored a different spelling.

var world: SimFixture = null
var graph: LcnItemGraph = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["build"])


func setup() -> void:
	world = SimFixture.new(7).start()
	graph = LcnItemGraph.new()
	graph.rebuild(world.system(&"build"), TestEnv.registry())


func teardown() -> void:
	world.stop()


func _hows(edges: Array[Dictionary]) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for e: Dictionary in edges:
		out.append(String(e.get("how", "")))
	return out


# ------------------------------------------------- from the building defs ----

func test_it_knows_what_an_item_is_spent_on() -> void:
	assert_gt(float(graph.item_count()), 0.0, "content mentions items")
	var uses: Array[Dictionary] = graph.consumers_of(&"iron_plate")
	assert_not_empty(uses, "iron plate is used for something")
	assert_has(_hows(uses), LcnItemGraph.HOW_BUILD_COST, "chiefly for building things")


func test_fuel_shows_up_as_a_consumer() -> void:
	var uses: Array[Dictionary] = graph.consumers_of(&"coal")
	assert_has(_hows(uses), LcnItemGraph.HOW_FUEL, "the generator burns coal")
	var text: String = ""
	for e: Dictionary in uses:
		if String(e["how"]) == LcnItemGraph.HOW_FUEL:
			text = String(e["text"])
			break
	assert_has(text, "burns", "and the row says so in words")


func test_extraction_is_a_producer() -> void:
	var found: bool = false
	for id: StringName in graph.item_ids():
		for e: Dictionary in graph.producers_of(id):
			if String(e["how"]) == LcnItemGraph.HOW_EXTRACT:
				found = true
				assert_gt(float(e["rate"]), 0.0, "an extractor states a rate")
				break
		if found:
			break
	if not found:
		skip("no extractor in this build's content")


func test_orphans_are_the_shopping_list() -> void:
	var orphans: Array[StringName] = graph.orphans()
	assert_not_empty(orphans,
		"with no recipes authored, most materials have no producer — and saying which is the point")
	for id: StringName in orphans:
		assert_empty(graph.producers_of(id), "%s really has no producer" % String(id))


func test_the_wildcard_deposit_is_not_an_item() -> void:
	assert_has_not(graph.item_ids(), &"*",
		"'*' means 'whatever seam it stands on'; a browser entry nobody can hold is a bug")


func test_the_browser_opens_on_the_busiest_item() -> void:
	var busiest: StringName = graph.busiest_item()
	assert_ne(String(busiest), "", "there is something to open on")
	var best: int = graph.producers_of(busiest).size() + graph.consumers_of(busiest).size()
	for id: StringName in graph.item_ids():
		assert_le(float(graph.producers_of(id).size() + graph.consumers_of(id).size()), float(best),
			"nothing is more connected than the item the browser opens on")


func test_an_empty_query_lists_the_recipes_too() -> void:
	var g := LcnItemGraph.new()
	g.rebuild(world.system(&"build"), _fake_registry())
	var kinds: Dictionary = {}
	for row: Dictionary in g.search("", world.system(&"build"), 500):
		kinds[String(row["kind"])] = true
	assert_true(kinds.has("item"), "the shelf shows items")
	assert_true(kinds.has("recipe"), "and the crafts, without having to type first")


func test_search_spans_items_recipes_and_buildings() -> void:
	var rows: Array[Dictionary] = graph.search("coal", world.system(&"build"))
	assert_not_empty(rows, "'coal' finds something")
	var kinds: Dictionary = {}
	for r: Dictionary in rows:
		kinds[String(r["kind"])] = true
	assert_true(kinds.has("item"), "the item itself")
	assert_true(kinds.has("building"), "and the building that burns it")


func test_the_graph_is_deterministic() -> void:
	assert_deterministic(_snapshot, "the same content produces the same graph")


func _snapshot() -> Array:
	var out: Array = []
	var fresh := LcnItemGraph.new()
	fresh.rebuild(world.system(&"build"), TestEnv.registry())
	for id: StringName in fresh.item_ids():
		out.append("%s:%d:%d" % [String(id),
			fresh.producers_of(id).size(), fresh.consumers_of(id).size()])
	return out


func test_it_survives_no_build_system_and_no_registry() -> void:
	var orphan := LcnItemGraph.new()
	orphan.rebuild(null, null)
	assert_eq(orphan.item_count(), 0, "nothing to index, nothing to crash on")
	assert_empty(orphan.search("anything"), "and searching an empty graph is safe")


# --------------------------------------------------- the [P04] recipe path ---

class FakeRecipe extends Resource:
	@export var id: StringName = &""
	@export var display_name: String = ""
	@export var inputs: Dictionary = {}
	@export var outputs: Dictionary = {}
	@export var craft_time_ticks: int = 20
	@export var machines: Array = []


class FakeRegistry extends RefCounted:
	var items: Array = []

	func all(category: String) -> Array:
		return items if category == "recipes" else []


func _fake_registry() -> FakeRegistry:
	var smelt := FakeRecipe.new()
	smelt.id = &"smelt_iron"
	smelt.display_name = "Smelt Iron"
	smelt.inputs = {&"iron_ore": 2, &"coal": 1}
	smelt.outputs = {&"iron_plate": 1}
	smelt.craft_time_ticks = 60
	smelt.machines = [&"smelter"]

	var gears := FakeRecipe.new()
	gears.id = &"make_gear"
	gears.display_name = "Gear"
	gears.inputs = {&"iron_plate": 2}
	gears.outputs = {&"gear": 1}
	gears.craft_time_ticks = 20

	var reg := FakeRegistry.new()
	reg.items = [gears, smelt]
	return reg


func test_authored_recipes_produce_and_consume() -> void:
	var g := LcnItemGraph.new()
	g.rebuild(world.system(&"build"), _fake_registry())
	assert_eq(g.recipe_count(), 2, "both recipes are read")

	var plate_makers: Array[Dictionary] = g.producers_of(&"iron_plate")
	assert_has(_hows(plate_makers), LcnItemGraph.HOW_RECIPE, "smelting makes plate")
	assert_has(_hows(g.consumers_of(&"iron_ore")), LcnItemGraph.HOW_RECIPE_INPUT, "and eats ore")

	var recipe: LcnItemGraph.Recipe = g.recipe(&"smelt_iron")
	assert_near(recipe.seconds, 3.0, 0.001, "60 ticks at 20 Hz is three seconds")
	assert_near(recipe.rate_of(&"iron_plate"), 1.0 / 3.0, 0.001, "one plate every three seconds")
	assert_has(recipe.summary(), "->", "the summary reads as a recipe")


func test_machines_are_learned_from_the_building_defs_too() -> void:
	var g := LcnItemGraph.new()
	g.rebuild(world.system(&"build"), _fake_registry())
	var recipe: LcnItemGraph.Recipe = g.recipe(&"make_gear")
	assert_not_null(recipe, "the gear recipe exists")
	# The fake authored no machine for it; any building def listing it should be
	# picked up automatically.
	var expected: Array[StringName] = []
	for raw: Variant in world.system(&"build").call(&"all_defs"):
		var d: Resource = raw as Resource
		var list: Variant = d.get(&"recipes")
		if typeof(list) == TYPE_ARRAY and (list as Array).has(&"make_gear"):
			expected.append(StringName(String(d.get(&"id"))))
	assert_eq(recipe.machines.size(), expected.size(),
		"a building that lists a recipe becomes one of its machines")


func test_chains_walk_both_directions() -> void:
	var g := LcnItemGraph.new()
	g.rebuild(world.system(&"build"), _fake_registry())
	var up: Array[Dictionary] = g.chain_upstream(&"gear", 3)
	var names: PackedStringArray = PackedStringArray()
	for step: Dictionary in up:
		names.append(String(step["item"]))
	assert_has(names, "iron_plate", "a gear needs plate")
	assert_has(names, "iron_ore", "and, one step further back, ore")

	var down: Array[Dictionary] = g.chain_downstream(&"iron_ore", 3)
	var down_names: PackedStringArray = PackedStringArray()
	for step2: Dictionary in down:
		down_names.append(String(step2["item"]))
	assert_has(down_names, "iron_plate", "ore ends up as plate")


func test_a_cyclic_recipe_set_terminates() -> void:
	var a := FakeRecipe.new()
	a.id = &"a_to_b"
	a.inputs = {&"a": 1}
	a.outputs = {&"b": 1}
	var b := FakeRecipe.new()
	b.id = &"b_to_a"
	b.inputs = {&"b": 1}
	b.outputs = {&"a": 1}
	var reg := FakeRegistry.new()
	reg.items = [a, b]
	var g := LcnItemGraph.new()
	g.rebuild(null, reg)
	assert_size(g.chain_upstream(&"a", 6), 1, "a cycle is visited once, not forever")
