class_name SocietyDefs
extends RefCounted
## [P06] Shared vocabulary for hope, discontent, laws, factions and grievances.
##
## Everything another part needs to bind against lives here as a constant, so no
## file outside this folder ever types a society string literal.
##
## UNITS. Every continuous pressure in this part is a RATE IN METER POINTS PER
## IN-WORLD HOUR. A day is 24 hours long whatever the climate profile says a day
## is in ticks, so tuning stays readable: "+3 discontent per hour" is a number a
## designer can reason about, and SocietySystem converts it to per-tick exactly
## once, in one place.


# =========================================================================
#  meters
# =========================================================================

const METER_MAX: float = 100.0
const HOPE_START: float = 55.0
const DISCONTENT_START: float = 6.0

## Ticks between world samples. Meters integrate every tick; the world is only
## re-read at this cadence, which is what keeps step() cheap.
const SAMPLE_EVERY: int = 20

const HOURS_PER_DAY: float = 24.0
const DEFAULT_DAY_TICKS: int = 9600

const METER_HOPE: StringName = &"hope"
const METER_DISCONTENT: StringName = &"discontent"

## Hope bleeds away on its own. A city that is merely not dying is still losing.
const HOPE_DRIFT_PER_HOUR: float = -0.22
## Discontent settles when nothing is wrong, but slowly, and never to zero while
## a grievance is open.
const DISCONTENT_SETTLE_PER_HOUR: float = -0.55


# =========================================================================
#  the escalation ladder: both losses are telegraphed, never sudden
# =========================================================================

## Discontent rungs. Crossing one raises a worded warning; the top one starts a
## countdown that the player can still stop.
const UNREST_MURMUR: float = 50.0
const UNREST_WARNING: float = 70.0
const UNREST_FINAL: float = 86.0
const UNREST_ULTIMATUM: float = 99.5
## Fall back below this while the ultimatum runs and the crowd goes home.
const UNREST_RELIEF: float = 80.0
const UNREST_ULTIMATUM_HOURS: float = 12.0

## Hope rungs, read downward.
const DESPAIR_MURMUR: float = 32.0
const DESPAIR_WARNING: float = 20.0
const DESPAIR_FINAL: float = 9.0
const DESPAIR_VIGIL: float = 0.5
const DESPAIR_RELIEF: float = 14.0
const DESPAIR_VIGIL_HOURS: float = 12.0

const REASON_EXILE: String = "exiled"
const REASON_DESPAIR: String = "despair"


# =========================================================================
#  Bus keys: narrative_event ids and alert keys
# =========================================================================

const EV_LAW_PROPOSED: StringName = &"society_law_proposed"
const EV_LAW_SIGNED: StringName = &"society_law_signed"
const EV_LAW_REFUSED: StringName = &"society_law_refused"
const EV_GRIEVANCE_OPENED: StringName = &"society_grievance_opened"
const EV_GRIEVANCE_CLOSED: StringName = &"society_grievance_closed"
const EV_DEMAND_MADE: StringName = &"society_demand_made"
const EV_DEMAND_MET: StringName = &"society_demand_met"
const EV_DEMAND_FAILED: StringName = &"society_demand_failed"
const EV_UNREST: StringName = &"society_unrest"
const EV_DESPAIR: StringName = &"society_despair"
const EV_ULTIMATUM: StringName = &"society_ultimatum"
const EV_ULTIMATUM_LIFTED: StringName = &"society_ultimatum_lifted"
const EV_DEATHS: StringName = &"society_deaths"
const EV_ARRIVALS: StringName = &"society_arrivals"

## Bus.alert_raised severity. The harness fails a run on severity >= 2, and a
## city in trouble is gameplay, not a fault, so society never goes above 1.
const SEV_NOTE: int = 0
const SEV_WARN: int = 1


# =========================================================================
#  factions
# =========================================================================

const FACTION_WORKERS: StringName = &"workers"
const FACTION_FAMILIES: StringName = &"families"
const FACTION_INFIRM: StringName = &"infirm"
const FACTION_FAITHFUL: StringName = &"faithful"
const FACTION_WATCH: StringName = &"watch"
const FACTION_LATECOMERS: StringName = &"latecomers"

## Sorted. Every iteration over factions goes through this array so ordering is
## never left to a Dictionary.
const FACTION_IDS: Array[StringName] = [
	&"faithful", &"families", &"infirm", &"latecomers", &"watch", &"workers",
]

## id -> {name, of_whom, share}. Shares overlap on purpose: a woman on the
## night shift is in The Shift and in the Hearthside both, and that is exactly
## why laws that please one enrage the other.
const FACTIONS: Dictionary = {
	&"workers": {
		"name": "The Shift",
		"of_whom": "the people who go down the shaft and into the workshops",
		"share": 0.55,
	},
	&"families": {
		"name": "The Hearthside",
		"of_whom": "everyone with a child asleep in the next room",
		"share": 0.34,
	},
	&"infirm": {
		"name": "The Care House",
		"of_whom": "the sick, the frostbitten and the too old to lift",
		"share": 0.16,
	},
	&"faithful": {
		"name": "The Ember Congregation",
		"of_whom": "those who kneel at the generator and call it something else",
		"share": 0.22,
	},
	&"watch": {
		"name": "The Watch",
		"of_whom": "the ones who volunteered to stand in the cold and be obeyed",
		"share": 0.11,
	},
	&"latecomers": {
		"name": "The Latecomers",
		"of_whom": "the column that arrived after the walls went up",
		"share": 0.13,
	},
}

const APPROVAL_MIN: float = -100.0
const APPROVAL_MAX: float = 100.0
## Approval creeps back toward indifference when a faction is left alone.
const APPROVAL_DRIFT_PER_HOUR: float = 0.35


# =========================================================================
#  grievances
# =========================================================================

const GRIEVANCE_IDS: Array[StringName] = [
	&"children", &"cold", &"dead_unburied", &"disorder", &"faithless",
	&"fear", &"homeless", &"hunger", &"overwork", &"sickness",
]

## id -> {faction, title, complaint, resolved}. `complaint` is what the crowd
## says; SocietySystem splices the real numbers into `detail` separately.
const GRIEVANCES: Dictionary = {
	&"cold": {
		"faction": &"families",
		"title": "The houses are cold",
		"complaint": "There is frost on the inside of the windows and it does not melt at noon.",
		"resolved": "The rooms are warm enough to undress in. Nobody says thank you, but the shouting stopped.",
	},
	&"hunger": {
		"faction": &"workers",
		"title": "There is not enough food",
		"complaint": "A man cannot swing a pick on a bowl of grey water and be expected to hit the same spot twice.",
		"resolved": "The queue at the kitchen moves and everyone in it gets fed.",
	},
	&"overwork": {
		"faction": &"workers",
		"title": "The shifts do not end",
		"complaint": "We came off the ice at midnight and were back on it before the light. Two of us did not get up.",
		"resolved": "The shift ends when the whistle says it ends. People have started sleeping again.",
	},
	&"children": {
		"faction": &"families",
		"title": "The children",
		"complaint": "You have our children. We would like to know what you are doing with them.",
		"resolved": "The children are where their parents can see them.",
	},
	&"sickness": {
		"faction": &"infirm",
		"title": "The fever",
		"complaint": "It goes room to room in the order the bunks are laid out. You can predict who is next.",
		"resolved": "The coughing has thinned out. There are empty beds in the care house for the first time.",
	},
	&"dead_unburied": {
		"faction": &"faithful",
		"title": "The dead are still here",
		"complaint": "They are stacked by the east wall under a tarp and the tarp is not long enough.",
		"resolved": "The dead have somewhere to be that is not the east wall.",
	},
	&"homeless": {
		"faction": &"latecomers",
		"title": "There is nowhere to sleep",
		"complaint": "We were told there was room. We are sleeping in the lee of a wall with our backs together.",
		"resolved": "Everyone has a roof. It is a low roof and a hard bunk, but it is a roof.",
	},
	&"fear": {
		"faction": &"families",
		"title": "People are afraid of you",
		"complaint": "Nobody argues in the street any more. They wait until they are indoors, and then they whisper.",
		"resolved": "There is arguing in the street again. It is a good sound.",
	},
	&"faithless": {
		"faction": &"faithful",
		"title": "You have no reverence",
		"complaint": "You keep the fire and you will not say what it is. A city needs something to kneel to.",
		"resolved": "There is a place to kneel and a time to do it.",
	},
	&"disorder": {
		"faction": &"watch",
		"title": "Nobody is in charge",
		"complaint": "There were three fights at the ration line today and nobody stopped any of them.",
		"resolved": "There is a rule, it is written down, and it is being kept.",
	},
}

## Pressure below which a grievance starts to close, and above which one opens.
const GRIEVANCE_OPEN: float = 0.34
const GRIEVANCE_CLOSE: float = 0.16
## Sustained hours above/below the line before the state actually flips.
const GRIEVANCE_OPEN_HOURS: float = 1.5
const GRIEVANCE_CLOSE_HOURS: float = 1.0
## How fast intensity chases pressure once open, in units per hour.
const GRIEVANCE_RISE_PER_HOUR: float = 0.55
const GRIEVANCE_FALL_PER_HOUR: float = 0.40
## Discontent per hour at full intensity for a grievance held by everyone.
const GRIEVANCE_DISCONTENT_PER_HOUR: float = 5.0
## Hope lost per hour the same way. Grievances hurt hope less than they anger.
const GRIEVANCE_HOPE_PER_HOUR: float = -1.6

const DEMAND_INTENSITY: float = 0.68
const DEMAND_HOURS_BASE: float = 10.0
const DEMAND_HOURS_MIN: float = 4.0
## Each time a faction is failed it radicalises; every step shortens the fuse
## and sharpens the penalty.
const RADICAL_MAX: int = 3

const DEMAND_MET_HOPE: float = 6.0
const DEMAND_MET_DISCONTENT: float = -9.0
const DEMAND_MET_APPROVAL: float = 22.0
const DEMAND_FAILED_HOPE: float = -5.0
const DEMAND_FAILED_DISCONTENT: float = 12.0
const DEMAND_FAILED_APPROVAL: float = -26.0


# =========================================================================
#  laws
# =========================================================================

const LAW_CATEGORY: String = "laws"

const BRANCH_TRUNK: StringName = &"trunk"
const BRANCH_ORDER: StringName = &"order"
const BRANCH_FAITH: StringName = &"faith"

const BRANCH_IDS: Array[StringName] = [&"faith", &"order", &"trunk"]

const BRANCH_TITLES: Dictionary = {
	&"trunk": "Necessity",
	&"order": "The Watch",
	&"faith": "The Ember Congregation",
}

## Hours the seal takes to dry. The player cannot sign a second law until this
## has elapsed after the last one came into force, which is what makes a law a
## decision rather than a shopping list.
const SIGN_COOLDOWN_HOURS: float = 18.0
## Hours a law spends being argued before it is in force. Per law, defaulted.
const DEFAULT_DEBATE_HOURS: float = 4.0

## Policy keys, with the value the city has before any law touches them.
## `policy_value(key)` returns default + the sum of every signed law's offset.
const POLICY_DEFAULTS: Dictionary = {
	&"work_hours": 10.0,          ## hours on shift per day
	&"ration": 1.0,               ## share of a full ration actually served
	&"food_yield": 1.0,           ## how far a unit of food stretches
	&"labour_pool": 1.0,          ## multiplier on hands available for work
	&"medical_care": 1.0,         ## multiplier on recovery from sickness
	&"shelter_capacity": 1.0,     ## multiplier on how many a house holds
	&"discipline": 0.0,           ## suppression of discontent, 0 .. ~1.5
	&"solace": 0.0,               ## hope support that costs no heat
	&"corpse_capacity": 0.0,      ## bodies handled per day, 0 means they pile up
	&"child_risk": 0.0,           ## added mortality on the youngest
	&"heat_priority_housing": 0.0,## how hard housing is favoured after dark
	&"crowding": 0.0,             ## added sickness pressure from packed rooms
}

const POLICY_KEYS: Array[StringName] = [
	&"child_risk", &"corpse_capacity", &"crowding", &"discipline", &"food_yield",
	&"heat_priority_housing", &"labour_pool", &"medical_care", &"ration",
	&"shelter_capacity", &"solace", &"work_hours",
]

## Flags a law can raise. Set membership, never a count.
const FLAG_CHILD_LABOUR: StringName = &"child_labour"
const FLAG_SAWDUST: StringName = &"sawdust"
const FLAG_FIGHTING_PIT: StringName = &"fighting_pit"
const FLAG_INFORMERS: StringName = &"informers"
const FLAG_MARTIAL_LAW: StringName = &"martial_law"
const FLAG_RENDERING: StringName = &"rendering"
const FLAG_NAMED_GRAVES: StringName = &"named_graves"
const FLAG_TRIAGE: StringName = &"triage"
const FLAG_PRESS_GANGS: StringName = &"press_gangs"
const FLAG_CURFEW: StringName = &"curfew"
const FLAG_PRAYER: StringName = &"prayer"
const FLAG_ZEALOTS: StringName = &"zealots"
const FLAG_NEW_ORDER: StringName = &"new_order"
const FLAG_NEW_FAITH: StringName = &"new_faith"
## Read by [P05]: the old are put back on the work roster.
const FLAG_ELDER_LABOUR: StringName = &"elder_labour"


# =========================================================================
#  the human model: only authoritative while [P05] citizens is absent
# =========================================================================

## Degrees at which a room stops costing people their health.
const COMFORT_C: float = 12.0
## Below this a room is actively killing whoever sleeps in it.
const LETHAL_C: float = -12.0
const OUTDOOR_FLOOR_C: float = -40.0

const START_POPULATION: float = 42.0
const ARRIVALS_PER_DAWN: float = 5.0
const ARRIVAL_HOPE_FLOOR: float = 38.0

## Per person per hour at full cold stress.
const SICKEN_PER_HOUR: float = 0.09
const RECOVER_PER_HOUR: float = 0.16
## Share of the sick who die per hour with no care at all.
const MORTALITY_PER_HOUR: float = 0.020
## Someone sleeping outside at full stress, per hour.
const EXPOSURE_MORTALITY_PER_HOUR: float = 0.055

const DEATH_HOPE: float = -2.6
const DEATH_DISCONTENT: float = 3.4


static func faction_name(id: StringName) -> String:
	var f: Dictionary = FACTIONS.get(id, {})
	return String(f.get("name", String(id)))


static func faction_share(id: StringName) -> float:
	var f: Dictionary = FACTIONS.get(id, {})
	return float(f.get("share", 0.1))


static func faction_of_whom(id: StringName) -> String:
	var f: Dictionary = FACTIONS.get(id, {})
	return String(f.get("of_whom", ""))


static func grievance_faction(id: StringName) -> StringName:
	var g: Dictionary = GRIEVANCES.get(id, {})
	return StringName(String(g.get("faction", FACTION_WORKERS)))


static func grievance_title(id: StringName) -> String:
	var g: Dictionary = GRIEVANCES.get(id, {})
	return String(g.get("title", String(id)))


static func grievance_complaint(id: StringName) -> String:
	var g: Dictionary = GRIEVANCES.get(id, {})
	return String(g.get("complaint", ""))


static func grievance_resolved(id: StringName) -> String:
	var g: Dictionary = GRIEVANCES.get(id, {})
	return String(g.get("resolved", ""))


static func policy_default(key: StringName) -> float:
	return float(POLICY_DEFAULTS.get(key, 0.0))


static func branch_title(id: StringName) -> String:
	return String(BRANCH_TITLES.get(id, String(id)))


## English count for prose. Numbers written out read as a person speaking;
## digits read as a spreadsheet, and this part is meant to sound like a person.
static func spell(n: int) -> String:
	const WORDS: Array[String] = [
		"no", "one", "two", "three", "four", "five", "six", "seven", "eight",
		"nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
		"sixteen", "seventeen", "eighteen", "nineteen", "twenty",
	]
	if n >= 0 and n < WORDS.size():
		return WORDS[n]
	return str(n)


## "one person" / "three people".
static func people(n: int) -> String:
	return "%s %s" % [spell(n), "person" if n == 1 else "people"]


## "is" / "are" for a spelled count.
static func is_are(n: int) -> String:
	return "is" if n == 1 else "are"


## Start of a sentence. String.capitalize() title cases every word, which turns
## "one person" into "One Person" and makes the whole part read like a form.
static func sentence(s: String) -> String:
	if s.is_empty():
		return s
	return s.substr(0, 1).to_upper() + s.substr(1)


## Lexicographic sort of StringNames. USE THIS, NEVER Array.sort().
##
## `Array[StringName].sort()` does NOT sort alphabetically. StringName's
## comparison operator compares the interned pointer, so the result is
## allocation order: [&"zebra", &"alpha", &"middle"].sort() returns
## [&"zebra", &"middle", &"alpha"]. It looks sorted at a glance and it is stable
## within one process, which is exactly why it survives a determinism check that
## compares two fresh processes and then diverges the moment the same process
## builds the same set twice in a different order.
##
## Found the hard way: two identical seeded society runs in one process produced
## different serialize() output, because a ledger key interned during the first
## run changed the pointer order of the second.
static func sorted_names(names: Array) -> Array[StringName]:
	var copy: Array = names.duplicate()
	copy.sort_custom(func(a: Variant, b: Variant) -> bool: return String(a) < String(b))
	var out: Array[StringName] = []
	for n: Variant in copy:
		out.append(StringName(String(n)))
	return out


## The same, for the keys of any Dictionary keyed by StringName.
static func sorted_keys(d: Dictionary) -> Array[StringName]:
	return sorted_names(d.keys())
