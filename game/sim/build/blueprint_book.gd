class_name BlueprintBook
extends RefCounted
## The player's blueprint library: named stamps, in memory and on disk.
##
## The book lives inside the build system's state so it saves with the run, and
## mirrors to `user://blueprints/` so a stamp survives into the next campaign.

## Where exported stamps live between runs.
const DISK_DIR: String = "user://blueprints"

var _items: Dictionary[StringName, Blueprint] = {}
var _next_auto: int = 1


## Stores a stamp, assigning an id when it has none. Returns the id used.
func add(bp: Blueprint) -> StringName:
	if String(bp.id) == "":
		bp.id = StringName("bp_%d" % _next_auto)
		_next_auto += 1
	while _items.has(bp.id):
		bp.id = StringName("%s_%d" % [String(bp.id), _next_auto])
		_next_auto += 1
	_items[bp.id] = bp
	return bp.id


## Replaces whatever sits under `bp.id`. Used by rename and overwrite-on-save.
func put(bp: Blueprint) -> void:
	if String(bp.id) == "":
		add(bp)
		return
	_items[bp.id] = bp


func has(id: StringName) -> bool:
	return _items.has(id)


## The stored stamp, or null. Callers that transform it must copy() first.
func get_bp(id: StringName) -> Blueprint:
	return _items.get(id)


func remove(id: StringName) -> bool:
	return _items.erase(id)


## Ids in sorted order — the book is iterated in the sim, so order is fixed.
func ids() -> Array[StringName]:
	var keys: Array = _items.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


func all() -> Array[Blueprint]:
	var out: Array[Blueprint] = []
	for k: StringName in ids():
		out.append(_items[k])
	return out


func size() -> int:
	return _items.size()


func clear() -> void:
	_items.clear()
	_next_auto = 1


## Writes one stamp to `user://blueprints/<id>.json`. Returns OK or an error.
func export_to_disk(id: StringName, dir: String = DISK_DIR) -> int:
	var bp: Blueprint = get_bp(id)
	if bp == null:
		return ERR_DOES_NOT_EXIST
	return bp.save_to_file("%s/%s.json" % [dir, String(id)])


## Reads one stamp from disk into the book. Returns the id, or &"" on failure.
func import_from_disk(path: String) -> StringName:
	var bp: Blueprint = Blueprint.load_from_file(path)
	if bp == null:
		return &""
	put(bp)
	return bp.id


## Loads every .json stamp in a directory, sorted by filename for determinism.
## Returns how many were read.
func import_dir(dir: String = DISK_DIR) -> int:
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	var files: Array[String] = []
	for f: String in d.get_files():
		if f.ends_with(".json"):
			files.append(f)
	files.sort()
	var n: int = 0
	for f: String in files:
		if String(import_from_disk("%s/%s" % [dir, f])) != "":
			n += 1
	return n


func to_dict() -> Dictionary:
	var arr: Array = []
	for bp: Blueprint in all():
		arr.append(bp.to_dict())
	return {"next_auto": _next_auto, "items": arr}


func from_dict(data: Dictionary) -> void:
	clear()
	_next_auto = int(data.get("next_auto", 1))
	for raw: Variant in data.get("items", []):
		if typeof(raw) == TYPE_DICTIONARY:
			put(Blueprint.from_dict(raw))
