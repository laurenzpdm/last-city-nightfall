extends TestCase
## [P18] The tooltip sheet — the part of this build where the player learns the
## game. These tests assert on CONTENT, not on layout: the point of every one of
## them is "does the sheet say the thing a player needs to know here".

var world: SimFixture = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["build"])


func setup() -> void:
	world = SimFixture.new(7).start()
	LcnBuildFacts.reset_caches()


func teardown() -> void:
	world.stop()


func _ctx(cell: Vector2i = Vector2i.ZERO, has_cell: bool = false) -> LcnBuildFacts.Ctx:
	return LcnBuildFacts.Ctx.from_sim(TestEnv.sim(), cell, 0, has_cell)


func _def(kind: StringName) -> Resource:
	return world.system(&"build").call(&"def_of", kind) as Resource


func _core() -> Vector2i:
	var grid: SimSystem = world.system(&"grid")
	return grid.call(&"core_cell") if grid != null else Vector2i(128, 128)


func _sheet_text(kind: StringName, cell: Vector2i = Vector2i.ZERO, has_cell: bool = false) -> String:
	return LcnBuildFacts.to_text(LcnBuildFacts.sheet(_def(kind), _ctx(cell, has_cell)))


func _warning_keys(sheet: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for w: Variant in sheet.get("warnings", []):
		out.append(String((w as Dictionary).get("key", "")))
	return out


func _row_value(sheet: Dictionary, heading: String, label: String) -> String:
	for raw: Variant in sheet.get("sections", []):
		var section: Dictionary = raw
		if String(section.get("heading", "")) != heading:
			continue
		for raw2: Variant in section.get("rows", []):
			var row: Dictionary = raw2
			if String(row.get("label", "")) == label:
				return String(row.get("value", ""))
	return ""


# --------------------------------------------------------------- contents ----

func test_a_generator_sheet_states_its_actual_output() -> void:
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"coal_generator"), _ctx())
	assert_eq(String(sheet["title"]), "Coal Generator", "the name")
	assert_has(String(sheet["subtitle"]), "Power", "the category")
	assert_eq(_row_value(sheet, "Heat", "Produces"), "30 u/s", "the number the sim will use")
	assert_ne(_row_value(sheet, "Heat", "Burns"), "", "and what it burns to do it")
	assert_eq(_row_value(sheet, "Structure", "Footprint"), "3 x 2  (6 tiles)", "the footprint")


func test_it_reports_the_derived_shed_priority() -> void:
	if not need_system(&"heat"):
		return
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"housing_block"), _ctx())
	var priority: String = _row_value(sheet, "Heat", "Shed priority")
	assert_ne(priority, "", "a consumer shows where it sits in the load-shedding order")
	assert_true(priority.contains("shed"), "in words, not just a number: %s" % priority)


func test_conduits_show_capacity_and_loss() -> void:
	if not need_system(&"heat"):
		return
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"heat_pipe"), _ctx())
	assert_ne(_row_value(sheet, "Heat", "Carries"), "", "a pipe states its throughput")
	assert_ne(_row_value(sheet, "Heat", "Loss per tile"), "",
		"and what it costs to move heat a tile — the whole pipe upgrade decision")


func test_cost_rows_measure_against_the_actual_stock() -> void:
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"iron_plate": 0, "scrap": 0}})
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"coal_generator"), _ctx())
	var cost: Dictionary = sheet["cost"]
	assert_false(bool(cost["affordable"]), "an empty warehouse is not affordable")
	assert_has(_warning_keys(sheet), "materials", "and the sheet says so out loud")
	var text: String = LcnBuildFacts.to_text(sheet)
	assert_has(text, "Short", "with the shortfall named")


func test_it_names_items_nothing_produces() -> void:
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"iron_plate": 0, "scrap": 0}})
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"coal_generator"), _ctx())
	var materials: String = ""
	for w: Variant in sheet["warnings"]:
		if String((w as Dictionary)["key"]) == "materials":
			materials = String((w as Dictionary)["text"])
	assert_has(materials, "Nothing in the city makes",
		"a shortfall with no producer is a different problem and must read differently")


func test_build_time_is_quoted_against_real_build_power() -> void:
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"coal_generator"), _ctx())
	var cost: Dictionary = sheet["cost"]
	assert_gt(float(cost["build_seconds"]), 0.0, "a build takes time")
	assert_ne(String(cost["build_label"]), "", "and the sheet spells it")


func test_a_locked_building_says_what_opens_it() -> void:
	var locked: Resource = null
	for raw: Variant in world.system(&"build").call(&"all_defs"):
		var d: Resource = raw as Resource
		if String(d.get(&"unlock_id")) != "":
			locked = d
			break
	if locked == null:
		skip("no gated content in this build")
		return
	var sheet: Dictionary = LcnBuildFacts.sheet(locked, _ctx())
	assert_true(bool(sheet["locked"]), "the sheet knows it is locked")
	assert_has(_warning_keys(sheet), "locked", "and warns about it")


func test_unique_buildings_report_their_limit() -> void:
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"the_hearth"), _ctx())
	assert_eq(_row_value(sheet, "Structure", "Limit"), "1 in the city", "one hearth, ever")


func test_the_second_hearth_is_refused_once_and_in_english() -> void:
	var c: Vector2i = _core()
	world.cmd_now({"system": &"build", "op": "place", "kind": "the_hearth",
		"cell": [c.x - 2, c.y - 2], "free": true, "instant": true})
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"the_hearth"), _ctx(c + Vector2i(20, 0), true))
	var texts: PackedStringArray = PackedStringArray()
	var about_the_cap: int = 0
	for w: Variant in sheet["warnings"]:
		var text: String = String((w as Dictionary)["text"])
		texts.append(text)
		if text.contains("already has"):
			about_the_cap += 1
	assert_eq(about_the_cap, 1,
		"the cap is stated once — [P11]'s refusal and ours are the same fact: %s" % str(texts))
	assert_has(texts, "The city already has its Hearth.",
		"and it reads as English, not as 'its The Hearth'")


func test_it_lists_what_a_conduit_lets_you_place() -> void:
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"heat_pipe"), _ctx())
	var enables: String = _row_value(sheet, "Connections", "Lets you place")
	assert_ne(enables, "",
		"a pipe's real value is the buildings that can only exist next to one")


# --------------------------------------------------- contextual warnings -----

func test_it_warns_when_no_heat_reaches_the_tile() -> void:
	if not need_system(&"heat"):
		return
	var far: Vector2i = _core() + Vector2i(60, 60)
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"housing_block"), _ctx(far, true))
	assert_has(_warning_keys(sheet), "no_heat_here",
		"placing a heat consumer in empty snow has to be called out")


func test_it_does_not_cry_wolf_next_to_a_live_main() -> void:
	if not need_system(&"heat"):
		return
	var c: Vector2i = _core()
	world.cmd_now({"system": &"build", "op": "place", "kind": "the_hearth",
		"cell": [c.x - 2, c.y - 2], "free": true, "instant": true})
	world.cmd_now({"system": &"build", "op": "place_line", "kind": "heat_pipe",
		"from": [c.x + 3, c.y], "to": [c.x + 12, c.y], "free": true, "instant": true})
	world.run(20)
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"housing_block"), _ctx(c + Vector2i(6, 1), true))
	assert_has_not(_warning_keys(sheet), "no_heat_here",
		"a tile touching the mains is served, and the tooltip must not claim otherwise")


func test_a_drill_off_the_seam_is_told_where_the_seam_is() -> void:
	var drill: Resource = _def(&"ore_drill")
	if drill == null or String(drill.get(&"needs_ore")) == "":
		skip("no ore-gated building in this build")
		return
	var sheet: Dictionary = LcnBuildFacts.sheet(drill, _ctx(_core(), true))
	var keys: PackedStringArray = _warning_keys(sheet)
	if not keys.has("placement"):
		skip("the city core happens to sit on a deposit in this seed")
		return
	var text: String = ""
	for w: Variant in sheet["warnings"]:
		if String((w as Dictionary)["key"]) == "placement":
			text = String((w as Dictionary)["text"])
	assert_true(text.length() > 20, "the refusal is a sentence, not a code: %s" % text)


func test_burners_report_how_long_the_fuel_lasts() -> void:
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"coal": 5}})
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"coal_generator"), _ctx())
	var keys: PackedStringArray = _warning_keys(sheet)
	assert_true(keys.has("low_fuel") or keys.has("no_fuel"),
		"five coal is not a supply and the sheet has to say so")

	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"coal": 0}})
	var empty: Dictionary = LcnBuildFacts.sheet(_def(&"coal_generator"), _ctx())
	assert_has(_warning_keys(empty), "no_fuel", "no coal at all is a blocking problem")


func test_warnings_are_ordered_worst_first() -> void:
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {"iron_plate": 0, "scrap": 0, "coal": 0}})
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"coal_generator"), _ctx(_core() + Vector2i(40, 40), true))
	var warnings: Array = sheet["warnings"]
	assert_not_empty(warnings, "a broke, fuel-less, disconnected plan has problems")
	for i: int in range(1, warnings.size()):
		assert_ge(float(int((warnings[i - 1] as Dictionary)["severity"])),
			float(int((warnings[i] as Dictionary)["severity"])),
			"blocking problems come before tight ones")


func test_no_warning_is_reported_twice() -> void:
	var sheet: Dictionary = LcnBuildFacts.sheet(_def(&"coal_generator"), _ctx(_core(), true))
	var seen: Dictionary = {}
	for w: Variant in sheet["warnings"]:
		var key: String = String((w as Dictionary)["key"])
		assert_false(seen.has(key), "'%s' appears once" % key)
		seen[key] = true


# ------------------------------------------------------ the live building ----

func test_an_existing_building_reports_its_own_state() -> void:
	var c: Vector2i = _core()
	world.cmd_now({"system": &"build", "op": "place", "kind": "the_hearth",
		"cell": [c.x - 2, c.y - 2], "free": true, "instant": true})
	world.run(10)
	var build: SimSystem = world.system(&"build")
	var instance: Object = build.call(&"building_at", c)
	assert_not_null(instance, "the hearth stands where it was put")
	var sheet: Dictionary = LcnBuildFacts.instance_sheet(instance, _ctx(c, true))
	assert_eq(String(sheet["title"]), "The Hearth", "the read-out names it")
	assert_has(String(sheet["subtitle"]), "running", "and states its lifecycle")
	assert_ne(_row_value(sheet, "Status", "Condition"), "", "with its condition")


func test_a_starved_building_shows_the_bottleneck_the_solver_found() -> void:
	if not need_system(&"heat"):
		return
	var c: Vector2i = _core()
	# A radiator on a stub of pipe with no generator anywhere on it: the network
	# exists, produces nothing, and the solver has to attribute the starvation.
	world.cmd_now({"system": &"build", "op": "place_line", "kind": "heat_pipe",
		"from": [c.x + 39, c.y + 40], "to": [c.x + 44, c.y + 40], "free": true, "instant": true})
	world.cmd_now({"system": &"build", "op": "place", "kind": "warmth_radiator",
		"cell": [c.x + 40, c.y + 41], "free": true, "instant": true})
	world.run(40)
	var build: SimSystem = world.system(&"build")
	var instance: Object = build.call(&"building_at", c + Vector2i(40, 41))
	if instance == null:
		skip("the radiator could not be placed on this seed")
		return
	var sheet: Dictionary = LcnBuildFacts.instance_sheet(instance, _ctx(c + Vector2i(40, 41), true))
	var text: String = LcnBuildFacts.to_text(sheet)
	assert_has(text, "Heat served", "a heat entity reports how much it actually gets")
	var heat: SimSystem = world.system(&"heat")
	if float(heat.call(&"served_of", int(instance.get(&"id")))) < 0.99:
		assert_true(text.contains("Starved") or text.contains("Limited by") or text.contains("Frozen"),
			"and when it is short, WHY — this is the number that never reached a pixel:\n%s" % text)


func test_bottleneck_kinds_become_sentences() -> void:
	var cases: Dictionary = {
		"throughput": "pipe", "supply": "does not make enough",
		"priority": "higher priority", "distance": "too far", "disconnected": "not connected",
	}
	var keys: Array = cases.keys()
	keys.sort()
	for k: Variant in keys:
		var sentence: String = LcnBuildFacts._bottleneck_sentence({
			"kind": String(k), "cell": [12, 34], "building": "heat_pipe"})
		assert_has(sentence.to_lower(), String(cases[k]).to_lower(),
			"'%s' reads as English" % String(k))


# ------------------------------------------------------------ robustness -----

func test_a_null_definition_does_not_crash_the_tooltip() -> void:
	var sheet: Dictionary = LcnBuildFacts.sheet(null, _ctx())
	assert_eq(String(sheet["title"]), "—", "an unknown building draws a dash, not an exception")


func _sheet_every_building() -> void:
	for raw: Variant in world.system(&"build").call(&"all_defs"):
		LcnBuildFacts.sheet(raw as Resource, _ctx(_core(), true))


func test_the_sheet_is_quiet() -> void:
	assert_no_errors(_sheet_every_building,
		"building a sheet for every definition in the game logs nothing")


## The tooltip is the only part of this UI that reads the simulation on a timer,
## so its cost is a number this suite is allowed to have an opinion about.
func test_a_sheet_is_cheap_enough_to_build_on_a_timer() -> void:
	var c: Vector2i = _core()
	for cmd: Dictionary in [
		{"system": &"build", "op": "place", "kind": "the_hearth",
			"cell": [c.x - 2, c.y - 2], "free": true, "instant": true},
		{"system": &"build", "op": "place_line", "kind": "heat_pipe",
			"from": [c.x + 3, c.y], "to": [c.x + 30, c.y], "free": true, "instant": true},
	]:
		world.cmd_now(cmd)
	world.run(20)
	var def: Resource = _def(&"housing_block")
	var ctx: LcnBuildFacts.Ctx = _ctx(c + Vector2i(10, 1), true)
	var t0: int = Time.get_ticks_usec()
	var runs: int = 40
	for _i: int in runs:
		LcnBuildFacts.sheet(def, ctx)
	var per_sheet_us: float = float(Time.get_ticks_usec() - t0) / float(runs)
	assert_lt(per_sheet_us, 2000.0,
		"a tooltip sheet costs %.0f us; the UI builds at most six a second" % per_sheet_us)
