extends TestCase
## [P10] Research & Progression, tested as BEHAVIOUR on a live world.
##
## Every case here states a rule the player can feel — "starting a project takes
## the plate out of the yard", "running out of copper stops the work and says
## so", "changing your mind does not throw away what you already spent" — and
## then measures it against the real simulation.

const STOCK: Dictionary = {
	"iron_plate": 400, "steel_plate": 300, "stone": 400, "timber": 400,
	"scrap": 400, "gear": 200, "copper_coil": 200, "coal": 300,
	"pipe_segment": 120,
}

var world: SimFixture = null
var res: SimSystem = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["research"])


func setup() -> void:
	world = SimFixture.new(7).start()
	res = world.system(&"research")
	if res == null:
		return
	# Manual control by default: an auto-picking system is the right behaviour in
	# play and the wrong one in a test that is asserting about one node.
	res.call("execute", {"op": "set_auto", "on": false})
	_fill_yard()


func teardown() -> void:
	if world != null:
		world.stop()


# --- helpers -----------------------------------------------------------------

func _fill_yard() -> void:
	var build: SimSystem = world.system(&"build")
	if build == null:
		return
	build.call("execute", {"op": &"set_stock", "items": STOCK})


func _stock(item: StringName) -> int:
	var build: SimSystem = world.system(&"build")
	if build == null:
		return 0
	return int((build.get("stock") as Object).call("count", item))


func _exec(cmd: Dictionary) -> Dictionary:
	return res.call("execute", cmd)


func _node(id: StringName) -> ResearchNode:
	return (res.call("graph") as ResearchGraph).node(id)


## Runs until `id` is finished or the budget runs out. Returns ticks spent.
func _research_until_done(id: StringName, budget: int = 4000) -> int:
	for t: int in budget:
		world.run(1)
		if bool(res.call("is_researched", id)):
			return t + 1
	return -1


# --- gating ------------------------------------------------------------------

func test_nothing_is_unlocked_before_it_is_researched() -> void:
	assert_false(bool(res.call("is_unlocked", &"pipe_lagging")), "pipe lagging starts locked")
	assert_false(bool(res.call("is_unlocked", &"geothermal_tapping")), "geothermal starts locked")
	assert_true(bool(res.call("is_unlocked", &"")), "an empty gate is always open")


func test_completing_a_node_opens_its_gates() -> void:
	var got: Dictionary = world.count_bus_signals(
		PackedStringArray(["research_completed", "unlocked"]),
		func() -> void: _exec({"op": "complete", "id": "pipe_lagging"}))
	assert_true(bool(res.call("is_unlocked", &"pipe_lagging")), "the gate opened")
	assert_true(bool(res.call("is_unlocked", &"draught_sealing")),
		"completing a node completes the path to it")
	assert_ge(float(got["research_completed"]), 2.0, "one completion signal per node finished")
	assert_ge(float(got["unlocked"]), 2.0, "one unlock signal per gate opened")


func test_build_asks_research_whether_a_building_is_unlocked() -> void:
	var build: SimSystem = world.system(&"build")
	if build == null:
		skip("no build system in this build")
		return
	var gated: BuildingDef = null
	for d: BuildingDef in build.call("all_defs"):
		if String(d.unlock_id) != "" and _node(d.unlock_id) != null:
			gated = d
			break
	if gated == null:
		skip("no building is gated on a research node yet")
		return
	assert_false(bool(build.call("is_unlocked", gated.unlock_id)),
		"'%s' must be locked before its research" % String(gated.id))
	assert_has_not(_def_ids(build.call("available_defs")), String(gated.id),
		"a locked building is not offered in the build menu")
	_exec({"op": "complete", "id": String(gated.unlock_id)})
	assert_true(bool(build.call("is_unlocked", gated.unlock_id)),
		"[P11] resolves the gate through [P10]")
	assert_has(_def_ids(build.call("available_defs")), String(gated.id),
		"the building appears in the menu the moment the research lands")


func _def_ids(defs: Array) -> Array:
	var out: Array = []
	for d: Variant in defs:
		out.append(String((d as BuildingDef).id))
	return out


func test_laws_and_recipes_are_handed_on_by_prefix() -> void:
	_exec({"op": "complete", "id": "child_apprenticeships"})
	assert_has(res.call("unlocked_laws"), &"law_child_labour",
		"[P06] reads the dark branch through unlocked_laws()")
	assert_has(res.call("unlocked_laws"), &"law_extended_shift",
		"the prerequisite law came with it")
	_exec({"op": "complete", "id": "bloomery_smelting"})
	assert_has(res.call("unlocked_recipes"), &"recipe_iron_plate",
		"[P04] reads the same set for recipes")


# --- cost --------------------------------------------------------------------

func test_starting_a_project_takes_materials_out_of_the_yard() -> void:
	var n: ResearchNode = _node(&"draught_sealing")
	var before_timber: int = _stock(&"timber")
	var before_scrap: int = _stock(&"scrap")
	_exec({"op": "start", "id": "draught_sealing"})
	world.run(1)
	var spent_timber: int = before_timber - _stock(&"timber")
	var spent_scrap: int = before_scrap - _stock(&"scrap")
	assert_gt(float(spent_timber), 0.0, "the first instalment is due immediately")
	assert_eq(spent_timber, int(ceil(float(n.cost[&"timber"]) * 0.25)),
		"exactly a quarter of the timber, rounded up")
	assert_eq(spent_scrap, int(ceil(float(n.cost[&"scrap"]) * 0.25)),
		"exactly a quarter of the scrap")


func test_the_full_cost_is_paid_by_completion_and_not_a_plate_more() -> void:
	var n: ResearchNode = _node(&"scrap_sorting")
	var before: Dictionary[StringName, int] = {}
	for k: Variant in n.cost.keys():
		before[StringName(String(k))] = _stock(StringName(String(k)))
	_exec({"op": "start", "id": "scrap_sorting"})
	var spent_ticks: int = _research_until_done(&"scrap_sorting")
	assert_gt(float(spent_ticks), 0.0, "the project finished inside the budget")
	for k2: StringName in before.keys():
		assert_eq(before[k2] - _stock(k2), int(n.cost[k2]),
			"'%s' paid exactly its listed cost" % String(k2))
	assert_empty(res.call("remaining_cost", &"scrap_sorting"), "nothing is still owed")


func test_a_project_stalls_when_the_yard_is_empty_and_says_what_it_needs() -> void:
	var build: SimSystem = world.system(&"build")
	build.call("execute", {"op": &"set_stock", "items": {"timber": 0, "scrap": 0}})
	_exec({"op": "start", "id": "draught_sealing"})
	world.run(60)
	assert_near(float(res.call("progress_of", &"draught_sealing")), 0.0, 0.0001,
		"work cannot pass an instalment it cannot pay for")
	assert_eq(int(world.metrics()["research.stalled"]), 1, "the stall is in the metrics")
	var state: Dictionary = res.call("serialize")
	var records: Array = state["records"]
	assert_not_empty(records, "the stalled project has a record")
	assert_not_empty((records[0] as Dictionary)["missing"],
		"the record names the shortfall, so the HUD can too")


func test_work_resumes_the_moment_the_materials_arrive() -> void:
	var build: SimSystem = world.system(&"build")
	build.call("execute", {"op": &"set_stock", "items": {"timber": 0, "scrap": 0}})
	_exec({"op": "start", "id": "draught_sealing"})
	world.run(40)
	assert_near(float(res.call("progress_of", &"draught_sealing")), 0.0, 0.0001, "stalled")
	build.call("execute", {"op": &"add_stock", "items": {"timber": 100, "scrap": 100}})
	world.run(40)
	assert_gt(float(res.call("progress_of", &"draught_sealing")), 0.0,
		"the same project picks up where it stopped")


func test_cancelling_refunds_half_of_what_was_spent() -> void:
	var n: ResearchNode = _node(&"scrap_sorting")
	_exec({"op": "start", "id": "scrap_sorting"})
	world.run(1)
	var after_pay: int = _stock(&"stone")
	var paid: int = int(ceil(float(n.cost[&"stone"]) * 0.25))
	_exec({"op": "cancel", "id": "scrap_sorting"})
	assert_eq(_stock(&"stone") - after_pay, int(floor(float(paid) * 0.5)),
		"half of what the project consumed comes back")
	assert_near(float(res.call("progress_of", &"scrap_sorting")), 0.0, 0.0001,
		"an abandoned project keeps nothing")


# --- progress and changing your mind ----------------------------------------

func test_progress_survives_being_set_aside() -> void:
	_exec({"op": "start", "id": "scrap_sorting"})
	world.run(200)
	var mid: float = float(res.call("progress_of", &"scrap_sorting"))
	assert_gt(mid, 0.05, "the first project made real progress")
	_exec({"op": "start", "id": "hand_carts"})
	assert_eq(String(res.call("active")), "hand_carts", "the new order took over")
	world.run(100)
	assert_near(float(res.call("progress_of", &"scrap_sorting")), mid, 0.0001,
		"the parked project kept every point it had earned")
	_exec({"op": "start", "id": "scrap_sorting"})
	world.run(20)
	assert_gt(float(res.call("progress_of", &"scrap_sorting")), mid,
		"and carries on from there rather than starting again")


func test_progress_is_a_fraction_and_reaches_exactly_one() -> void:
	assert_near(float(res.call("progress_of", &"scrap_sorting")), 0.0, 0.0001, "untouched")
	assert_near(float(res.call("progress_of", &"not_a_node")), 0.0, 0.0001, "unknown node")
	_exec({"op": "start", "id": "scrap_sorting"})
	world.run(60)
	assert_between(float(res.call("progress_of", &"scrap_sorting")), 0.01, 0.99, "part way")
	_research_until_done(&"scrap_sorting")
	assert_near(float(res.call("progress_of", &"scrap_sorting")), 1.0, 0.0001, "finished")


# --- the queue ---------------------------------------------------------------

func test_the_queue_walks_the_path_to_a_deep_goal() -> void:
	_exec({"op": "queue", "id": "pressurised_mains"})
	world.run(2)
	assert_eq(String(res.call("active")), "draught_sealing",
		"queuing a goal starts the cheapest missing prerequisite, not the goal")
	_exec({"op": "complete", "id": "pipe_lagging"})
	world.run(2)
	assert_eq(String(res.call("active")), "pressurised_mains",
		"once the path is walked, the goal itself begins")


func test_refusals_explain_themselves() -> void:
	var locked: Dictionary = _exec({"op": "start", "id": "heat_lance"})
	assert_false(bool(locked["ok"]), "a locked node cannot be started")
	assert_eq(String(locked["code"]), "prereqs_missing", "and says why")
	assert_true(String(locked["reason"]).contains("needs"), "in words a player can read")
	var unknown: Dictionary = _exec({"op": "start", "id": "nonsense"})
	assert_eq(String(unknown["code"]), "unknown_node", "an unknown id is refused cleanly")
	var bad: Dictionary = _exec({"op": "explode"})
	assert_eq(String(bad["code"]), "bad_command", "so is an unknown verb")


func test_a_refused_command_never_turns_a_run_red() -> void:
	assert_no_errors(func() -> void:
		world.cmd_now({"system": &"research", "op": "start", "id": "heat_lance"})
		world.cmd_now({"system": &"research", "op": "nonsense"}),
		"research refuses through warnings, never through Log.error")


# --- effects -----------------------------------------------------------------

func test_effects_stack_additively_not_exponentially() -> void:
	assert_near(float(res.call("multiplier", ResearchDefs.E_HEAT_LOSS_MULT)), 1.0, 0.0001,
		"an unresearched world changes nothing")
	_exec({"op": "complete", "id": "pipe_lagging"})
	assert_near(float(res.call("multiplier", ResearchDefs.E_HEAT_LOSS_MULT)), 0.75, 0.0001,
		"lagging takes a quarter off transmission loss")
	_exec({"op": "complete", "id": "heat_recovery"})
	assert_near(float(res.call("multiplier", ResearchDefs.E_HEAT_LOSS_MULT)), 0.55, 0.0001,
		"recovery adds another fifth: 1 - 0.25 - 0.20, not a product")
	assert_near(float(res.call("modifier", ResearchDefs.E_HEAT_LOSS_MULT)), -0.45, 0.0001,
		"the raw sum is available too")


func test_an_unknown_effect_key_is_simply_neutral() -> void:
	assert_near(float(res.call("multiplier", &"nothing.at_all")), 1.0, 0.0001, "neutral")
	assert_near(float(res.call("modifier", &"nothing.at_all")), 0.0, 0.0001, "and zero")


# --- pacing ------------------------------------------------------------------

func test_the_recommendation_answers_the_loudest_problem() -> void:
	var pacing := ResearchPacing.new()
	var cold: ResearchNode = _node(&"insulated_clothing")
	var armour: ResearchNode = _node(&"armour_piercing")
	pacing.signals[ResearchDefs.SIG_COLD] = 0.9
	pacing.signals[ResearchDefs.SIG_ARMOURED] = 0.0
	assert_gt(pacing.score(cold, true, 2), pacing.score(armour, true, 2),
		"when the city is freezing, coats outrank ammunition")
	pacing.signals[ResearchDefs.SIG_COLD] = 0.0
	pacing.signals[ResearchDefs.SIG_ARMOURED] = 0.9
	assert_gt(pacing.score(armour, true, 2), pacing.score(cold, true, 2),
		"when the armour arrives, ammunition outranks coats")


func test_the_pacing_sample_reads_the_real_world() -> void:
	world.run(120)
	var snap: Dictionary = res.call("pacing_snapshot")
	assert_gt(float(int(snap["tick"])), 0.0, "the engine sampled during the run")
	assert_not_empty(snap["signals"], "it measured something")
	assert_true((snap["sources"] as Dictionary).values().has("measured"),
		"at least one signal comes from a live system rather than a proxy")


func test_the_engineers_pick_something_when_left_alone() -> void:
	res.call("execute", {"op": "set_auto", "on": true})
	world.run(3)
	assert_ne(String(res.call("active")), "", "an idle city always has a project")
	var suggestion: Dictionary = res.call("suggestion")
	assert_not_empty(suggestion, "and can say what it would pick next")
	assert_true(String(suggestion["reason"]).length() > 10,
		"with a sentence a player can read: '%s'" % String(suggestion.get("reason", "")))


func test_an_unaffordable_project_is_not_what_the_engineers_open() -> void:
	var build: SimSystem = world.system(&"build")
	# Only the cheapest branch is payable. The auto-picker must find it.
	build.call("execute", {"op": &"set_stock", "items": {
		"iron_plate": 0, "steel_plate": 0, "copper_coil": 0, "gear": 0, "coal": 0,
		"stone": 400, "timber": 400, "scrap": 400,
	}})
	res.call("execute", {"op": "set_auto", "on": true})
	world.run(3)
	var active: StringName = StringName(String(res.call("active")))
	assert_ne(String(active), "", "something was started")
	var n: ResearchNode = _node(active)
	for k: Variant in n.cost.keys():
		assert_has(["stone", "timber", "scrap"], String(k),
			"the engineers opened '%s', which needs %s they do not have"
			% [String(active), String(k)])


# --- tree_layout, the contract with [P18] ------------------------------------

func test_tree_layout_is_drawable_without_re_deriving_the_graph() -> void:
	var layout: Dictionary = res.call("tree_layout")
	assert_gt(float(int(layout["columns"])), 3.0, "the tree has real width")
	assert_gt(float(int(layout["rows"])), 5.0, "and real height")
	assert_ge(float((layout["nodes"] as Array).size()), 40.0, "every node is in it")
	assert_not_empty(layout["edges"], "with the edges to draw between them")
	assert_eq((layout["branches"] as Array).size(), ResearchDefs.BRANCH_ORDER.size(),
		"one band per branch")

	var first: Dictionary = (layout["nodes"] as Array)[0]
	for key: String in ["id", "title", "description", "branch", "tier", "column", "row",
			"state", "progress", "cost", "prereqs", "unlocks", "effects", "eta_seconds",
			"affordable", "remaining_cost", "answers", "urgency"]:
		assert_has(first, key, "a node row must carry '%s'" % key)

	var branch: Dictionary = (layout["branches"] as Array)[0]
	for key2: String in ["key", "title", "summary", "color", "row_start", "row_end",
			"total", "done", "available"]:
		assert_has(branch, key2, "a branch row must carry '%s'" % key2)


func test_layout_state_tracks_the_simulation() -> void:
	_exec({"op": "complete", "id": "scrap_sorting"})
	_exec({"op": "start", "id": "hand_carts"})
	_exec({"op": "queue", "id": "belt_drives"})
	world.run(5)
	var states: Dictionary = {}
	for row: Variant in (res.call("tree_layout") as Dictionary)["nodes"]:
		states[String((row as Dictionary)["id"])] = String((row as Dictionary)["state"])
	assert_eq(states["scrap_sorting"], "done", "a finished node reads as done")
	assert_eq(states["hand_carts"], "active", "the active one reads as active")
	assert_eq(states["belt_drives"], "queued", "a queued one reads as queued")
	assert_eq(states["heat_lance"], "locked", "an unreachable one reads as locked")


# --- state -------------------------------------------------------------------

func test_metrics_carry_the_four_numbers_the_brief_asks_for() -> void:
	_exec({"op": "start", "id": "scrap_sorting"})
	world.run(30)
	var m: Dictionary = world.metrics()
	for key: String in ["research.researched_count", "research.active",
			"research.progress", "research.unlocks_pending"]:
		assert_has(m, key, "metrics must expose '%s'" % key)
	assert_eq(String(m["research.active"]), "scrap_sorting", "the active project is named")
	assert_gt(float(m["research.unlocks_pending"]), 0.0, "there is always something to choose")


func test_state_round_trips_through_save_and_load() -> void:
	_exec({"op": "complete", "id": "pipe_lagging"})
	_exec({"op": "start", "id": "combustion_tuning"})
	_exec({"op": "queue", "id": "radiant_focusing"})
	world.run(120)
	var saved: Dictionary = res.call("serialize")

	var fresh: SimFixture = SimFixture.new(11).start()
	var other: SimSystem = fresh.system(&"research")
	other.call("deserialize", saved)
	var reloaded: Dictionary = other.call("serialize")
	for key: String in ["researched", "active", "queue", "unlocked", "effects", "records"]:
		assert_eq(reloaded[key], saved[key], "'%s' survived the round trip" % key)
	assert_near(float(other.call("progress_of", &"combustion_tuning")),
		float(res.call("progress_of", &"combustion_tuning")), 0.001, "and so did the progress")
	fresh.stop()


func test_serialize_explains_itself_to_a_critic() -> void:
	world.run(120)
	var s: Dictionary = res.call("serialize")
	for key: String in ["researched", "researched_count", "active", "progress", "queue",
			"available", "suggestion", "pacing", "board", "effects", "laws", "recipes",
			"rate", "rate_reason", "ledger"]:
		assert_has(s, key, "state.json must carry '%s'" % key)
	assert_eq(String(s["ledger"]), "build",
		"research draws from the same yard construction does")


func test_the_same_seed_produces_the_same_research() -> void:
	var script: Dictionary = {
		5: [{"system": &"research", "op": "queue", "id": "belt_drives"}],
		30: [{"system": &"research", "op": "start", "id": "insulated_clothing"}],
		60: [{"system": &"research", "op": "set_auto", "on": true}],
	}
	var diff: PackedStringArray = SimFixture.replay_diff(9, 400, script)
	assert_empty(diff, "two identical runs diverged:\n      " + "\n      ".join(diff))
