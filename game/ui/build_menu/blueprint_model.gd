class_name LcnBlueprintModel
extends RefCounted
## [P18] The blueprint library, made visible.
##
## [P11] already ships capture, rotate, mirror, a book and a paste that validates
## the whole stamp as a unit — and until now none of it appeared on screen, so
## effectively none of it existed. This model turns the book into cards a panel
## can draw and click:
##
##   * a real THUMBNAIL, drawn from the stamp's own footprints and [P13]'s tints,
##     so two heat blocks are told apart at a glance
##   * what it costs, measured against what the city holds RIGHT NOW
##   * what it contains, by kind
##   * whether it still references content that exists
##
## Renaming lives in UI state, not in the sim: [P11] has no rename command, and
## inventing one from the UI would mean writing into simulation state from a
## click. The override travels with the rest of the panel state instead, and the
## day a rename op exists this class hands it the command and stops overriding.

## One card in the library.
class Card extends RefCounted:
	var id: StringName = &""
	var title: String = ""
	## True when the title shown is a UI-side rename rather than the stamp's own.
	var renamed: bool = false
	var description: String = ""
	var size: Vector2i = Vector2i.ONE
	var entry_count: int = 0
	var created_tick: int = 0
	var kind_counts: Dictionary[StringName, int] = {}
	var cost: Dictionary[StringName, int] = {}
	var missing: Dictionary[StringName, int] = {}
	var missing_kinds: Array[StringName] = []
	var affordable: bool = true
	## {rect: Rect2i, color: Color, kind: StringName} per building in the stamp.
	var thumb: Array[Dictionary] = []
	var bp: Object = null

	func is_broken() -> bool:
		return not missing_kinds.is_empty()

	func subtitle() -> String:
		return "%d x %d  ·  %d building%s" % [
			size.x, size.y, entry_count, "" if entry_count == 1 else "s"]

	func cost_label() -> String:
		return LcnUiFormat.items(cost)

	func contents_label() -> String:
		var keys: Array = kind_counts.keys()
		keys = LcnUiFormat.sorted_names(keys)
		var parts: PackedStringArray = PackedStringArray()
		for k: Variant in keys:
			parts.append("%d x %s" % [int(kind_counts[k]), LcnUiFormat.item_name(StringName(String(k)))])
		return ", ".join(parts)


var cards: Array[Card] = []

var _by_id: Dictionary[StringName, Card] = {}
var _revision: int = 0


## Reads the book out of [P11]. `overrides` maps blueprint id -> renamed title
## and comes from the panel's own state store.
func rebuild(build_system: Object, overrides: Dictionary = {}) -> void:
	cards.clear()
	_by_id.clear()
	_revision += 1
	if build_system == null:
		return
	var book: Object = build_system.get(&"book") as Object
	if book == null or not book.has_method(&"all"):
		return
	var stock: Object = build_system.get(&"stock") as Object

	for raw: Variant in book.call(&"all"):
		var bp: Object = raw
		if bp == null:
			continue
		var c := Card.new()
		c.bp = bp
		c.id = LcnUiFormat.as_name(bp.get(&"id"))
		c.title = LcnUiFormat.as_text(bp.get(&"title"))
		if overrides.has(String(c.id)):
			c.title = String(overrides[String(c.id)])
			c.renamed = true
		if c.title == "":
			c.title = "Untitled stamp"
		c.description = LcnUiFormat.as_text(bp.get(&"description"))
		c.size = bp.get(&"size") if typeof(bp.get(&"size")) == TYPE_VECTOR2I else Vector2i.ONE
		c.created_tick = LcnUiFormat.as_int(bp.get(&"created_tick"))
		if bp.has_method(&"entry_count"):
			c.entry_count = int(bp.call(&"entry_count"))
		if bp.has_method(&"kind_counts"):
			var counts: Dictionary = bp.call(&"kind_counts")
			var ck: Array = counts.keys()
			ck = LcnUiFormat.sorted_names(ck)
			for k: Variant in ck:
				c.kind_counts[StringName(String(k))] = int(counts[k])
		if bp.has_method(&"total_cost"):
			var bill: Dictionary = bp.call(&"total_cost")
			var bk: Array = bill.keys()
			bk = LcnUiFormat.sorted_names(bk)
			for k2: Variant in bk:
				c.cost[StringName(String(k2))] = int(bill[k2])
		if bp.has_method(&"missing_kinds"):
			for m: Variant in bp.call(&"missing_kinds"):
				c.missing_kinds.append(StringName(String(m)))
		if stock != null and stock.has_method(&"missing"):
			var short: Dictionary = stock.call(&"missing", c.cost)
			var sk: Array = short.keys()
			sk = LcnUiFormat.sorted_names(sk)
			for k3: Variant in sk:
				c.missing[StringName(String(k3))] = int(short[k3])
			c.affordable = c.missing.is_empty()
		c.thumb = thumbnail_of(bp, build_system)
		cards.append(c)
		_by_id[c.id] = c

	cards.sort_custom(_card_less)


func revision() -> int:
	return _revision


func size() -> int:
	return cards.size()


func card(id: StringName) -> Card:
	return _by_id.get(id)


func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for c: Card in cards:
		out.append(c.id)
	return out


## Newest first: a player who just copied something wants it at the top.
static func _card_less(a: Card, b: Card) -> bool:
	if a.created_tick != b.created_tick:
		return a.created_tick > b.created_tick
	if a.title != b.title:
		return a.title < b.title
	return String(a.id) < String(b.id)


## The drawable form of a stamp: one coloured rectangle per building, in stamp
## coordinates. The panel scales it into whatever box it has.
static func thumbnail_of(bp: Object, build_system: Object) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if bp == null:
		return out
	var entries: Variant = bp.get(&"entries")
	if typeof(entries) != TYPE_ARRAY:
		return out
	for raw: Variant in (entries as Array):
		var e: Object = raw
		if e == null:
			continue
		var kind := LcnUiFormat.as_name(e.get(&"kind"))
		var offset: Vector2i = e.get(&"offset") if typeof(e.get(&"offset")) == TYPE_VECTOR2I else Vector2i.ZERO
		var span: Vector2i = e.get(&"span") if typeof(e.get(&"span")) == TYPE_VECTOR2I else Vector2i.ONE
		var colour: Color = LcnPalette.STEEL_LIGHT
		if build_system != null and build_system.has_method(&"def_of"):
			var def: Resource = build_system.call(&"def_of", kind) as Resource
			colour = LcnUiStyle.building_color(def)
		out.append({
			"rect": Rect2i(offset, Vector2i(maxi(1, span.x), maxi(1, span.y))),
			"color": colour,
			"kind": String(kind),
		})
	return out


# -------------------------------------------------------------- commands -----
# Every mutation goes out as a command through Sim, exactly as a scripted
# scenario would. The UI never touches [P11]'s dictionaries.

static func place_command(id: StringName, cell: Vector2i, rot: int = 0,
		mirror_x: bool = false, mirror_y: bool = false) -> Dictionary:
	return {
		"system": &"build", "op": "place_blueprint", "blueprint": String(id),
		"cell": [cell.x, cell.y], "rot": rot,
		"mirror_x": mirror_x, "mirror_y": mirror_y,
	}


static func delete_command(id: StringName) -> Dictionary:
	return {"system": &"build", "op": "delete_blueprint", "blueprint": String(id)}


static func export_command(id: StringName) -> Dictionary:
	return {"system": &"build", "op": "save_blueprint", "blueprint": String(id)}


static func import_command(dir: String = "user://blueprints") -> Dictionary:
	return {"system": &"build", "op": "load_blueprint", "dir": dir}


static func capture_command(from: Vector2i, to: Vector2i, title: String) -> Dictionary:
	return {
		"system": &"build", "op": "capture_blueprint",
		"from": [from.x, from.y], "to": [to.x, to.y], "title": title,
	}


static func transform_command(id: StringName, rot: int, mirror_x: bool, mirror_y: bool) -> Dictionary:
	return {
		"system": &"build", "op": "transform_blueprint", "blueprint": String(id),
		"rot": rot, "mirror_x": mirror_x, "mirror_y": mirror_y,
	}
