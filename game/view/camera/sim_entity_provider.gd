class_name SimEntityProvider
extends RefCounted
## Default selection provider: asks the simulation what sits under the cursor.
##
## It is deliberately duck-typed. The camera cannot know [P11]'s or [P07]'s internals,
## and neither part should have to know about the camera. Whichever sim system first
## implements one of the four documented lookups below starts answering selection
## queries with no wiring on either side; until then selection still reports cells,
## which is all a build tool needs.
##
## Read-only by contract: a provider answers questions, it never mutates sim state.
## Anything that changes the world goes through Sim.submit_command.

const POINT_METHODS: Array[StringName] = [&"entity_at_world", &"entity_at_cell"]
const RECT_METHODS: Array[StringName] = [&"entities_in_world_rect", &"entities_in_cell_rect"]

## Sim systems asked, in order. First one answering a given query wins.
var system_names: Array[StringName] = [&"build", &"combat", &"production", &"logistics"]
var tile_size: int = CameraTuning.TILE_SIZE

var _warned: bool = false


func entity_at_world(pos: Vector2) -> int:
	var cell: Vector2i = SelectionController.world_to_cell(pos, tile_size)
	for name: StringName in system_names:
		var sys: Object = CameraServices.sim_system(name)
		if sys == null:
			continue
		if sys.has_method(&"entity_at_world"):
			var id: int = int(sys.call(&"entity_at_world", pos))
			if id >= 0:
				return id
		elif sys.has_method(&"entity_at_cell"):
			var id2: int = int(sys.call(&"entity_at_cell", cell))
			if id2 >= 0:
				return id2
	_warn_once()
	return -1


func entities_in_world_rect(rect: Rect2) -> PackedInt32Array:
	var cells: Rect2i = SelectionController.cell_rect(rect.position, rect.end, tile_size)
	var out: PackedInt32Array = PackedInt32Array()
	for name: StringName in system_names:
		var sys: Object = CameraServices.sim_system(name)
		if sys == null:
			continue
		var found: Variant = null
		if sys.has_method(&"entities_in_world_rect"):
			found = sys.call(&"entities_in_world_rect", rect)
		elif sys.has_method(&"entities_in_cell_rect"):
			found = sys.call(&"entities_in_cell_rect", cells)
		if found == null:
			continue
		for id: int in _to_ids(found):
			if out.find(id) == -1:
				out.append(id)
	if out.is_empty():
		_warn_once()
	return out


## Whether any sim system can currently answer selection queries at all.
func available() -> bool:
	for name: StringName in system_names:
		var sys: Object = CameraServices.sim_system(name)
		if sys == null:
			continue
		for m: StringName in POINT_METHODS:
			if sys.has_method(m):
				return true
		for m2: StringName in RECT_METHODS:
			if sys.has_method(m2):
				return true
	return false


static func _to_ids(value: Variant) -> PackedInt32Array:
	if value is PackedInt32Array:
		var packed: PackedInt32Array = value
		return packed
	var out: PackedInt32Array = PackedInt32Array()
	if value is Array:
		for v: Variant in value:
			out.append(int(v))
	return out


func _warn_once() -> void:
	if _warned:
		return
	_warned = true
	CameraServices.log_debug("camera", "no sim system answers entity lookups yet; selection reports cells only")
