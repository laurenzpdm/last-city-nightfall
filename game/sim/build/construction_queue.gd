class_name ConstructionQueue
extends RefCounted
## The order construction sites get materials and build power.
##
## Ordering is (priority desc, placed tick asc, id asc). The tie-breakers are not
## decoration: two sites placed on the same tick must resolve the same way on
## every replay, or the whole determinism contract is a lie.

## priority, placed_tick, id — packed so the sort has no side lookups.
var _entries: Array[Vector3i] = []
var _index: Dictionary[int, bool] = {}
var _dirty: bool = false


func add(building_id: int, priority: int, placed_tick: int) -> void:
	if _index.has(building_id):
		return
	_entries.append(Vector3i(priority, placed_tick, building_id))
	_index[building_id] = true
	_dirty = true


func remove(building_id: int) -> bool:
	if not _index.erase(building_id):
		return false
	for i: int in range(_entries.size()):
		if _entries[i].z == building_id:
			_entries.remove_at(i)
			return true
	return true


func has(building_id: int) -> bool:
	return _index.has(building_id)


func size() -> int:
	return _entries.size()


func is_empty() -> bool:
	return _entries.is_empty()


## Site ids in service order.
func ids() -> Array[int]:
	_sort_if_needed()
	var out: Array[int] = []
	for e: Vector3i in _entries:
		out.append(e.z)
	return out


## Changes a site's priority, e.g. when the player marks a turret urgent.
func set_priority(building_id: int, priority: int) -> void:
	for i: int in range(_entries.size()):
		if _entries[i].z == building_id:
			_entries[i] = Vector3i(priority, _entries[i].y, building_id)
			_dirty = true
			return


func clear() -> void:
	_entries.clear()
	_index.clear()
	_dirty = false


func to_json() -> Array:
	_sort_if_needed()
	var out: Array = []
	for e: Vector3i in _entries:
		out.append([e.x, e.y, e.z])
	return out


func from_json(data: Array) -> void:
	clear()
	for raw: Variant in data:
		if typeof(raw) != TYPE_ARRAY:
			continue
		var arr: Array = raw
		if arr.size() < 3:
			continue
		add(int(arr[2]), int(arr[0]), int(arr[1]))


func _sort_if_needed() -> void:
	if not _dirty:
		return
	_entries.sort_custom(_less)
	_dirty = false


static func _less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x > b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z
