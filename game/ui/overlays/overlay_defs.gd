class_name LcnOverlayDefs
extends RefCounted
## [P19] Shared vocabulary for the readability lenses.
##
## Every other file in game/ui/overlays/ agrees on these ids, bit flags and
## labels, so a lens, the legend and the snapshot can never disagree about what
## "starved" or "downstream" means. Pure data — no drawing, no sim access.

## The lenses, in hotkey order. NONE is the resting state: the always-on
## legibility layer is still up, nothing else is.
enum Mode {
	NONE,
	HEAT_NETWORK,   ## which grid is which, where the heat is flowing, how hard
	BOTTLENECK,     ## the tile that is strangling a building, and the victim
	THERMAL,        ## warmth over the terrain + the survival isotherm
	FREEZE,         ## internal temperature, time-to-freeze, structural damage
	LOGISTICS,      ## belts, fuel, stalled machines
	COVERAGE,       ## turret range, walking distance, unserved structures
}

const MODE_COUNT: int = 7

const MODE_IDS: Array[StringName] = [
	&"none", &"heat_network", &"bottleneck", &"thermal", &"freeze", &"logistics", &"coverage",
]
const MODE_TITLES: Array[String] = [
	"", "HEAT NETWORK", "BOTTLENECKS", "WARMTH", "FREEZE & DAMAGE", "LOGISTICS", "COVERAGE",
]
const MODE_BLURBS: Array[String] = [
	"",
	"one hue per grid — if two halves differ, they are not connected",
	"the tile that is strangling each starving building",
	"degrees on the ground; inside the line the city can live",
	"how cold every building is and how long it has left",
	"belts, bunkers and the machines that stopped",
	"what your turrets reach and what nothing reaches",
]

## Bit flags on a heat node in the snapshot.
const F_PRODUCER: int = 1 << 0
const F_CONSUMER: int = 1 << 1
const F_CONDUIT: int = 1 << 2
const F_BUFFER: int = 1 << 3
const F_RADIATOR: int = 1 << 4
const F_FROZEN: int = 1 << 5
const F_DISABLED: int = 1 << 6
const F_STARVED_FUEL: int = 1 << 7
const F_UNREACHABLE: int = 1 << 8   ## on a network but no route from any live source
const F_CHOKED: int = 1 << 9        ## this tile is itself a bottleneck
const F_REPEATER: int = 1 << 10
const F_STARVED: int = 1 << 11      ## served < 1, i.e. asking for heat it did not get
const F_NO_NETWORK: int = 1 << 12   ## wants heat, sits on no grid at all

## Direction bits used for pipe flow. Order matches DIR_VECTORS.
const D_EAST: int = 1 << 0
const D_WEST: int = 1 << 1
const D_SOUTH: int = 1 << 2
const D_NORTH: int = 1 << 3

const DIR_VECTORS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

## Why a consumer is short. Mirrors HeatNode.bottleneck_kind.
enum Choke { NONE, CAPACITY, SUPPLY, UNREACHABLE }

const CHOKE_LABELS: Array[String] = [
	"", "OVER CAPACITY", "NOT ENOUGH GENERATION", "NOT CONNECTED",
]

## What the always-on layer can complain about, worst last so `maxi` picks the
## loudest problem for a building that has several.
enum Problem {
	NONE,
	BUILDING,     ## under construction — informational, never pulses
	NO_WORKER,
	NO_INPUT,
	OUTPUT_FULL,
	NO_FUEL,
	BROWNOUT,
	DAMAGED,
	NO_HEAT,
	UNPOWERED,    ## wants heat and is on no grid at all
	FROZEN,
}

const PROBLEM_COUNT: int = 11

const PROBLEM_LABELS: Array[String] = [
	"", "building", "no crew", "no input", "output full", "no fuel",
	"brownout", "damaged", "no heat", "no grid", "FROZEN",
]

## 0 calm, 1 warn, 2 critical. Only 1 and 2 ever pulse.
const PROBLEM_SEVERITY: Array[int] = [0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 2]


static func mode_id(mode: int) -> StringName:
	return MODE_IDS[mode] if mode >= 0 and mode < MODE_COUNT else &"none"


static func mode_title(mode: int) -> String:
	return MODE_TITLES[mode] if mode >= 0 and mode < MODE_COUNT else ""


static func mode_blurb(mode: int) -> String:
	return MODE_BLURBS[mode] if mode >= 0 and mode < MODE_COUNT else ""


static func mode_from_id(id: StringName) -> int:
	var at: int = MODE_IDS.find(id)
	return at if at >= 0 else Mode.NONE


static func choke_label(kind: int) -> String:
	return CHOKE_LABELS[kind] if kind >= 0 and kind < CHOKE_LABELS.size() else ""


static func problem_label(p: int) -> String:
	return PROBLEM_LABELS[p] if p >= 0 and p < PROBLEM_COUNT else ""


static func problem_severity(p: int) -> int:
	return PROBLEM_SEVERITY[p] if p >= 0 and p < PROBLEM_COUNT else 0


## Bit for the direction from `a` to `b`, or 0 when they are not orthogonal
## neighbours in the four-way sense.
static func dir_bit(a: Vector2i, b: Vector2i) -> int:
	var d: Vector2i = b - a
	if absi(d.x) >= absi(d.y):
		if d.x > 0:
			return D_EAST
		if d.x < 0:
			return D_WEST
		return 0
	if d.y > 0:
		return D_SOUTH
	return D_NORTH
