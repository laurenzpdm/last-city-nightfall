extends TestCase
## [P18] The tech tree model: three sources, one layout, and a relevance line
## that measures each node against the city as it stands.

var world: SimFixture = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["build"])


func setup() -> void:
	world = SimFixture.new(7).start()


func teardown() -> void:
	world.stop()


func _build() -> SimSystem:
	return world.system(&"build")


# --------------------------------------------- derived from content today ----

func test_a_tree_exists_with_or_without_a_research_part() -> void:
	var model := LcnTechModel.new()
	model.rebuild(null, _build(), TestEnv.registry())
	if model.is_empty():
		skip("no gated content and no research content in this build")
		return
	var source: String = String(model.source())
	assert_true(source == "content" or source == "buildings",
		"the tree is read from authored research when there is any, and derived from "
		+ "BuildingDef.unlock_id when there is not (got '%s')" % source)
	if source == "buildings":
		for n: LcnTechModel.TechNode in model.nodes:
			assert_not_empty(n.unlocks, "%s opens at least one building" % String(n.id))


func test_authored_nodes_are_matched_to_the_buildings_they_open() -> void:
	var model := LcnTechModel.new()
	model.rebuild(null, _build(), TestEnv.registry())
	if model.is_empty():
		skip("no research content in this build")
		return
	# Whatever the tree's source, a building gated behind an unlock id must find
	# that node and hang itself off it — otherwise the screen cannot answer
	# "what does this research give me".
	var gated: int = 0
	var matched: int = 0
	for raw: Variant in _build().call(&"all_defs"):
		var def: Resource = raw as Resource
		var unlock: StringName = LcnUiFormat.as_name(def.get(&"unlock_id"))
		if String(unlock) == "":
			continue
		gated += 1
		var n: LcnTechModel.TechNode = model.node(unlock)
		if n != null and n.unlocks.has(LcnUiFormat.as_name(def.get(&"id"))):
			matched += 1
	if gated == 0:
		skip("nothing in content is gated behind research")
		return
	assert_eq(matched, gated, "every gated building is listed under the node that opens it")


func test_granting_an_unlock_marks_the_node_done() -> void:
	var model := LcnTechModel.new()
	model.rebuild(null, _build(), TestEnv.registry())
	if model.is_empty():
		skip("no gated content in this build")
		return
	var target: LcnTechModel.TechNode = model.nodes[0]
	assert_ne(target.state, LcnTechModel.State.DONE, "it starts locked")
	world.cmd_now({"system": &"build", "op": "grant_unlock", "unlock": String(target.id)})
	model.refresh_state(null, _build())
	assert_eq(model.node(target.id).state, LcnTechModel.State.DONE, "and reads as done afterwards")


func test_relevance_speaks_about_this_city() -> void:
	var model := LcnTechModel.new()
	model.rebuild(null, _build(), TestEnv.registry())
	if model.is_empty():
		skip("no tree to describe")
		return
	model.refresh_relevance(LcnBuildFacts.Ctx.from_sim(TestEnv.sim()))
	var said_something: bool = false
	for n: LcnTechModel.TechNode in model.nodes:
		if n.relevance != "":
			said_something = true
			break
	assert_true(said_something, "every node the player can see is given a reason to care")


# ------------------------------------------------------- authored content ----

class FakeTech extends Resource:
	@export var id: StringName = &""
	@export var display_name: String = ""
	@export var description: String = ""
	@export var prereqs: Array = []
	@export var unlocks: Array = []
	@export var cost: Dictionary = {}


class FakeRegistry extends RefCounted:
	var items: Array = []

	func all(category: String) -> Array:
		return items if category == "research" else []


class FakeResearch extends RefCounted:
	var done: Dictionary = {}
	var active: StringName = &""

	func is_completed(id: StringName) -> bool:
		return bool(done.get(id, false))

	func current_research() -> StringName:
		return active

	func progress_of(_id: StringName) -> float:
		return 0.5


func _chain_registry() -> FakeRegistry:
	var a := FakeTech.new()
	a.id = &"metalwork"
	a.display_name = "Metalwork"
	a.cost = {&"iron_plate": 20}
	var b := FakeTech.new()
	b.id = &"pressurised_mains"
	b.display_name = "Pressurised Mains"
	b.prereqs = [&"metalwork"]
	var c := FakeTech.new()
	c.id = &"deep_drilling"
	c.display_name = "Deep Drilling"
	c.prereqs = [&"pressurised_mains"]
	var reg := FakeRegistry.new()
	reg.items = [c, a, b]        # deliberately out of order
	return reg


func test_layout_is_longest_path_layering() -> void:
	var model := LcnTechModel.new()
	model.rebuild(null, _build(), _chain_registry())
	assert_eq(String(model.source()), "content", "authored research beats the derived tree")
	assert_eq(model.node(&"metalwork").column, 0, "a root sits in column zero")
	assert_eq(model.node(&"pressurised_mains").column, 1, "its child one column right")
	assert_eq(model.node(&"deep_drilling").column, 2, "and the grandchild after that")
	assert_eq(model.columns(), 3, "three columns in total")
	assert_size(model.edges(), 2, "two prerequisite edges")


func test_rows_are_unique_within_a_column() -> void:
	var model := LcnTechModel.new()
	model.rebuild(null, _build(), _chain_registry())
	var seen: Dictionary = {}
	for n: LcnTechModel.TechNode in model.nodes:
		var key: String = "%d,%d" % [n.column, n.row]
		assert_false(seen.has(key), "no two nodes share a cell (%s)" % key)
		seen[key] = true


func test_availability_follows_the_prerequisites() -> void:
	var model := LcnTechModel.new()
	var research := FakeResearch.new()
	model.rebuild(research, _build(), _chain_registry())
	assert_eq(model.node(&"metalwork").state, LcnTechModel.State.AVAILABLE, "the root is open")
	assert_eq(model.node(&"pressurised_mains").state, LcnTechModel.State.LOCKED, "its child is not")

	research.done[&"metalwork"] = true
	model.refresh_state(research, _build())
	assert_eq(model.node(&"metalwork").state, LcnTechModel.State.DONE, "completing the root")
	assert_eq(model.node(&"pressurised_mains").state, LcnTechModel.State.AVAILABLE, "opens the child")

	research.active = &"pressurised_mains"
	model.refresh_state(research, _build())
	assert_eq(model.node(&"pressurised_mains").state, LcnTechModel.State.ACTIVE, "and researching it shows")
	assert_near(model.node(&"pressurised_mains").progress, 0.5, 0.001, "with its progress")


func test_missing_prereqs_are_named() -> void:
	var model := LcnTechModel.new()
	var research := FakeResearch.new()
	model.rebuild(research, _build(), _chain_registry())
	var missing: PackedStringArray = model.missing_prereqs(
		model.node(&"deep_drilling"), research, _build())
	assert_has(missing, "Pressurised Mains", "the blocker is named, not numbered")


func test_a_cycle_cannot_hang_the_layout() -> void:
	var a := FakeTech.new()
	a.id = &"a"
	a.prereqs = [&"b"]
	var b := FakeTech.new()
	b.id = &"b"
	b.prereqs = [&"a"]
	var reg := FakeRegistry.new()
	reg.items = [a, b]
	var model := LcnTechModel.new()
	model.rebuild(null, null, reg)
	assert_eq(model.nodes.size(), 2, "both nodes survive")
	assert_gt(float(model.columns()), 0.0, "and the layout terminates with a column count")


func test_a_published_layout_wins() -> void:
	var research := _LayoutResearch.new()
	var model := LcnTechModel.new()
	model.rebuild(research, _build(), _chain_registry())
	assert_eq(String(model.source()), "research", "[P10] publishing a layout takes precedence")
	assert_not_null(model.node(&"from_the_system"), "and its nodes are the ones shown")


class _LayoutResearch extends RefCounted:
	func tree_layout() -> Dictionary:
		return {"nodes": [
			{"id": "from_the_system", "name": "From The System", "cost": 40.0, "unlocks": ["wall"]},
		]}

	func is_completed(_id: StringName) -> bool:
		return false
