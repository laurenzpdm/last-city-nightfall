class_name NarrativeDefs
extends RefCounted
## [P22] Shared vocabulary for events, dilemmas, the campaign spine and flavour.
##
## THE CONTRACT THIS FILE ENFORCES
##
## An event fires because the world is in a particular state, and the player is
## always told which state. That is only true if the state has a NAME, so every
## number an event may look at lives in `FACTS` below. A condition naming a fact
## that is not in this table is refused at load, loudly, the same way a malformed
## law is — because an event whose trigger nobody measures is a timer wearing a
## costume, and a timer is exactly what this part is not allowed to be.
##
## The city is CALDERA NINE. It was a survey label before it was a place: nine
## was the ninth vent the column found still breathing under the ice, and they
## stopped there because the ninth was the first one big enough to stand a
## generator in. Nobody has said the whole name out loud since the second night.
## Every line of writing in this part is about that caldera, that generator and
## the people who did not walk any further. Nothing in here is about a generic
## frozen wasteland, and any line that would survive being pasted into another
## game is a line that has failed.

const TAG: String = "narrative"

## The only randomness this part is allowed to touch.
const RNG_STREAM: String = "narrative"

## After research (90), before the metrics slot (99). Narrative reads the world
## the tick has already produced; it must never be the reason a number moved
## before the system that owns it got to move it.
const SYSTEM_ORDER: int = 95

## The world is re-read, and every event re-tested, this often. One second of
## in-world time. Between samples step() does nothing but count.
const SAMPLE_EVERY: int = 20

## Fallbacks used only while [P09] is absent. Climate is authoritative.
const DEFAULT_DAY_TICKS: int = 9600
const HOURS_PER_DAY: int = 24

## A ring, not a log file: the journal is serialized into every save and every
## harness state dump, so it has to have a ceiling.
const JOURNAL_KEEP: int = 240
const FEED_KEEP: int = 60

## No more than this many events may be waiting on the player at once. A city
## that hands you nine decisions has handed you none.
const PENDING_MAX: int = 4


# =========================================================================
#  categories and severity
# =========================================================================

## What KIND of thing arrived. The presenter draws each differently and [P17]
## can filter on it without knowing a single event id.
const CAT_BEAT: StringName = &"beat"           ## campaign spine, unskippable
const CAT_DILEMMA: StringName = &"dilemma"     ## two bad options, both priced
const CAT_REPORT: StringName = &"report"       ## acknowledge and move on
const CAT_OBITUARY: StringName = &"obituary"   ## someone died, by name
const CAT_SCOUT: StringName = &"scout"         ## word from outside the caldera

const CATEGORIES: Array[StringName] = [
	&"beat", &"dilemma", &"obituary", &"report", &"scout",
]

## Presentation weight, not danger. The harness fails a run on Bus.alert_raised
## severity >= 2, and a city in trouble is the game working, so this part never
## raises above 1 on the Bus either.
const SEV_NOTE: int = 0
const SEV_WARN: int = 1


# =========================================================================
#  Bus keys — narrative_event ids this part raises
# =========================================================================

const EV_RAISED: StringName = &"narrative_raised"
const EV_RESOLVED: StringName = &"narrative_resolved"
const EV_EXPIRED: StringName = &"narrative_expired"
const EV_CHAPTER: StringName = &"narrative_chapter"
const EV_FLAVOUR: StringName = &"narrative_flavour"
const EV_EPILOGUE: StringName = &"narrative_epilogue"


# =========================================================================
#  comparators
# =========================================================================

enum Cmp { GE, LE, GT, LT, EQ, NE }

const CMP_NAMES: Array[StringName] = [&"ge", &"le", &"gt", &"lt", &"eq", &"ne"]
const CMP_WORDS: Array[String] = [
	"is at or above", "is at or below", "is above", "is below",
	"is exactly", "is anything but",
]


static func cmp_name(c: int) -> StringName:
	if c < 0 or c >= CMP_NAMES.size():
		return &"ge"
	return CMP_NAMES[c]


static func cmp_word(c: int) -> String:
	if c < 0 or c >= CMP_WORDS.size():
		return CMP_WORDS[0]
	return CMP_WORDS[c]


static func cmp_from_name(n: StringName) -> int:
	var i: int = CMP_NAMES.find(n)
	return i if i >= 0 else Cmp.GE


static func compare(value: float, c: int, threshold: float) -> bool:
	match c:
		Cmp.GE: return value >= threshold
		Cmp.LE: return value <= threshold
		Cmp.GT: return value > threshold
		Cmp.LT: return value < threshold
		Cmp.EQ: return absf(value - threshold) < 0.0001
		Cmp.NE: return absf(value - threshold) >= 0.0001
	return false


# =========================================================================
#  THE FACT TABLE
# =========================================================================
##
## key -> [human label, unit suffix, decimals]. Everything an event is allowed
## to be caused by. NarrativeWorld fills exactly these keys and no others, so
## "what caused this" is never a guess and never a hand-written sentence that
## has drifted away from the number it claims to quote.
##
## Adding a fact is one line here and one line in NarrativeWorld.read(). A
## condition on a key that is not here fails validation at load.

const FACTS: Dictionary = {
	# --- the clock and the sky ---------------------------------------------
	&"day": ["The day", "", 0],
	&"hour": ["The hour", "", 0],
	&"phase": ["Time of day", "", 0],
	&"is_night": ["Night", "", 0],
	&"is_deep_night": ["Deep night", "", 0],
	&"temperature": ["Outside temperature", " C", 1],
	&"severity": ["How bad the winter has got", "", 2],
	&"era": ["Winter era", "", 0],
	&"storm_active": ["A Great Frost is blowing", "", 0],
	&"storm_hours": ["Hours until the next Great Frost", " h", 1],
	&"storm_intensity": ["Great Frost intensity", "", 2],
	&"wind": ["Wind", "", 2],
	&"visibility": ["Visibility", "", 2],
	&"snow_depth": ["Snow on the ground", "", 2],

	# --- the people ---------------------------------------------------------
	&"population": ["People alive", "", 0],
	&"deaths": ["People dead", "", 0],
	&"deaths_cold": ["Frozen to death", "", 0],
	&"deaths_starvation": ["Starved", "", 0],
	&"deaths_illness": ["Died of fever", "", 0],
	&"deaths_injury": ["Died of injuries", "", 0],
	&"deaths_exhaustion": ["Worked to death", "", 0],
	&"deaths_today": ["Dead since dawn", "", 0],
	&"homeless": ["People with no bunk", "", 0],
	&"sick": ["People down with fever", "", 0],
	&"injured": ["People carrying injuries", "", 0],
	&"avg_warmth": ["How warm the city feels", "", 1],
	&"avg_morale": ["Morale", "", 1],
	&"avg_health": ["Health", "", 1],
	&"hunger_share": ["Share of the city going hungry", "", 2],
	&"food_days": ["Days of food left", " d", 1],
	&"unrest": ["Share of the city ready to make trouble", "", 2],

	# --- the meters ---------------------------------------------------------
	&"hope": ["Hope", "", 1],
	&"discontent": ["Discontent", "", 1],
	&"hope_rate": ["Hope, per hour", "/h", 2],
	&"discontent_rate": ["Discontent, per hour", "/h", 2],
	&"laws_signed": ["Laws signed", "", 0],
	&"grievances": ["Open grievances", "", 0],
	&"demands": ["Demands with a deadline on them", "", 0],
	&"worst_approval": ["The angriest faction's approval", "", 1],

	# --- the dark -----------------------------------------------------------
	&"wave": ["Nights survived, counting this one", "", 0],
	&"waves_cleared": ["Nights cleared", "", 0],
	&"threat_pressure": ["How hard the dark is pushing", "", 2],
	&"wave_seconds": ["Seconds until they arrive", " s", 0],
	&"enemies_alive": ["Things inside the caldera", "", 0],
	&"turrets": ["Guns on the wall", "", 0],
	&"turret_uptime": ["Share of the guns that can fire", "", 2],

	# --- the machine --------------------------------------------------------
	&"buildings": ["Standing structures", "", 0],
	&"frozen_buildings": ["Structures frozen solid", "", 0],
	&"heat_supply": ["Heat made", "", 1],
	&"heat_demand": ["Heat asked for", "", 1],
	&"heat_deficit": ["Heat the grid could not deliver", "", 1],
	&"networks": ["Separate heat networks", "", 0],
	&"machines": ["Machines", "", 0],
	&"stalled_machines": ["Machines standing idle", "", 0],
	&"belt_lines": ["Belt lines running", "", 0],
	&"items_moved": ["Items carried by belt", "", 0],
	&"research_done": ["Finished research", "", 0],
	&"researching": ["Something is being researched", "", 0],
	&"stock_timber": ["Timber", "", 0],
	&"stock_coal": ["Coal", "", 0],
	&"stock_scrap": ["Scrap", "", 0],
	&"stock_iron_plate": ["Iron plate", "", 0],
	&"stock_stone": ["Stone", "", 0],

	# --- this part's own state ----------------------------------------------
	&"chapter": ["Chapter of the winter", "", 0],
	&"events_fired": ["Events so far", "", 0],
	&"dilemmas_resolved": ["Decisions taken", "", 0],
	&"quiet_hours": ["Hours since the last event", " h", 1],
}


static func has_fact(key: StringName) -> bool:
	return FACTS.has(key)


## Sorted. Every iteration over the fact table goes through this so ordering is
## never left to a Dictionary.
static func fact_keys() -> Array[StringName]:
	var keys: Array = FACTS.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


static func fact_label(key: StringName) -> String:
	var row: Array = FACTS.get(key, [])
	return String(row[0]) if row.size() > 0 else String(key)


## "61.4", "-24.0 C", "3" — the number as the player will read it in the
## sentence that explains why something happened.
static func fact_value_text(key: StringName, value: float) -> String:
	var row: Array = FACTS.get(key, [])
	var unit: String = String(row[1]) if row.size() > 1 else ""
	var decimals: int = int(row[2]) if row.size() > 2 else 1
	if key.begins_with("is_") or key == &"storm_active" or key == &"researching":
		return ("yes" if value >= 0.5 else "no") + unit
	if decimals <= 0:
		return "%d%s" % [int(roundf(value)), unit]
	return "%.*f%s" % [decimals, value, unit]


# =========================================================================
#  effect keys
# =========================================================================
##
## What an option is allowed to DO. Everything here is applied through another
## part's public command surface, never by reaching into its fields, and every
## one of them is refused silently-but-loudly if that part is not in the build.

const FX_HOPE: StringName = &"hope"
const FX_DISCONTENT: StringName = &"discontent"
const FX_FOOD: StringName = &"food"
const FX_DEATHS: StringName = &"deaths"
const FX_ARRIVALS: StringName = &"arrivals"
const FX_APPROVAL: StringName = &"approval"      ## "approval:workers"
const FX_STOCK: StringName = &"stock"            ## "stock:timber"
const FX_FLAG: StringName = &"flag"              ## "flag:the_pits_dug"
const FX_RESEARCH: StringName = &"research"      ## "research:heat_lance"

const EFFECT_PREFIXES: Array[StringName] = [
	&"approval", &"arrivals", &"deaths", &"discontent", &"flag", &"food",
	&"hope", &"research", &"stock",
]

## Items the city keeps in the yard. An effect naming anything else is refused
## at load rather than vanishing at runtime.
const STOCK_ITEMS: Array[StringName] = [
	&"coal", &"iron_plate", &"scrap", &"stone", &"timber",
]

const FACTION_IDS: Array[StringName] = [
	&"faithful", &"families", &"infirm", &"latecomers", &"watch", &"workers",
]


## Splits "approval:workers" into [&"approval", &"workers"].
static func split_effect(key: StringName) -> Array[StringName]:
	var s: String = String(key)
	var i: int = s.find(":")
	if i < 0:
		return [StringName(s), &""]
	return [StringName(s.substr(0, i)), StringName(s.substr(i + 1))]


# =========================================================================
#  the places in this city
# =========================================================================
##
## Named so the writing can point at them. A line that says "a building" is a
## line about nothing; a line that says "the third boiler on Kettle Row" is a
## line about Caldera Nine.

const CITY_NAME: String = "Caldera Nine"
const CITY_SHORT: String = "the Nine"

const PLACES: Array[String] = [
	"the Hearth", "Kettle Row", "the East Wall", "the North Gate",
	"the Ash Stair", "the Long Shaft", "the Drop", "the Survey Hall",
	"the second boiler", "the sledway", "the west drift", "the rim road",
]
