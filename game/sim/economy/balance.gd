class_name Balance
extends RefCounted
## [P12] Economy & Balance — the read side of the balance table.
##
## Every other part asks its balance questions here instead of hardcoding a
## number. `Balance` is static and lazily cached: the first call resolves the
## highest-priority BalanceTable and DifficultyCurve out of `Registry`, and
## every call after that is a dictionary lookup. Nothing here allocates per
## tick and nothing here is a SimSystem, so it costs the tick budget zero.
##
##     var hp: float = Balance.threat_budget(day, city_points)   # [P08]
##     var n: float  = Balance.population_growth_per_day(...)    # [P05]
##     var pts: float = Balance.research_cost(tier, index)       # [P10]
##     var stock: Dictionary = Balance.starting_stock()          # new campaign
##
## DETERMINISM: pure functions of their arguments and of content on disk. No
## Rng, no clock, no per-run state. Two processes on the same build return the
## same answers, which is why a balance number is safe to put in serialize().

const CATEGORY: String = "economy"

static var _table: BalanceTable = null
static var _curve: DifficultyCurve = null
static var _audit_cache: Array[Dictionary] = []
static var _audit_valid: bool = false


## The active balance table. Never null — falls back to the script defaults so
## a build with an empty game/content/economy/ still runs and still balances.
static func table() -> BalanceTable:
	if _table != null:
		return _table
	_table = _pick(func(r: Resource) -> bool: return r is BalanceTable) as BalanceTable
	if _table == null:
		_table = BalanceTable.new()
		Log.debug("economy", "no BalanceTable in game/content/economy/, using script defaults")
	if not _table.validate():
		Log.warn("economy", "balance table '%s' had to be repaired — check the .tres" % _table.id)
	return _table


## The active difficulty curve. Never null, same fallback contract.
static func curve() -> DifficultyCurve:
	if _curve != null:
		return _curve
	_curve = _pick(func(r: Resource) -> bool: return r is DifficultyCurve) as DifficultyCurve
	if _curve == null:
		_curve = DifficultyCurve.new()
		Log.debug("economy", "no DifficultyCurve in game/content/economy/, using script defaults")
	if not _curve.validate():
		Log.warn("economy", "difficulty curve '%s' had to be repaired — check the .tres" % _curve.id)
	return _curve


## Drops the cache. Call after editing content at runtime; tests use it to prove
## a different table produces different answers.
static func reload() -> void:
	_table = null
	_curve = null
	_audit_cache = []
	_audit_valid = false


# ==========================================================================
#  MATERIALS
# ==========================================================================

## Labour points of a bag of items, e.g. a BuildingDef.cost.
static func points_of(items: Dictionary) -> float:
	var t: BalanceTable = table()
	var total: float = 0.0
	for k: Variant in EconomyDefs.sorted_keys(items):
		total += t.value_of(StringName(String(k))) * float(items[k])
	return total


## What a new campaign begins with, after the global cost knob. A copy: callers
## spend out of it.
static func starting_stock() -> Dictionary[StringName, int]:
	var t: BalanceTable = table()
	var out: Dictionary[StringName, int] = {}
	for k: Variant in EconomyDefs.sorted_keys(t.starting_stock):
		var key: StringName = StringName(String(k))
		out[key] = int(round(float(t.starting_stock[k]) * t.cost_mult))
	return out


## A building's cost after the global cost knob, ready to hand to [P11].
static func cost_of(def: BuildingDef) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	if def == null:
		return out
	var mult: float = table().cost_mult
	for k: Variant in EconomyDefs.sorted_keys(def.cost):
		var key: StringName = StringName(String(k))
		out[key] = maxi(1, int(round(float(def.cost[k]) * mult)))
	return out


# ==========================================================================
#  EXTRACTION
# ==========================================================================

## Units per second an extractor pulls from a seam of this kind holding this
## much, at full staffing and before the machine's own extract_rate.
static func extraction_rate(ore: StringName, deposit_amount: float) -> float:
	var t: BalanceTable = table()
	var base: float = float(t.deposit_yield.get(ore, 0.0))
	if base <= 0.0:
		return 0.0
	return base * richness(deposit_amount)


## Richness multiplier of a seam holding `amount`, clamped to the design bounds.
static func richness(amount: float) -> float:
	var t: BalanceTable = table()
	var r: float = sqrt(maxf(0.0, amount) / t.deposit_reference_amount)
	return clampf(r, t.deposit_richness_min, t.deposit_richness_max)


## Deposit units consumed to yield `units` of item.
static func depletion_for(units: float) -> float:
	return maxf(0.0, units) * table().deposit_depletion_per_unit


# ==========================================================================
#  HEAT
# ==========================================================================

## Heat/second the design budgets for a city of this size at this time of day.
## The planning figure the tutorial and the build menu quote — the live number
## always comes from [P02].
static func heat_budget_for(residents: int, night: bool, great_frost: bool = false) -> float:
	var t: BalanceTable = table()
	var mult: float = t.demand_mult_day
	if great_frost:
		mult = t.demand_mult_great_frost
	elif night:
		mult = t.demand_mult_night
	return float(maxi(0, residents)) * t.heat_per_resident * mult * t.demand_mult


## Stored heat the design wants banked before dusk on this campaign day.
static func buffer_target(campaign_day: int, city_demand: float) -> float:
	var t: BalanceTable = table()
	var span: float = clampf(float(campaign_day - 1) / 12.0, 0.0, 1.0)
	var seconds: float = lerpf(t.buffer_seconds_early, t.buffer_seconds_late, span)
	return maxf(0.0, city_demand) * seconds


## Ticks in one day. Prefers [P09]'s live profile; falls back to the curve.
static func day_ticks() -> int:
	var climate: SimSystem = Sim.get_system(&"climate")
	if climate != null and climate.has_method("day_length_ticks"):
		var v: Variant = climate.call("day_length_ticks")
		if typeof(v) == TYPE_INT and int(v) > 0:
			return int(v)
	return curve().day_ticks


# ==========================================================================
#  POPULATION — [P05]
# ==========================================================================

## New citizens per in-game day, given the three things that gate growth.
## `warmth_c` is degrees above the exposure-safe line in the housing districts,
## `food_days` is days of ration stock, `beds_free` is unoccupied residency.
static func population_growth_per_day(population: int, beds_free: int,
		warmth_c: float, food_days: float) -> float:
	var t: BalanceTable = table()
	if population <= 0:
		return 0.0
	var needed: float = float(population) * t.pop_housing_headroom
	if float(beds_free) < needed:
		return 0.0
	var warm: float = clampf(warmth_c / t.pop_growth_warmth_c, 0.0, 1.0)
	var fed: float = clampf(food_days / t.pop_growth_food_days, 0.0, 1.0)
	# Multiplicative, not additive: a warm city with no food does not grow, and
	# neither does a fed city that is freezing. Both, or nothing.
	return t.pop_growth_per_day * warm * fed


## Deaths per in-game day. `exposed` and `starving` are 0..1 fractions of the
## population in each condition; they overlap and both bills come due.
static func population_deaths_per_day(population: int, exposed: float, starving: float) -> float:
	var t: BalanceTable = table()
	var pop: float = float(maxi(0, population))
	return pop * (clampf(exposed, 0.0, 1.0) * t.pop_death_freezing_per_day
		+ clampf(starving, 0.0, 1.0) * t.pop_death_starving_per_day) / 100.0


## Citizens available to staff buildings.
static func workforce(population: int) -> int:
	return int(floor(float(maxi(0, population)) * table().pop_workforce_fraction))


# ==========================================================================
#  RESEARCH — [P10]
# ==========================================================================

## Points to unlock the `index`-th (0-based) technology of a tier.
static func research_cost(tier: int, index: int) -> float:
	var t: BalanceTable = table()
	var i: int = clampi(tier, EconomyDefs.MIN_TIER, EconomyDefs.MAX_TIER) - 1
	var base: float = float(t.research_tier_base[i])
	return base * pow(t.research_tier_growth, float(maxi(0, index))) * t.research_mult


## Research points per second from `workers` at this power factor.
static func research_rate(workers: int, power_factor: float) -> float:
	var t: BalanceTable = table()
	return float(maxi(0, workers)) * t.research_points_per_worker * clampf(power_factor, 0.0, 1.0)


# ==========================================================================
#  THREAT — [P08]
# ==========================================================================

## Budget points the design throws at the city on this night.
##
## [P08] owns the wave director and ships a far richer curve than a balance
## table should duplicate, so this DELEGATES to `ThreatSystem.budget_for_night`
## whenever that system exists, and only computes from the table when it does
## not. One source of truth at runtime; a documented envelope when [P08] is
## absent, so a scenario written against economy alone still behaves.
##
## `city_points` is the labour value of everything standing (see
## `city_points_of`), which is how the fallback adapts to an overbuilder.
static func threat_budget(campaign_day: int, city_points: float = 0.0) -> float:
	var threat: SimSystem = Sim.get_system(&"threat")
	if threat != null and threat.has_method("budget_for_night"):
		var v: Variant = threat.call("budget_for_night", campaign_day)
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			return float(v) * table().threat_mult
	var t: BalanceTable = table()
	var base: float = _scripted_threat(t, campaign_day)
	var adapt: float = 1.0
	if city_points > 0.0:
		adapt = clampf(1.0 + t.threat_city_size_k * (city_points / t.threat_city_size_reference),
			1.0, t.threat_city_size_max_mult)
	return base * adapt * t.threat_mult


## Material points of defence the design expects a player to have standing on
## night N. The number the tutorial's "you are under-defended" nudge should use.
static func defence_investment_target(campaign_day: int) -> float:
	var t: BalanceTable = table()
	return _scripted_threat(t, campaign_day) * t.defence_points_per_threat_point


## Attack lanes open at once on this night.
static func threat_lanes(campaign_day: int) -> int:
	var t: BalanceTable = table()
	var lanes: int = 1
	for i: int in t.threat_lanes_day.size():
		if campaign_day >= t.threat_lanes_day[i]:
			lanes = t.threat_lanes[i]
	return maxi(1, lanes)


## Hit points in the opening wave of the night.
static func threat_first_wave(campaign_day: int, city_points: float = 0.0) -> float:
	return threat_budget(campaign_day, city_points) * table().threat_first_wave_fraction


## Labour value of a city, from whatever [P11] currently has standing. Zero when
## build has not landed, so a caller degrades to the scripted budget.
static func city_points_of(build: SimSystem = null) -> float:
	var b: SimSystem = build if build != null else Sim.get_system(&"build")
	if b == null or not b.has_method("all_buildings"):
		return 0.0
	var raw: Variant = b.call("all_buildings")
	if typeof(raw) != TYPE_ARRAY:
		return 0.0
	var total: float = 0.0
	for item: Variant in (raw as Array):
		var inst: Object = item as Object
		if inst == null or not ("def" in inst):
			continue
		var def: BuildingDef = inst.get("def") as BuildingDef
		if def != null:
			total += points_of(def.cost)
	return total


static func _scripted_threat(t: BalanceTable, campaign_day: int) -> float:
	var n: int = t.threat_day.size()
	if n == 0:
		return 0.0
	if campaign_day <= t.threat_day[0]:
		return float(t.threat_budget_hp[0])
	for i: int in range(1, n):
		if campaign_day <= t.threat_day[i]:
			var span: int = t.threat_day[i] - t.threat_day[i - 1]
			var f: float = float(campaign_day - t.threat_day[i - 1]) / float(maxi(1, span))
			return lerpf(float(t.threat_budget_hp[i - 1]), float(t.threat_budget_hp[i]), f)
	var extra: int = campaign_day - t.threat_day[n - 1]
	return float(t.threat_budget_hp[n - 1]) * pow(t.threat_growth_per_day, float(extra))


# ==========================================================================
#  THE AUDIT — the table's teeth over content it does not own
# ==========================================================================

## Every live building definition measured against the design bands. Empty means
## the content economy is inside the fence. Each entry is
## {kind, rule, value, low, high, note} and reads as a sentence in a test failure.
##
## Cached: the registry does not change mid-run, and tests call this per assert.
static func audit() -> Array[Dictionary]:
	if _audit_valid:
		return _audit_cache
	_audit_cache = _run_audit()
	_audit_valid = true
	return _audit_cache


## Economic summary of one definition, the numbers the audit reasons about.
##
## `role` is the audit's classification and is the whole trick: a smelter vents
## heat but is a consumer, an accumulator conducts but is a tank, and a
## watchtower draws a token 1.0 and is neither. Judging a building by what it is
## FOR instead of by which fields are non-zero is what keeps the bands honest.
static func economics_of(def: BuildingDef) -> Dictionary:
	if def == null:
		return {}
	var t: BalanceTable = table()
	var points: float = points_of(def.cost)
	var cells: int = maxi(1, def.size.x * def.size.y)
	if not def.footprint_cells.is_empty():
		cells = def.footprint_cells.size()
	var out: float = def.heat_produced * t.supply_mult
	var draw: float = def.heat_consumed * t.demand_mult
	var net: float = out - draw
	var throughput: float = def.conduit_throughput if def.is_heat_conduit else 0.0
	var is_tank: bool = def.heat_buffer > 0.0 and (throughput <= 0.0
		or def.heat_buffer > throughput * t.buffer_classification_seconds)

	var recovery: bool = false
	for tag: StringName in t.recovery_tags:
		if def.has_tag(tag):
			recovery = true
			break

	var role: StringName = &"passive"
	if net > 0.0:
		role = &"recovery" if recovery else &"producer"
	elif throughput > 0.0 and not is_tank:
		role = &"conduit"
	elif is_tank and def.has_tag(&"buffer"):
		role = &"buffer"
	elif draw >= t.consumer_audit_min_demand and t.consumer_audit_categories.has(def.category):
		role = &"consumer"

	return {
		"kind": def.id,
		"tier": clampi(def.tier, EconomyDefs.MIN_TIER, EconomyDefs.MAX_TIER),
		"category": String(def.category),
		"role": String(role),
		"points": points,
		"cells": cells,
		"points_per_cell": points / float(cells),
		"heat_out": out,
		"heat_in": draw,
		"net_heat": net,
		"storage": def.heat_buffer,
		"build_seconds": float(def.build_time_ticks) / float(EconomyDefs.TICKS_PER_SECOND),
		"throughput": throughput,
		"residents": def.residents,
		"points_per_heat_out": (points / net) if net > 0.0 else 0.0,
		"points_per_heat_in": (points / draw) if draw > 0.0 else 0.0,
		"throughput_per_point": (throughput / points) if points > 0.0 else 0.0,
		"storage_per_point": (def.heat_buffer / points) if points > 0.0 else 0.0,
		"exempt": _is_exempt(def, t),
	}


static func _run_audit() -> Array[Dictionary]:
	var t: BalanceTable = table()
	var out: Array[Dictionary] = []
	for id: StringName in Registry.ids("buildings"):
		var def: BuildingDef = Registry.get_item("buildings", id) as BuildingDef
		if def == null:
			continue
		var e: Dictionary = economics_of(def)
		var tier_i: int = int(e["tier"]) - 1
		var exempt: bool = bool(e["exempt"])
		var points: float = float(e["points"])
		var role: StringName = StringName(String(e["role"]))

		for item: Variant in EconomyDefs.sorted_keys(def.cost):
			if not t.prices(StringName(String(item))):
				out.append(_finding(id, &"unpriced_material", 0.0, 0.0, 0.0,
					"'%s' has no entry in material_value, so every cost band that "
					% String(item) + "mentions it is guessing"))

		if points <= 0.0:
			out.append(_finding(id, &"free_building", 0.0, 1.0, INF, "costs nothing at all"))
		else:
			# The floor is universal: a big cheap building is always a bug. The
			# ceiling only means something once there is a footprint to divide by.
			var ppc: float = float(e["points_per_cell"])
			var ceiling: float = t.points_per_cell.y if int(e["cells"]) >= t.points_per_cell_max_from_cells else INF
			_band(out, id, &"points_per_cell", ppc, t.points_per_cell.x, ceiling,
				"material points per footprint cell")

		match role:
			&"producer":
				_band(out, id, &"producer_cost", float(e["points_per_heat_out"]),
					t.producer_points_per_heat.x, t.producer_points_per_heat.y,
					"material points per heat/second of net output")
				if not exempt:
					_band(out, id, &"tier_output", float(e["net_heat"]),
						float(t.tier_output_min[tier_i]), float(t.tier_output_max[tier_i]),
						"net heat/second at tier %d" % int(e["tier"]))
					if float(e["net_heat"]) > t.max_ordinary_output:
						out.append(_finding(id, &"landmark_output", float(e["net_heat"]),
							0.0, t.max_ordinary_output,
							"outproduces max_ordinary_output without a unique/landmark tag"))
			&"conduit":
				if points > 0.0:
					_band(out, id, &"conduit_value", float(e["throughput_per_point"]),
						t.conduit_throughput_per_point.x, t.conduit_throughput_per_point.y,
						"heat/second carried per material point")
			&"buffer":
				if points > 0.0:
					_band(out, id, &"buffer_value", float(e["storage_per_point"]),
						t.buffer_units_per_point.x, t.buffer_units_per_point.y,
						"units of stored heat per material point")
			&"recovery":
				_band(out, id, &"recovery_cost", float(e["points_per_heat_out"]),
					t.recovery_points_per_heat.x, t.recovery_points_per_heat.y,
					"material points per heat/second of recovered heat")
			&"consumer":
				if points > 0.0:
					var ceiling_in: float = t.consumer_points_per_heat.y \
						* pow(t.consumer_points_tier_growth, float(int(e["tier"]) - 1))
					_band(out, id, &"consumer_cost", float(e["points_per_heat_in"]),
						t.consumer_points_per_heat.x, ceiling_in,
						"material points per heat/second drawn at tier %d" % int(e["tier"]))

		_band(out, id, &"build_time", float(e["build_seconds"]),
			float(t.tier_build_seconds_min[tier_i]), float(t.tier_build_seconds_max[tier_i]),
			"seconds of build work at tier %d" % int(e["tier"]))

		if def.residents > 0:
			# Housing carries roughly two thirds of a citizen's heat bill; the
			# radiator on the street carries the rest. Both ends checked, because
			# free-to-heat housing and unheatable housing break the game equally.
			_band(out, id, &"heat_per_resident", float(e["heat_in"]) / float(def.residents),
				t.heat_per_resident * 0.35, t.heat_per_resident * 1.20,
				"heat/second per resident housed")
	return out


## Cross-system audit: is [P10]'s tech tree priced in materials this economy has
## heard of, and does each tier sit inside its affordability band?
##
## Returns the same {kind, rule, value, low, high, note, text} shape as audit().
## Empty when game/content/research/ is absent — a part that has not landed
## cannot be wrong yet.
static func audit_research() -> Array[Dictionary]:
	var t: BalanceTable = table()
	var out: Array[Dictionary] = []
	var ids: Array[StringName] = Registry.ids("research")
	if ids.is_empty():
		return out
	var per_tier: Dictionary[int, float] = {}
	var counted: Dictionary[int, int] = {}
	for id: StringName in ids:
		var node: Resource = Registry.get_item("research", id)
		if node == null or not ("cost" in node):
			continue
		var raw: Variant = node.get("cost")
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var cost: Dictionary = raw
		for item: Variant in EconomyDefs.sorted_keys(cost):
			if not t.prices(StringName(String(item))):
				out.append(_finding(id, &"unpriced_research_material", 0.0, 0.0, 0.0,
					"research '%s' is bought with '%s', which material_value does not price"
					% [String(id), String(item)]))
		var tier: int = clampi(int(node.get("tier")) if "tier" in node else 1,
			EconomyDefs.MIN_TIER, EconomyDefs.MAX_TIER)
		per_tier[tier] = float(per_tier.get(tier, 0.0)) + points_of(cost)
		counted[tier] = int(counted.get(tier, 0)) + 1
	for tier: Variant in EconomyDefs.sorted_keys(per_tier):
		var i: int = int(tier) - 1
		_band(out, StringName("research_tier_%d" % int(tier)), &"research_tier_points",
			float(per_tier[tier]),
			float(t.research_tier_points_min[i]), float(t.research_tier_points_max[i]),
			"material points across all %d tier-%d unlocks" % [int(counted[tier]), int(tier)])
	return out


## Cross-system audit: can a player who followed the intended build order afford
## the nights [P08]'s director plans?
##
## Reads whatever ThreatProfile the registry holds, defensively — a shape check
## and an affordability line, never a second copy of the curve. Empty when [P08]
## has not shipped a profile.
static func audit_threat() -> Array[Dictionary]:
	var t: BalanceTable = table()
	var out: Array[Dictionary] = []
	var curve_points: PackedFloat32Array = _threat_curve()
	if curve_points.is_empty():
		return out
	for i: int in range(1, curve_points.size()):
		if curve_points[i] < curve_points[i - 1]:
			out.append(_finding(StringName("night_%d" % (i + 1)), &"threat_curve_dips",
				float(curve_points[i]), float(curve_points[i - 1]), INF,
				"night %d asks for less than night %d — pressure that goes backwards "
				% [i + 1, i] + "reads as the game losing interest"))
			break
	# Affordability: what the night asks for, against what the city could have
	# built by then if it spent everything on defence.
	var built: float = 0.0
	var affordable_line: float = _city_points_by_night(1)
	for i: int in curve_points.size():
		var night: int = i + 1
		built = _city_points_by_night(night)
		var needed: float = float(curve_points[i]) * t.defence_points_per_threat_point
		var ceiling: float = built * t.defence_share_of_city_max * t.defence_affordability_slack
		if needed > ceiling and ceiling > 0.0:
			out.append(_finding(StringName("night_%d" % night), &"threat_unaffordable",
				needed, 0.0, ceiling,
				"night %d wants %.0f points of defence; a city of %.0f points may only "
				% [night, needed, built] + "spend %.0f on it" % ceiling))
			break
	affordable_line = built
	if affordable_line <= 0.0:
		out.append(_finding(&"economy", &"no_city_growth_model", 0.0, 1.0, INF,
			"the affordability line evaluated to zero, so this audit proved nothing"))
	return out


## Material points a city following the intended curve has standing on night N.
## Deliberately crude and deliberately here rather than in a system: it is a
## DESIGN assumption (the starting stock plus a district a day), and the whole
## point of the audit is to state that assumption out loud where it can be argued
## with, instead of leaving it implicit in a threat curve nobody cross-checked.
static func _city_points_by_night(night: int) -> float:
	var t: BalanceTable = table()
	var start: float = points_of(t.starting_stock)
	# One district a day: two generators, a radiator, two homes, one workshop.
	var per_day: float = 0.0
	for kind: StringName in [&"coal_generator", &"coal_generator", &"warmth_radiator",
			&"housing_block", &"housing_block"]:
		var def: BuildingDef = Registry.get_item("buildings", kind) as BuildingDef
		if def != null:
			per_day += points_of(def.cost)
	if per_day <= 0.0:
		per_day = start * 0.5
	return start + per_day * float(maxi(0, night - 1))


static func _threat_curve() -> PackedFloat32Array:
	for id: StringName in Registry.ids("threat"):
		var res: Resource = Registry.get_item("threat", id)
		if res != null and "budget_table" in res:
			var raw: Variant = res.get("budget_table")
			if typeof(raw) == TYPE_PACKED_FLOAT32_ARRAY:
				return raw
	var threat: SimSystem = Sim.get_system(&"threat")
	if threat != null and threat.has_method("budget_for_night"):
		var out := PackedFloat32Array()
		for night: int in range(1, 13):
			var v: Variant = threat.call("budget_for_night", night)
			if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
				return PackedFloat32Array()
			out.append(float(v))
		return out
	return PackedFloat32Array()


## Which economic rules each definition is actually covered by, {kind: [rule]}.
## A building covered by nothing is a hole in the fence, and tests/economy says
## so — that is what stops the audit from being green because it checks nothing.
static func audit_coverage() -> Dictionary[StringName, PackedStringArray]:
	var out: Dictionary[StringName, PackedStringArray] = {}
	for id: StringName in Registry.ids("buildings"):
		var def: BuildingDef = Registry.get_item("buildings", id) as BuildingDef
		if def == null:
			continue
		var e: Dictionary = economics_of(def)
		var rules := PackedStringArray(["build_time"])
		if float(e["points"]) > 0.0:
			rules.append("points_per_cell")
		match StringName(String(e["role"])):
			&"producer":
				rules.append("producer_cost")
				if not bool(e["exempt"]):
					rules.append("tier_output")
			&"recovery":
				rules.append("recovery_cost")
			&"conduit":
				rules.append("conduit_value")
			&"buffer":
				rules.append("buffer_value")
			&"consumer":
				rules.append("consumer_cost")
		if def.residents > 0:
			rules.append("heat_per_resident")
		out[id] = rules
	return out


static func _band(out: Array[Dictionary], kind: StringName, rule: StringName,
		value: float, low: float, high: float, note: String) -> void:
	if value >= low and value <= high:
		return
	out.append(_finding(kind, rule, value, low, high, note))


static func _finding(kind: StringName, rule: StringName, value: float,
		low: float, high: float, note: String) -> Dictionary:
	return {
		"kind": String(kind),
		"rule": String(rule),
		"value": snappedf(value, 0.001),
		"low": snappedf(low, 0.001),
		"high": snappedf(high, 0.001) if is_finite(high) else -1.0,
		"note": note,
		"text": "%s: %s is %.2f, band is %.2f..%.2f (%s)" % [
			String(kind), String(rule), value, low, high, note],
	}


static func _is_exempt(def: BuildingDef, t: BalanceTable) -> bool:
	for tag: StringName in t.audit_exempt_tags:
		if def.tags.has(tag):
			return true
	return false


## Highest-priority resource in game/content/economy/ matching `want`, or null.
static func _pick(want: Callable) -> Resource:
	if not Registry.loaded:
		return null
	var best: Resource = null
	var best_priority: int = -2147483648
	for id: StringName in Registry.ids(CATEGORY):
		var res: Resource = Registry.get_item(CATEGORY, id)
		if res == null or not bool(want.call(res)):
			continue
		var p: int = int(res.get("priority")) if "priority" in res else 0
		if best == null or p > best_priority:
			best = res
			best_priority = p
	return best
