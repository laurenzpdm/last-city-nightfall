class_name LogiTypes
extends RefCounted
## [P03] Shared vocabulary for logistics: directions, lane geometry, and the
## numbers every other file in game/sim/logistics/ agrees on.
##
## THROUGHPUT MATH, written down once so it can be checked rather than trusted.
## A lane holds [constant ITEMS_PER_TILE] items per tile, so compressed items sit
## [constant SPACING] tiles apart. A lane running at `speed` tiles per second
## therefore carries `speed * ITEMS_PER_TILE` items per second, and a belt — two
## lanes — carries twice that:
##
##     tier   speed (tiles/s)   lane (items/s)   belt (items/s)
##     mk1    1.875             7.5              15
##     mk2    3.750             15               30
##     mk3    5.625             22.5             45
##
## That is the same ladder Factorio uses, deliberately: players arrive with
## intuitions about 15/30/45 and a ratio of 1 : 2 : 3, and those intuitions
## should transfer. Note that a tick is 50 ms, so an mk3 lane must move 1.125
## items per tick — every hand-off in this part has to be able to pass more than
## one item in a tick or the tier would silently cap at 20 items/s.
##
## Positions along a lane are measured in TILES FROM THE EXIT: 0.0 is the leading
## edge of the last tile (the item is about to leave), `length` is the back of the
## first tile (the item has just entered). Smaller means further along.

const TILE: float = 32.0
const EPS: float = 0.00001

## Item slots per tile of ONE lane. A belt tile holds 2 * ITEMS_PER_TILE items.
const ITEMS_PER_TILE: int = 4
const SPACING: float = 1.0 / float(ITEMS_PER_TILE)

const LANE_LEFT: int = 0
const LANE_RIGHT: int = 1
const LANES: int = 2

## Longest run of belt tiles kept in one transport line. Beyond this the run is
## cut and the halves chain, which bounds the cost of a single rebuild.
const MAX_SEGMENT_TILES: int = 192

## What a transport line feeds into.
enum Sink {
	NONE,      ## nothing: items back up, which is what a player expects
	BELT,      ## the back of another line
	SIDE,      ## the flank of another line — one lane only, Factorio's side-load
	SPLITTER,  ## a splitter, which PULLS rather than being pushed into
	STORE,     ## a chest, yard or machine buffer straight off the end of the belt
}

## Roles a logistics definition can take.
enum Role { NONE, BELT, UNDERGROUND, SPLITTER, INSERTER, CHEST }

const ROLE_NAMES: Array[StringName] = [
	&"none", &"belt", &"underground", &"splitter", &"inserter", &"chest",
]

## Rotation 0..3 as a step on the grid. Clockwise in a y-down world:
## 0 east, 1 south, 2 west, 3 north.
const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
]


static func dir_vec(rot: int) -> Vector2i:
	return DIRS[posmod(rot, 4)]


## Quarter-turns for a step vector, or -1 when it is not one of the four.
static func rot_of(d: Vector2i) -> int:
	for i: int in 4:
		if DIRS[i] == d:
			return i
	return -1


## The tile to the travelling item's left. With y pointing down the screen,
## facing east means left is north.
static func left_of(d: Vector2i) -> Vector2i:
	return Vector2i(d.y, -d.x)


static func right_of(d: Vector2i) -> Vector2i:
	return Vector2i(-d.y, d.x)


## Lane a neighbour on `side_step` loads into: the near one.
static func lane_for_side(d: Vector2i, side_step: Vector2i) -> int:
	return LANE_LEFT if side_step == left_of(d) else LANE_RIGHT


## Centre of a tile in world pixels.
static func cell_center(cell: Vector2i) -> Vector2:
	return Vector2((float(cell.x) + 0.5) * TILE, (float(cell.y) + 0.5) * TILE)


## Sideways offset of a lane from the middle of the belt, in world pixels.
static func lane_offset(d: Vector2i, lane: int) -> Vector2:
	var step: Vector2i = left_of(d) if lane == LANE_LEFT else right_of(d)
	return Vector2(float(step.x), float(step.y)) * (TILE * 0.25)


## Items per second one lane of a belt running at `speed` tiles/s can carry.
static func lane_rate(speed: float) -> float:
	return speed * float(ITEMS_PER_TILE)


## Reads a cell out of whatever a command handed us: Vector2i, Vector2,
## [x, y] or {"x": .., "y": ..}.
static func to_cell(v: Variant) -> Vector2i:
	match typeof(v):
		TYPE_VECTOR2I:
			return v
		TYPE_VECTOR2:
			var f: Vector2 = v
			return Vector2i(int(f.x), int(f.y))
		TYPE_ARRAY:
			var a: Array = v
			if a.size() >= 2:
				return Vector2i(int(a[0]), int(a[1]))
		TYPE_DICTIONARY:
			var d: Dictionary = v
			return Vector2i(int(d.get("x", 0)), int(d.get("y", 0)))
	return Vector2i.ZERO


static func cell_to_json(c: Vector2i) -> Array:
	return [c.x, c.y]


## Chebyshev distance — the grid's own idea of "how far away is that".
static func chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))
