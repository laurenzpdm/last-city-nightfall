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
	for raw: String in dir.get_files():
		# AN EXPORTED BUILD HAS NO .tres ON DISK, and this loop threw all 226
		# items away because of it. The exporter rewrites every text resource to
		# binary under `.godot/exported/` and leaves a `<name>.tres.remap` at the
		# original path. `load()` follows that remap perfectly well — but
		# `get_files()` reports `hearth.tres.remap`, the extension test below
		# refused it, and `dist/linux/last-city-nightfall.x86_64` came up with
		# `loaded 0 items across 20 categories`: no buildings, no recipes, no
		# enemies, no laws, and none of the `*_bootstrap.tres` that install the
		# view. Every suite in this repo runs from source, so nothing here could
		# ever have seen it; it was found by running the shipped binary.
		var f: String = raw.get_basename() if raw.ends_with(".remap") else raw
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


## THE PLAYER-FACING NAME OF ANYTHING WITH AN ID, from content, once.
##
## Three parts each grew their own id-to-words helper and none of them ever
## reached the content that carries the answer:
##
##   [P17] `LcnHudFormat.item_title` asked categories "items" and "resources".
##         Neither folder exists — items live in `game/content/logistics/` — so
##         every lookup missed and every caller got the titleized id.
##   [P18] `LcnUiFormat.item_name` titleizes and says so in its own header:
##         "nothing in content carries a display name for ITEMS yet — when [P04]
##         ships ItemDefs this is the single place that has to learn to ask."
##         [P04] shipped. Seventeen LogiItems carry `display_name`.
##   [P20] `LcnStatsDefs.item_label` titleizes with no comment at all.
##
## Twenty-two ids in this build read differently the two ways, and the player
## meets both: the build palette offers a **Slat Belt**, a **Sorting Table** and
## a **Lagged Pipe**; the research tree that unlocks them, the recipe browser and
## the statistics table call the same three things **Belt Mk1**, **Splitter Mk1**
## and **Heat Pipe Insulated**. Nothing connects the node you finished to the
## entry you are looking for.
##
## `CATEGORY` order is search order, and it is content-first with the widest
## vocabulary last: a kind that is both a building and a carried item (a belt is
## both) must resolve to the same words either way, and it does because both
## files carry the same `display_name`.
static var NAMED_CATEGORIES: PackedStringArray = PackedStringArray([
	"buildings", "logistics", "recipes", "research", "laws", "enemies", "weapons",
])


## Display name for `id`, or "" when no content carries one. Callers keep their
## own fallback — this function never invents words, because a titleized id is a
## part's own house style and a wrong guess from here would be everybody's.
func display_name(id: StringName, categories: PackedStringArray = NAMED_CATEGORIES) -> String:
	if String(id) == "":
		return ""
	for category: String in categories:
		var res: Resource = get_item(category, id)
		if res == null:
			continue
		if not ("display_name" in res):
			continue
		var dn: String = String(res.get("display_name"))
		if dn != "":
			return dn
	return ""
