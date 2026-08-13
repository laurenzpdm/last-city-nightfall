class_name Blueprint
extends Resource
## A reusable stamp of a chunk of city: copy a rectangle, rotate it, mirror it,
## paste it anywhere, and let construction fulfil it over time.
##
## Blueprints are the reason a second base does not cost a second hour. They are
## pure data — every transform returns a NEW blueprint, so a book entry is never
## silently mutated by a preview rotation.

## Stable id inside the blueprint book.
@export var id: StringName = &""
## Player-facing name.
@export var title: String = "Blueprint"
## Optional note the player types.
@export var description: String = ""
## Bounding box of the stamp in tiles.
@export var size: Vector2i = Vector2i.ONE
## Buildings in the stamp, sorted by (offset.y, offset.x, kind) so two captures
## of the same layout always produce byte-identical data.
@export var entries: Array[BlueprintEntry] = []
## Tick it was captured, for sorting the book by recency.
@export var created_tick: int = 0
## Up to four kinds used as the book icon.
@export var icon_kinds: Array[StringName] = []


## Number of buildings in the stamp.
func entry_count() -> int:
	return entries.size()


## Deep copy. Everything that hands a blueprint out uses this.
func copy() -> Blueprint:
	var bp := Blueprint.new()
	bp.id = id
	bp.title = title
	bp.description = description
	bp.size = size
	bp.created_tick = created_tick
	bp.icon_kinds = icon_kinds.duplicate()
	var out: Array[BlueprintEntry] = []
	for e: BlueprintEntry in entries:
		out.append(e.copy())
	bp.entries = out
	return bp


## Sorts entries into canonical order and refreshes the icon list.
## Called after every capture and transform so equality is comparable.
func canonicalize() -> void:
	entries.sort_custom(_entry_less)
	var seen: Dictionary[StringName, bool] = {}
	var icons: Array[StringName] = []
	for e: BlueprintEntry in entries:
		if icons.size() >= 4:
			break
		if seen.has(e.kind):
			continue
		seen[e.kind] = true
		icons.append(e.kind)
	icon_kinds = icons


static func _entry_less(a: BlueprintEntry, b: BlueprintEntry) -> bool:
	if a.offset.y != b.offset.y:
		return a.offset.y < b.offset.y
	if a.offset.x != b.offset.x:
		return a.offset.x < b.offset.x
	if String(a.kind) != String(b.kind):
		return String(a.kind) < String(b.kind)
	return a.rot < b.rot


## Rotated copy, `times` quarter-turns clockwise. The bounding box flips with it.
func rotated_cw(times: int) -> Blueprint:
	var turns: int = posmod(times, 4)
	var bp: Blueprint = copy()
	for _i: int in turns:
		var h: int = bp.size.y
		for e: BlueprintEntry in bp.entries:
			if e.fixed:
				# A workshop that cannot be turned keeps its 4x3 footprint. Only
				# its POSITION rotates with the stamp, so the slot the layout
				# reserves for it is the slot it actually lands in.
				var cx2: int = e.offset.x * 2 + e.span.x
				var cy2: int = e.offset.y * 2 + e.span.y
				var ncx2: int = h * 2 - cy2
				var ncy2: int = cx2
				e.offset = Vector2i(
					int(floor(float(ncx2 - e.span.x) * 0.5)),
					int(floor(float(ncy2 - e.span.y) * 0.5)))
				continue
			var new_offset := Vector2i(h - e.offset.y - e.span.y, e.offset.x)
			e.offset = new_offset
			e.span = Vector2i(e.span.y, e.span.x)
			e.rot = posmod(e.rot + 1, 4)
		bp.size = Vector2i(bp.size.y, bp.size.x)
		_refit(bp)
	bp.canonicalize()
	return bp


## Grows the stamp to cover anything a fixed entry pushed outside the turned
## bounding box, and shifts so the minimum corner stays (0, 0). A stamp with no
## fixed entries is untouched, which is what keeps four turns an identity.
static func _refit(bp: Blueprint) -> void:
	var lo := Vector2i.ZERO
	var hi: Vector2i = bp.size
	for e: BlueprintEntry in bp.entries:
		lo.x = mini(lo.x, e.offset.x)
		lo.y = mini(lo.y, e.offset.y)
		hi.x = maxi(hi.x, e.offset.x + e.span.x)
		hi.y = maxi(hi.y, e.offset.y + e.span.y)
	if lo == Vector2i.ZERO and hi == bp.size:
		return
	for e2: BlueprintEntry in bp.entries:
		e2.offset -= lo
	bp.size = hi - lo


## Mirrored copy across the vertical axis. Facings flip left <-> right.
func mirrored_x() -> Blueprint:
	var bp: Blueprint = copy()
	for e: BlueprintEntry in bp.entries:
		e.offset = Vector2i(bp.size.x - e.offset.x - e.span.x, e.offset.y)
		if not e.fixed:
			e.rot = BuildTypes.mirror_rot_x(e.rot)
	bp.canonicalize()
	return bp


## Mirrored copy across the horizontal axis. Facings flip up <-> down.
func mirrored_y() -> Blueprint:
	var bp: Blueprint = copy()
	for e: BlueprintEntry in bp.entries:
		e.offset = Vector2i(e.offset.x, bp.size.y - e.offset.y - e.span.y)
		if not e.fixed:
			e.rot = BuildTypes.mirror_rot_y(e.rot)
	bp.canonicalize()
	return bp


## Copy with empty margins trimmed away, so the stamp hugs its contents and
## pasting lines the cursor up with the first real building.
func normalized() -> Blueprint:
	var bp: Blueprint = copy()
	if bp.entries.is_empty():
		bp.size = Vector2i.ZERO
		return bp
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for e: BlueprintEntry in bp.entries:
		lo.x = mini(lo.x, e.offset.x)
		lo.y = mini(lo.y, e.offset.y)
		hi.x = maxi(hi.x, e.offset.x + e.span.x)
		hi.y = maxi(hi.y, e.offset.y + e.span.y)
	for e: BlueprintEntry in bp.entries:
		e.offset -= lo
	bp.size = hi - lo
	bp.canonicalize()
	return bp


## Total materials a full paste of this stamp will consume, item id -> amount.
## Missing kinds are skipped; use missing_kinds() to report them.
func total_cost() -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	for e: BlueprintEntry in entries:
		var d: BuildingDef = Registry.get_item("buildings", e.kind) as BuildingDef
		if d == null:
			continue
		BuildTypes.add_items(out, BuildTypes.to_items(d.cost))
	return out


## Kinds referenced by the stamp that no longer exist in content.
func missing_kinds() -> Array[StringName]:
	var out: Array[StringName] = []
	var seen: Dictionary[StringName, bool] = {}
	for e: BlueprintEntry in entries:
		if seen.has(e.kind):
			continue
		seen[e.kind] = true
		if Registry.get_item("buildings", e.kind) == null:
			out.append(e.kind)
	out.sort()
	return out


## How many of each kind the stamp contains, for the paste tooltip.
func kind_counts() -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	for e: BlueprintEntry in entries:
		out[e.kind] = int(out.get(e.kind, 0)) + 1
	return out


func to_dict() -> Dictionary:
	var arr: Array = []
	for e: BlueprintEntry in entries:
		arr.append(e.to_dict())
	return {
		"id": String(id),
		"title": title,
		"description": description,
		"size": BuildTypes.cell_to_json(size),
		"created_tick": created_tick,
		"entries": arr,
	}


static func from_dict(data: Dictionary) -> Blueprint:
	var bp := Blueprint.new()
	bp.id = StringName(String(data.get("id", "")))
	bp.title = String(data.get("title", "Blueprint"))
	bp.description = String(data.get("description", ""))
	bp.size = BuildTypes.to_cell(data.get("size", [1, 1]))
	bp.created_tick = int(data.get("created_tick", 0))
	var out: Array[BlueprintEntry] = []
	for raw: Variant in data.get("entries", []):
		if typeof(raw) == TYPE_DICTIONARY:
			out.append(BlueprintEntry.from_dict(raw))
	bp.entries = out
	bp.canonicalize()
	return bp


## Writes the stamp as JSON. `path` may be user:// or res://.
## Returns OK, or the FileAccess error.
func save_to_file(path: String) -> int:
	var dir: String = path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), "  "))
	f.close()
	return OK


## Reads a stamp written by save_to_file(). Returns null when unreadable.
static func load_from_file(path: String) -> Blueprint:
	if not FileAccess.file_exists(path):
		return null
	var txt: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	return Blueprint.from_dict(parsed)


## Stable fingerprint of the layout. Two stamps of the same shape share it,
## which is what makes the blueprint round-trip test meaningful.
func signature() -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append("%dx%d" % [size.x, size.y])
	for e: BlueprintEntry in entries:
		parts.append("%s@%d,%d:%d" % [String(e.kind), e.offset.x, e.offset.y, e.rot])
	return "|".join(parts)
