extends TestCase
## [P12] The economy audit over content [P12] does not own.
##
## Building costs and heat figures live in game/content/buildings/, written by
## [P11] and the content agents. This suite is how the balance owner holds them
## to the design without editing their files: the shipped content must sit
## inside the bands, every heat entity must be covered by at least one band, and
## — the part that matters — a deliberately broken definition must be CAUGHT.
##
## An audit nobody has ever watched fail is indistinguishable from an audit that
## checks nothing, so half of this file exists to make it fail on purpose.


func before_all() -> void:
	Balance.reload()


func after_all() -> void:
	Balance.reload()


# --- the shipped content ------------------------------------------------------

func test_no_shipped_building_is_outside_its_economic_band() -> void:
	if Registry.ids("buildings").is_empty():
		skip("game/content/buildings/ is empty")
		return
	var findings: Array[Dictionary] = Balance.audit()
	var lines: PackedStringArray = PackedStringArray()
	for f: Dictionary in findings:
		lines.append(String(f["text"]))
	assert_empty(lines, "the building economy has drifted outside the balance "
		+ "table's bands:\n      " + "\n      ".join(lines))


func test_every_building_is_covered_by_at_least_two_rules() -> void:
	# Coverage, not just cleanliness. A band that applies to nothing is a band
	# that cannot catch anything, and a green audit over an empty rule set is
	# the exact failure mode this suite is written against.
	var coverage: Dictionary[StringName, PackedStringArray] = Balance.audit_coverage()
	if coverage.is_empty():
		skip("game/content/buildings/ is empty")
		return
	for id: Variant in EconomyDefs.sorted_keys(coverage):
		var rules: PackedStringArray = coverage[id]
		assert_ge(float(rules.size()), 2.0,
			"'%s' is checked by only %d rule(s): %s" % [String(id), rules.size(),
				", ".join(rules)])


func test_every_heat_entity_is_judged_on_what_it_is_for() -> void:
	var coverage: Dictionary[StringName, PackedStringArray] = Balance.audit_coverage()
	if coverage.is_empty():
		skip("game/content/buildings/ is empty")
		return
	var economic: PackedStringArray = PackedStringArray([
		"producer_cost", "recovery_cost", "conduit_value", "buffer_value",
		"consumer_cost", "heat_per_resident"])
	for id: Variant in EconomyDefs.sorted_keys(coverage):
		var def: BuildingDef = Registry.get_item("buildings", StringName(String(id))) as BuildingDef
		if def == null:
			continue
		# The buildings whose worth is not measured in heat: walls, roads,
		# stores, watchtowers, turrets. [P07] owns the damage economy.
		if def.heat_produced <= 0.0 and def.heat_consumed < 3.0 \
				and def.conduit_throughput <= 0.0 and def.residents <= 0:
			continue
		if def.category == &"defense":
			continue
		var covered: bool = false
		for rule: String in coverage[id]:
			if economic.has(rule):
				covered = true
				break
		assert_true(covered,
			"'%s' participates in the heat economy and no economic band judges it"
				% String(id))


func test_the_research_tree_is_priced_and_gets_dearer() -> void:
	if Registry.ids("research").is_empty():
		skip("game/content/research/ has not landed yet")
		return
	var lines: PackedStringArray = PackedStringArray()
	for f: Dictionary in Balance.audit_research():
		lines.append(String(f["text"]))
	assert_empty(lines, "the tech tree is outside its affordability bands:\n      "
		+ "\n      ".join(lines))


func test_the_wave_director_asks_for_nights_the_economy_can_arm() -> void:
	var lines: PackedStringArray = PackedStringArray()
	for f: Dictionary in Balance.audit_threat():
		lines.append(String(f["text"]))
	if lines.size() == 1 and lines[0].contains("no_city_growth_model"):
		skip("no ThreatProfile and no [P08] to read a curve from")
		return
	assert_empty(lines, "the threat curve outruns the economy that has to pay "
		+ "for it:\n      " + "\n      ".join(lines))


# --- the fence has teeth ------------------------------------------------------

func test_a_free_five_by_five_is_caught() -> void:
	var def: BuildingDef = _def(&"cheat_hall", 1, Vector2i(5, 5),
		{&"stone": 2} as Dictionary[StringName, int])
	def.heat_consumed = 20.0
	def.category = &"housing"
	assert_true(_has_rule(Balance.audit_def(def), &"points_per_cell"),
		"a twenty-five tile building for two stone must break points_per_cell")


func test_a_building_that_costs_nothing_is_caught() -> void:
	var def: BuildingDef = _def(&"free_lunch", 1, Vector2i(2, 2),
		{} as Dictionary[StringName, int])
	assert_true(_has_rule(Balance.audit_def(def), &"free_building"),
		"a building with no cost at all must be reported")


func test_a_generator_with_a_misplaced_decimal_point_is_caught() -> void:
	var def: BuildingDef = _def(&"runaway_burner", 1, Vector2i(3, 2),
		{&"iron_plate": 20, &"scrap": 45} as Dictionary[StringName, int])
	def.category = &"power"
	def.heat_produced = 300.0        # one zero too many
	var findings: Array[Dictionary] = Balance.audit_def(def)
	assert_true(_has_rule(findings, &"tier_output"),
		"300 heat/second at tier 1 must break the tier band")
	assert_true(_has_rule(findings, &"landmark_output"),
		"and it must be called out for outproducing the Hearth without a landmark tag")
	assert_true(_has_rule(findings, &"producer_cost"),
		"and for being nearly free energy")


func test_an_unpriced_material_is_caught() -> void:
	var def: BuildingDef = _def(&"mystery_shed", 1, Vector2i(2, 2),
		{&"unobtanium": 4} as Dictionary[StringName, int])
	assert_true(_has_rule(Balance.audit_def(def), &"unpriced_material"),
		"a cost in an item the table has never heard of must be reported, not "
		+ "silently valued at the fallback")


func test_housing_that_is_free_to_heat_is_caught() -> void:
	var def: BuildingDef = _def(&"magic_tenement", 1, Vector2i(4, 4),
		{&"stone": 60, &"timber": 80, &"scrap": 30} as Dictionary[StringName, int])
	def.category = &"housing"
	def.residents = 40               # forty people on nine heat a second
	def.heat_consumed = 9.0
	assert_true(_has_rule(Balance.audit_def(def), &"heat_per_resident"),
		"housing forty citizens for the heat of twelve must break the band")


func test_a_pipe_that_carries_the_whole_city_for_nothing_is_caught() -> void:
	var def: BuildingDef = _def(&"wonder_pipe", 1, Vector2i(1, 1),
		{&"iron_plate": 1} as Dictionary[StringName, int])
	def.category = &"heat"
	def.is_heat_conduit = true
	def.conduit_throughput = 5000.0
	assert_true(_has_rule(Balance.audit_def(def), &"conduit_value"),
		"a four-point pipe carrying five thousand removes the layout game")


func test_a_correct_definition_is_not_caught() -> void:
	# The control. Without it, every test above would still pass if audit_def()
	# simply reported everything.
	var def: BuildingDef = Registry.get_item("buildings", &"coal_generator") as BuildingDef
	if def == null:
		skip("no coal_generator in the registry")
		return
	assert_empty(Balance.audit_def(def),
		"the shipped coal generator is inside every band it is judged by")


# --- helpers ------------------------------------------------------------------

func _def(id: StringName, tier: int, size: Vector2i,
		cost: Dictionary[StringName, int]) -> BuildingDef:
	var def := BuildingDef.new()
	def.id = id
	def.display_name = String(id)
	def.tier = tier
	def.size = size
	def.cost = cost
	def.build_time_ticks = 600
	return def


func _has_rule(findings: Array[Dictionary], rule: StringName) -> bool:
	for f: Dictionary in findings:
		if String(f["rule"]) == String(rule):
			return true
	return false
