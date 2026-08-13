extends Node
## Content registry. Scans game/content/** at boot and indexes every Resource by id.
##
## This exists so parts never edit a shared list. To add a building, drop a .tres
## in game/content/buildings/. To add a law, drop one in game/content/laws/.
## No merge conflicts, no registration boilerplate.

const ROOT: String = "res://game/content"

## category -> { StringName id -> Resource }
var _items: Dictionary[String, Dictionary] = {}
var loaded: bool = false


func _ready() -> void:
	scan()


func scan() -> void:
	_items.clear()
	var dir := DirAccess.open(ROOT)
	if dir == null:
		Log.warn("registry", "no content dir at %s" % ROOT)
		loaded = true
		return
	for category: String in dir.get_directories():
		_scan_category(category, "%s/%s" % [ROOT, category])
	loaded = true
	var total: int = 0
	for c: String in _items:
		total += (_items[c] as Dictionary).size()
	Log.info("registry", "loaded %d items across %d categories" % [total, _items.size()])


func _scan_category(category: String, path: String) -> void:
	var bucket: Dictionary = _items.get(category, {})
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub: String in dir.get_directories():
		_scan_category(category, "%s/%s" % [path, sub])
	for f: String in dir.get_files():
		if not (f.ends_with(".tres") or f.ends_with(".res")):
			continue
		var full: String = "%s/%s" % [path, f]
		var res: Resource = load(full)
		if res == null:
			Log.error("registry", "failed to load %s" % full)
			continue
		var id: StringName = _id_of(res, f)
		if bucket.has(id):
			Log.error("registry", "duplicate id '%s' in %s (%s)" % [id, category, full])
			continue
		bucket[id] = res
	_items[category] = bucket


func _id_of(res: Resource, filename: String) -> StringName:
	if "id" in res:
		var v: Variant = res.get("id")
		if v != null and String(v) != "":
			return StringName(String(v))
	return StringName(filename.get_basename())


## Single item, or null.
func get_item(category: String, id: StringName) -> Resource:
	return (_items.get(category, {}) as Dictionary).get(id)


## Every item in a category, sorted by id — sorted so iteration is deterministic.
func all(category: String) -> Array[Resource]:
	var bucket: Dictionary = _items.get(category, {})
	var keys: Array = bucket.keys()
	keys.sort()
	var out: Array[Resource] = []
	for k: StringName in keys:
		out.append(bucket[k])
	return out


func ids(category: String) -> Array[StringName]:
	var keys: Array = (_items.get(category, {}) as Dictionary).keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


func has(category: String, id: StringName) -> bool:
	return (_items.get(category, {}) as Dictionary).has(id)


func categories() -> Array[String]:
	var keys: Array = _items.keys()
	keys.sort()
	var out: Array[String] = []
	for k: String in keys:
		out.append(k)
	return out
