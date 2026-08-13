extends TestCase
## [P18] Against the REAL content and the REAL systems.
##
## The other suites prove the models handle any shape. This one proves they
## handle THIS shape: [P04]'s recipes, [P06]'s Book of Laws and [P10]'s published
## tree, as they are actually authored in this build. It is the suite that goes
## red the day another part renames a field, which is exactly what a UI part
## needs, because a renamed field in a browser is a silently empty screen.

var world: SimFixture = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["build"])


func before_all() -> void:
	world = SimFixture.new(7).start()


func after_all() -> void:
	world.stop()


func setup() -> void:
	world.ensure()


# ------------------------------------------------------------- [P04] items ---

func test_the_recipe_graph_is_populated_from_content() -> void:
	var graph := LcnItemGraph.new()
	graph.rebuild(world.system(&"build"), TestEnv.registry())
	if graph.recipe_count() == 0:
		skip("no recipe content in this build")
		return
	assert_gt(float(graph.recipe_count()), 0.0, "recipes are read")
	var with_machines: int = 0
	for id: StringName in graph.recipe_ids():
		var r: LcnItemGraph.Recipe = graph.recipe(id)
		assert_not_empty(r.outputs, "%s produces something" % String(id))
		assert_gt(r.seconds, 0.0, "%s takes time" % String(id))
		if not r.machines.is_empty():
			with_machines += 1
	assert_gt(float(with_machines), 0.0, "at least one recipe names the machine that runs it")


func test_authored_recipes_close_the_loop_on_build_materials() -> void:
	var graph := LcnItemGraph.new()
	graph.rebuild(world.system(&"build"), TestEnv.registry())
	if graph.recipe_count() == 0:
		skip("no recipe content in this build")
		return
	# Iron plate is spent by half the building costs in the game. If the browser
	# cannot say where it comes from, the browser is useless.
	var makers: Array[Dictionary] = graph.producers_of(&"iron_plate")
	assert_not_empty(makers, "something in the content makes iron plate")
	var users: Array[Dictionary] = graph.consumers_of(&"iron_plate")
	assert_not_empty(users, "and plenty of things spend it")


func test_recipes_report_their_heat_bill() -> void:
	var graph := LcnItemGraph.new()
	graph.rebuild(world.system(&"build"), TestEnv.registry())
	var priced: int = 0
	for id: StringName in graph.recipe_ids():
		if graph.recipe(id).heat_cost > 0.0:
			priced += 1
	if graph.recipe_count() == 0:
		skip("no recipe content in this build")
		return
	assert_gt(float(priced), 0.0,
		"crafting costs heat in this game, and the browser has to say how much")


# ---------------------------------------------------------- [P10] research ---

func test_the_published_tree_is_used_as_published() -> void:
	if not need_system(&"research"):
		return
	var model := LcnTechModel.new()
	model.rebuild(world.system(&"research"), world.system(&"build"), TestEnv.registry())
	assert_eq(String(model.source()), "research", "[P10] publishes a layout and it wins")
	assert_gt(float(model.nodes.size()), 10.0, "the whole tree arrives")
	assert_gt(float(model.columns()), 1.0, "laid out in the columns [P10] chose")

	var named: int = 0
	var with_why: int = 0
	var with_cost: int = 0
	for n: LcnTechModel.TechNode in model.nodes:
		if n.display_name != "" and n.display_name != LcnUiFormat.item_name(n.id):
			named += 1
		if n.why_now() != "":
			with_why += 1
		if n.cost_label() != "—":
			with_cost += 1
	assert_gt(float(named), 0.0, "nodes carry their authored titles, not id-cased ones")
	assert_eq(with_why, model.nodes.size(), "every node can say why it matters now")
	assert_eq(with_cost, model.nodes.size(), "and what it costs")


func test_research_state_tracks_the_system() -> void:
	if not need_system(&"research"):
		return
	var research: SimSystem = world.system(&"research")
	var model := LcnTechModel.new()
	model.rebuild(research, world.system(&"build"), TestEnv.registry())
	var open: LcnTechModel.TechNode = null
	for n: LcnTechModel.TechNode in model.nodes:
		if n.state == LcnTechModel.State.AVAILABLE:
			open = n
			break
	if open == null:
		skip("nothing is available to start on tick zero")
		return
	world.cmd_now({"system": &"research", "op": "start", "id": String(open.id)})
	world.run(5)
	model.refresh_state(research, world.system(&"build"))
	assert_eq(model.node(open.id).state, LcnTechModel.State.ACTIVE,
		"starting a project through the panel's own command shows up in the tree")


func test_a_node_never_claims_to_open_itself() -> void:
	if not need_system(&"research"):
		return
	var model := LcnTechModel.new()
	model.rebuild(world.system(&"research"), world.system(&"build"), TestEnv.registry())
	var build: SimSystem = world.system(&"build")
	for n: LcnTechModel.TechNode in model.nodes:
		assert_has_not(n.unlocks, n.id,
			"'%s' must not list itself as a building it opens" % String(n.id))
		for kind: StringName in n.unlocks:
			assert_not_null(build.call(&"def_of", kind),
				"'%s' lists '%s' as a building, so it had better be one" % [
					String(n.id), String(kind)])


func test_every_gated_building_hangs_off_a_node() -> void:
	if not need_system(&"research"):
		return
	var model := LcnTechModel.new()
	model.rebuild(world.system(&"research"), world.system(&"build"), TestEnv.registry())
	var gated: int = 0
	var orphaned: PackedStringArray = PackedStringArray()
	for raw: Variant in world.system(&"build").call(&"all_defs"):
		var def: Resource = raw as Resource
		var unlock: StringName = LcnUiFormat.as_name(def.get(&"unlock_id"))
		if String(unlock) == "":
			continue
		gated += 1
		var n: LcnTechModel.TechNode = model.node(unlock)
		if n == null or not n.unlocks.has(LcnUiFormat.as_name(def.get(&"id"))):
			orphaned.append(String(def.get(&"id")))
	if gated == 0:
		skip("nothing is gated behind research")
		return
	assert_empty(orphaned, "every gated building is listed under the node that opens it")


# ------------------------------------------------------------- [P06] laws ----

func test_the_book_of_laws_is_read_whole() -> void:
	if not need_system(&"society"):
		return
	var model := LcnLawModel.new()
	model.rebuild(world.system(&"society"), TestEnv.registry())
	if model.is_empty():
		skip("no law content in this build")
		return
	assert_gt(float(model.laws.size()), 5.0, "the whole book arrives")
	assert_true(model.has_system(), "and there is a council to sign them")

	var with_prose: int = 0
	var with_both_sides: int = 0
	for l: LcnLawModel.LawRecord in model.laws:
		if l.prose != "":
			with_prose += 1
		if l.argument_for != "" and l.argument_against != "":
			with_both_sides += 1
	assert_eq(with_prose, model.laws.size(), "every law shows its authored text")
	assert_gt(float(with_both_sides), 0.0,
		"and the ones with two sides show both — that is the decision, not the stats")


func test_chapters_come_from_the_authored_sections() -> void:
	if not need_system(&"society"):
		return
	var model := LcnLawModel.new()
	model.rebuild(world.system(&"society"), TestEnv.registry())
	if model.is_empty():
		skip("no law content in this build")
		return
	assert_not_empty(model.chapters(), "the book has chapters")
	for c: StringName in model.chapters():
		assert_not_empty(model.laws_in(c), "chapter '%s' is not empty" % String(c))
		assert_ne(model.chapter_title(c), "", "and it has a heading")


func test_a_law_states_its_price_in_hope_and_discontent() -> void:
	if not need_system(&"society"):
		return
	var model := LcnLawModel.new()
	model.rebuild(world.system(&"society"), TestEnv.registry())
	if model.is_empty():
		skip("no law content in this build")
		return
	var priced: int = 0
	for l: LcnLawModel.LawRecord in model.laws:
		if l.cost_label() != "nothing but the signature":
			priced += 1
	assert_gt(float(priced), 0.0, "signing costs something and the screen says what")


func test_availability_comes_from_the_council() -> void:
	if not need_system(&"society"):
		return
	var society: SimSystem = world.system(&"society")
	var model := LcnLawModel.new()
	model.rebuild(society, TestEnv.registry())
	if model.is_empty():
		skip("no law content in this build")
		return
	var open: Array[StringName] = society.call(&"available_laws")
	for id: StringName in open:
		var l: LcnLawModel.LawRecord = model.law(id)
		if l == null:
			continue
		assert_eq(l.status, LcnLawModel.Status.AVAILABLE,
			"'%s' is open in the council and open on the screen" % String(id))
	var blocked: int = 0
	for l2: LcnLawModel.LawRecord in model.laws:
		if l2.status != LcnLawModel.Status.AVAILABLE and l2.status != LcnLawModel.Status.ENACTED:
			blocked += 1
			assert_ne(l2.blocked_reason, "",
				"'%s' is closed and the screen says why" % String(l2.id))
	assert_gt(float(blocked + open.size()), 0.0, "the book has a standing on tick zero")


# ---------------------------------------------------------- the whole shelf --

func test_a_tooltip_for_a_crafter_lists_its_recipes() -> void:
	var build: SimSystem = world.system(&"build")
	var crafter: Resource = null
	for raw: Variant in build.call(&"all_defs"):
		var def: Resource = raw as Resource
		var recipes: Variant = def.get(&"recipes")
		if typeof(recipes) == TYPE_ARRAY and not (recipes as Array).is_empty():
			crafter = def
			break
	if crafter == null:
		skip("no building lists a recipe")
		return
	var sheet: Dictionary = LcnBuildFacts.sheet(
		crafter, LcnBuildFacts.Ctx.from_sim(TestEnv.sim()))
	assert_has(LcnBuildFacts.to_text(sheet), "Recipes",
		"a machine's tooltip says what it can make")
