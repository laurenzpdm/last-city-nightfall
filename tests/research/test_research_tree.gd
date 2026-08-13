extends TestCase
## [P10] The tech tree as CONTENT: the graph is a real DAG, every node is
## reachable, every node states the beat it is meant to arrive at, and every
## unlock another part already gates on actually exists in the tree.
##
## These tests need no world. They read game/content/research/ through Registry
## and build the graph directly, which makes them fast enough to run on every
## edit to a .tres.

const CATEGORY: String = "research"
## The brief's floor. Below this the tree is not a tree.
const MIN_NODES: int = 40

var nodes: Array[ResearchNode] = []
var graph: ResearchGraph = null


func before_all() -> void:
	for res: Resource in Registry.all(CATEGORY):
		var n := res as ResearchNode
		if n != null:
			nodes.append(n)
	graph = ResearchGraph.new()
	graph.build(nodes)


func requires_files() -> PackedStringArray:
	return PackedStringArray(["res://game/sim/research/research_system.gd"])


# --- shape -------------------------------------------------------------------

func test_the_tree_is_big_enough_to_be_a_campaign() -> void:
	assert_ge(nodes.size(), MIN_NODES,
		"the tree must carry at least %d real nodes" % MIN_NODES)
	assert_eq(graph.size(), nodes.size(), "every content node reached the graph")


func test_content_loads_without_problems() -> void:
	assert_empty(graph.problems,
		"ResearchGraph.build reported content problems:\n      "
		+ "\n      ".join(graph.problems))


func test_every_node_validates() -> void:
	for n: ResearchNode in nodes:
		var issues: PackedStringArray = n.validate()
		assert_empty(issues, "'%s': %s" % [String(n.id), ", ".join(issues)])


func test_ids_match_their_filenames() -> void:
	for n: ResearchNode in nodes:
		var file: String = n.resource_path.get_file().get_basename()
		assert_eq(file, String(n.id),
			"a .tres must be named after its id so Registry and the tree agree")


func test_every_branch_is_populated() -> void:
	for branch: StringName in ResearchDefs.BRANCH_ORDER:
		var members: Array[StringName] = graph.branch_ids(branch)
		assert_ge(members.size(), 5.0,
			"branch '%s' has only %d node(s); a lane needs a shape"
			% [String(branch), members.size()])


func test_the_desperate_branch_exists_and_costs_something() -> void:
	var laws: Array[String] = []
	var hope_penalties: int = 0
	for id: StringName in graph.branch_ids(ResearchDefs.BRANCH_DESPERATE):
		var n: ResearchNode = graph.node(id)
		for law: StringName in n.law_ids():
			laws.append(String(law))
		if float(n.effects.get(ResearchDefs.E_HOPE_MULT, 0.0)) < 0.0 \
				or float(n.effects.get(ResearchDefs.E_DISCONTENT_MULT, 0.0)) > 0.0:
			hope_penalties += 1
	assert_ge(laws.size(), 5.0, "the dark branch must actually hand [P06] laws: %s" % str(laws))
	assert_ge(hope_penalties, 4.0,
		"a desperate measure that costs the player nothing is not a desperate measure")


func test_there_are_four_tiers() -> void:
	var by_tier: Dictionary[int, int] = {}
	for n: ResearchNode in nodes:
		by_tier[n.tier] = int(by_tier.get(n.tier, 0)) + 1
	for t: int in [1, 2, 3, 4]:
		assert_gt(float(by_tier.get(t, 0)), 0.0, "no tier-%d nodes at all" % t)


# --- graph correctness -------------------------------------------------------

func test_the_graph_is_acyclic() -> void:
	assert_true(graph.is_acyclic(), "the prerequisite graph contains a cycle")


func test_every_node_is_reachable() -> void:
	assert_empty(graph.unreachable(),
		"nodes no player can ever research: %s" % str(graph.unreachable()))
	assert_eq(graph.order.size(), graph.size(), "the topological order covers the tree")


func test_every_prerequisite_exists() -> void:
	for n: ResearchNode in nodes:
		for p: StringName in n.prereqs:
			assert_true(graph.has(p),
				"'%s' requires '%s', which is not a node" % [String(n.id), String(p)])


func test_prerequisites_come_first_in_the_topological_order() -> void:
	var seen: Dictionary[StringName, bool] = {}
	for id: StringName in graph.order:
		for p: StringName in graph.prereqs[id]:
			assert_true(seen.has(p),
				"'%s' is ordered before its prerequisite '%s'" % [String(id), String(p)])
		seen[id] = true


func test_every_branch_has_a_root() -> void:
	var roots: Array[StringName] = graph.roots()
	assert_ge(roots.size(), 5.0, "a campaign needs several honest opening moves")
	for r: StringName in roots:
		assert_eq(graph.depth[r], 0, "a root sits in column zero")


func test_the_tree_is_a_graph_not_six_ladders() -> void:
	var cross: int = 0
	for e: Dictionary in graph.edges():
		if bool(e.get("cross_branch", false)):
			cross += 1
	assert_ge(cross, 4.0,
		"only %d cross-branch prerequisite(s): the branches never talk to each other" % cross)


func test_depth_is_the_longest_path() -> void:
	for id: StringName in graph.ids:
		var want: int = 0
		for p: StringName in graph.prereqs[id]:
			want = maxi(want, int(graph.depth[p]) + 1)
		assert_eq(graph.depth[id], want, "depth of '%s'" % String(id))


func test_ancestors_and_descendants_agree() -> void:
	for id: StringName in graph.ids:
		for anc: StringName in graph.ancestors(id):
			assert_has(graph.descendants(anc), id,
				"'%s' is an ancestor of '%s' but not the reverse" % [String(anc), String(id)])


# --- layout, the thing [P18] draws ------------------------------------------

func test_every_node_has_a_position() -> void:
	assert_gt(float(graph.columns), 0.0, "the layout has no columns")
	assert_gt(float(graph.rows), 0.0, "the layout has no rows")
	for id: StringName in graph.ids:
		assert_true(graph.placement.has(id), "'%s' was never placed" % String(id))
		var p: Vector2i = graph.placement[id]
		assert_eq(p.x, int(graph.depth[id]), "'%s' sits in its depth column" % String(id))
		assert_between(float(p.y), 0.0, float(graph.rows - 1), "row of '%s'" % String(id))


func test_no_two_nodes_overlap() -> void:
	var taken: Dictionary[Vector2i, StringName] = {}
	for id: StringName in graph.ids:
		var p: Vector2i = graph.placement[id]
		assert_false(taken.has(p),
			"'%s' and '%s' both want cell %s" % [String(id), String(taken.get(p, &"")), str(p)])
		taken[p] = id


func test_branch_bands_do_not_interleave() -> void:
	for id: StringName in graph.ids:
		var branch: StringName = graph.node(id).branch
		var band: Vector2i = graph.bands[branch]
		var row: int = graph.placement[id].y
		assert_between(float(row), float(band.x), float(band.y),
			"'%s' is drawn outside its own lane" % String(id))


func test_the_layout_is_deterministic() -> void:
	var produce: Callable = func() -> Variant:
		var g := ResearchGraph.new()
		g.build(nodes)
		var out: Dictionary = {}
		for id: StringName in g.ids:
			out[String(id)] = [g.placement[id].x, g.placement[id].y, g.depth[id]]
		return out
	assert_deterministic(produce, "two builds of the same content lay out identically")


# --- pacing discipline -------------------------------------------------------

func test_every_node_states_the_beat_it_arrives_at() -> void:
	for n: ResearchNode in nodes:
		assert_gt(float(n.description.strip_edges().length()), 80.0,
			"'%s' has no real beat written on it" % String(n.id))
		assert_true(n.description.contains("BEAT"),
			"'%s' description must name the moment it is meant to land" % String(n.id))


func test_almost_every_node_answers_a_measured_problem() -> void:
	var answering: int = 0
	for n: ResearchNode in nodes:
		if String(n.answers) == "":
			continue
		answering += 1
		assert_true(ResearchDefs.is_signal(n.answers),
			"'%s' answers unknown signal '%s'" % [String(n.id), String(n.answers)])
		assert_gt(float(n.urgency_line.strip_edges().length()), 20.0,
			"'%s' answers a signal but never says why now" % String(n.id))
	assert_ge(float(answering) / float(nodes.size()), 0.95,
		"only %d of %d nodes answer a measured problem" % [answering, nodes.size()])


func test_the_signals_nodes_answer_are_actually_measured() -> void:
	var used: Dictionary[StringName, bool] = {}
	for n: ResearchNode in nodes:
		if String(n.answers) != "":
			used[n.answers] = true
		if String(n.also_answers) != "":
			used[n.also_answers] = true
	assert_ge(used.size(), 15.0,
		"the tree only answers %d distinct problems; the pacing engine measures %d"
		% [used.size(), ResearchDefs.SIGNAL_KEYS.size()])
	var pacing := ResearchPacing.new()
	pacing.sample(0)
	for k: StringName in used.keys():
		assert_true(ResearchDefs.is_signal(k), "'%s' is not a measurable signal" % String(k))


func test_effect_keys_are_all_in_the_contract() -> void:
	for n: ResearchNode in nodes:
		for k: Variant in n.effects.keys():
			assert_true(ResearchDefs.is_effect_key(StringName(String(k))),
				"'%s' sets unknown effect key '%s'" % [String(n.id), String(k)])


func test_costs_use_items_the_game_can_actually_make() -> void:
	# Every material a node asks for must be one some building already costs, or
	# a research cost is a permanent stall dressed up as a tech tree.
	var known: Dictionary[StringName, bool] = {}
	for res: Resource in Registry.all("buildings"):
		var d := res as BuildingDef
		if d == null:
			continue
		for k: Variant in d.cost.keys():
			known[StringName(String(k))] = true
	if known.is_empty():
		skip("no building content to cross-check costs against")
		return
	known[&"coal"] = true  ## fuel, consumed by burners rather than by construction
	for n: ResearchNode in nodes:
		for k2: Variant in n.cost.keys():
			assert_true(known.has(StringName(String(k2))),
				"'%s' costs '%s', which nothing in the game produces"
				% [String(n.id), String(k2)])


# --- the join with [P11] -----------------------------------------------------

## THE INTEGRATION TEST THAT MATTERS. Any part may gate its content behind a
## research id — buildings, recipes, belts, weapons. If this tree never opens
## that id, the content is unreachable for the whole campaign and nothing else
## in the build will say so: it simply never appears in a menu.
##
## A failure here is not a research bug in isolation. The fix is one line in
## tests/research/author_research.gd: add the id to the `grants` of whichever
## node should hand it over, and re-run the authoring tool.
func test_every_content_gate_in_the_game_exists_in_the_tree() -> void:
	var opened: Dictionary[StringName, bool] = {}
	for n: ResearchNode in nodes:
		for u: StringName in n.unlock_ids():
			opened[u] = true

	var checked: int = 0
	var orphans: Array[String] = []
	for category: String in Registry.categories():
		if category == CATEGORY:
			continue
		for res: Resource in Registry.all(category):
			if res == null or not ("unlock_id" in res):
				continue
			var gate: StringName = StringName(String(res.get("unlock_id")))
			if String(gate) == "":
				continue
			checked += 1
			if not opened.has(gate):
				orphans.append("%s/%s needs '%s'" % [
					category, res.resource_path.get_file().get_basename(), String(gate)])
	if checked == 0:
		skip("nothing in the registry is gated on research yet")
		return
	assert_empty(orphans,
		"content gated on a research id no node opens — it can never be built:\n      "
		+ "\n      ".join(orphans))


func test_the_early_gates_are_early() -> void:
	# A building gated behind a tier-3 node on day one is a building the player
	# will never see. Anything [P11] gates today must sit shallow in the tree.
	for res: Resource in Registry.all("buildings"):
		var d := res as BuildingDef
		if d == null or String(d.unlock_id) == "":
			continue
		if not graph.has(d.unlock_id):
			continue
		if d.tier > 2:
			continue
		assert_le(float(graph.depth[d.unlock_id]), 3.0,
			"tier-%d building '%s' is %d prerequisites deep"
			% [d.tier, String(d.id), int(graph.depth[d.unlock_id])])
