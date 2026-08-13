class_name BalanceTable
extends Resource
## ============================================================================
##  THE BALANCE TABLE.  [P12] Economy & Balance.
## ============================================================================
##
## Every number that decides whether the city lives, other than the ones a
## building definition already owns. One file, one designer, one diff.
##
## The script defaults below ARE the shipped campaign. Override any of them by
## dropping a `.tres` into `game/content/economy/` — `Registry` finds it and the
## highest `priority` wins, exactly like ClimateProfile in [P09].
##
## Three kinds of number live here, and it matters which is which:
##
##  1. **Owned outright.** Population growth, research costs, the threat budget,
##     deposit yields, the starting stock. No other part has these; the parts
##     that will consume them ([P05] [P08] [P10]) read them through `Balance`
##     instead of hardcoding, which is the entire point of this file existing
##     before those parts land.
##
##  2. **Design rules over content someone else owns.** Building costs and heat
##     figures live in `game/content/buildings/*.tres`, owned by [P11] and the
##     content agents. This table does not copy them — copies rot. It states the
##     BANDS a definition has to sit inside (cost per heat/second, output per
##     tier, build seconds per tier), and `Balance.audit()` measures the live
##     registry against them. A content change that breaks the economy turns
##     tests/economy red with the offending building named.
##
##  3. **Global knobs.** Multipliers a difficulty setting or a scenario moves
##     without touching a single .tres.
##
## Units, stated once: heat is units per SECOND, time is SECONDS unless a field
## says ticks, temperature is Celsius, and "material points" is the abstract
## labour currency defined by `material_value` below.

## Id used by Registry. Must be unique across game/content/economy/.
@export var id: StringName = &"long_winter"
@export var display_name: String = "The Long Winter"
## Highest priority table in the registry wins.
@export var priority: int = 0

# ==========================================================================
#  1. MATERIALS — the common currency
# ==========================================================================
# Every cost in the game is a bag of items. To compare a wall against a smelter
# you need one axis, and this is it: abstract labour points per unit of item.
# Raw ground materials are ~1, a smelted plate is what it cost to smelt, and a
# fabricated part carries its whole chain. Change these and every audit band,
# every research cost and every threat budget re-scales with them.

@export var material_value: Dictionary[StringName, float] = {
	# raw — dug, cut or scavenged
	&"stone": 1.0,
	&"timber": 1.0,
	&"scrap": 1.2,
	&"coal": 1.5,
	&"grain": 1.0,
	# smelted / first pass
	&"iron_plate": 4.0,
	&"insulation_wool": 3.0,
	&"ration": 3.0,
	# fabricated
	&"copper_coil": 7.0,
	&"gear": 8.0,
	&"pipe_segment": 9.0,
	&"steel_plate": 10.0,
	&"insulation": 6.0,
	&"ammo_shell": 12.0,
	&"circuit": 20.0,
}

## Value assigned to an item the table has never heard of. Deliberately high:
## an unpriced item showing up in a cost should make the audit notice, not
## quietly count as free.
@export var unknown_material_value: float = 5.0

## What a new campaign starts with. Enough for a hearth, a short grid, two
## radiators and two housing blocks, and nothing else — the first decision of
## the game is which of those to skip.
@export var starting_stock: Dictionary[StringName, int] = {
	&"stone": 400,
	&"timber": 300,
	&"scrap": 260,
	&"iron_plate": 180,
	&"steel_plate": 60,
	&"copper_coil": 40,
	&"gear": 30,
	&"coal": 500,
}

# ==========================================================================
#  2. EXTRACTION — what the ground gives back
# ==========================================================================

## Units per second an extractor pulls at full staffing from a seam of average
## richness, by deposit kind. BuildingDef.extract_rate is the machine's side of
## the multiplication; this is the ground's.
@export var deposit_yield: Dictionary[StringName, float] = {
	&"iron": 1.0,
	&"copper": 0.85,
	&"coal": 1.25,
	&"sulfur": 0.7,
	&"scrap": 1.1,
	&"vent": 0.0,          ## a vent is tapped for heat, never mined
}

## Deposit amount that counts as "average richness" (yield multiplier 1.0).
## Richness scales as sqrt(amount / reference), clamped by the two bounds below,
## so a fat seam is worth walking to but never worth ignoring the rest of the map.
@export var deposit_reference_amount: float = 300.0
@export var deposit_richness_min: float = 0.55
@export var deposit_richness_max: float = 1.85

## Fraction of a deposit removed per unit extracted. 1.0 means a seam holding
## 300 units yields 300 units. Below 1.0 the ground is more generous than it
## looks, which is how an early game stops being a bookkeeping exercise.
@export var deposit_depletion_per_unit: float = 0.8

# ==========================================================================
#  3. HEAT — the one resource
# ==========================================================================
# The heat SOLVER is [P02]'s and is not tuned from here. What is tuned from here
# is what the city is allowed to ask of it.

## Heat per second the design budgets for one citizen, all-in: their share of
## the housing block's draw plus their share of the radiator that keeps the
## street between the blocks alive. Used by `Balance.heat_budget_for()` and by
## the audit that stops a housing block from getting quietly cheaper to heat.
@export var heat_per_resident: float = 1.25

## Multipliers the design expects on the base draw, before [P09]'s own weather
## curve. These are what a *plan* is made against; the live number comes from
## ClimateSystem.heat_loss_multiplier().
@export var demand_mult_day: float = 1.15
@export var demand_mult_night: float = 1.45
@export var demand_mult_great_frost: float = 2.30

## Seconds of full city demand the design wants buffered before dusk on day 1,
## rising to the second figure by the late campaign. A grid that cannot hold
## this much has no answer to a storm except switching things off.
@export var buffer_seconds_early: float = 45.0
@export var buffer_seconds_late: float = 120.0

## Heat/second one producer may put on the grid before it counts as a landmark.
## The Hearth is the exception and is exempt by tag (see audit_exempt_tags).
@export var max_ordinary_output: float = 72.0

# ==========================================================================
#  4. BUILDING AUDIT BANDS — design rules over [P11]'s content
# ==========================================================================
# Deliberately wide. These are not the designed values, they are the fence
# around them: a tweak passes, a typo does not. `Balance.audit()` reports every
# building outside its band, and tests/economy fails the build on it.

## Material points a producer may cost per heat/second of NET output. Low = free
## energy, high = never worth building. Coal at ~4.5, geothermal at ~6.
## "Net" matters: a smelter vents 4 heat/s while drawing 14, and judging it as a
## generator would price its waste heat as if it were a power plant.
@export var producer_points_per_heat: Vector2 = Vector2(2.5, 11.0)

## Material points a heat CUSTOMER may cost per heat/second it draws. Applied
## only to the buildings whose product is warmth or habitation — see
## consumer_audit_categories and consumer_audit_min_demand.
@export var consumer_points_per_heat: Vector2 = Vector2(4.0, 34.0)

## A building drawing less than this is not a heat customer in any meaningful
## sense (a watchtower draws 1.0), and cost-per-heat says nothing useful about it.
@export var consumer_audit_min_demand: float = 3.0

## Categories whose economic worth IS measured in heat drawn. Defense is absent
## on purpose: a turret's cost buys damage, and that band belongs to [P07] once
## weapons exist. Adding it here without a damage model would be a fence painted
## on the ground.
@export var consumer_audit_categories: Array[StringName] = [
	&"housing", &"heat", &"production", &"extraction", &"storage",
	&"logistics", &"infrastructure",
]

## Heat/second output allowed at each tier, index 0 = tier 1. A producer at the
## wrong tier is a progression bug, not a balance one, and shows up here first.
@export var tier_output_min: PackedFloat32Array = PackedFloat32Array([8.0, 35.0, 70.0, 120.0])
@export var tier_output_max: PackedFloat32Array = PackedFloat32Array([45.0, 95.0, 190.0, 400.0])

## Seconds of build work allowed at each tier. 20 ticks = 1 second. The tier
## gates how complicated a thing is, not how long a metre of pipe takes to lay,
## so the minima stay low even at tier 4.
@export var tier_build_seconds_min: PackedFloat32Array = PackedFloat32Array([0.5, 1.0, 3.0, 6.0])
@export var tier_build_seconds_max: PackedFloat32Array = PackedFloat32Array([130.0, 240.0, 420.0, 900.0])

## Material points per footprint cell. The floor catches a five-by-five that
## costs less than a wall segment, which is the cheapest way to break a city
## builder. The ceiling only applies from `points_per_cell_max_from_cells` up:
## below that the number is dominated by the fixed cost of the mechanism inside
## and says nothing about the footprint.
@export var points_per_cell: Vector2 = Vector2(1.0, 62.0)
@export var points_per_cell_max_from_cells: int = 4

## Heat/second a conduit may carry per material point of its cost. A pipe that
## carries the whole city for two iron plates removes the layout game.
@export var conduit_throughput_per_point: Vector2 = Vector2(0.5, 14.0)

## Units of stored heat a buffer may hold per material point. A tank is judged on
## what it holds, not on what it passes through: the accumulator's 40 throughput
## is incidental to its 900 units of storage.
@export var buffer_units_per_point: Vector2 = Vector2(1.5, 15.0)

## A conduit holding more than this many seconds of its own throughput is a tank
## with a pipe attached, and is audited as a buffer instead.
@export var buffer_classification_seconds: float = 3.0

## Tags that opt a definition out of the tier and output bands. A landmark is
## allowed to break the curve — that is what makes it a landmark. It is NOT
## exempt from cost-per-heat: a landmark may be huge, not free.
@export var audit_exempt_tags: Array[StringName] = [&"unique", &"landmark"]

# ==========================================================================
#  5. POPULATION — [P05] citizens reads this
# ==========================================================================

## Survivors who reach the site on day one.
@export var pop_start: int = 24

## New citizens per in-game DAY at perfect conditions: spare housing, warm
## streets, food in the granary. Everything below scales this down.
@export var pop_growth_per_day: float = 6.0
## Spare beds needed before anyone arrives at all, as a fraction of population.
@export var pop_housing_headroom: float = 0.08
## Warmth (degrees above the exposure-safe line) at which growth is unimpeded.
@export var pop_growth_warmth_c: float = 6.0
## Days of food stock at which growth is unimpeded.
@export var pop_growth_food_days: float = 2.0

## Deaths per day among citizens who spend the night below the safe line, at
## full exposure. [P09] owns what "full exposure" means.
@export var pop_death_freezing_per_day: float = 0.9
## Deaths per day at zero food.
@export var pop_death_starving_per_day: float = 0.55

## Fraction of the population that can work. The rest are too old, too young or
## too sick, and they still need heating — which is the whole tension.
@export var pop_workforce_fraction: float = 0.62

# ==========================================================================
#  6. RESEARCH — the affordability side of [P10]'s tech tree
# ==========================================================================
# A ResearchNode owns its own `cost` (materials) and `work` (ticks). What it
# cannot know is whether the city can PAY that by the day the tree expects it
# to. That is an economy question, and these are its numbers.

## Material points a whole tier of research may cost, floor and ceiling. The
## audit sums every node in a tier and complains when the tier is free or
## unreachable. Index 0 = tier 1.
@export var research_tier_points_min: PackedFloat32Array = PackedFloat32Array([40.0, 200.0, 700.0, 1600.0])
@export var research_tier_points_max: PackedFloat32Array = PackedFloat32Array([1400.0, 5000.0, 16000.0, 48000.0])

## Cost in abstract research points of the first unlock at each tier. Used by
## `Balance.research_cost()` when a caller wants a planning figure rather than a
## node's own material bill — the tutorial and the [P20] stats screen do.
@export var research_tier_base: PackedFloat32Array = PackedFloat32Array([60.0, 220.0, 700.0, 2000.0])
## Each further unlock in a tier costs this much more than the one before it.
@export var research_tier_growth: float = 1.28
## Research points per second from one worker in a fully powered workshop.
@export var research_points_per_worker: float = 0.09

# ==========================================================================
#  7. THREAT & DEFENCE — the envelope around [P08]'s wave director
# ==========================================================================
# [P08] owns the wave director and ships a far more detailed ThreatProfile than
# a balance table should try to duplicate: set pieces, lulls, adaptation, storm
# synchronisation. `Balance.threat_budget()` DELEGATES to that profile whenever
# it is present and only falls back to the table below when it is not.
#
# What lives here instead is the thing neither part owns alone: whether a player
# following the intended build order can AFFORD the night the director plans.
# `Balance.audit_threat()` measures one against the other.

## Nights that carry a fallback budget, and the budget for each, in [P08]'s
## budget-point currency. Used only when no ThreatProfile is loaded.
@export var threat_day: PackedInt32Array = PackedInt32Array([1, 2, 3, 4, 6, 8, 12, 18, 25])
@export var threat_budget_hp: PackedFloat32Array = PackedFloat32Array([
	8.0, 18.0, 30.0, 44.0, 80.0, 132.0, 286.0, 620.0, 1300.0,
])
## Compounding factor per night past the last entry.
@export var threat_growth_per_day: float = 1.11

## Adaptive pressure: the fallback budget is multiplied by
## (1 + threat_city_size_k * city_points / threat_city_size_reference),
## so a player who builds twice the city gets a harder night rather than a
## victory lap. Kept gentle — Factorio's evolution, not a rubber band.
@export var threat_city_size_k: float = 0.45
@export var threat_city_size_reference: float = 6000.0
@export var threat_city_size_max_mult: float = 2.4

## Attack lanes opened at once, by night, when [P08] is absent.
@export var threat_lanes_day: PackedInt32Array = PackedInt32Array([1, 3, 7, 14, 24])
@export var threat_lanes: PackedInt32Array = PackedInt32Array([1, 2, 3, 4, 5])

## Fraction of a night's budget that arrives in the first wave.
@export var threat_first_wave_fraction: float = 0.35

## THE AFFORDABILITY LINE. Material points of defence the design expects a
## player to have standing per point of that night's threat budget. A turret
## costs 224 points and a wall segment 6, so 9.0 means night 12's budget of 286
## expects roughly eleven turrets and a perimeter — reachable, and only just.
@export var defence_points_per_threat_point: float = 9.0

## Fraction of everything the city has built that the design is willing to see
## spent on defence. Above this the game is a tower defence with a city attached,
## which is the wrong game.
@export var defence_share_of_city_max: float = 0.35

## How far [P08]'s curve may run past the affordability line before the audit
## calls it, as a multiple. Wide, because the director also has walls, terrain
## and chokepoints working for it that this line does not model.
@export var defence_affordability_slack: float = 2.5

# ==========================================================================
#  8. GLOBAL KNOBS — one line to move the whole game
# ==========================================================================

## Scales every building cost. A difficulty setting moves this, not 21 .tres files.
@export var cost_mult: float = 1.0
## Scales every heat_consumed. Above 1.0 the city is thirstier.
@export var demand_mult: float = 1.0
## Scales every heat_produced.
@export var supply_mult: float = 1.0
## Scales the threat budget.
@export var threat_mult: float = 1.0
## Scales research costs.
@export var research_mult: float = 1.0


## Repairs a hand-authored table into something the game can run on, and reports
## whether it had to. Same contract as ClimateProfile.validate(): a designer who
## deletes half an array gets a working game and a warning, not a crash.
func validate() -> bool:
	var ok: bool = true

	if String(id) == "":
		id = &"long_winter"
		ok = false

	unknown_material_value = maxf(0.0, unknown_material_value)
	heat_per_resident = maxf(0.0, heat_per_resident)
	max_ordinary_output = maxf(1.0, max_ordinary_output)

	demand_mult_day = maxf(0.1, demand_mult_day)
	demand_mult_night = maxf(demand_mult_day, demand_mult_night)
	demand_mult_great_frost = maxf(demand_mult_night, demand_mult_great_frost)

	buffer_seconds_early = maxf(0.0, buffer_seconds_early)
	buffer_seconds_late = maxf(buffer_seconds_early, buffer_seconds_late)

	deposit_reference_amount = maxf(1.0, deposit_reference_amount)
	deposit_richness_min = clampf(deposit_richness_min, 0.01, 1.0)
	deposit_richness_max = maxf(deposit_richness_min, deposit_richness_max)
	deposit_depletion_per_unit = maxf(0.0, deposit_depletion_per_unit)

	producer_points_per_heat = _ordered(producer_points_per_heat)
	consumer_points_per_heat = _ordered(consumer_points_per_heat)
	points_per_cell = _ordered(points_per_cell)
	conduit_throughput_per_point = _ordered(conduit_throughput_per_point)
	buffer_units_per_point = _ordered(buffer_units_per_point)
	consumer_audit_min_demand = maxf(0.0, consumer_audit_min_demand)
	points_per_cell_max_from_cells = maxi(1, points_per_cell_max_from_cells)
	buffer_classification_seconds = maxf(0.0, buffer_classification_seconds)

	var tiers: int = EconomyDefs.MAX_TIER
	if tier_output_min.size() < tiers or tier_output_max.size() < tiers \
			or tier_build_seconds_min.size() < tiers or tier_build_seconds_max.size() < tiers:
		tier_output_min = PackedFloat32Array([8.0, 35.0, 70.0, 120.0])
		tier_output_max = PackedFloat32Array([45.0, 95.0, 190.0, 400.0])
		tier_build_seconds_min = PackedFloat32Array([0.5, 1.0, 3.0, 6.0])
		tier_build_seconds_max = PackedFloat32Array([130.0, 240.0, 420.0, 900.0])
		ok = false
	for i: int in tiers:
		if tier_output_max[i] < tier_output_min[i]:
			tier_output_max[i] = tier_output_min[i]
			ok = false
		if tier_build_seconds_max[i] < tier_build_seconds_min[i]:
			tier_build_seconds_max[i] = tier_build_seconds_min[i]
			ok = false

	pop_start = maxi(1, pop_start)
	pop_growth_per_day = maxf(0.0, pop_growth_per_day)
	pop_housing_headroom = clampf(pop_housing_headroom, 0.0, 1.0)
	pop_growth_warmth_c = maxf(0.1, pop_growth_warmth_c)
	pop_growth_food_days = maxf(0.1, pop_growth_food_days)
	pop_workforce_fraction = clampf(pop_workforce_fraction, 0.05, 1.0)

	if research_tier_base.size() < tiers:
		research_tier_base = PackedFloat32Array([60.0, 220.0, 700.0, 2000.0])
		ok = false
	if research_tier_points_min.size() < tiers or research_tier_points_max.size() < tiers:
		research_tier_points_min = PackedFloat32Array([40.0, 200.0, 700.0, 1600.0])
		research_tier_points_max = PackedFloat32Array([1400.0, 5000.0, 16000.0, 48000.0])
		ok = false
	for i: int in tiers:
		if research_tier_points_max[i] < research_tier_points_min[i]:
			research_tier_points_max[i] = research_tier_points_min[i]
			ok = false
	research_tier_growth = maxf(1.0, research_tier_growth)
	research_points_per_worker = maxf(0.0, research_points_per_worker)
	defence_points_per_threat_point = maxf(0.0, defence_points_per_threat_point)
	defence_share_of_city_max = clampf(defence_share_of_city_max, 0.01, 1.0)
	defence_affordability_slack = maxf(1.0, defence_affordability_slack)

	var beats: int = mini(threat_day.size(), threat_budget_hp.size())
	if beats < 1:
		threat_day = PackedInt32Array([1])
		threat_budget_hp = PackedFloat32Array([0.0])
		beats = 1
		ok = false
	if threat_day.size() != beats or threat_budget_hp.size() != beats:
		threat_day = threat_day.slice(0, beats)
		threat_budget_hp = threat_budget_hp.slice(0, beats)
		ok = false
	for i: int in range(1, beats):
		if threat_day[i] <= threat_day[i - 1]:
			threat_day[i] = threat_day[i - 1] + 1
			ok = false
	threat_growth_per_day = maxf(1.0, threat_growth_per_day)
	threat_city_size_reference = maxf(1.0, threat_city_size_reference)
	threat_city_size_max_mult = maxf(1.0, threat_city_size_max_mult)
	threat_first_wave_fraction = clampf(threat_first_wave_fraction, 0.0, 1.0)

	var lanes: int = mini(threat_lanes_day.size(), threat_lanes.size())
	if lanes < 1:
		threat_lanes_day = PackedInt32Array([1])
		threat_lanes = PackedInt32Array([1])
		ok = false
	elif threat_lanes_day.size() != lanes or threat_lanes.size() != lanes:
		threat_lanes_day = threat_lanes_day.slice(0, lanes)
		threat_lanes = threat_lanes.slice(0, lanes)
		ok = false

	cost_mult = maxf(0.01, cost_mult)
	demand_mult = maxf(0.01, demand_mult)
	supply_mult = maxf(0.01, supply_mult)
	threat_mult = maxf(0.0, threat_mult)
	research_mult = maxf(0.01, research_mult)
	return ok


## Labour points of one item id. Unknown items are priced, loudly, at
## unknown_material_value rather than at zero.
func value_of(item: StringName) -> float:
	return float(material_value.get(item, unknown_material_value))


## True when the table has an explicit price for this item.
func prices(item: StringName) -> bool:
	return material_value.has(item)


static func _ordered(v: Vector2) -> Vector2:
	return v if v.y >= v.x else Vector2(v.y, v.x)
