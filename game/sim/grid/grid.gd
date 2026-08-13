class_name Grid
extends RefCounted
## Static geometry and world constants for the 32 px square tile grid.
##
## Pure functions only — no state, no allocation of world data, no engine
## singletons. Safe to call from sim, view and ui alike. The authoritative
## tile store is [WorldGrid]; this file is the maths around it.

const TILE_SIZE: int = 32
const TILE_SIZE_F: float = 32.0
const HALF_TILE_F: float = 16.0
const CHUNK_SIZE: int = 32
const CHUNK_SHIFT: int = 5
const CHUNK_MASK: int = 31
const CHUNK_AREA: int = 1024

## Ground material of a tile. Index order is serialized — append, never reorder.
enum Terrain {
	SNOW,
	DEEP_SNOW,
	ICE,
	GRAVEL,
	ROCK,
	RIDGE,
	CHASM,
	GEOTHERMAL,
	ASH,
	RUBBLE,
	WRECK,
	ROAD,
}
const TERRAIN_COUNT: int = 12

## Harvestable deposit on a tile. Index order is serialized — append, never reorder.
enum Res {
	NONE,
	SCRAP,
	COAL,
	IRON,
	COPPER,
	SULFUR,
	VENT,
}
const RES_COUNT: int = 7

const TERRAIN_NAMES: Array[String] = [
	"snow", "deep_snow", "ice", "gravel", "rock", "ridge", "chasm",
	"geothermal", "ash", "rubble", "wreck", "road",
]
const RES_NAMES: Array[String] = [
	"none", "scrap", "coal", "iron", "copper", "sulfur", "vent",
]

# --- passability bit flags (derived from Terrain, never stored per tile) ---
const F_WALK: int = 1 << 0          ## ground units may enter
const F_BUILD: int = 1 << 1         ## a structure may be placed here
const F_BLOCK_SIGHT: int = 1 << 2   ## breaks line of sight
const F_FLY: int = 1 << 3           ## flyers may cross even if not walkable
const F_HAZARD: int = 1 << 4        ## lethal / damaging to ground units
const F_WARM: int = 1 << 5          ## geothermal ground: snow never settles

const TERRAIN_FLAGS: Array[int] = [
	F_WALK | F_BUILD | F_FLY,                              # SNOW
	F_WALK | F_BUILD | F_FLY,                              # DEEP_SNOW
	F_WALK | F_BUILD | F_FLY,                              # ICE
	F_WALK | F_BUILD | F_FLY,                              # GRAVEL
	F_WALK | F_BUILD | F_FLY,                              # ROCK
	F_BLOCK_SIGHT,                                         # RIDGE
	F_FLY | F_HAZARD,                                      # CHASM
	F_WALK | F_BUILD | F_FLY | F_WARM,                     # GEOTHERMAL
	F_WALK | F_BUILD | F_FLY | F_WARM,                     # ASH
	F_WALK | F_BUILD | F_FLY,                              # RUBBLE
	F_WALK | F_BUILD | F_FLY | F_BLOCK_SIGHT,              # WRECK
	F_WALK | F_BUILD | F_FLY,                              # ROAD
]

## Movement cost in tenths of a tile. IMPASSABLE marks a wall.
const IMPASSABLE: int = 255
const COST_MIN: int = 6
const COST_MAX: int = 24
const TERRAIN_COST: Array[int] = [
	10,        # SNOW
	17,        # DEEP_SNOW
	9,         # ICE
	10,        # GRAVEL
	12,        # ROCK
	IMPASSABLE,# RIDGE
	IMPASSABLE,# CHASM
	9,         # GEOTHERMAL
	10,        # ASH
	14,        # RUBBLE
	16,        # WRECK
	6,         # ROAD
]

## E, SE, S, SW, W, NW, N, NE. Index 8 means "no direction".
const DIRS8: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
]
const DIRS4: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
]
const DIR_NONE: int = 8
const ZERO: Vector2i = Vector2i(0, 0)


# ---------------------------------------------------------------- conversion

## Centre of a tile in world pixels.
static func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(float(cell.x) * TILE_SIZE_F + HALF_TILE_F, float(cell.y) * TILE_SIZE_F + HALF_TILE_F)


## Top-left corner of a tile in world pixels.
static func cell_origin(cell: Vector2i) -> Vector2:
	return Vector2(float(cell.x) * TILE_SIZE_F, float(cell.y) * TILE_SIZE_F)


## World pixels to the tile that contains them. Correct for negative coords.
static func world_to_cell(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / TILE_SIZE_F), floori(pos.y / TILE_SIZE_F))


## Pixel rect covered by a footprint anchored at its top-left tile.
static func footprint_rect(cell: Vector2i, size: Vector2i) -> Rect2:
	return Rect2(cell_origin(cell), Vector2(float(size.x) * TILE_SIZE_F, float(size.y) * TILE_SIZE_F))


## Pixel centre of a footprint — where a building sprite and its turret sit.
static func footprint_center(cell: Vector2i, size: Vector2i) -> Vector2:
	return cell_origin(cell) + Vector2(float(size.x) * HALF_TILE_F, float(size.y) * HALF_TILE_F)


## Every tile of a footprint, row-major. Deterministic order.
static func footprint_cells(cell: Vector2i, size: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy: int in range(maxi(size.y, 1)):
		for dx: int in range(maxi(size.x, 1)):
			out.append(Vector2i(cell.x + dx, cell.y + dy))
	return out


static func chunk_coord(cell: Vector2i) -> Vector2i:
	return Vector2i(cell.x >> CHUNK_SHIFT, cell.y >> CHUNK_SHIFT)


static func local_index(cell: Vector2i) -> int:
	return ((cell.y & CHUNK_MASK) << CHUNK_SHIFT) | (cell.x & CHUNK_MASK)


## Packs a cell into a single int usable as a Dictionary key (|coord| < 2^20).
static func key(cell: Vector2i) -> int:
	return ((cell.x + 0x80000) << 21) | (cell.y + 0x80000)


static func unkey(k: int) -> Vector2i:
	return Vector2i((k >> 21) - 0x80000, (k & 0x1FFFFF) - 0x80000)


# ---------------------------------------------------------------- neighbours

static func neighbours4(cell: Vector2i) -> Array[Vector2i]:
	return [
		Vector2i(cell.x + 1, cell.y), Vector2i(cell.x, cell.y + 1),
		Vector2i(cell.x - 1, cell.y), Vector2i(cell.x, cell.y - 1),
	]


static func neighbours8(cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d: Vector2i in DIRS8:
		out.append(cell + d)
	return out


## Index into DIRS8 for a unit step, or DIR_NONE.
static func dir_index(step: Vector2i) -> int:
	for i: int in range(8):
		if DIRS8[i] == step:
			return i
	return DIR_NONE


static func dir_vector(index: int) -> Vector2i:
	return DIRS8[index] if index >= 0 and index < 8 else ZERO


## Opposite of a DIRS8 index.
static func dir_opposite(index: int) -> int:
	return DIR_NONE if index >= 8 or index < 0 else (index + 4) & 7


# ---------------------------------------------------------------- distances

static func manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


static func chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## Squared euclidean distance in tiles. Integer, so it is replay-safe.
static func dist_sq(a: Vector2i, b: Vector2i) -> int:
	var dx: int = a.x - b.x
	var dy: int = a.y - b.y
	return dx * dx + dy * dy


## Octile distance in the same tenths-of-a-tile unit the flow field uses.
static func octile_cost(a: Vector2i, b: Vector2i) -> int:
	var dx: int = absi(a.x - b.x)
	var dy: int = absi(a.y - b.y)
	var lo: int = mini(dx, dy)
	return 14 * lo + 10 * (dx + dy - 2 * lo)


# ---------------------------------------------------------------- iteration

## Square ring at Chebyshev radius r, clockwise from the top-left corner.
static func ring(center: Vector2i, r: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if r <= 0:
		out.append(center)
		return out
	var x0: int = center.x - r
	var x1: int = center.x + r
	var y0: int = center.y - r
	var y1: int = center.y + r
	for x: int in range(x0, x1 + 1):
		out.append(Vector2i(x, y0))
	for y: int in range(y0 + 1, y1 + 1):
		out.append(Vector2i(x1, y))
	for x: int in range(x1 - 1, x0 - 1, -1):
		out.append(Vector2i(x, y1))
	for y: int in range(y1 - 1, y0, -1):
		out.append(Vector2i(x0, y))
	return out


## Centre outward, ring by ring. Use for "nearest thing that satisfies X".
static func spiral(center: Vector2i, max_radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for r: int in range(0, maxi(max_radius, 0) + 1):
		out.append_array(ring(center, r))
	return out


## Filled disc of tiles whose centre is within `radius` tiles.
static func disc(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var r2: int = radius * radius
	for dy: int in range(-radius, radius + 1):
		for dx: int in range(-radius, radius + 1):
			if dx * dx + dy * dy <= r2:
				out.append(Vector2i(center.x + dx, center.y + dy))
	return out


static func rect_cells(rect: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y: int in range(rect.position.y, rect.position.y + rect.size.y):
		for x: int in range(rect.position.x, rect.position.x + rect.size.x):
			out.append(Vector2i(x, y))
	return out


## Bresenham line, endpoints included. Steps diagonally where the line is exact.
static func line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var x: int = a.x
	var y: int = a.y
	var dx: int = absi(b.x - a.x)
	var dy: int = absi(b.y - a.y)
	var sx: int = 1 if b.x > a.x else -1
	var sy: int = 1 if b.y > a.y else -1
	var err: int = dx - dy
	var guard: int = dx + dy + 2
	out.append(Vector2i(x, y))
	while (x != b.x or y != b.y) and guard > 0:
		guard -= 1
		var e2: int = err * 2
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy
		out.append(Vector2i(x, y))
	return out


## Every tile the segment touches, including the corners it clips. Endpoints included.
static func supercover(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var x: int = a.x
	var y: int = a.y
	var dx: int = absi(b.x - a.x)
	var dy: int = absi(b.y - a.y)
	var sx: int = 1 if b.x > a.x else -1
	var sy: int = 1 if b.y > a.y else -1
	var err: int = dx - dy
	out.append(Vector2i(x, y))
	var steps: int = dx + dy
	for _i: int in range(steps):
		var e2: int = err * 2
		if e2 > -dy and e2 < dx:
			# exact diagonal: take the horizontal corner so nothing is skipped
			err -= dy
			x += sx
			out.append(Vector2i(x, y))
			err += dx
			y += sy
		elif e2 > -dy:
			err -= dy
			x += sx
		else:
			err += dx
			y += sy
		out.append(Vector2i(x, y))
		if x == b.x and y == b.y:
			break
	return out


## Generic 4-way flood fill. `accept` is `func(cell: Vector2i) -> bool`.
## Returns the filled cells in breadth-first order, capped at `max_cells`.
static func flood_fill(start: Vector2i, max_cells: int, accept: Callable) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not accept.call(start):
		return out
	var seen: Dictionary[int, bool] = {}
	var queue: Array[Vector2i] = [start]
	seen[key(start)] = true
	var head: int = 0
	while head < queue.size() and out.size() < max_cells:
		var c: Vector2i = queue[head]
		head += 1
		out.append(c)
		for d: Vector2i in DIRS4:
			var n: Vector2i = c + d
			var k: int = key(n)
			if seen.has(k):
				continue
			seen[k] = true
			if accept.call(n):
				queue.append(n)
	return out


# ---------------------------------------------------------------- misc

static func terrain_name(t: int) -> String:
	return TERRAIN_NAMES[t] if t >= 0 and t < TERRAIN_COUNT else "?"


static func res_name(r: int) -> String:
	return RES_NAMES[r] if r >= 0 and r < RES_COUNT else "?"


static func terrain_flags(t: int) -> int:
	return TERRAIN_FLAGS[t] if t >= 0 and t < TERRAIN_COUNT else 0
