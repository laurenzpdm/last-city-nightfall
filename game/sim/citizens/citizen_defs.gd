class_name CitizenDefs
extends RefCounted
## [P05] Shared vocabulary and the whole balance table for the population.
##
## Everything a citizen IS lives here as data: the states they can be in, the
## brackets they age through, the trades they can hold, the names they can carry
## and every rate that turns a cold night into a funeral. Other parts compare
## against the StringName tables rather than the raw ints so the enums can grow.
##
## The numbers are quoted per SECOND of in-world time, never per tick, so they
## survive a change of tick rate. One day is 9600 ticks = 480 seconds.

# ==========================================================================
#  states
# ==========================================================================

## What a citizen is doing right now. Serialized as an int; values are frozen.
enum State {
	IDLE = 0,       ## awake, off shift, nothing to do — mills about near shelter
	WALKING = 1,    ## en route to a destination
	WORKING = 2,    ## on station at a job site, contributing to its output
	SLEEPING = 3,   ## in a bed, burning off fatigue
	EATING = 4,     ## taking a meal; a short, visible pause
	SICK = 5,       ## illness has taken them off the roster
	INJURED = 6,    ## hurt at work, out of action until it heals
	DEAD = 7,       ## the slot is a memory now
}

const STATE_NAMES: Array[StringName] = [
	&"idle", &"walking", &"working", &"sleeping", &"eating", &"sick", &"injured", &"dead",
]

const STATE_LABELS: Array[String] = [
	"idle", "walking", "working", "asleep", "eating", "sick", "injured", "dead",
]

enum Age { CHILD = 0, ADULT = 1, ELDER = 2 }

const AGE_NAMES: Array[StringName] = [&"child", &"adult", &"elder"]
const AGE_LABELS: Array[String] = ["child", "adult", "elder"]

const CHILD_MAX_AGE: int = 14
const ELDER_MIN_AGE: int = 60

## Which rotation a citizen belongs to. OFF is children, elders and the unfit.
enum Shift { DAY = 0, NIGHT = 1, OFF = 2 }

const SHIFT_NAMES: Array[StringName] = [&"day", &"night", &"off"]
const SHIFT_LABELS: Array[String] = ["day shift", "night shift", "off duty"]

## Cause carried by Bus.citizen_died. [P06] society and [P22] narrative branch
## on these, so they are a contract: add, never rename.
const CAUSE_COLD: StringName = &"cold"
const CAUSE_STARVATION: StringName = &"starvation"
const CAUSE_ILLNESS: StringName = &"illness"
const CAUSE_INJURY: StringName = &"injury"
const CAUSE_OLD_AGE: StringName = &"old_age"
const CAUSE_EXHAUSTION: StringName = &"exhaustion"

const CAUSE_PHRASES: Dictionary[StringName, String] = {
	&"cold": "froze",
	&"starvation": "starved",
	&"illness": "died of fever",
	&"injury": "died of their injuries",
	&"old_age": "died of old age",
	&"exhaustion": "worked themselves to death",
}

# ==========================================================================
#  trades
# ==========================================================================

## Index-aligned tables. The profession a citizen holds is derived from the
## building they work in, by TAG first and CATEGORY second — no code in this
## folder knows the name of a single building.
enum Trade {
	LABOURER = 0, STOKER = 1, TINSMITH = 2, DIGGER = 3,
	HAULER = 4, COOK = 5, GUNNER = 6, WARDEN = 7,
	MEDIC = 8, CHILD = 9, ELDER = 10,
}

const TRADE_NAMES: Array[StringName] = [
	&"labourer", &"stoker", &"tinsmith", &"digger", &"hauler",
	&"cook", &"gunner", &"warden", &"medic", &"child", &"elder",
]

const TRADE_LABELS: Array[String] = [
	"labourer", "stoker", "tinsmith", "digger", "hauler",
	"cook", "gunner", "warden", "medic", "child", "pensioner",
]

## Tag -> trade, checked before the category table. First match in this order.
const TRADE_BY_TAG: Array = [
	[&"medical", Trade.MEDIC],
	[&"food", Trade.COOK],
	[&"turret", Trade.GUNNER],
	[&"defense", Trade.GUNNER],
	[&"extractor", Trade.DIGGER],
	[&"salvage", Trade.DIGGER],
	[&"heat_source", Trade.STOKER],
	[&"radiator", Trade.STOKER],
	[&"conduit", Trade.STOKER],
	[&"crafter", Trade.TINSMITH],
	[&"machine", Trade.TINSMITH],
	[&"storage", Trade.HAULER],
	[&"housing", Trade.WARDEN],
]

const TRADE_BY_CATEGORY: Dictionary[StringName, int] = {
	&"power": Trade.STOKER,
	&"heat": Trade.STOKER,
	&"extraction": Trade.DIGGER,
	&"production": Trade.TINSMITH,
	&"logistics": Trade.HAULER,
	&"storage": Trade.HAULER,
	&"housing": Trade.WARDEN,
	&"defense": Trade.GUNNER,
	&"medical": Trade.MEDIC,
}

## Buildings carrying this tag treat the sick. Drop a .tres with it into
## game/content/buildings/ and it becomes an infirmary; nothing here changes.
const TAG_MEDICAL: StringName = &"medical"
const TAG_FOOD: StringName = &"food"
const TAG_COMFORT: StringName = &"comfort"
## Somewhere a worker can get hurt: presses, drills, furnaces.
const HAZARD_TAGS: Array[StringName] = [&"machine", &"extractor", &"crafter", &"salvage"]

# ==========================================================================
#  traits — the reason two citizens in the same room are not the same number
# ==========================================================================

enum Trait { STEADY = 0, HARDY = 1, FRAIL = 2, RESTLESS = 3, STOIC = 4, SICKLY = 5 }

const TRAIT_NAMES: Array[StringName] = [
	&"steady", &"hardy", &"frail", &"restless", &"stoic", &"sickly",
]

const TRAIT_LABELS: Array[String] = [
	"steady", "hardy", "frail", "restless", "stoic", "sickly",
]

## Multiplier on how fast the cold reaches them. Lower is tougher.
const TRAIT_COLD: Array[float] = [1.0, 0.68, 1.35, 1.05, 0.85, 1.15]
## Multiplier on illness accumulation.
const TRAIT_SICK: Array[float] = [1.0, 0.8, 1.25, 1.0, 0.9, 1.6]
## Multiplier on work output and on fatigue gained doing it.
const TRAIT_WORK: Array[float] = [1.0, 1.05, 0.9, 1.15, 1.0, 0.85]
## Multiplier on how fast morale sags. Stoics barely complain.
const TRAIT_MORALE: Array[float] = [1.0, 0.95, 1.2, 1.1, 0.7, 1.15]

# ==========================================================================
#  need model — every rate is PER SECOND of in-world time
# ==========================================================================

## Needs run 0..100. warmth and morale are "more is better"; hunger, fatigue,
## illness and injury are "more is worse". health is 0..100, 0 is death.
const NEED_MAX: float = 100.0

## Felt temperature that reads as fully warm, and the one that reads as zero.
const WARM_COMFORT_C: float = 18.0
const WARM_LETHAL_C: float = -35.0
## How fast body warmth converges on what the air is doing, per second.
const WARM_GAIN_RATE: float = 0.085
const WARM_LOSS_RATE: float = 0.055
## Degrees a roof, a door and a stove pipe are worth on top of the heat field.
const SHELTER_C: float = 9.0
## A building starved of heat is barely better than the street.
const SHELTER_MIN_FACTOR: float = 0.25
## Wind strips warmth off anyone standing outdoors. Multiplies the loss rate.
const WIND_CHILL: float = 0.55

## Hunger climbs this fast while awake; sleeping bodies burn a little less.
const HUNGER_PER_SEC: float = 0.30
const HUNGER_SLEEP_FACTOR: float = 0.6
const HUNGER_CHILD_FACTOR: float = 0.75
## Above this a citizen wants a meal; a meal takes this much off.
const HUNGER_MEAL_WANT: float = 52.0
const HUNGER_MEAL_RELIEF: float = 62.0
## Above this the body starts eating itself.
const HUNGER_STARVING: float = 88.0
const STARVE_HEALTH_PER_SEC: float = 0.17
## Ticks a meal takes. Long enough to see, short enough not to stall a shift.
const EAT_TICKS: int = 40

## Fatigue while working, while merely awake, and recovery in a bed.
const FATIGUE_WORK_PER_SEC: float = 0.26
const FATIGUE_AWAKE_PER_SEC: float = 0.11
const FATIGUE_SLEEP_PER_SEC: float = -0.85
## No bed, no real rest. Sleeping rough barely helps and costs warmth.
const FATIGUE_ROUGH_PER_SEC: float = -0.22
const FATIGUE_EXHAUSTED: float = 92.0
const EXHAUST_HEALTH_PER_SEC: float = 0.06

## Cold below this feeds illness, at this much illness per second per degree.
const COLD_SICK_BELOW: float = 40.0
const COLD_SICK_PER_SEC: float = 0.0075
const MALNUTRITION_SICK_PER_SEC: float = 0.045
const EXHAUSTION_SICK_PER_SEC: float = 0.035
## Fever spreads: every sick body in the city raises everyone else's odds.
const CONTAGION_PER_SEC: float = 0.055
const ILLNESS_RECOVER_PER_SEC: float = 0.13
## A staffed infirmary bed is worth this multiple of bed rest at home.
const CARE_RECOVERY_MULT: float = 3.2
## Illness above this eats health, at this rate per point above.
const ILLNESS_HARM_ABOVE: float = 58.0
const ILLNESS_HEALTH_PER_SEC: float = 0.0042
## Crossing this puts a citizen off the roster; they return below the clear line.
const SICK_ONSET: float = 36.0
const SICK_CLEAR: float = 14.0

## Warmth below this is frostbite territory: health drains per point below.
const FREEZING_BELOW: float = 12.0
const FREEZE_HEALTH_PER_SEC: float = 0.12

## Chance per second that a worker on a hazardous machine has an accident, at
## zero fatigue and full morale. Fatigue and misery multiply it.
const ACCIDENT_PER_SEC: float = 0.000105
const ACCIDENT_FATIGUE_MULT: float = 2.6
const ACCIDENT_MORALE_MULT: float = 1.8
const INJURY_MIN: float = 28.0
const INJURY_MAX: float = 72.0
const INJURY_HEALTH_FACTOR: float = 0.34
const INJURY_HEAL_PER_SEC: float = 0.16
const INJURY_CLEAR: float = 9.0
const INJURY_HARM_ABOVE: float = 60.0
const INJURY_HEALTH_PER_SEC: float = 0.005

## Health creeps back when warm, fed, rested and unhurt.
const HEALTH_RECOVER_PER_SEC: float = 0.075
const ELDER_RECOVER_FACTOR: float = 0.55
const ELDER_SICK_FACTOR: float = 1.45
const CHILD_SICK_FACTOR: float = 1.30

## Morale drifts toward a target computed from everything else, this fast.
const MORALE_DRIFT_PER_SEC: float = 0.11
const MORALE_BASE: float = 12.0
const MORALE_FROM_WARMTH: float = 26.0
const MORALE_FROM_FOOD: float = 22.0
const MORALE_FROM_REST: float = 11.0
const MORALE_HOUSED: float = 9.0
const MORALE_SICK_PENALTY: float = 22.0
const MORALE_INJURED_PENALTY: float = 14.0
const MORALE_JOBLESS_PENALTY: float = 6.0
## What one death does to the city's nerve, spread across the survivors.
const GRIEF_PER_DEATH: float = 4.5
const GRIEF_DECAY_PER_SEC: float = 0.10
## Below this a citizen is a source of unrest [P06] can read.
const MORALE_UNREST_BELOW: float = 30.0

## Age advances this slowly. A campaign is weeks, not decades.
const DAYS_PER_YEAR: float = 4.0
const OLD_AGE_FROM: int = 68
const OLD_AGE_PER_SEC: float = 0.00022

# ==========================================================================
#  movement
# ==========================================================================

## Cells per second at full health on clear ground. A tile is 32 px.
const WALK_CELLS_PER_SEC: float = 1.15
const WALK_CHILD_FACTOR: float = 0.85
const WALK_ELDER_FACTOR: float = 0.72
## Deep snow, exhaustion and sickness all slow the walk to a trudge.
const WALK_SNOW_PENALTY: float = 0.45
const WALK_FATIGUE_PENALTY: float = 0.30
const WALK_SICK_PENALTY: float = 0.35
const WALK_MIN_FACTOR: float = 0.30
## Squared cell distance that counts as "arrived" at a waypoint.
const ARRIVE_EPSILON2: float = 0.030
## How far off the door centre a citizen stands, so a crowd looks like a crowd.
const CROWD_SPREAD: float = 0.34

# ==========================================================================
#  shifts
# ==========================================================================

## Phase bitmask per shift law: bit N set means "this shift works in phase N",
## indexed by ClimateDefs.Phase (dawn, morning, afternoon, dusk, night, deep).
const LAW_STANDARD: StringName = &"standard"
const LAW_EXTENDED: StringName = &"extended"
const LAW_EMERGENCY: StringName = &"emergency"

const SHIFT_LAWS: Dictionary[StringName, Dictionary] = {
	&"standard": {
		"day_mask": 0b000111, "night_mask": 0b111000,
		"fatigue": 1.0, "output": 1.0, "morale": 0.0,
		"label": "Standard Shifts",
	},
	&"extended": {
		"day_mask": 0b001111, "night_mask": 0b111001,
		"fatigue": 1.45, "output": 1.22, "morale": -8.0,
		"label": "Extended Shifts",
	},
	&"emergency": {
		"day_mask": 0b111111, "night_mask": 0b111111,
		"fatigue": 2.15, "output": 1.40, "morale": -20.0,
		"label": "Emergency Shift",
	},
}

## The trades whose work IS the dark: the guns on the wall and the fires that
## keep the wall worth defending. A gunner rostered to noon is a gun that is
## manned in the daylight and cold at the hour it was built for, and a stoker
## rostered to noon is a generator with nobody at it on the coldest night of the
## week. Everything else a city does is better done in the light.
##
## This is not "who may work nights". It is "whose building has no daytime", and
## the list is short on purpose — every trade added to it is a building that goes
## dark at noon instead.
##
## Measured rather than argued, over 24000 ticks of `first_night`: with the wall
## alone on this list the city ended the night with 20 of 29 crewed buildings
## reading `no crew`, WORSE than the 16 the hire counter left, because the
## generators had all gone home. With the fires on it as well that falls to 10,
## and the ten are the workshops — which is the city saying "the factory is shut
## and the watch is on", rather than "nothing here works". The cost is real and
## is not hidden: average morale over the run falls from 58.6 to 52.3, because
## a third of the workforce now sleeps through the daylight.
##
## Read off the trade, which comes off tags and category, so a new .tres with a
## `defense` or `heat_source` tag joins the night watch without this file ever
## learning its name.
const NIGHT_TRADES: Array[int] = [Trade.GUNNER, Trade.STOKER]

## True when this trade's building is one the city needs manned after dark.
static func is_night_trade(trade: int) -> bool:
	return NIGHT_TRADES.has(trade)


## Laws other parts can flip on this system. [P06] owns the politics; we only
## own what the rule does to a body.
const FLAG_CHILD_LABOUR: StringName = &"child_labour"
const FLAG_ELDER_LABOUR: StringName = &"elder_labour"
const CHILD_LABOUR_MIN_AGE: int = 10
const CHILD_WORK_FACTOR: float = 0.55
const ELDER_WORK_FACTOR: float = 0.70

# ==========================================================================
#  population
# ==========================================================================

const START_POPULATION: int = 18
const MAX_POPULATION: int = 1200
## Fractions of the founding group, in order: children, adults, elders.
const START_CHILD_FRACTION: float = 0.18
const START_ELDER_FRACTION: float = 0.12

## How often the road is checked for people walking in out of the white.
const ARRIVAL_INTERVAL_TICKS: int = 1600
const ARRIVAL_MIN_SPARE_BEDS: int = 3
const ARRIVAL_MIN_MORALE: float = 32.0
const ARRIVAL_MIN_FOOD_DAYS: float = 0.75
const ARRIVAL_GROUP_MIN: int = 2
const ARRIVAL_GROUP_MAX: int = 6

## Rations the founders carry in. Enough to matter, not enough to relax.
const STARTING_LARDER: float = 220.0
## Item ids the city eats, best first. [P03]/[P04] fill the shelves; until then
## the larder is the whole pantry.
const FOOD_ITEMS: Array[StringName] = [&"ration", &"grain"]
## A staffed kitchen stretches a ration this much further.
const KITCHEN_EFFICIENCY: float = 0.55
## Days of food left before the city cuts every meal in half, and by how much.
const LEAN_DAYS_TRIGGER: float = 1.0
const LEAN_RATION: float = 0.5

# ==========================================================================
#  scheduling — the perf contract
# ==========================================================================

## Needs, health and the state machine run on one of this many buckets per
## tick, so a thousand citizens cost a fifth of a tick each rather than all of
## them every tick. 8 buckets at 20 Hz = every citizen 2.5 times a second.
const NEED_BUCKETS: int = 8
## Job market, housing and building state refresh. Hiring is allowed to lag.
const JOB_SYNC_TICKS: int = 20
## Vacancies filled per job pass. A shift change should look like people
## finding out, not like a spreadsheet resolving.
const HIRES_PER_PASS: int = 12
## Meals are handed out in one batched withdrawal at this cadence.
const FEED_TICKS: int = 10
## Bus alerts of the same key are never repeated faster than this.
const ALERT_COOLDOWN_TICKS: int = 200
## Obituary depth kept for [P22] narrative.
const OBITUARY_KEEP: int = 48

## Agent ids handed to the view are offset so citizens can never collide with
## [P07]'s enemies in the renderer's agent table.
const AGENT_ID_BASE: int = 5000000

# ==========================================================================
#  names — the whole point. A number does not have a surname.
# ==========================================================================

const FIRST_NAMES: Array[String] = [
	"Mara", "Tobias", "Ilse", "Anton", "Greta", "Kasimir", "Nadia", "Emrik",
	"Halina", "Bruno", "Vera", "Otto", "Zofia", "Lennart", "Milena", "Rurik",
	"Agnes", "Fedor", "Karin", "Janos", "Lidia", "Marek", "Sonja", "Hendrik",
	"Ewa", "Piotr", "Ruth", "Aksel", "Danuta", "Stefan", "Ingrid", "Lukas",
	"Bogna", "Viktor", "Hedda", "Tomas", "Wanda", "Erik", "Alina", "Josef",
	"Malin", "Radek", "Sigrid", "Pavel", "Bertha", "Nils", "Irina", "Casper",
]

const LAST_NAMES: Array[String] = [
	"Kessler", "Novak", "Vinter", "Brandt", "Sokol", "Halvorsen", "Kowal",
	"Grim", "Bauer", "Lindqvist", "Marek", "Frost", "Sandvik", "Duda",
	"Aalto", "Weiss", "Petrov", "Norrland", "Kaminski", "Holm", "Voss",
	"Ilmari", "Radek", "Steen", "Wojcik", "Berg", "Malik", "Ostrom",
	"Czerny", "Lund", "Havel", "Torvik", "Rausch", "Zima", "Sorensen",
	"Klemm", "Bielik", "Nyholm", "Draska", "Ekman", "Rothe", "Salo",
]


# ==========================================================================
#  helpers
# ==========================================================================

static func state_name(s: int) -> StringName:
	if s < 0 or s >= STATE_NAMES.size():
		return &"idle"
	return STATE_NAMES[s]


static func state_label(s: int) -> String:
	if s < 0 or s >= STATE_LABELS.size():
		return "idle"
	return STATE_LABELS[s]


static func age_bracket(years: int) -> int:
	if years <= CHILD_MAX_AGE:
		return Age.CHILD
	if years >= ELDER_MIN_AGE:
		return Age.ELDER
	return Age.ADULT


static func age_name(bracket: int) -> StringName:
	if bracket < 0 or bracket >= AGE_NAMES.size():
		return &"adult"
	return AGE_NAMES[bracket]


static func trade_name(t: int) -> StringName:
	if t < 0 or t >= TRADE_NAMES.size():
		return &"labourer"
	return TRADE_NAMES[t]


static func trade_label(t: int) -> String:
	if t < 0 or t >= TRADE_LABELS.size():
		return "labourer"
	return TRADE_LABELS[t]


static func shift_name(s: int) -> StringName:
	if s < 0 or s >= SHIFT_NAMES.size():
		return &"off"
	return SHIFT_NAMES[s]


static func trait_name(t: int) -> StringName:
	if t < 0 or t >= TRAIT_NAMES.size():
		return &"steady"
	return TRAIT_NAMES[t]


## The trade a job in this building teaches, from its tags then its category.
static func trade_for(tags: Array, category: StringName) -> int:
	for entry: Array in TRADE_BY_TAG:
		if tags.has(entry[0]):
			return int(entry[1])
	return int(TRADE_BY_CATEGORY.get(category, Trade.LABOURER))


static func law_row(law: StringName) -> Dictionary:
	return SHIFT_LAWS.get(law, SHIFT_LAWS[LAW_STANDARD])


## True when a shift is on the clock during a ClimateDefs.Phase.
static func works_in_phase(law: StringName, shift: int, phase: int) -> bool:
	if shift == Shift.OFF:
		return false
	var row: Dictionary = law_row(law)
	var mask: int = int(row.get("night_mask", 0)) if shift == Shift.NIGHT else int(row.get("day_mask", 0))
	return (mask >> maxi(0, phase)) & 1 == 1


## Two words and a comma is the difference between a statistic and a person.
static func compose_name(first_idx: int, last_idx: int) -> String:
	var f: String = FIRST_NAMES[posmod(first_idx, FIRST_NAMES.size())]
	var l: String = LAST_NAMES[posmod(last_idx, LAST_NAMES.size())]
	return "%s %s" % [f, l]


## Short human description of how a citizen is doing, e.g. "cold and hungry".
## Empty when nothing is wrong — silence is the good news.
static func condition_phrase(warmth: float, hunger: float, fatigue: float,
		illness: float, injury: float, morale: float) -> String:
	var bits: PackedStringArray = PackedStringArray()
	if injury >= INJURY_CLEAR:
		bits.append("hurt")
	if illness >= SICK_CLEAR:
		bits.append("feverish" if illness >= SICK_ONSET else "coming down with something")
	if warmth <= FREEZING_BELOW:
		bits.append("freezing")
	elif warmth < COLD_SICK_BELOW:
		bits.append("cold")
	if hunger >= HUNGER_STARVING:
		bits.append("starving")
	elif hunger >= HUNGER_MEAL_WANT:
		bits.append("hungry")
	if fatigue >= FATIGUE_EXHAUSTED:
		bits.append("dead on their feet")
	elif fatigue >= 70.0:
		bits.append("tired")
	if bits.is_empty():
		if morale >= 70.0:
			return "in good spirits"
		if morale <= MORALE_UNREST_BELOW:
			return "bitter"
		return "holding up"
	if bits.size() == 1:
		return bits[0]
	var last: String = bits[bits.size() - 1]
	bits.remove_at(bits.size() - 1)
	return "%s and %s" % [", ".join(bits), last]
