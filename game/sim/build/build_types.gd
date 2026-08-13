class_name BuildTypes
extends RefCounted
## Shared vocabulary for [P11] Build & Construction.
##
## Lifecycle states, machine-readable rejection codes, and the pure coordinate
## helpers every layer must agree on. Pure data + static functions, no state —
## safe to call from sim, view and ui alike.

## Edge length of one grid tile in pixels. Mirrored from the world constants so
## the view layer can turn a building cell into a pixel position without a lookup.
const TILE_PX: int = 32

## Lifecycle of a building. Emitted as an int on Bus.building_state_changed.
## Values are frozen — the view and the save format index into them.
enum State {
	GHOST = 0,           ## planned; waiting for materials to be delivered
	CONSTRUCTING = 1,    ## materials delivered, build work in progress
	OPERATIONAL = 2,     ## finished and running
	DISABLED = 3,        ## finished, switched off by the player
	FROZEN = 4,          ## finished, but starved of heat and not running
	DECONSTRUCTING = 5,  ## being taken apart, refund pending
	DESTROYED = 6,       ## hp reached zero; removed on the same tick
}

## How the build menu should let the player drag this building out. [P18] reads it.
enum DragMode {
	SINGLE = 0,  ## one click, one building
	LINE = 1,    ## drag a straight run (pipes, walls, roads)
	AREA = 2,    ## drag a filled rectangle (foundations, floors)
}

## Every reason a placement can be refused. The string form is what the player
## sees; the code is what tests and UI logic branch on.
const CODE_OK: StringName = &"ok"
const CODE_UNKNOWN_KIND: StringName = &"unknown_kind"
const CODE_LOCKED: StringName = &"locked"
const CODE_MAX_COUNT: StringName = &"max_count"
const CODE_OUT_OF_BOUNDS: StringName = &"out_of_bounds"
const CODE_TERRAIN: StringName = &"terrain"
const CODE_NOT_FLAT: StringName = &"not_flat"
const CODE_OCCUPIED: StringName = &"occupied"
const CODE_NEEDS_ORE: StringName = &"needs_ore"
const CODE_SPACING: StringName = &"spacing"
const CODE_MUST_CONNECT: StringName = &"must_connect"
const CODE_MATERIALS: StringName = &"insufficient_materials"
const CODE_NOT_ROTATABLE: StringName = &"not_rotatable"
const CODE_NO_SUCH_BUILDING: StringName = &"no_such_building"
const CODE_EMPTY_REGION: StringName = &"empty_region"
const CODE_REGION_TOO_LARGE: StringName = &"region_too_large"
const CODE_UNKNOWN_BLUEPRINT: StringName = &"unknown_blueprint"
const CODE_NOTHING_TO_UNDO: StringName = &"nothing_to_undo"
const CODE_NOTHING_TO_REDO: StringName = &"nothing_to_redo"
const CODE_BAD_COMMAND: StringName = &"bad_command"
const CODE_IO: StringName = &"io_error"

## Largest rectangle a single blueprint capture or area command may cover.
## Keeps a stray drag from stalling a tick for a second.
const MAX_REGION_CELLS: int = 4096

## Ore id that means "any ore vein will do" in BuildingDef.needs_ore.
const ANY_ORE: StringName = &"*"


## Human label for a lifecycle state. Used by tooltips and the log.
static func state_name(state: int) -> String:
	match state:
		State.GHOST: return "planned"
		State.CONSTRUCTING: return "building"
		State.OPERATIONAL: return "running"
		State.DISABLED: return "off"
		State.FROZEN: return "frozen"
		State.DECONSTRUCTING: return "demolishing"
		State.DESTROYED: return "destroyed"
	return "unknown"


## True while the building physically exists on the grid and blocks placement.
static func state_occupies(state: int) -> bool:
	return state != State.DESTROYED


## True once the building is finished, regardless of whether it is running.
static func state_is_complete(state: int) -> bool:
	return state == State.OPERATIONAL or state == State.DISABLED \
		or state == State.FROZEN or state == State.DECONSTRUCTING


## Rotates a cell offset `rot` quarter-turns clockwise inside a `span`-sized box.
## The box itself flips w/h on every odd turn, which is what keeps 3x2 buildings honest.
static func rotate_cell(off: Vector2i, rot: int, span: Vector2i) -> Vector2i:
	var turns: int = posmod(rot, 4)
	var c: Vector2i = off
	var s: Vector2i = span
	for _i: int in turns:
		c = Vector2i(s.y - 1 - c.y, c.x)
		s = Vector2i(s.y, s.x)
	return c


## Footprint dimensions after `rot` quarter-turns.
static func rotated_size(size: Vector2i, rot: int) -> Vector2i:
	return size if posmod(rot, 4) % 2 == 0 else Vector2i(size.y, size.x)


## Mirrors a facing direction across the vertical axis (right <-> left).
static func mirror_rot_x(rot: int) -> int:
	return posmod(4 - posmod(rot, 4), 4)


## Mirrors a facing direction across the horizontal axis (up <-> down).
static func mirror_rot_y(rot: int) -> int:
	return posmod(2 - posmod(rot, 4), 4)


## Inclusive integer rectangle spanned by two corner cells, in any order.
static func region_rect(a: Vector2i, b: Vector2i) -> Rect2i:
	var lo := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	var hi := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
	return Rect2i(lo, hi - lo + Vector2i.ONE)


## The four orthogonal neighbours of a cell, in a fixed order (N, E, S, W).
## Fixed order matters: connection checks must not depend on iteration luck.
static func neighbors4(cell: Vector2i) -> Array[Vector2i]:
	return [
		cell + Vector2i(0, -1),
		cell + Vector2i(1, 0),
		cell + Vector2i(0, 1),
		cell + Vector2i(-1, 0),
	]


## Centre of a footprint in world pixels. The view layer's only conversion.
static func world_center(origin: Vector2i, size: Vector2i) -> Vector2:
	return Vector2(
		float(origin.x) * float(TILE_PX) + float(size.x) * float(TILE_PX) * 0.5,
		float(origin.y) * float(TILE_PX) + float(size.y) * float(TILE_PX) * 0.5
	)


## Parses a cell from anything a command or a JSON scenario can carry:
## Vector2i, [x, y], {"x": .., "y": ..}, "12,7", or Vector2.
static func to_cell(value: Variant) -> Vector2i:
	match typeof(value):
		TYPE_VECTOR2I:
			return value
		TYPE_VECTOR2:
			var v: Vector2 = value
			return Vector2i(roundi(v.x), roundi(v.y))
		TYPE_ARRAY:
			var arr: Array = value
			if arr.size() >= 2:
				return Vector2i(int(arr[0]), int(arr[1]))
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			var pi: Array = Array(value)
			if pi.size() >= 2:
				return Vector2i(int(pi[0]), int(pi[1]))
		TYPE_DICTIONARY:
			var d: Dictionary = value
			return Vector2i(int(d.get("x", 0)), int(d.get("y", 0)))
		TYPE_STRING, TYPE_STRING_NAME:
			var parts: PackedStringArray = String(value).split(",")
			if parts.size() >= 2:
				return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))
	return Vector2i.ZERO


## JSON-safe form of a cell. serialize() must never leak a Vector2i.
static func cell_to_json(cell: Vector2i) -> Array:
	return [cell.x, cell.y]


## Normalises an item bundle from a command or a resource into StringName -> int.
## Drops non-positive amounts so "give me 0 scrap" cannot poison a cost check.
static func to_items(value: Variant) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	if typeof(value) != TYPE_DICTIONARY:
		return out
	var src: Dictionary = value
	var keys: Array = src.keys()
	keys.sort()
	for k: Variant in keys:
		var amount: int = int(src[k])
		if amount <= 0:
			continue
		out[StringName(String(k))] = amount
	return out


## JSON-safe form of an item bundle, with string keys and sorted order.
static func items_to_json(items: Dictionary[StringName, int]) -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		out[String(k)] = items[k]
	return out


## Adds `add` into `into` in place. Used to accumulate refunds and blueprint costs.
static func add_items(into: Dictionary[StringName, int], add: Dictionary[StringName, int]) -> void:
	var keys: Array = add.keys()
	keys.sort()
	for k: StringName in keys:
		into[k] = int(into.get(k, 0)) + add[k]


## Like to_items(), but keeps explicit zeros. Only "set this to exactly N" wants
## this — every cost and refund path must keep dropping the zeros.
static func to_amounts(value: Variant) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	if typeof(value) != TYPE_DICTIONARY:
		return out
	var src: Dictionary = value
	var keys: Array = src.keys()
	keys.sort()
	for k: Variant in keys:
		out[StringName(String(k))] = maxi(0, int(src[k]))
	return out


## Scales an item bundle, rounding down but never below zero. Refund ratios use it.
static func scale_items(items: Dictionary[StringName, int], factor: float) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		var n: int = int(floor(float(items[k]) * factor))
		if n > 0:
			out[k] = n
	return out


## Scales an item bundle, rounding up. A charge must never round away to free:
## repairing a six-stone wall costs one stone, not nothing.
static func scale_items_up(items: Dictionary[StringName, int], factor: float) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	if factor <= 0.0:
		return out
	var keys: Array = items.keys()
	keys.sort()
	for k: StringName in keys:
		var n: int = int(ceil(float(items[k]) * factor))
		if n > 0:
			out[k] = n
	return out


## "40 scrap, 12 iron plate" — the phrasing costs and shortfalls use in the UI.
static func describe_items(items: Dictionary[StringName, int]) -> String:
	var keys: Array = items.keys()
	keys.sort()
	var parts: PackedStringArray = PackedStringArray()
	for k: StringName in keys:
		parts.append("%d %s" % [items[k], String(k).replace("_", " ")])
	return ", ".join(parts) if parts.size() > 0 else "nothing"
