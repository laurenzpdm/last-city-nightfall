class_name SocietyPopulace
extends RefCounted
## The people, and what the city is doing to them.
##
## READ THIS BEFORE YOU CHANGE IT. This class is a STAND IN. [P05] citizens owns
## population, jobs, needs and shifts. The moment a `citizens` system exists and
## answers `population()`, everything below switches to mirroring it: the model
## stops running, `authoritative` goes false, and society reads its dead out of
## [P05] instead of computing them.
##
## It exists at all because hope and discontent are meaningless without people.
## A society system that waits for its dependency is a society system nobody can
## test, balance or judge, and the escalation ladder that ends a run has to be
## reachable in an actual harness run today.
##
## What it models, all of it deterministic and all of it driven by things the
## player can see and change:
##
##   exposure   people in cold rooms and people with no room at all
##   hunger     kitchens running x what the ration law says they may serve
##   sickness   a pool that fills from exposure, hunger, crowding and strain,
##              and drains at a rate the medical policy sets
##   death      from the sick pool, from the cold, and from famine that has gone
##              on long enough to matter
##   the dead   bodies pile up until a law says where they go
##
## Everything it produces comes back as EVENTS, never as a silent state change,
## so every death that moves a meter has a sentence attached to it.

## Hours of deep shortage before anyone actually starves.
const FAMINE_ONSET_HOURS: float = 14.0
const FAMINE_HUNGER_LINE: float = 0.55
const FAMINE_MORTALITY_PER_HOUR: float = 0.028
## A room this far past cold is killing the people asleep in it.
const INDOOR_LETHAL_FRACTION: float = 0.75
const INDOOR_LETHAL_GAIN: float = 2.0

## The column arrived with canvas. Canvas does not last: the wind takes it, and
## what the wind leaves gets burned. This is why the opening hours are survivable
## and why the third day is not, and it is the clock the whole first act runs on.
const TENT_CAPACITY: float = 64.0
const TENT_LIFE_DAYS: float = 3.0
## Degrees a sheet of canvas is worth on its own.
const TENT_BONUS_C: float = 6.0
## Degrees a lit heat source is worth to the people camped around it.
const TENT_HEARTH_C: float = 5.0
const TENT_HEARTH_MAX_C: float = 18.0

var authoritative: bool = true      ## false once [P05] answers

var population: float = 0.0
var sick: float = 0.0
var homeless: float = 0.0
var sheltered: float = 0.0
var tented: float = 0.0
var tent_capacity: float = TENT_CAPACITY
var camp_temp_c: float = 0.0
var hunger_share: float = 0.0
var crowding: float = 0.0
var exposure: float = 0.0           ## 0..1, population weighted cold stress
var corpses: float = 0.0

var deaths_total: float = 0.0
var deaths_today: float = 0.0
var deaths_by_cause: Dictionary[StringName, float] = {}
var arrivals_total: float = 0.0

var _death_accum: Dictionary[StringName, float] = {}
var _arrival_accum: float = 0.0
var _famine_hours: float = 0.0
var _citizens_deaths_seen: float = -1.0


func reset() -> void:
	authoritative = true
	population = SocietyDefs.START_POPULATION
	sick = 0.0
	homeless = 0.0
	sheltered = 0.0
	tented = 0.0
	tent_capacity = TENT_CAPACITY
	camp_temp_c = 0.0
	hunger_share = 0.0
	crowding = 0.0
	exposure = 0.0
	corpses = 0.0
	deaths_total = 0.0
	deaths_today = 0.0
	deaths_by_cause.clear()
	arrivals_total = 0.0
	_death_accum.clear()
	_arrival_accum = 0.0
	_famine_hours = 0.0
	_citizens_deaths_seen = -1.0


## Advances the people by `hours`. Returns the events that happened, each with
## enough detail to write a sentence: {kind, cause, count, detail}.
func step(reading: SocietyReading, book: LawBook, hours: float) -> Array[Dictionary]:
	if reading.citizens_authoritative():
		return _mirror_citizens(reading)
	authoritative = true
	if hours <= 0.0:
		return []
	return _model(reading, book, hours)


## [P05] has landed. Stop modelling, start reporting.
func _mirror_citizens(reading: SocietyReading) -> Array[Dictionary]:
	authoritative = false
	population = maxf(0.0, reading.citizens_population)
	if reading.citizens_sick >= 0.0:
		sick = reading.citizens_sick
	if reading.citizens_homeless >= 0.0:
		homeless = reading.citizens_homeless
		sheltered = maxf(0.0, population - homeless)
	else:
		sheltered = minf(population, reading.housing_capacity)
		homeless = maxf(0.0, population - sheltered)
	if reading.citizens_food_days >= 0.0:
		hunger_share = clampf(1.0 - reading.citizens_food_days, 0.0, 1.0)
	var out: Array[Dictionary] = []
	var total: float = maxf(0.0, reading.citizens_deaths_total)
	if _citizens_deaths_seen < 0.0:
		_citizens_deaths_seen = total
		deaths_total = total
		return out
	var fresh: int = int(floor(total - _citizens_deaths_seen))
	if fresh > 0:
		_citizens_deaths_seen += float(fresh)
		deaths_total = total
		deaths_today += float(fresh)
		corpses += float(fresh)
		_bump_cause(&"reported", float(fresh))
		out.append({
			"kind": &"death", "cause": &"reported", "count": fresh,
			"detail": "%s died." % SocietyDefs.sentence(SocietyDefs.people(fresh)),
		})
	return out


func _model(reading: SocietyReading, book: LawBook, hours: float) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var pop: float = maxf(0.0, population)
	if pop <= 0.0:
		return events

	# --- shelter -----------------------------------------------------------
	# Three tiers, and the difference between them is who is alive at dawn:
	# a heated room, a sheet of canvas near the fire, and the open ice.
	var seats: float = reading.housing_capacity * maxf(0.1, book.policy_value(&"shelter_capacity"))
	var canvas: float = tent_capacity * maxf(0.1, book.policy_value(&"shelter_capacity"))
	sheltered = minf(pop, seats)
	tented = minf(pop - sheltered, canvas)
	homeless = maxf(0.0, pop - sheltered - tented)
	crowding = maxf(0.0, book.policy_value(&"crowding"))
	if seats > 0.0:
		crowding += clampf(sheltered / seats - 0.85, 0.0, 1.0)
	if tented > 0.0:
		crowding += 0.25 * clampf(tented / maxf(pop, 1.0), 0.0, 1.0)

	# --- cold --------------------------------------------------------------
	camp_temp_c = reading.outdoor_c + TENT_BONUS_C \
		+ minf(float(reading.hearths_lit) * TENT_HEARTH_C, TENT_HEARTH_MAX_C)
	var indoor: float = _stress(reading.home_temp_avg, SocietyDefs.LETHAL_C)
	var camp: float = _stress(camp_temp_c, SocietyDefs.LETHAL_C)
	var outdoor: float = _stress(reading.outdoor_c, SocietyDefs.OUTDOOR_FLOOR_C)
	if reading.homes_total == 0:
		indoor = camp
	exposure = ((sheltered * indoor) + (tented * camp) + (homeless * outdoor)) / maxf(pop, 1.0)

	# --- food --------------------------------------------------------------
	var ration: float = maxf(0.15, book.policy_value(&"ration"))
	var yield_mult: float = maxf(0.25, book.policy_value(&"food_yield"))
	var need: float = pop * ration
	var supply: float = reading.food_capacity_per_day * yield_mult
	var raw_hunger: float = 0.0 if need <= 0.001 else clampf(1.0 - supply / need, 0.0, 1.0)
	hunger_share = raw_hunger * clampf(1.0 - 0.4 * reading.food_reserve_days, 0.15, 1.0)
	if hunger_share >= FAMINE_HUNGER_LINE:
		_famine_hours += hours
	else:
		_famine_hours = maxf(0.0, _famine_hours - hours * 2.0)

	# --- sickness ----------------------------------------------------------
	var strain: float = clampf((book.policy_value(&"work_hours") - 10.0) / 8.0, 0.0, 1.0)
	var child_risk: float = maxf(0.0, book.policy_value(&"child_risk"))
	var care: float = clampf(book.policy_value(&"medical_care"), 0.15, 3.0)
	var pressure: float = 0.80 * exposure + 0.60 * hunger_share + 0.45 * crowding \
		+ 0.40 * strain + child_risk
	sick += pop * SocietyDefs.SICKEN_PER_HOUR * pressure * hours
	sick -= sick * SocietyDefs.RECOVER_PER_HOUR * care * hours
	sick = clampf(sick, 0.0, pop)

	# --- death -------------------------------------------------------------
	var from_sick: float = sick * SocietyDefs.MORTALITY_PER_HOUR / care * hours
	var from_cold: float = homeless * outdoor * SocietyDefs.EXPOSURE_MORTALITY_PER_HOUR * hours
	from_cold += (sheltered * maxf(0.0, indoor - INDOOR_LETHAL_FRACTION)
		+ tented * maxf(0.0, camp - INDOOR_LETHAL_FRACTION)) \
		* INDOOR_LETHAL_GAIN * SocietyDefs.EXPOSURE_MORTALITY_PER_HOUR * hours
	var from_hunger: float = 0.0
	if _famine_hours > FAMINE_ONSET_HOURS:
		from_hunger = pop * hunger_share * FAMINE_MORTALITY_PER_HOUR \
			* clampf((_famine_hours - FAMINE_ONSET_HOURS) / 12.0, 0.0, 1.0) * hours

	events.append_array(_kill(&"sickness", from_sick, reading))
	events.append_array(_kill(&"cold", from_cold, reading))
	events.append_array(_kill(&"hunger", from_hunger, reading))

	# --- the dead ----------------------------------------------------------
	var handled: float = maxf(0.0, book.policy_value(&"corpse_capacity")) * hours / SocietyDefs.HOURS_PER_DAY
	corpses = maxf(0.0, corpses - handled)

	# --- the canvas runs out -----------------------------------------------
	tent_capacity = maxf(0.0, tent_capacity
		- TENT_CAPACITY / (TENT_LIFE_DAYS * SocietyDefs.HOURS_PER_DAY) * hours)

	population = maxf(0.0, population)
	return events


## Whole deaths only. Fractions carry over so a slow trickle still eventually
## costs someone, and a single tick can never quietly erase half a person.
func _kill(cause: StringName, amount: float, reading: SocietyReading) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if amount <= 0.0:
		return out
	var acc: float = float(_death_accum.get(cause, 0.0)) + amount
	var whole: int = int(floor(acc))
	_death_accum[cause] = acc - float(whole)
	if whole <= 0:
		return out
	whole = mini(whole, int(ceil(population)))
	if whole <= 0:
		return out
	population = maxf(0.0, population - float(whole))
	if cause == &"sickness":
		sick = maxf(0.0, sick - float(whole))
	deaths_total += float(whole)
	deaths_today += float(whole)
	corpses += float(whole)
	_bump_cause(cause, float(whole))
	out.append({
		"kind": &"death",
		"cause": cause,
		"count": whole,
		"detail": _death_sentence(cause, whole, reading),
	})
	return out


func _death_sentence(cause: StringName, n: int, reading: SocietyReading) -> String:
	var who: String = SocietyDefs.sentence(SocietyDefs.people(n))
	match cause:
		&"cold":
			if homeless > 0.5:
				return "%s froze. They had no bunk and no canvas, and the night was %.0f below." % [
					who, absf(reading.outdoor_c)]
			if reading.homes_total == 0 or tented > sheltered:
				return "%s froze under canvas. The camp was at %.0f degrees." % [who, camp_temp_c]
			return "%s froze in their beds. The rooms were at %.0f degrees." % [
				who, reading.home_temp_avg]
		&"sickness":
			return "%s died of the fever. There are %s still coughing." % [
				who, SocietyDefs.people(int(round(sick)))]
		&"hunger":
			return "%s starved. The kitchens have been short for the better part of a day." % who
	return "%s died." % who


func _bump_cause(cause: StringName, n: float) -> void:
	deaths_by_cause[cause] = float(deaths_by_cause.get(cause, 0.0)) + n


## Called at dawn. Newcomers only walk in when word of the city is good.
func dawn(reading: SocietyReading, hope: float) -> Array[Dictionary]:
	deaths_today = 0.0
	if not authoritative:
		return []
	var events: Array[Dictionary] = []
	var seats: float = reading.housing_capacity
	if hope < SocietyDefs.ARRIVAL_HOPE_FLOOR or seats <= population + 0.5:
		return events
	var room: float = seats - population
	var want: float = minf(SocietyDefs.ARRIVALS_PER_DAWN, room) * clampf(hope / 100.0 + 0.35, 0.0, 1.2)
	_arrival_accum += want
	var whole: int = int(floor(_arrival_accum))
	if whole <= 0:
		return events
	_arrival_accum -= float(whole)
	population += float(whole)
	arrivals_total += float(whole)
	events.append({
		"kind": &"arrival",
		"cause": &"newcomers",
		"count": whole,
		"detail": "%s walked in out of the white at first light. They had heard there was a fire here."
			% SocietyDefs.sentence(SocietyDefs.people(whole)),
	})
	return events


func _stress(celsius: float, floor_c: float) -> float:
	var span: float = maxf(1.0, SocietyDefs.COMFORT_C - floor_c)
	return clampf((SocietyDefs.COMFORT_C - celsius) / span, 0.0, 1.0)


func serialize() -> Dictionary:
	var causes: Dictionary = {}
	for k: StringName in SocietyDefs.sorted_keys(deaths_by_cause):
		causes[String(k)] = snappedf(float(deaths_by_cause[k]), 0.01)
	return {
		"authoritative": authoritative,
		"population": snappedf(population, 0.01),
		"sheltered": snappedf(sheltered, 0.01),
		"tented": snappedf(tented, 0.01),
		"tent_capacity": snappedf(tent_capacity, 0.01),
		"camp_temp_c": snappedf(camp_temp_c, 0.01),
		"homeless": snappedf(homeless, 0.01),
		"sick": snappedf(sick, 0.01),
		"hunger_share": snappedf(hunger_share, 0.001),
		"exposure": snappedf(exposure, 0.001),
		"crowding": snappedf(crowding, 0.001),
		"corpses": snappedf(corpses, 0.01),
		"deaths_total": snappedf(deaths_total, 0.01),
		"deaths_today": snappedf(deaths_today, 0.01),
		"deaths_by_cause": causes,
		"arrivals_total": snappedf(arrivals_total, 0.01),
		"famine_hours": snappedf(_famine_hours, 0.01),
	}


func deserialize(data: Dictionary) -> void:
	reset()
	authoritative = bool(data.get("authoritative", true))
	population = float(data.get("population", SocietyDefs.START_POPULATION))
	sheltered = float(data.get("sheltered", 0.0))
	tented = float(data.get("tented", 0.0))
	tent_capacity = float(data.get("tent_capacity", TENT_CAPACITY))
	camp_temp_c = float(data.get("camp_temp_c", 0.0))
	homeless = float(data.get("homeless", 0.0))
	sick = float(data.get("sick", 0.0))
	hunger_share = float(data.get("hunger_share", 0.0))
	exposure = float(data.get("exposure", 0.0))
	crowding = float(data.get("crowding", 0.0))
	corpses = float(data.get("corpses", 0.0))
	deaths_total = float(data.get("deaths_total", 0.0))
	deaths_today = float(data.get("deaths_today", 0.0))
	arrivals_total = float(data.get("arrivals_total", 0.0))
	_famine_hours = float(data.get("famine_hours", 0.0))
	var causes: Dictionary = data.get("deaths_by_cause", {})
	var names: Array = causes.keys()
	names.sort_custom(func(a: Variant, b: Variant) -> bool: return String(a) < String(b))
	for k: Variant in names:
		deaths_by_cause[StringName(String(k))] = float(causes[k])
