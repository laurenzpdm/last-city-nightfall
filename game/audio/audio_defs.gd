class_name LcnAudioDefs
extends RefCounted
## [P23] The palette, as constants. Bus names, categories, voice budgets, and
## the map from a thing in the world to the noise it makes.
##
## THE ART DIRECTION, stated once so every recipe below can be judged against it:
## this city is **cold, low and mechanical**. There are no melodies played on
## instruments, because there is nobody left to play one. What the player hears
## is the machinery of survival — a fire, a wind, a grid of engines — and the
## only "music" is those same materials arranged into layers that rise and fall
## with how the night is going. Everything is synthesised from noise, sine and
## saw, filtered hard, and pitched into D minor so the beds and the score are
## never in disagreement.
##
## THE MIX HAS A HIERARCHY and it is not negotiable:
##   1. the hearth   — always present, always audible, the emotional floor
##   2. alerts       — everything else ducks under them
##   3. combat       — what is happening to you right now
##   4. machines     — what your factory is doing, as a legibility instrument
##   5. wind / music — the weather of the scene

# --- buses -------------------------------------------------------------------
#
# Godot routes a bus only to a LOWER index, so the creation order below IS the
# graph. Master is 0 by definition; the four the player has sliders for come
# next; the shaping buses hang off those.

const BUS_MASTER: StringName = &"Master"
const BUS_MUSIC: StringName = &"Music"
const BUS_AMBIENCE: StringName = &"Ambience"
const BUS_SFX: StringName = &"Sfx"
const BUS_WIND: StringName = &"Wind"
const BUS_HEARTH: StringName = &"Hearth"
const BUS_MACHINE: StringName = &"Machine"
const BUS_COMBAT: StringName = &"Combat"
const BUS_UI: StringName = &"Ui"
const BUS_ALERT: StringName = &"Alert"

## name → parent. Order is the creation order and therefore the bus index order.
const BUS_TREE: Array[Dictionary] = [
	{"name": BUS_MUSIC, "send": BUS_MASTER, "db": -4.0},
	{"name": BUS_AMBIENCE, "send": BUS_MASTER, "db": -3.0},
	{"name": BUS_SFX, "send": BUS_MASTER, "db": -1.0},
	{"name": BUS_WIND, "send": BUS_AMBIENCE, "db": -2.0},
	{"name": BUS_HEARTH, "send": BUS_AMBIENCE, "db": 0.0},
	{"name": BUS_MACHINE, "send": BUS_SFX, "db": -5.0},
	{"name": BUS_COMBAT, "send": BUS_SFX, "db": -1.0},
	{"name": BUS_UI, "send": BUS_SFX, "db": -6.0},
	{"name": BUS_ALERT, "send": BUS_SFX, "db": -2.0},
]

## Which Settings.audio slider owns which bus. The four the player sees.
const SLIDER_BUS: Dictionary[String, StringName] = {
	"master": BUS_MASTER,
	"music": BUS_MUSIC,
	"ambience": BUS_AMBIENCE,
	"sfx": BUS_SFX,
}

## Buses that dip when an alert speaks. The alert bus itself never ducks.
const DUCKED_BUSES: Array[StringName] = [BUS_MUSIC, BUS_AMBIENCE, BUS_MACHINE]

# --- voice budget ------------------------------------------------------------
#
# A wave of two hundred bodies must not be able to spend the whole mix on
# footsteps. Every category has its own ceiling and they add up to less than the
# hard cap, so a big fight cannot starve the interface.

const MAX_WORLD_VOICES: int = 28        ## positional one-shots alive at once
const MAX_FLAT_VOICES: int = 12         ## non-positional (interface, alerts, music)
const MAX_MACHINE_LOOPS: int = 10       ## one persistent voice per machine family

## category → how many world voices it may hold.
const CATEGORY_CAP: Dictionary[StringName, int] = {
	&"combat": 14,
	&"world": 8,
	&"build": 4,
	&"voice": 6,
}

## Starts allowed in a single frame. The harness pushes eleven thousand ticks
## through a handful of frames; without this, one frame tries to open a thousand
## voices and the mix becomes a wall.
const MAX_STARTS_PER_FRAME: int = 10

## Two requests for the same cue, this close in time AND in space, merge into one
## louder start. The distance term is what keeps a volley a volley and stops two
## simultaneous attacks on opposite walls collapsing into one.
const COALESCE_MS: int = 45
const COALESCE_TILES: float = 7.0
const COALESCE_GAIN_DB: float = 1.6
const COALESCE_GAIN_MAX_DB: float = 5.0

## Tiles. Beyond this a positional cue is not started at all.
const AUDIBLE_TILES: float = 46.0
const TILE: float = 32.0

# --- cue table ---------------------------------------------------------------
#
# priority 0 is furniture and 3 is "the player must hear this". Stealing never
# takes a voice from a higher priority than the one asking.

const PRI_BED: int = 0
const PRI_AMBIENT: int = 1
const PRI_ACTION: int = 2
const PRI_CRITICAL: int = 3

## cue → {stream, bus, category, db, pitch (jitter in semitones), priority}
## `stream` is the recipe key in LcnSynthRecipes; several cues may share one.
const CUES: Dictionary[StringName, Dictionary] = {
	# --- combat -------------------------------------------------------------
	&"turret_fire": {"stream": &"shot_light", "bus": BUS_COMBAT, "category": &"combat",
		"db": -6.0, "pitch": 1.4, "priority": PRI_ACTION},
	&"turret_fire_heavy": {"stream": &"shot_heavy", "bus": BUS_COMBAT, "category": &"combat",
		"db": -3.0, "pitch": 0.9, "priority": PRI_ACTION},
	&"enemy_hit": {"stream": &"impact_soft", "bus": BUS_COMBAT, "category": &"combat",
		"db": -11.0, "pitch": 1.8, "priority": PRI_AMBIENT},
	&"enemy_died": {"stream": &"death_rattle", "bus": BUS_COMBAT, "category": &"combat",
		"db": -9.0, "pitch": 2.2, "priority": PRI_ACTION},
	&"structure_hit": {"stream": &"impact_metal", "bus": BUS_COMBAT, "category": &"combat",
		"db": -5.0, "pitch": 1.2, "priority": PRI_ACTION},
	&"breach": {"stream": &"breach_groan", "bus": BUS_COMBAT, "category": &"combat",
		"db": -2.0, "pitch": 0.3, "priority": PRI_CRITICAL},
	&"enemy_call": {"stream": &"call_far", "bus": BUS_COMBAT, "category": &"voice",
		"db": -13.0, "pitch": 2.6, "priority": PRI_AMBIENT},
	&"enemy_call_near": {"stream": &"call_near", "bus": BUS_COMBAT, "category": &"voice",
		"db": -8.0, "pitch": 1.8, "priority": PRI_ACTION},
	&"big_one": {"stream": &"dread_swell", "bus": BUS_COMBAT, "category": &"voice",
		"db": -3.0, "pitch": 0.4, "priority": PRI_CRITICAL},

	# --- the city -----------------------------------------------------------
	&"build_place": {"stream": &"thud_wood", "bus": BUS_UI, "category": &"build",
		"db": -8.0, "pitch": 1.2, "priority": PRI_ACTION},
	&"build_done": {"stream": &"chord_soft", "bus": BUS_UI, "category": &"build",
		"db": -12.0, "pitch": 0.8, "priority": PRI_AMBIENT},
	&"build_removed": {"stream": &"rubble", "bus": BUS_UI, "category": &"build",
		"db": -10.0, "pitch": 1.5, "priority": PRI_AMBIENT},
	&"machine_stall": {"stream": &"stall_sigh", "bus": BUS_MACHINE, "category": &"world",
		"db": -9.0, "pitch": 1.0, "priority": PRI_ACTION},
	&"froze": {"stream": &"freeze_crack", "bus": BUS_SFX, "category": &"world",
		"db": -6.0, "pitch": 1.2, "priority": PRI_ACTION},
	&"death": {"stream": &"toll", "bus": BUS_SFX, "category": &"world",
		"db": -7.0, "pitch": 0.4, "priority": PRI_CRITICAL},

	# --- interface ----------------------------------------------------------
	&"ui_click": {"stream": &"click", "bus": BUS_UI, "category": &"ui",
		"db": -14.0, "pitch": 0.6, "priority": PRI_ACTION},
	&"ui_open": {"stream": &"panel_open", "bus": BUS_UI, "category": &"ui",
		"db": -13.0, "pitch": 0.3, "priority": PRI_ACTION},
	&"ui_deny": {"stream": &"deny", "bus": BUS_UI, "category": &"ui",
		"db": -11.0, "pitch": 0.3, "priority": PRI_ACTION},
	&"ui_confirm": {"stream": &"confirm", "bus": BUS_UI, "category": &"ui",
		"db": -12.0, "pitch": 0.3, "priority": PRI_ACTION},
	&"law_signed": {"stream": &"law_chord", "bus": BUS_UI, "category": &"ui",
		"db": -8.0, "pitch": 0.0, "priority": PRI_CRITICAL},
	&"research_done": {"stream": &"research_shine", "bus": BUS_UI, "category": &"ui",
		"db": -9.0, "pitch": 0.0, "priority": PRI_CRITICAL},

	# --- alerts, graded by severity ----------------------------------------
	&"alert_info": {"stream": &"sting_info", "bus": BUS_ALERT, "category": &"ui",
		"db": -14.0, "pitch": 0.0, "priority": PRI_ACTION},
	&"alert_warn": {"stream": &"sting_warn", "bus": BUS_ALERT, "category": &"ui",
		"db": -8.0, "pitch": 0.0, "priority": PRI_CRITICAL},
	&"alert_critical": {"stream": &"sting_critical", "bus": BUS_ALERT, "category": &"ui",
		"db": -4.0, "pitch": 0.0, "priority": PRI_CRITICAL},

	# --- the clock ----------------------------------------------------------
	&"nightfall": {"stream": &"night_drain", "bus": BUS_MUSIC, "category": &"world",
		"db": -6.0, "pitch": 0.0, "priority": PRI_CRITICAL},
	&"daybreak": {"stream": &"dawn_lift", "bus": BUS_MUSIC, "category": &"world",
		"db": -8.0, "pitch": 0.0, "priority": PRI_CRITICAL},
	&"wave_horn": {"stream": &"war_horn", "bus": BUS_ALERT, "category": &"world",
		"db": -5.0, "pitch": 0.0, "priority": PRI_CRITICAL},
	&"wave_cleared": {"stream": &"relief", "bus": BUS_MUSIC, "category": &"world",
		"db": -8.0, "pitch": 0.0, "priority": PRI_CRITICAL},
}

# --- machines ----------------------------------------------------------------
#
# A machine family is a SOUND, not a building. Ten families cover twenty-five
# building kinds and leave room for content nobody has written yet, and the
# player learns ten rhythms instead of twenty-five.

## building kind → machine family (a recipe key prefixed `mach_`).
const KIND_FAMILY: Dictionary[StringName, StringName] = {
	&"coal_generator": &"burner",
	&"geothermal_tap": &"burner",
	&"recuperator": &"burner",
	&"smelter": &"smelter",
	&"workshop": &"press",
	&"assembly_hall": &"assembler",
	&"survey_hall": &"assembler",
	&"ore_drill": &"drill",
	&"scrap_collector": &"sorter",
	&"rubble_sorter": &"sorter",
	&"field_kitchen": &"kitchen",
	&"heat_booster_pump": &"pump",
	&"warmth_radiator": &"radiator",
}

## Fallback for a kind nobody mapped: the first tag that matches wins, in this
## order. New content is audible the day it lands instead of the day someone
## remembers to add a line here.
const TAG_FAMILY: Array[Array] = [
	[&"belt", &"belt"],
	[&"conveyor", &"belt"],
	[&"burner", &"burner"],
	[&"extractor", &"drill"],
	[&"assembler", &"assembler"],
	[&"sorter", &"sorter"],
	[&"food", &"kitchen"],
	[&"radiator", &"radiator"],
	[&"repeater", &"pump"],
	[&"heat_source", &"burner"],
	[&"crafter", &"press"],
	[&"machine", &"press"],
]

## Families in the order the chorus is allowed to spend voices on them. When
## more families are running than there are voices, the ones at the top are the
## ones the player keeps hearing.
const FAMILY_PRIORITY: Array[StringName] = [
	&"burner", &"smelter", &"press", &"assembler", &"drill",
	&"sorter", &"pump", &"belt", &"kitchen", &"radiator",
]

## Per-family trim, in dB. A row of radiators must not out-shout a smelter.
const FAMILY_DB: Dictionary[StringName, float] = {
	&"burner": -4.0, &"smelter": -3.0, &"press": -5.0, &"assembler": -7.0,
	&"drill": -5.0, &"sorter": -8.0, &"pump": -8.0, &"belt": -10.0,
	&"kitchen": -11.0, &"radiator": -13.0,
}


## The family a building belongs to, or &"" for something that makes no noise.
static func family_of(kind: StringName, tags: Array) -> StringName:
	var direct: StringName = KIND_FAMILY.get(kind, &"")
	if direct != &"":
		return direct
	for row: Array in TAG_FAMILY:
		if tags.has(row[0]):
			return row[1]
	return &""


## Alert severity → cue. [P17] grades its alerts 0/1/2; anything higher is
## still the loudest sting rather than silence.
static func alert_cue(severity: int) -> StringName:
	if severity >= 2:
		return &"alert_critical"
	if severity == 1:
		return &"alert_warn"
	return &"alert_info"
