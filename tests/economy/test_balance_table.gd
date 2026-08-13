extends TestCase
## [P12] The balance table itself: does it load, is it internally consistent,
## and do the curves other parts will read off it behave.
##
## A tuning table that silently falls back to its script defaults is the most
## expensive kind of bug in a data-driven game, because every number a designer
## edits appears to do nothing. The first test here exists to make that
## impossible to ship.


func before_all() -> void:
	Balance.reload()


func after_all() -> void:
	Balance.reload()


# --- it is real content, not a silent fallback -------------------------------

func test_the_shipped_table_comes_from_content_not_from_the_script() -> void:
	assert_true(Registry.has("economy", &"long_winter"),
		"game/content/economy/balance_table.tres must be in the registry — "
		+ "without it every tuning edit is a no-op and nobody notices")
	var t: BalanceTable = Balance.table()
	assert_not_null(t)
	assert_eq(String(t.id), "long_winter", "the highest-priority table won")


func test_the_table_needs_no_repair() -> void:
	# validate() returns false when it had to fix something. A shipped table
	# that needs fixing is a shipped table nobody read.
	var fresh: BalanceTable = Registry.get_item("economy", &"long_winter") as BalanceTable
	assert_not_null(fresh)
	assert_true(fresh.validate(), "the shipped balance table validates untouched")


func test_the_table_is_cached_and_reload_actually_reloads() -> void:
	var a: BalanceTable = Balance.table()
	assert_true(a == Balance.table(), "table() is cached, not re-resolved per call")
	Balance.reload()
	assert_not_null(Balance.table(), "reload() leaves a working table behind")


# --- materials ----------------------------------------------------------------

func test_every_material_a_building_is_bought_with_has_a_price() -> void:
	var t: BalanceTable = Balance.table()
	var missing: PackedStringArray = PackedStringArray()
	for id: StringName in Registry.ids("buildings"):
		var def: BuildingDef = Registry.get_item("buildings", id) as BuildingDef
		if def == null:
			continue
		for item: Variant in EconomyDefs.sorted_keys(def.cost):
			var key: String = String(item)
			if not t.prices(StringName(key)) and not missing.has(key):
				missing.append(key)
	assert_empty(missing,
		"material_value prices nothing it has not been told about, so an unpriced "
		+ "item makes every cost band downstream a guess: " + ", ".join(missing))


func test_raw_materials_are_cheaper_than_what_is_made_from_them() -> void:
	var t: BalanceTable = Balance.table()
	assert_lt(t.value_of(&"iron_plate"), t.value_of(&"steel_plate"),
		"steel is smelted from iron and must cost more")
	assert_lt(t.value_of(&"stone"), t.value_of(&"iron_plate"),
		"a quarried stone is cheaper than a smelted plate")
	assert_lt(t.value_of(&"gear"), t.value_of(&"circuit"),
		"a circuit sits further up the chain than a gear")
	assert_gt(t.unknown_material_value, t.value_of(&"stone"),
		"an unpriced item must not be cheaper than the cheapest real one, or "
		+ "the audit rewards forgetting to price things")


func test_points_of_sums_a_bag_of_items() -> void:
	var t: BalanceTable = Balance.table()
	var bag: Dictionary[StringName, int] = {&"stone": 10, &"iron_plate": 5}
	assert_near(Balance.points_of(bag),
		t.value_of(&"stone") * 10.0 + t.value_of(&"iron_plate") * 5.0, 0.001)
	assert_near(Balance.points_of({} as Dictionary), 0.0, 0.001, "an empty bag is free")


# --- the opening position -----------------------------------------------------

func test_the_starting_stock_buys_the_opening_but_not_the_whole_first_day() -> void:
	var stock: Dictionary[StringName, int] = Balance.starting_stock()
	assert_not_empty(stock, "a new campaign starts with something")
	var opening: float = 0.0
	for kind: StringName in [&"warmth_radiator", &"warmth_radiator",
			&"housing_block", &"housing_block", &"coal_generator"]:
		var def: BuildingDef = Registry.get_item("buildings", kind) as BuildingDef
		if def != null:
			opening += Balance.points_of(def.cost)
	if opening <= 0.0:
		skip("game/content/buildings/ has no opening set to price")
		return
	var purse: float = Balance.points_of(stock)
	assert_gt(purse, opening,
		"the starting stock has to cover two radiators, two blocks and a "
		+ "generator or the first night is unwinnable before it begins")
	assert_lt(purse, opening * 4.0,
		"and it must NOT cover four times that, or the first decision of the "
		+ "game is not a decision")


func test_cost_of_applies_the_global_cost_knob() -> void:
	var def: BuildingDef = Registry.get_item("buildings", &"coal_generator") as BuildingDef
	if def == null:
		skip("no coal_generator in the registry")
		return
	var priced: Dictionary[StringName, int] = Balance.cost_of(def)
	assert_eq(priced.size(), def.cost.size(), "every cost line survives pricing")
	for k: Variant in EconomyDefs.sorted_keys(def.cost):
		assert_ge(float(priced[k]), 1.0, "no cost line rounds away to nothing")


# --- extraction ---------------------------------------------------------------

func test_a_richer_seam_yields_more_but_within_bounds() -> void:
	var t: BalanceTable = Balance.table()
	var poor: float = Balance.extraction_rate(&"iron", 10.0)
	var average: float = Balance.extraction_rate(&"iron", t.deposit_reference_amount)
	var rich: float = Balance.extraction_rate(&"iron", 20000.0)
	assert_lt(poor, average, "a thin seam pays less")
	assert_lt(average, rich, "a fat seam pays more")
	assert_near(average, float(t.deposit_yield[&"iron"]), 0.001,
		"the reference amount is exactly the 1.0 multiplier")
	assert_le(rich, float(t.deposit_yield[&"iron"]) * t.deposit_richness_max + 0.001,
		"richness is clamped, so no seam is worth ignoring the rest of the map for")
	assert_near(Balance.extraction_rate(&"vent", 5000.0), 0.0, 0.001,
		"a vent is tapped for heat, never mined")


# --- heat planning ------------------------------------------------------------

func test_the_heat_budget_rises_from_day_to_night_to_storm() -> void:
	var day: float = Balance.heat_budget_for(40, false)
	var night: float = Balance.heat_budget_for(40, true)
	var storm: float = Balance.heat_budget_for(40, true, true)
	assert_lt(day, night, "night costs more than day")
	assert_lt(night, storm, "a Great Frost costs more than an ordinary night")
	assert_near(Balance.heat_budget_for(0, true), 0.0, 0.001, "no citizens, no bill")


func test_the_buffer_target_grows_as_the_campaign_cools() -> void:
	var early: float = Balance.buffer_target(1, 100.0)
	var late: float = Balance.buffer_target(20, 100.0)
	assert_lt(early, late, "a late-campaign grid has to bank more than a day-one one")
	assert_gt(early, 0.0)


# --- population ---------------------------------------------------------------

func test_growth_needs_beds_warmth_and_food_all_three() -> void:
	var t: BalanceTable = Balance.table()
	var full: float = Balance.population_growth_per_day(50, 20, 20.0, 10.0)
	assert_near(full, t.pop_growth_per_day, 0.001, "perfect conditions, full growth")
	assert_near(Balance.population_growth_per_day(50, 0, 20.0, 10.0), 0.0, 0.001,
		"no spare beds, nobody arrives")
	assert_near(Balance.population_growth_per_day(50, 20, 0.0, 10.0), 0.0, 0.001,
		"a freezing city does not grow no matter how well fed")
	assert_near(Balance.population_growth_per_day(50, 20, 20.0, 0.0), 0.0, 0.001,
		"a warm city with no food does not grow either")
	assert_lt(Balance.population_growth_per_day(50, 20, 3.0, 1.0), full,
		"partial conditions, partial growth")


func test_deaths_scale_with_exposure_and_starvation() -> void:
	assert_near(Balance.population_deaths_per_day(100, 0.0, 0.0), 0.0, 0.001,
		"a comfortable city buries nobody")
	assert_lt(Balance.population_deaths_per_day(100, 0.5, 0.0),
		Balance.population_deaths_per_day(100, 1.0, 0.0),
		"more exposure, more deaths")
	assert_gt(Balance.population_deaths_per_day(100, 1.0, 1.0),
		Balance.population_deaths_per_day(100, 1.0, 0.0),
		"cold and hungry is worse than cold")


func test_the_workforce_is_a_fraction_of_the_population() -> void:
	var pop: int = 100
	var workers: int = Balance.workforce(pop)
	assert_gt(float(workers), 0.0)
	assert_lt(float(workers), float(pop),
		"somebody has to be too old, too young or too sick — that is the tension")


# --- research and defence -----------------------------------------------------

func test_research_gets_dearer_within_a_tier_and_between_tiers() -> void:
	assert_lt(Balance.research_cost(1, 0), Balance.research_cost(1, 3),
		"the fourth unlock of a tier costs more than the first")
	assert_lt(Balance.research_cost(1, 0), Balance.research_cost(2, 0),
		"tier two opens dearer than tier one")
	assert_lt(Balance.research_cost(3, 0), Balance.research_cost(4, 0))
	assert_near(Balance.research_rate(0, 1.0), 0.0, 0.001, "no workers, no insight")
	assert_lt(Balance.research_rate(4, 0.5), Balance.research_rate(4, 1.0),
		"a browned-out workshop researches slower")


func test_the_threat_curve_never_goes_backwards() -> void:
	var previous: float = -1.0
	for day: int in range(1, 26):
		var budget: float = Balance.threat_budget(day)
		assert_ge(budget, previous,
			"night %d asks for less than the night before it" % day)
		previous = budget


func test_defence_investment_target_tracks_the_threat_curve() -> void:
	assert_lt(Balance.defence_investment_target(2), Balance.defence_investment_target(8),
		"a harder night expects more turret standing")
	assert_gt(Balance.defence_investment_target(8), 0.0)


# --- the tick budget ----------------------------------------------------------

func test_reading_the_table_costs_the_tick_budget_nothing() -> void:
	# [P12] is not a SimSystem: it adds exactly 0 ms to step(). What it CAN do is
	# make somebody else's step() slow, if a system calls a balance question ten
	# thousand times a tick and each call re-resolves the registry. It does not —
	# the table is cached on first touch. This is the assertion that keeps it so.
	Balance.table()
	var t0: int = Time.get_ticks_usec()
	var sink: float = 0.0
	for i: int in 20000:
		sink += Balance.table().heat_per_resident
	var us: int = Time.get_ticks_usec() - t0
	assert_gt(sink, 0.0)
	assert_lt(float(us), 20000.0,
		"20 000 table() calls took %d us — that is more than a microsecond each "
		% us + "and means the cache is not holding")


func test_the_audit_is_cached_between_calls() -> void:
	if Registry.ids("buildings").is_empty():
		skip("game/content/buildings/ is empty")
		return
	Balance.audit()
	var t0: int = Time.get_ticks_usec()
	for i: int in 500:
		Balance.audit()
	var us: int = Time.get_ticks_usec() - t0
	assert_lt(float(us), 25000.0,
		"500 audit() calls took %d us; the audit walks the whole registry and "
		% us + "must only do it once")
