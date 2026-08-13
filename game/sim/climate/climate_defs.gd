class_name ClimateDefs
extends RefCounted
## Shared enums and name tables for [P09] Climate & Nightfall.
##
## Other parts should compare against the StringName tables (`ClimateDefs.PHASE_NAMES`)
## rather than the raw ints, so the enum can grow without breaking them.

enum Phase { DAWN, MORNING, AFTERNOON, DUSK, NIGHT, DEEP_NIGHT }
enum Weather { CLEAR, OVERCAST, SNOWFALL, BLIZZARD }
enum Archetype { CALM, SNOWY, HARSH, BRUTAL }

const PHASE_COUNT: int = 6
const WEATHER_COUNT: int = 4
const ARCHETYPE_COUNT: int = 4

## Index-aligned with Phase. The day is an arc, not a switch: six named beats.
const PHASE_NAMES: Array[StringName] = [
	&"dawn", &"morning", &"afternoon", &"dusk", &"night", &"deep_night",
]

## Human-facing label for each phase. UI may localise; sim never does.
const PHASE_LABELS: Array[String] = [
	"Dawn", "Morning", "Afternoon", "Dusk", "Night", "Deep Night",
]

const WEATHER_NAMES: Array[StringName] = [
	&"clear", &"overcast", &"snowfall", &"blizzard",
]

const WEATHER_LABELS: Array[String] = [
	"Clear", "Overcast", "Snowfall", "Whiteout Blizzard",
]

const ARCHETYPE_NAMES: Array[StringName] = [
	&"calm", &"snowy", &"harsh", &"brutal",
]

## The campaign-defining storm. Reported by `ClimateSystem.weather()` while it blows.
const GREAT_FROST: StringName = &"great_frost"
const GREAT_FROST_LABEL: String = "Great Frost"

## Alert / narrative keys this part raises on the Bus. Listed here so UI, audio and
## narrative can bind to constants instead of typing string literals.
const KEY_DAWN: StringName = &"climate_dawn"
const KEY_DUSK: StringName = &"climate_dusk"
const KEY_NIGHT: StringName = &"climate_night"
const KEY_ERA: StringName = &"climate_era"
const KEY_STORM_WARNING: StringName = &"climate_storm_warning"
const KEY_STORM_BEGAN: StringName = &"climate_storm_began"
const KEY_STORM_ENDED: StringName = &"climate_storm_ended"
const KEY_BLIZZARD: StringName = &"climate_blizzard"

## The harness treats Bus.alert_raised severity >= 2 as a failed run, so climate
## never exceeds this. Real urgency travels in the narrative_event payload instead.
const MAX_BUS_SEVERITY: int = 1


static func phase_name(p: int) -> StringName:
	if p < 0 or p >= PHASE_NAMES.size():
		return &"dawn"
	return PHASE_NAMES[p]


static func phase_label(p: int) -> String:
	if p < 0 or p >= PHASE_LABELS.size():
		return "Dawn"
	return PHASE_LABELS[p]


static func weather_name(w: int) -> StringName:
	if w < 0 or w >= WEATHER_NAMES.size():
		return &"clear"
	return WEATHER_NAMES[w]


static func weather_label(w: int) -> String:
	if w < 0 or w >= WEATHER_LABELS.size():
		return "Clear"
	return WEATHER_LABELS[w]


static func archetype_name(a: int) -> StringName:
	if a < 0 or a >= ARCHETYPE_NAMES.size():
		return &"calm"
	return ARCHETYPE_NAMES[a]


## "4:12" — used in every warning string so the player always reads the same format.
static func format_clock(seconds: float) -> String:
	var s: int = int(roundf(maxf(0.0, seconds)))
	return "%d:%02d" % [s / 60, s % 60]
