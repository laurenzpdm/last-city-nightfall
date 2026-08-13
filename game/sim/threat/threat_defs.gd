class_name ThreatDefs
extends RefCounted
## Shared enums, name tables and Bus keys for [P08] Threat Director.
##
## Other parts compare against the StringName tables rather than the raw ints,
## so the enums can grow without breaking the HUD, the audio mix or a save.

# ---------------------------------------------------------------- wave state

## Lifecycle of one night's attack. A wave walks these in order and never back.
enum WaveState { IDLE, TELEGRAPHED, ACTIVE, RESOLVED }

const WAVE_STATE_NAMES: Array[StringName] = [
	&"idle", &"telegraphed", &"active", &"resolved",
]


static func wave_state_name(s: int) -> StringName:
	if s < 0 or s >= WAVE_STATE_NAMES.size():
		return &"idle"
	return WAVE_STATE_NAMES[s]


# --------------------------------------------------------------------- roles

## What a unit is FOR. The composer thinks in roles; the content decides which
## creature fills one. A night is shaped by weighting roles, never by naming
## creatures, so adding a .tres to game/content/enemies/ changes the game.
const ROLE_SWARM: StringName = &"swarm"       ## cheap, many, dies to anything
const ROLE_LINE: StringName = &"line"         ## the ordinary body of an attack
const ROLE_BREAKER: StringName = &"breaker"   ## armoured, eats walls
const ROLE_STALKER: StringName = &"stalker"   ## fast, flanks, ignores the front
const ROLE_SIEGE: StringName = &"siege"       ## slow, huge, ends a district

const ROLES: Array[StringName] = [
	ROLE_SWARM, ROLE_LINE, ROLE_BREAKER, ROLE_STALKER, ROLE_SIEGE,
]


static func role_index(r: StringName) -> int:
	return ROLES.find(r)


static func is_role(r: StringName) -> bool:
	return ROLES.has(r)


# -------------------------------------------------------------------- shapes

## The character of one night. A shape is a set of role multipliers, so two
## nights of the same budget can still feel completely different: a tide of
## small things versus four armoured backs walking up the main road.
const SHAPE_PROBE: StringName = &"probe"
const SHAPE_SWARM: StringName = &"swarm"
const SHAPE_COLUMN: StringName = &"column"
const SHAPE_HAMMER: StringName = &"hammer"
const SHAPE_SIEGE: StringName = &"siege"

const SHAPES: Array[StringName] = [
	SHAPE_PROBE, SHAPE_SWARM, SHAPE_COLUMN, SHAPE_HAMMER, SHAPE_SIEGE,
]

const SHAPE_LABELS: Array[String] = [
	"a probe", "a swarm", "a column", "a hammer", "a siege",
]


static func shape_index(s: StringName) -> int:
	return SHAPES.find(s)


static func shape_label(s: StringName) -> String:
	var i: int = SHAPES.find(s)
	return SHAPE_LABELS[i] if i >= 0 else "an attack"


# ------------------------------------------------------------------ compass

## Index-aligned with the sector returned by [method compass_sector].
## Screen space: +x is east, +y is SOUTH. The whole game agrees on that.
const COMPASS_NAMES: Array[StringName] = [
	&"east", &"south_east", &"south", &"south_west",
	&"west", &"north_west", &"north", &"north_east",
]

const COMPASS_LABELS: Array[String] = [
	"the east", "the south-east", "the south", "the south-west",
	"the west", "the north-west", "the north", "the north-east",
]

const COMPASS_SHORT: Array[String] = ["E", "SE", "S", "SW", "W", "NW", "N", "NE"]


## 0..7 sector of a direction vector, starting at east and turning clockwise
## on screen. Integer maths on purpose: two runs must agree exactly.
static func compass_sector(delta: Vector2i) -> int:
	if delta == Vector2i.ZERO:
		return 0
	var angle: float = atan2(float(delta.y), float(delta.x))
	return int(roundf(angle / (TAU / 8.0))) & 7


static func compass_name(sector: int) -> StringName:
	return COMPASS_NAMES[sector & 7]


static func compass_label(sector: int) -> String:
	return COMPASS_LABELS[sector & 7]


static func compass_short(sector: int) -> String:
	return COMPASS_SHORT[sector & 7]


# ------------------------------------------------------------ strength bands

## What the player is told instead of a number. The bands are wide on purpose:
## the telegraph promises a size, never an exact roster, so preparing is a
## judgement call rather than arithmetic.
const BAND_THRESHOLDS: PackedFloat32Array = PackedFloat32Array([
	0.0, 12.0, 40.0, 100.0, 220.0, 460.0,
])

const BAND_LABELS: Array[String] = [
	"a handful", "a pack", "a column", "a host", "a tide", "everything out there",
]

const BAND_KEYS: Array[StringName] = [
	&"handful", &"pack", &"column", &"host", &"tide", &"everything",
]


static func band_index(budget: float) -> int:
	var idx: int = 0
	for i: int in BAND_THRESHOLDS.size():
		if budget >= BAND_THRESHOLDS[i]:
			idx = i
	return idx


static func band_label(budget: float) -> String:
	return BAND_LABELS[band_index(budget)]


static func band_key(budget: float) -> StringName:
	return BAND_KEYS[band_index(budget)]


# ------------------------------------------------------------------ bus keys

## Alert and narrative keys this part raises. Listed here so UI, audio and
## narrative bind to constants instead of typing string literals.
const KEY_WARNING: StringName = &"threat_warning"
const KEY_WAVE_STARTED: StringName = &"threat_wave_started"
const KEY_WAVE_CLEARED: StringName = &"threat_wave_cleared"
const KEY_SET_PIECE: StringName = &"threat_set_piece"
const KEY_BREACH: StringName = &"threat_breach"
const KEY_CONTACT: StringName = &"threat_contact"
const KEY_WITHDRAW: StringName = &"threat_withdraw"
const KEY_PRESSURE: StringName = &"threat_pressure"

## The harness fails a run on Bus.alert_raised severity >= 2, so this part never
## exceeds 1. Real urgency travels in the narrative_event payload instead.
const MAX_BUS_SEVERITY: int = 1


## "4:12" — the same clock format climate uses, so every warning in the game
## reads the same way.
static func format_clock(seconds: float) -> String:
	var s: int = int(roundf(maxf(0.0, seconds)))
	return "%d:%02d" % [s / 60, s % 60]
