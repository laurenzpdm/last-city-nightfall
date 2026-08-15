class_name LcnPalettePanel
extends LcnUiPanel
## [P18] The build palette. Sixty buildings, one keyboard, no scrolling for the
## thing you build every thirty seconds.
##
## Shape of the interaction, in the order a player learns it:
##   1. press B — the palette opens with the caret already in the search box
##   2. type three letters — the whole catalogue filters, best match first
##   3. Enter — that building is on the cursor, the panel gets out of the way
##   4. 1..0 — the quickbar: pinned buildings and the last things you placed
##
## Everything else (tabs, pinning, the lock state of unresearched buildings) is
## there for the first hour and invisible after it, which is the correct weight
## for a menu in a game about hands.

signal picked(kind: StringName)
signal hovered(kind: StringName)
signal pin_toggled(kind: StringName, pinned: bool)

const PANEL_W: float = 460.0
const PANEL_H: float = 560.0
const ROW_H: float = 40.0

var catalog: LcnBuildCatalog = null
## Filled by the root each refresh so rows can colour themselves by affordability.
var stock: Object = null

var tab: StringName = LcnBuildCatalog.TAB_ALL
var cursor: int = 0

var _search: LineEdit = null
var _tab_strip: HBoxContainer = null
var _list: VBoxContainer = null
var _scroll: ScrollContainer = null
var _status: Label = null
var _rows: Array[Control] = []
var _view: Array[LcnBuildCatalog.Entry] = []
var _rendered_signature: String = ""


func _init() -> void:
	panel_id = &"palette"
	panel_title = "Build"
	hotkey_hint = "B  ·  type to search  ·  ↑↓ Enter  ·  1-0 quickbar"


func build_body() -> void:
	_search = LineEdit.new()
	_search.placeholder_text = "search buildings…"
	_search.clear_button_enabled = true
	_search.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_BODY)
	_search.add_theme_color_override(&"font_color", LcnUiStyle.TEXT)
	_search.add_theme_color_override(&"font_placeholder_color", LcnUiStyle.TEXT_FAINT)
	_search.add_theme_stylebox_override(&"normal", LcnUiStyle.chip_box(
		LcnUiStyle.PANEL_DEEP, LcnUiStyle.RIM_SOFT))
	_search.add_theme_stylebox_override(&"focus", LcnUiStyle.chip_box(
		LcnUiStyle.PANEL_DEEP, LcnUiStyle.RIM_HOT))
	_search.text_changed.connect(_on_search_changed)
	body.add_child(_search)

	_tab_strip = HBoxContainer.new()
	_tab_strip.add_theme_constant_override(&"separation", 3)
	body.add_child(_tab_strip)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Vector2(PANEL_W - LcnUiStyle.PAD * 2.0, 380.0)
	body.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override(&"separation", 2)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)

	_status = LcnUiStyle.label("", LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT)
	body.add_child(_status)


func on_opened() -> void:
	if _search != null and is_inside_tree():
		_search.grab_focus()
		_search.select_all()


# ------------------------------------------------------------------ model ----

func query() -> String:
	return "" if _search == null else _search.text


func set_query(text: String) -> void:
	if _search != null and _search.text != text:
		_search.text = text
	# LineEdit.text_changed only fires for a human typing, so the store has to be
	# updated here too or a restored query would never be remembered again.
	if store != null and store.last_query != text:
		store.last_query = text
		store.mark_dirty()
	cursor = 0
	_rebuild_view()


func set_tab(id: StringName) -> void:
	if tab == id:
		return
	tab = id
	cursor = 0
	if store != null:
		store.last_tab = id
		store.mark_dirty()
	_rebuild_view()


func current_entry() -> LcnBuildCatalog.Entry:
	if cursor < 0 or cursor >= _view.size():
		return null
	return _view[cursor]


func current_kind() -> StringName:
	var e: LcnBuildCatalog.Entry = current_entry()
	return &"" if e == null else e.id


func view_size() -> int:
	return _view.size()


func refresh() -> void:
	if catalog == null:
		return
	_rebuild_tabs()
	_rebuild_view()


func _on_search_changed(text: String) -> void:
	cursor = 0
	if store != null:
		store.last_query = text
		store.mark_dirty()
	_rebuild_view()
	_emit_hover()


func _rebuild_tabs() -> void:
	if _tab_strip == null or catalog == null:
		return
	var tabs: Array[Dictionary] = catalog.tabs()
	var sig: String = ""
	for t: Dictionary in tabs:
		sig += "%s:%d|" % [String(t["id"]), int(t["count"])]
	sig += "@" + String(tab)
	if sig == _rendered_signature:
		return
	_rendered_signature = sig
	for child: Node in _tab_strip.get_children():
		_tab_strip.remove_child(child)
		child.queue_free()
	for t2: Dictionary in tabs:
		var id := StringName(String(t2["id"]))
		var b := Button.new()
		b.text = String(t2["label"])
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_TINY)
		var active: bool = id == tab
		b.add_theme_color_override(&"font_color",
			LcnUiStyle.TEXT_BRIGHT if active else LcnUiStyle.TEXT_DIM)
		b.add_theme_color_override(&"font_hover_color", LcnUiStyle.ACCENT)
		b.add_theme_stylebox_override(&"normal", LcnUiStyle.chip_box(
			LcnUiStyle.ROW_ACTIVE if active else LcnUiStyle.PANEL_DEEP,
			LcnUiStyle.RIM_HOT if active else LcnUiStyle.RIM_SOFT))
		b.add_theme_stylebox_override(&"hover", LcnUiStyle.chip_box(
			LcnUiStyle.ROW_HOVER, LcnUiStyle.RIM))
		b.add_theme_stylebox_override(&"pressed", LcnUiStyle.chip_box(
			LcnUiStyle.ROW_ACTIVE, LcnUiStyle.RIM_HOT))
		b.pressed.connect(_on_tab_pressed.bind(id))
		_tab_strip.add_child(b)


func _on_tab_pressed(id: StringName) -> void:
	set_query("")
	set_tab(id)


func _rebuild_view() -> void:
	if catalog == null:
		return
	_view = catalog.view(tab, query())
	cursor = clampi(cursor, 0, maxi(0, _view.size() - 1))
	_sync_rows()
	_update_status()


func _sync_rows() -> void:
	if _list == null:
		return
	while _rows.size() < _view.size():
		var row: Control = _make_row()
		_rows.append(row)
		_list.add_child(row)
	for i: int in _rows.size():
		var row2: Control = _rows[i]
		if i < _view.size():
			row2.visible = true
			row2.call(&"bind", _view[i], catalog.is_favourite(_view[i].id), stock)
			row2.call(&"set_active", i == cursor)
		else:
			row2.visible = false


func _update_status() -> void:
	if _status == null or catalog == null:
		return
	var quick: Array[StringName] = catalog.quickbar_ids()
	var parts: PackedStringArray = PackedStringArray()
	for i: int in quick.size():
		var e: LcnBuildCatalog.Entry = catalog.entry(quick[i])
		if e == null:
			continue
		parts.append("%d %s" % [(i + 1) % 10, e.display_name])
	var head: String = "%d of %d shown" % [_view.size(), catalog.size()]
	if parts.is_empty():
		_status.text = "%s   ·   place something to fill the quickbar" % head
	else:
		_status.text = "%s   ·   %s" % [head, "   ".join(parts)]


func _make_row() -> Control:
	var row := _PaletteRow.new()
	row.custom_minimum_size = Vector2(0.0, ROW_H)
	row.clicked.connect(_on_row_clicked)
	row.entered.connect(_on_row_entered)
	row.pin_clicked.connect(_on_row_pin)
	return row


func _on_row_clicked(kind: StringName) -> void:
	for i: int in _view.size():
		if _view[i].id == kind:
			cursor = i
			break
	_sync_rows()
	pick()


func _on_row_entered(kind: StringName) -> void:
	hovered.emit(kind)


func _on_row_pin(kind: StringName) -> void:
	if catalog == null:
		return
	var pinned: bool = catalog.toggle_favourite(kind)
	pin_toggled.emit(kind, pinned)
	if store != null:
		store.palette = catalog.to_dict()
		store.mark_dirty()
	_rendered_signature = ""
	refresh()


# --------------------------------------------------------------- keyboard ----

func handle_key(event: InputEventKey) -> bool:
	match event.physical_keycode:
		KEY_DOWN:
			move_cursor(1)
			return true
		KEY_UP:
			move_cursor(-1)
			return true
		KEY_PAGEDOWN:
			move_cursor(8)
			return true
		KEY_PAGEUP:
			move_cursor(-8)
			return true
		KEY_HOME:
			if query() == "":
				set_cursor(0)
				return true
		KEY_END:
			if query() == "":
				set_cursor(_view.size() - 1)
				return true
		KEY_ENTER, KEY_KP_ENTER:
			pick()
			return true
		KEY_TAB:
			cycle_tab(-1 if event.shift_pressed else 1)
			return true
		KEY_P:
			if event.ctrl_pressed or event.meta_pressed:
				var e: LcnBuildCatalog.Entry = current_entry()
				if e != null:
					_on_row_pin(e.id)
				return true
	return false


func move_cursor(delta: int) -> void:
	if _view.is_empty():
		return
	set_cursor(posmod(cursor + delta, _view.size()))


func set_cursor(index: int) -> void:
	if _view.is_empty():
		return
	cursor = clampi(index, 0, _view.size() - 1)
	_sync_rows()
	_scroll_to_cursor()
	_emit_hover()


func _scroll_to_cursor() -> void:
	if _scroll == null or not is_inside_tree():
		return
	var y: float = float(cursor) * (ROW_H + 2.0)
	var top: float = _scroll.scroll_vertical
	var height: float = _scroll.size.y
	if y < top:
		_scroll.scroll_vertical = int(y)
	elif y + ROW_H > top + height:
		_scroll.scroll_vertical = int(y + ROW_H - height)


func _emit_hover() -> void:
	var e: LcnBuildCatalog.Entry = current_entry()
	if e != null:
		hovered.emit(e.id)


func cycle_tab(delta: int) -> void:
	if catalog == null:
		return
	var tabs: Array[Dictionary] = catalog.tabs()
	if tabs.is_empty():
		return
	var at: int = 0
	for i: int in tabs.size():
		if StringName(String(tabs[i]["id"])) == tab:
			at = i
			break
	set_query("")
	set_tab(StringName(String(tabs[posmod(at + delta, tabs.size())]["id"])))


## Commits the cursor. A locked building is refused out loud rather than
## silently ignored — the reason is the teaching moment.
func pick() -> void:
	var e: LcnBuildCatalog.Entry = current_entry()
	if e == null:
		return
	picked.emit(e.id)


# ------------------------------------------------------------------- row -----

## One line of the palette. A PanelContainer rather than a hand-drawn Control so
## the text uses the engine's own font handling and stays correct at any UI scale.
class _PaletteRow extends PanelContainer:
	signal clicked(kind: StringName)
	signal entered(kind: StringName)
	signal pin_clicked(kind: StringName)

	var kind: StringName = &""

	var _glyph: _Glyph = null
	var _name: Label = null
	var _sub: Label = null
	var _cost: Label = null
	var _pin: Button = null
	var _active: bool = false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		add_theme_stylebox_override(&"panel", LcnUiStyle.flat_box(Color(0, 0, 0, 0)))
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)

		_glyph = _Glyph.new()
		_glyph.custom_minimum_size = Vector2(30.0, 30.0)
		row.add_child(_glyph)

		var text := VBoxContainer.new()
		text.add_theme_constant_override(&"separation", 0)
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(text)

		_name = LcnUiStyle.label("", LcnUiStyle.FS_BODY, LcnUiStyle.TEXT)
		text.add_child(_name)
		_sub = LcnUiStyle.label("", LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT)
		text.add_child(_sub)

		_cost = LcnUiStyle.label("", LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_DIM)
		_cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_cost.custom_minimum_size = Vector2(140.0, 0.0)
		row.add_child(_cost)

		_pin = Button.new()
		_pin.flat = true
		_pin.focus_mode = Control.FOCUS_NONE
		_pin.custom_minimum_size = Vector2(20.0, 0.0)
		_pin.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_SMALL)
		_pin.pressed.connect(func() -> void: pin_clicked.emit(kind))
		row.add_child(_pin)

		mouse_entered.connect(func() -> void: entered.emit(kind))
		gui_input.connect(_on_gui_input)

	func _on_gui_input(event: InputEvent) -> void:
		var b := event as InputEventMouseButton
		if b != null and b.pressed and b.button_index == MOUSE_BUTTON_LEFT:
			clicked.emit(kind)
			accept_event()

	func bind(entry: LcnBuildCatalog.Entry, pinned: bool, stock: Object) -> void:
		kind = entry.id
		# A capped entry reads exactly like a locked one, because to a player they
		# are the same fact: the list is showing you something you cannot place,
		# and it owes you the reason on the same line as the name. See
		# `LcnBuildCatalog.refresh_caps` for what this was costing on row one.
		var placeable: bool = entry.unlocked and not entry.capped
		_glyph.def = entry.def
		_glyph.dim = 1.0 if placeable else 0.45
		_glyph.queue_redraw()
		_name.text = entry.display_name
		_name.add_theme_color_override(&"font_color",
			LcnUiStyle.TEXT if placeable else LcnUiStyle.TEXT_FAINT)
		var bits: PackedStringArray = PackedStringArray()
		bits.append(LcnUiFormat.category_name(entry.category))
		if entry.tier > 1:
			bits.append(LcnUiFormat.tier_mark(entry.tier))
		if not entry.unlocked:
			bits.append("locked — %s" % LcnUiFormat.item_name(entry.unlock_id))
		elif entry.capped:
			bits.append("the city has it already" if entry.max_count == 1
				else "the city has all %d of them" % entry.max_count)
		_sub.text = "  ·  ".join(bits)
		_sub.add_theme_color_override(&"font_color",
			LcnUiStyle.WARN if not placeable else LcnUiStyle.TEXT_FAINT)

		var bill: Variant = entry.def.get(&"cost")
		var text: String = ""
		var tone: int = LcnUiStyle.Tone.DIM
		if typeof(bill) == TYPE_DICTIONARY:
			text = LcnUiFormat.items_compact(bill)
			if stock != null and stock.has_method(&"missing"):
				var missing: Dictionary = stock.call(&"missing", bill)
				if not missing.is_empty():
					tone = LcnUiStyle.Tone.BAD
		_cost.text = text
		_cost.add_theme_color_override(&"font_color", LcnUiStyle.tone_color(tone))
		_pin.text = "★" if pinned else "☆"
		_pin.add_theme_color_override(&"font_color",
			LcnUiStyle.ACCENT if pinned else LcnUiStyle.TEXT_FAINT)

	func set_active(value: bool) -> void:
		if _active == value:
			return
		_active = value
		add_theme_stylebox_override(&"panel", LcnUiStyle.flat_box(
			LcnUiStyle.ROW_ACTIVE if value else Color(0, 0, 0, 0)))


## The little footprint icon. Generated, so a new building is legible the moment
## its .tres lands instead of waiting for art.
class _Glyph extends Control:
	var def: Resource = null
	var dim: float = 1.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		LcnUiStyle.draw_building_glyph(self, Rect2(Vector2.ZERO, size), def, dim)
