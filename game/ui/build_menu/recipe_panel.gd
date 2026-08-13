class_name LcnRecipePanel
extends LcnUiPanel
## [P18] The recipe browser: what makes this, what is this for, click through.
##
## Two columns. Left: a search box and its results, over items, recipes and
## buildings at once. Right: whatever you last clicked, with every way IN to it
## above every way OUT of it, and every line in both lists is itself a link.
##
## The back/forward stack is the point. A player asking "why am I short of iron
## plate" walks: iron plate → smelter → iron ore → ore drill → "ah, I have one
## drill and four smelters". No wiki, no alt-tab.

signal building_requested(kind: StringName)

const PANEL_W: float = 760.0
const PANEL_H: float = 560.0
const MAX_RESULTS: int = 60

var graph: LcnItemGraph = null
var build_system: Object = null

var subject_kind: String = "item"
var subject_id: StringName = &""

var _search: LineEdit = null
var _results: VBoxContainer = null
var _detail: VBoxContainer = null
var _crumb: Label = null
var _back: Button = null
var _forward: Button = null
var _history: Array[Dictionary] = []
var _future: Array[Dictionary] = []


func _init() -> void:
	panel_id = &"recipes"
	panel_title = "Recipes & Items"
	hotkey_hint = "I  ·  click anything to follow it  ·  Backspace to go back"


func build_body() -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override(&"separation", 6)
	body.add_child(top)

	_back = _nav_button("<", _go_back)
	top.add_child(_back)
	_forward = _nav_button(">", _go_forward)
	top.add_child(_forward)

	_search = LineEdit.new()
	_search.placeholder_text = "search items, recipes, buildings…"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_BODY)
	_search.add_theme_color_override(&"font_color", LcnUiStyle.TEXT)
	_search.add_theme_color_override(&"font_placeholder_color", LcnUiStyle.TEXT_FAINT)
	_search.add_theme_stylebox_override(&"normal", LcnUiStyle.chip_box(
		LcnUiStyle.PANEL_DEEP, LcnUiStyle.RIM_SOFT))
	_search.add_theme_stylebox_override(&"focus", LcnUiStyle.chip_box(
		LcnUiStyle.PANEL_DEEP, LcnUiStyle.RIM_HOT))
	_search.text_changed.connect(func(_t: String) -> void: _rebuild_results())
	top.add_child(_search)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override(&"separation", 12)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(columns)

	var left := ScrollContainer.new()
	left.custom_minimum_size = Vector2(250.0, 420.0)
	left.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	columns.add_child(left)
	_results = VBoxContainer.new()
	_results.add_theme_constant_override(&"separation", 1)
	_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(_results)

	var right_column := VBoxContainer.new()
	right_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_column.add_theme_constant_override(&"separation", 4)
	columns.add_child(right_column)

	_crumb = LcnUiStyle.label("", LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT)
	right_column.add_child(_crumb)

	var right := ScrollContainer.new()
	right.custom_minimum_size = Vector2(440.0, 400.0)
	right.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_column.add_child(right)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override(&"separation", 2)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_detail)


func _nav_button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(26.0, 0.0)
	b.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_SMALL)
	b.add_theme_color_override(&"font_color", LcnUiStyle.TEXT_DIM)
	b.add_theme_stylebox_override(&"normal", LcnUiStyle.chip_box(
		LcnUiStyle.PANEL_DEEP, LcnUiStyle.RIM_SOFT))
	b.pressed.connect(action)
	return b


func on_opened() -> void:
	if _search != null and is_inside_tree():
		_search.grab_focus()
		_search.select_all()


func refresh() -> void:
	if graph == null:
		return
	if String(subject_id) == "" and graph.item_count() > 0:
		focus("item", graph.item_ids()[0], false)
	_rebuild_results()
	_rebuild_detail()


# -------------------------------------------------------------- navigation ---

## Points the right-hand column at something. `record` false while restoring
## state, so loading a save does not push a phantom history entry.
func focus(kind: String, id: StringName, record: bool = true) -> void:
	if record and String(subject_id) != "":
		_history.append({"kind": subject_kind, "id": String(subject_id)})
		_future.clear()
	subject_kind = kind
	subject_id = id
	if store != null:
		store.browser_item = id
		store.mark_dirty()
	_rebuild_detail()
	_update_nav()


func _go_back() -> void:
	if _history.is_empty():
		return
	_future.append({"kind": subject_kind, "id": String(subject_id)})
	var prev: Dictionary = _history.pop_back()
	subject_kind = String(prev["kind"])
	subject_id = StringName(String(prev["id"]))
	_rebuild_detail()
	_update_nav()


func _go_forward() -> void:
	if _future.is_empty():
		return
	_history.append({"kind": subject_kind, "id": String(subject_id)})
	var next: Dictionary = _future.pop_back()
	subject_kind = String(next["kind"])
	subject_id = StringName(String(next["id"]))
	_rebuild_detail()
	_update_nav()


func _update_nav() -> void:
	if _back != null:
		_back.disabled = _history.is_empty()
	if _forward != null:
		_forward.disabled = _future.is_empty()
	if _crumb != null:
		_crumb.text = "%s  ·  %d step%s back" % [
			subject_kind, _history.size(), "" if _history.size() == 1 else "s"]


func handle_key(event: InputEventKey) -> bool:
	if event.physical_keycode == KEY_BACKSPACE and _search != null and _search.text == "":
		_go_back()
		return true
	return false


# ----------------------------------------------------------------- results ---

func _rebuild_results() -> void:
	if _results == null or graph == null:
		return
	_clear(_results)
	var rows: Array[Dictionary] = graph.search(_search.text if _search != null else "",
		build_system, MAX_RESULTS)
	if rows.is_empty():
		_results.add_child(LcnUiStyle.label("nothing matches", LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_FAINT))
		return
	for row: Dictionary in rows:
		_results.add_child(_link_row(
			String(row["label"]), String(row["detail"]),
			String(row["kind"]), StringName(String(row["id"])),
			_kind_tone(String(row["kind"]))))


static func _kind_tone(kind: String) -> int:
	match kind:
		"recipe": return LcnUiStyle.Tone.ACCENT
		"building": return LcnUiStyle.Tone.LINK
	return LcnUiStyle.Tone.NEUTRAL


# ------------------------------------------------------------------ detail ---

func _rebuild_detail() -> void:
	if _detail == null or graph == null:
		return
	_clear(_detail)
	match subject_kind:
		"recipe":
			_detail_recipe()
		"building":
			_detail_building()
		_:
			_detail_item()
	_update_nav()


func _detail_item() -> void:
	var node: LcnItemGraph.ItemNode = graph.item(subject_id)
	if node == null:
		_detail.add_child(LcnUiStyle.label("Nothing known about %s." % LcnUiFormat.item_name(subject_id),
			LcnUiStyle.FS_BODY, LcnUiStyle.TEXT_DIM))
		return
	_detail.add_child(LcnUiStyle.label(node.display_name, LcnUiStyle.FS_TITLE, LcnUiStyle.TEXT_BRIGHT))
	if node.is_orphan():
		_detail.add_child(LcnUiStyle.label(
			"Nothing in the city makes this yet.", LcnUiStyle.FS_SMALL, LcnUiStyle.BAD))

	_detail.add_child(_heading("Made by"))
	if node.made_by.is_empty():
		_detail.add_child(_note("— nothing"))
	for edge: Dictionary in node.made_by:
		_detail.add_child(_edge_row(edge))

	_detail.add_child(_heading("Used for"))
	if node.used_by.is_empty():
		_detail.add_child(_note("— nothing yet"))
	for edge2: Dictionary in node.used_by:
		_detail.add_child(_edge_row(edge2))

	var upstream: Array[Dictionary] = graph.chain_upstream(subject_id, 3)
	if not upstream.is_empty():
		_detail.add_child(_heading("Everything behind it"))
		for step: Dictionary in upstream:
			var item := StringName(String(step["item"]))
			_detail.add_child(_link_row(
				"%s%s" % ["   ".repeat(int(step["depth"]) - 1), LcnUiFormat.item_name(item)],
				"via %s" % LcnUiFormat.item_name(StringName(String(step["via"]))),
				"item", item, LcnUiStyle.Tone.DIM))


func _detail_recipe() -> void:
	var r: LcnItemGraph.Recipe = graph.recipe(subject_id)
	if r == null:
		_detail.add_child(_note("That recipe is gone."))
		return
	_detail.add_child(LcnUiStyle.label(r.display_name, LcnUiStyle.FS_TITLE, LcnUiStyle.TEXT_BRIGHT))
	_detail.add_child(LcnUiStyle.label(r.summary(), LcnUiStyle.FS_SMALL, LcnUiStyle.ACCENT))

	_detail.add_child(_heading("Takes"))
	var in_keys: Array = r.inputs.keys()
	in_keys = LcnUiFormat.sorted_names(in_keys)
	if in_keys.is_empty():
		_detail.add_child(_note("— nothing"))
	for k: Variant in in_keys:
		var item := StringName(String(k))
		_detail.add_child(_link_row(
			"%d x %s" % [int(r.inputs[k]), LcnUiFormat.item_name(item)],
			LcnUiFormat.per_minute(float(r.inputs[k]) / maxf(0.05, r.seconds)),
			"item", item, LcnUiStyle.Tone.NEUTRAL))

	_detail.add_child(_heading("Gives"))
	var out_keys: Array = r.outputs.keys()
	out_keys = LcnUiFormat.sorted_names(out_keys)
	for k2: Variant in out_keys:
		var item2 := StringName(String(k2))
		_detail.add_child(_link_row(
			"%d x %s" % [int(r.outputs[k2]), LcnUiFormat.item_name(item2)],
			LcnUiFormat.per_minute(float(r.outputs[k2]) / maxf(0.05, r.seconds)),
			"item", item2, LcnUiStyle.Tone.GOOD))

	_detail.add_child(_heading("Made in"))
	if r.machines.is_empty():
		_detail.add_child(_note("— no building lists this recipe"))
	for m: StringName in r.machines:
		_detail.add_child(_link_row(_building_name(m), "open in the palette", "building", m,
			LcnUiStyle.Tone.LINK))


func _detail_building() -> void:
	var def: Resource = null
	if build_system != null and build_system.has_method(&"def_of"):
		def = build_system.call(&"def_of", subject_id) as Resource
	if def == null:
		_detail.add_child(_note("That building is gone."))
		return
	_detail.add_child(LcnUiStyle.label(String(def.get(&"display_name")),
		LcnUiStyle.FS_TITLE, LcnUiStyle.TEXT_BRIGHT))
	var desc: Label = LcnUiStyle.label(String(def.get(&"description")),
		LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_DIM)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(420.0, 0.0)
	_detail.add_child(desc)

	var pick := Button.new()
	pick.text = "Put it on the cursor"
	pick.focus_mode = Control.FOCUS_NONE
	pick.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_SMALL)
	pick.add_theme_color_override(&"font_color", LcnUiStyle.ACCENT)
	pick.add_theme_stylebox_override(&"normal", LcnUiStyle.chip_box(
		LcnUiStyle.PANEL_DEEP, LcnUiStyle.RIM_HOT))
	pick.pressed.connect(func() -> void: building_requested.emit(subject_id))
	_detail.add_child(pick)

	_detail.add_child(_heading("Costs"))
	var cost: Variant = def.get(&"cost")
	if typeof(cost) == TYPE_DICTIONARY:
		var keys: Array = (cost as Dictionary).keys()
		keys = LcnUiFormat.sorted_names(keys)
		for k: Variant in keys:
			var item := StringName(String(k))
			_detail.add_child(_link_row(
				"%d x %s" % [int((cost as Dictionary)[k]), LcnUiFormat.item_name(item)],
				"", "item", item, LcnUiStyle.Tone.NEUTRAL))

	var recipes: Variant = def.get(&"recipes")
	if typeof(recipes) == TYPE_ARRAY and not (recipes as Array).is_empty():
		_detail.add_child(_heading("Runs"))
		for rid: Variant in (recipes as Array):
			var id := StringName(String(rid))
			var r: LcnItemGraph.Recipe = graph.recipe(id)
			_detail.add_child(_link_row(
				r.display_name if r != null else LcnUiFormat.item_name(id),
				r.summary() if r != null else "recipe not authored yet",
				"recipe", id, LcnUiStyle.Tone.ACCENT))

	var ore := StringName(String(def.get(&"extracts")))
	if String(ore) != "":
		_detail.add_child(_heading("Digs"))
		_detail.add_child(_link_row(LcnUiFormat.item_name(ore),
			LcnUiFormat.per_minute(float(def.get(&"extract_rate"))), "item", ore, LcnUiStyle.Tone.GOOD))

	var fuels: Variant = def.get(&"fuel_items")
	if typeof(fuels) == TYPE_ARRAY and not (fuels as Array).is_empty():
		_detail.add_child(_heading("Burns"))
		for f: Variant in (fuels as Array):
			var fid := StringName(String(f))
			_detail.add_child(_link_row(LcnUiFormat.item_name(fid),
				LcnUiFormat.rate(float(def.get(&"fuel_burn_rate")), "per second"),
				"item", fid, LcnUiStyle.Tone.WARN))


func _building_name(kind: StringName) -> String:
	if build_system != null and build_system.has_method(&"def_of"):
		var def: Resource = build_system.call(&"def_of", kind) as Resource
		if def != null:
			return String(def.get(&"display_name"))
	return LcnUiFormat.item_name(kind)


func _edge_row(edge: Dictionary) -> Control:
	var how: String = String(edge.get("how", ""))
	var recipe: String = String(edge.get("recipe", ""))
	var building: String = String(edge.get("building", ""))
	var target_kind: String = "recipe" if recipe != "" else "building"
	var target_id: StringName = StringName(recipe if recipe != "" else building)
	var tone: int = LcnUiStyle.Tone.NEUTRAL
	match how:
		LcnItemGraph.HOW_EXTRACT, LcnItemGraph.HOW_RECIPE:
			tone = LcnUiStyle.Tone.GOOD
		LcnItemGraph.HOW_FUEL, LcnItemGraph.HOW_UPKEEP:
			tone = LcnUiStyle.Tone.WARN
		LcnItemGraph.HOW_BUILD_COST:
			tone = LcnUiStyle.Tone.LINK
	return _link_row(String(edge.get("text", "")), how.replace("_", " "), target_kind, target_id, tone)


# ------------------------------------------------------------------ pieces ---

func _heading(text: String) -> Control:
	var spacer := VBoxContainer.new()
	spacer.add_theme_constant_override(&"separation", 0)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, 6.0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.add_child(gap)
	spacer.add_child(LcnUiStyle.label(text.to_upper(), LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT))
	return spacer


func _note(text: String) -> Control:
	return LcnUiStyle.label(text, LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_FAINT)


func _link_row(label: String, detail: String, kind: String, id: StringName, tone: int) -> Control:
	var b := Button.new()
	b.text = label if detail == "" else "%s      %s" % [label, detail]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	b.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_SMALL)
	b.add_theme_color_override(&"font_color", LcnUiStyle.tone_color(tone))
	b.add_theme_color_override(&"font_hover_color", LcnUiStyle.TEXT_BRIGHT)
	b.add_theme_stylebox_override(&"hover", LcnUiStyle.flat_box(LcnUiStyle.ROW_HOVER))
	if String(id) != "":
		b.pressed.connect(func() -> void: focus(kind, id))
	else:
		b.disabled = true
	return b


func _clear(box: VBoxContainer) -> void:
	for child: Node in box.get_children():
		box.remove_child(child)
		child.queue_free()
