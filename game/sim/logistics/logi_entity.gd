class_name LogiEntity
extends RefCounted
## One placed piece of transport. A record, not a machine: everything that
## happens to it happens in LogiWorld, which is what keeps the tick loop in one
## readable place instead of scattered across a hundred little objects.

var id: int = -1
var kind: StringName = &""
var def: LogiDef = null
var cell: Vector2i = Vector2i.ZERO
var rot: int = 0
var cells: Array[Vector2i] = []
var enabled: bool = true
## True when [P11] owns this building and logistics only adopted its behaviour.
var from_build: bool = false
var placed_tick: int = 0

# --- belts and undergrounds -------------------------------------------------

## Transport line this tile belongs to, or -1.
var seg_id: int = -1
## Index of this tile inside that line, entry first.
var seg_index: int = 0
## Underground: the other end of the pair, or -1 while it is unpaired.
var pair_id: int = -1
## Underground: true for the mouth items go in at.
var is_entrance: bool = true

# --- containers -------------------------------------------------------------

var store: LogiStore = null


func direction() -> Vector2i:
	return LogiTypes.dir_vec(rot)


func role() -> int:
	return LogiTypes.Role.NONE if def == null else def.role_id()


func is_belt() -> bool:
	return role() == LogiTypes.Role.BELT


func is_underground() -> bool:
	return role() == LogiTypes.Role.UNDERGROUND


func is_transport() -> bool:
	var r: int = role()
	return r == LogiTypes.Role.BELT or r == LogiTypes.Role.UNDERGROUND


func world_pos() -> Vector2:
	return LogiTypes.cell_center(cell)


func to_json() -> Dictionary:
	var d: Dictionary = {
		"id": id,
		"kind": String(kind),
		"cell": LogiTypes.cell_to_json(cell),
		"rot": rot,
		"enabled": enabled,
	}
	if from_build:
		d["from_build"] = true
	if is_transport():
		d["seg"] = seg_id
	if is_underground():
		d["pair"] = pair_id
		d["entrance"] = is_entrance
	if store != null:
		d["store"] = store.to_json()
	return d
