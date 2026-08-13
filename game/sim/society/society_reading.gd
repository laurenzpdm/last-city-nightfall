class_name SocietyReading
extends RefCounted
## What society can actually see of the city this second.
##
## One scan of the building list per sample (20 ticks), and every number the
## rest of [P06] needs falls out of it. Nothing here changes anything: a reading
## is an observation, and observations are cheap, cached and thrown away.
##
## Everything is read through public accessors and probed for first, because
## eleven other parts are landing in parallel and a missing system must cost
## fidelity, never correctness. `sources` records which systems actually
## answered, and it goes into serialize() so a critic can see exactly how much
## of this reading was measured and how much was assumed.

const COMFORT_C: float = SocietyDefs.COMFORT_C

## Food a working kitchen turns out per day, in person-days.
const FOOD_PER_KITCHEN_PER_DAY: float = 26.0
## Days of buffer a granary adds to the city's margin.
const FOOD_DAYS_PER_GRANARY: float = 0.8

# --- physical city ----------------------------------------------------------
var buildings_total: int = 0
var buildings_operational: int = 0
var frozen_buildings: int = 0
var homes_total: int = 0
var homes_cold: int = 0
var homes_frozen: int = 0
var housing_capacity: float = 0.0
var home_temp_avg: float = 0.0        ## residents weighted, degrees C
var coldest_home_c: float = 0.0
var warm_share: float = 0.0           ## share of housed people at or above comfort

# --- heat -------------------------------------------------------------------
var heat_demand: float = 0.0
var heat_delivered: float = 0.0
var heat_deficit: float = 0.0
var heat_deficit_share: float = 0.0
var outdoor_c: float = -18.0
var brownouts: int = 0

# --- provisioning -----------------------------------------------------------
var kitchens: int = 0
var kitchens_running: float = 0.0     ## sum of power factors, not a headcount
var granaries: int = 0
## Complete heat producers that are enabled and not iced over. This is what a
## camp with no houses yet actually huddles around.
var hearths_lit: int = 0
var workplaces: int = 0
var jobs_required: int = 0
var food_capacity_per_day: float = 0.0
var food_reserve_days: float = 0.0

# --- calendar ---------------------------------------------------------------
var day: int = 1
var night: bool = false
var storm: bool = false
var storm_title: String = ""
var era: int = 0
var day_ticks: int = SocietyDefs.DEFAULT_DAY_TICKS

# --- what other systems report, when they exist -----------------------------
var citizens_population: float = -1.0
var citizens_deaths_total: float = -1.0
var citizens_sick: float = -1.0
var citizens_homeless: float = -1.0
var citizens_food_days: float = -1.0
var citizens_morale: float = -1.0
var citizens_warmth: float = -1.0
## 0..1 share of the city bitter enough to make trouble. [P05] computes this
## per citizen from their own needs, which is a far better number than anything
## society could infer from the outside.
var citizens_unrest: float = -1.0
## cause -> cumulative count, straight out of [P05]'s obituary.
var citizens_death_toll: Dictionary = {}
var buildings_destroyed_total: int = 0
var research_completed_total: int = 0
var waves_cleared_total: int = 0

var sources: Dictionary[StringName, bool] = {}


func has_source(s: StringName) -> bool:
	return bool(sources.get(s, false))


## Whether [P05] is present and answering. When it is, SocietyPopulace stands
## down completely and society reads its people from citizens instead.
func citizens_authoritative() -> bool:
	return citizens_population >= 0.0


## One sample. `heat`, `climate`, `build`, `citizens`, `research`, `threat` may
## each be null. Cost is one pass over the building list plus a handful of
## dictionary reads per home.
func sample(heat: SimSystem, climate: SimSystem, build: SimSystem,
		citizens: SimSystem, research: SimSystem, threat: SimSystem) -> void:
	sources.clear()
	_read_climate(climate)
	_read_heat(heat)
	_read_buildings(build, heat)
	_read_citizens(citizens)
	_read_progress(build, research, threat)


func _read_climate(climate: SimSystem) -> void:
	if climate == null:
		return
	sources[&"climate"] = true
	if climate.has_method("day"):
		day = maxi(1, int(climate.call("day")))
	if climate.has_method("is_night"):
		night = bool(climate.call("is_night"))
	if climate.has_method("ambient_temperature"):
		outdoor_c = float(climate.call("ambient_temperature"))
	if climate.has_method("is_storm_active"):
		storm = bool(climate.call("is_storm_active"))
	if climate.has_method("storm_title"):
		storm_title = String(climate.call("storm_title"))
	if climate.has_method("era_index"):
		era = int(climate.call("era_index"))
	if climate.has_method("day_length_seconds"):
		var secs: float = float(climate.call("day_length_seconds"))
		if secs > 1.0:
			day_ticks = maxi(24, int(round(secs / SimClock.DT)))


func _read_heat(heat: SimSystem) -> void:
	if heat == null:
		return
	sources[&"heat"] = true
	if not heat.has_method("totals"):
		return
	var t: Dictionary = heat.call("totals")
	heat_demand = float(t.get("demand", 0.0))
	heat_delivered = float(t.get("delivered", 0.0))
	heat_deficit = float(t.get("deficit", 0.0))
	frozen_buildings = int(t.get("frozen", 0))
	brownouts = int(t.get("brownouts", 0))
	if not sources.has(&"climate"):
		outdoor_c = float(t.get("ambient", outdoor_c))
	heat_deficit_share = 0.0 if heat_demand <= 0.001 else clampf(heat_deficit / heat_demand, 0.0, 1.0)


## The single pass. Homes are weighted by how many people sleep in them, so one
## frozen barracks of twenty counts for more than two chilly huts of four.
func _read_buildings(build: SimSystem, heat: SimSystem) -> void:
	buildings_total = 0
	buildings_operational = 0
	homes_total = 0
	homes_cold = 0
	homes_frozen = 0
	housing_capacity = 0.0
	kitchens = 0
	kitchens_running = 0.0
	granaries = 0
	hearths_lit = 0
	workplaces = 0
	jobs_required = 0
	home_temp_avg = outdoor_c
	coldest_home_c = outdoor_c
	warm_share = 0.0
	if build == null or not build.has_method("all_buildings"):
		return
	sources[&"build"] = true
	var raw: Variant = build.call("all_buildings")
	if typeof(raw) != TYPE_ARRAY:
		return

	var has_temp: bool = heat != null and heat.has_method("temperature_of")
	var has_frozen: bool = heat != null and heat.has_method("is_frozen")
	var has_power: bool = heat != null and heat.has_method("power_factor")
	var has_node: bool = heat != null and heat.has_method("has_building")

	var warm_people: float = 0.0
	var temp_weighted: float = 0.0
	var coldest: float = 1000.0

	for entry: Variant in raw:
		var b: Object = entry
		if b == null:
			continue
		buildings_total += 1
		if not b.has_method("is_complete") or not bool(b.call("is_complete")):
			continue
		buildings_operational += 1
		var def: BuildingDef = b.get("def") as BuildingDef
		if def == null:
			continue
		var id: int = int(b.get("id"))
		jobs_required += def.workers_required

		if def.residents > 0:
			homes_total += 1
			var seats: float = float(def.residents)
			housing_capacity += seats
			var temp: float = outdoor_c
			if has_temp and has_node and bool(heat.call("has_building", id)):
				temp = float(heat.call("temperature_of", id))
			temp_weighted += temp * seats
			coldest = minf(coldest, temp)
			if temp >= COMFORT_C:
				warm_people += seats
			else:
				homes_cold += 1
			if has_frozen and bool(heat.call("is_frozen", id)):
				homes_frozen += 1

		if def.has_tag(&"food"):
			if def.has_tag(&"storage"):
				granaries += 1
			else:
				kitchens += 1
				var pf: float = 1.0
				if has_power and has_node and bool(heat.call("has_building", id)):
					pf = clampf(float(heat.call("power_factor", id)), 0.0, 1.0)
				kitchens_running += pf
		if def.heat_produced > 0.0:
			var lit: bool = bool(b.get("enabled"))
			if lit and has_frozen and has_node and bool(heat.call("has_building", id)):
				lit = not bool(heat.call("is_frozen", id))
			if lit:
				hearths_lit += 1
		if def.workers_required > 0:
			workplaces += 1

	if housing_capacity > 0.0:
		home_temp_avg = temp_weighted / housing_capacity
		warm_share = clampf(warm_people / housing_capacity, 0.0, 1.0)
	coldest_home_c = outdoor_c if coldest > 999.0 else coldest
	food_capacity_per_day = kitchens_running * FOOD_PER_KITCHEN_PER_DAY
	food_reserve_days = float(granaries) * FOOD_DAYS_PER_GRANARY


func _read_citizens(citizens: SimSystem) -> void:
	citizens_population = -1.0
	citizens_deaths_total = -1.0
	citizens_sick = -1.0
	citizens_homeless = -1.0
	citizens_food_days = -1.0
	citizens_morale = -1.0
	citizens_warmth = -1.0
	citizens_unrest = -1.0
	citizens_death_toll = {}
	if citizens == null:
		return
	sources[&"citizens"] = true
	citizens_population = _probe(citizens, [&"population", &"citizen_count", &"alive_count"], -1.0)
	citizens_deaths_total = _probe(citizens,
		[&"dead_total", &"deaths_total", &"total_deaths", &"dead_count"], -1.0)
	citizens_sick = _probe(citizens, [&"sick_count", &"sick", &"ill_count"], -1.0)
	citizens_homeless = _probe(citizens, [&"homeless_count", &"homeless", &"unhoused"], -1.0)
	citizens_food_days = _probe(citizens,
		[&"food_days_remaining", &"food_days", &"food_reserve_days"], -1.0)
	citizens_morale = _probe(citizens, [&"average_morale", &"morale"], -1.0)
	citizens_warmth = _probe(citizens, [&"average_warmth"], -1.0)
	citizens_unrest = _probe(citizens, [&"unrest_pressure", &"unrest"], -1.0)
	if citizens.has_method(&"death_toll"):
		var toll: Variant = citizens.call(&"death_toll")
		if typeof(toll) == TYPE_DICTIONARY:
			citizens_death_toll = toll


func _read_progress(build: SimSystem, research: SimSystem, threat: SimSystem) -> void:
	buildings_destroyed_total = 0
	research_completed_total = 0
	waves_cleared_total = 0
	if build != null and build.has_method("metrics"):
		var m: Dictionary = build.call("metrics")
		buildings_destroyed_total = int(m.get("destroyed", m.get("destroyed_total", 0)))
	if research != null:
		sources[&"research"] = true
		research_completed_total = int(_probe(research,
			[&"completed_count", &"completed_total", &"researched_count"], 0.0))
	if threat != null:
		sources[&"threat"] = true
		waves_cleared_total = int(_probe(threat,
			[&"waves_cleared", &"cleared_waves", &"wave_cleared_count"], 0.0))


## First method on `sys` that exists and returns a number, else `fallback`.
static func _probe(sys: SimSystem, names: Array[StringName], fallback: float) -> float:
	for n: StringName in names:
		if sys.has_method(n):
			var v: Variant = sys.call(n)
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				return float(v)
	return fallback


func serialize() -> Dictionary:
	var src: Array = []
	for k: StringName in SocietyDefs.sorted_keys(sources):
		src.append(String(k))
	return {
		"day": day,
		"night": night,
		"storm": storm,
		"era": era,
		"outdoor_c": snappedf(outdoor_c, 0.01),
		"homes": homes_total,
		"homes_cold": homes_cold,
		"homes_frozen": homes_frozen,
		"housing_capacity": snappedf(housing_capacity, 0.1),
		"home_temp_avg": snappedf(home_temp_avg, 0.01),
		"coldest_home_c": snappedf(coldest_home_c, 0.01),
		"warm_share": snappedf(warm_share, 0.001),
		"heat_deficit_share": snappedf(heat_deficit_share, 0.001),
		"frozen_buildings": frozen_buildings,
		"citizens_morale": snappedf(citizens_morale, 0.01),
		"citizens_unrest": snappedf(citizens_unrest, 0.001),
		"kitchens": kitchens,
		"kitchens_running": snappedf(kitchens_running, 0.01),
		"granaries": granaries,
		"hearths_lit": hearths_lit,
		"food_capacity_per_day": snappedf(food_capacity_per_day, 0.01),
		"buildings": buildings_operational,
		"sources": src,
	}
