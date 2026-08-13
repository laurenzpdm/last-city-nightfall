class_name GridChunk
extends RefCounted
## One 32x32 block of tiles, stored as flat packed arrays.
##
## Deliberately not one object per tile: a 500x500 world is 250 000 tiles and
## per-tile objects would cost hundreds of megabytes and thrash the GC. Six flat
## arrays of 1024 entries each keep a chunk at ~10 KB and make bulk operations
## (serialize, upload to the renderer, mapgen passes) a single memcpy.
##
## Passability is NOT stored: it is a pure function of terrain (see
## Grid.TERRAIN_FLAGS) plus building occupancy, so it can never drift out of sync.

var cx: int = 0
var cy: int = 0

var terrain: PackedByteArray = PackedByteArray()
var elevation: PackedByteArray = PackedByteArray()
var res_kind: PackedByteArray = PackedByteArray()
var snow: PackedByteArray = PackedByteArray()
var res_amount: PackedInt32Array = PackedInt32Array()
var occupancy: PackedInt32Array = PackedInt32Array()

## Bumped on every write. The renderer re-meshes a chunk only when this changes.
var version: int = 0
## Number of tiles in this chunk carrying a deposit with amount > 0.
var deposits: int = 0


func _init(chunk_x: int = 0, chunk_y: int = 0) -> void:
	cx = chunk_x
	cy = chunk_y
	terrain.resize(Grid.CHUNK_AREA)
	elevation.resize(Grid.CHUNK_AREA)
	res_kind.resize(Grid.CHUNK_AREA)
	snow.resize(Grid.CHUNK_AREA)
	res_amount.resize(Grid.CHUNK_AREA)
	occupancy.resize(Grid.CHUNK_AREA)


## World-space tile coordinate of this chunk's top-left tile.
func origin() -> Vector2i:
	return Vector2i(cx << Grid.CHUNK_SHIFT, cy << Grid.CHUNK_SHIFT)


func set_terrain(i: int, v: int) -> void:
	terrain[i] = v
	version += 1


func set_elevation(i: int, v: int) -> void:
	elevation[i] = v


func set_snow(i: int, v: int) -> void:
	snow[i] = v


func set_resource(i: int, kind: int, amount: int) -> void:
	var had: bool = res_amount[i] > 0
	res_kind[i] = kind
	res_amount[i] = amount
	var has: bool = amount > 0
	if has and not had:
		deposits += 1
	elif had and not has:
		deposits -= 1
	version += 1


func set_occupancy(i: int, id: int) -> void:
	occupancy[i] = id
	version += 1


## Replaces every field at once. Used by the generator, which fills local
## arrays and hands them over in one move instead of 1024 indexed writes.
func adopt(t: PackedByteArray, e: PackedByteArray, s: PackedByteArray) -> void:
	terrain = t
	elevation = e
	snow = s
	version += 1


func recount_deposits() -> void:
	var n: int = 0
	for i: int in range(Grid.CHUNK_AREA):
		if res_amount[i] > 0:
			n += 1
	deposits = n
