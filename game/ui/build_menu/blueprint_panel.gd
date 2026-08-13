class_name LcnBlueprintPanel
extends LcnUiPanel
## [P18] The blueprint library.
##
## [P11] built capture, rotate, mirror, a book, disk export and a paste that
## validates the whole stamp before it charges for it — and none of it was on
## screen, so the feature effectively did not exist. This panel is the screen.
##
## Each card carries a real thumbnail drawn from the stamp's own footprints, the
## price measured against the city's current stock, and three verbs: place,
## export, delete. Renaming is inline and lives in this part's UI state, because
## [P11] has no rename command and a UI does not get to write into sim state.

signal place_requested(id: StringName)
signal command_requested(cmd: Dictionary)

const PANEL_W: float = 620.0
const PANEL_H: float = 560.0

var model: LcnBlueprintModel = null
var armed: StringName = &""

var _cached_build: Object = null

var _list: VBoxContainer = null
var _empty: Label = null
var _footer: Label = null
var _signature: String = ""


func _init() -> void:
	panel_id = &"blueprints"
	panel_title = "Blueprints"
	hotkey_hint = "N  ·  click Place, then click the map"


func build_body() -> void:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(PANEL_W - LcnUiStyle.PAD * 2.0, 440.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override(&"separation", 8)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	_empty = LcnUiStyle.label(
		"No stamps yet. Drag a selection in the world and press Ctrl+C to copy one.",
		LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_FAINT)
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.custom_minimum_size = Vector2(PANEL_W - LcnUiStyle.PAD * 2.0, 0.0)
	_list.add_child(_empty)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override(&"separation", 6)
	body.add_child(bar)
	bar.add_child(_action("Import from disk", func() -> void:
		command_requested.emit(LcnBlueprintModel.import_command())))
	_footer = LcnUiStyle.label("", LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT)
	_footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_footer)


func refresh() -> void:
	if model == null or _list == null:
		return
	var sig: String = "%d:%s" % [model.revision(), String(armed)]
	for c: LcnBlueprintModel.Card in model.cards:
		sig += "|%s%s%d" % [String(c.id), c.title, c.missing.size()]
	if sig == _signature:
		return
	_signature = sig

	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	if model.size() == 0:
		_empty = LcnUiStyle.label(
			"No stamps yet. Drag a selection in the world and press Ctrl+C to copy one.",
			LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_FAINT)
		_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_empty.custom_minimum_size = Vector2(PANEL_W - LcnUiStyle.PAD * 2.0, 0.0)
		_list.add_child(_empty)
	else:
		for card: LcnBlueprintModel.Card in model.cards:
			_list.add_child(_make_card(card))
	_footer.text = "%d stamp%s" % [model.size(), "" if model.size() == 1 else "s"]


func handle_key(_event: InputEventKey) -> bool:
	return false


func _make_card(card: LcnBlueprintModel.Card) -> Control:
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override(&"panel", LcnUiStyle.panel_box(card.id == armed, true))
	frame.mouse_filter = Control.MOUSE_FILTER_STOP

	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 10)
	frame.add_child(row)

	var thumb := _Thumb.new()
	thumb.card = card
	thumb.custom_minimum_size = Vector2(120.0, 92.0)
	row.add_child(thumb)

	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 2)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(column)

	var name_edit := LineEdit.new()
	name_edit.text = card.title
	name_edit.flat = true
	name_edit.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_HEAD)
	name_edit.add_theme_color_override(&"font_color",
		LcnUiStyle.ACCENT if card.renamed else LcnUiStyle.TEXT_BRIGHT)
	name_edit.tooltip_text = "rename — the label is yours, the stamp keeps its own title"
	name_edit.text_submitted.connect(func(text: String) -> void: _rename(card.id, text))
	name_edit.focus_exited.connect(func() -> void: _rename(card.id, name_edit.text))
	column.add_child(name_edit)

	column.add_child(LcnUiStyle.label(card.subtitle(), LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT))
	var contents: Label = LcnUiStyle.label(card.contents_label(), LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_DIM)
	contents.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	contents.custom_minimum_size = Vector2(330.0, 0.0)
	column.add_child(contents)

	var cost_tone: int = LcnUiStyle.Tone.GOOD if card.affordable else LcnUiStyle.Tone.BAD
	var cost_text: String = card.cost_label()
	if not card.affordable:
		cost_text += "   (short %s)" % LcnUiFormat.items(card.missing)
	column.add_child(LcnUiStyle.label(cost_text, LcnUiStyle.FS_SMALL, LcnUiStyle.tone_color(cost_tone)))

	if card.is_broken():
		var names: PackedStringArray = PackedStringArray()
		for k: StringName in card.missing_kinds:
			names.append(LcnUiFormat.item_name(k))
		column.add_child(LcnUiStyle.label(
			"Refers to buildings that no longer exist: %s" % LcnUiFormat.prose_list(names),
			LcnUiStyle.FS_TINY, LcnUiStyle.BAD))

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override(&"separation", 5)
	column.add_child(buttons)
	var place_label: String = "Placing…" if card.id == armed else "Place"
	var place: Button = _action(place_label, func() -> void: place_requested.emit(card.id))
	place.disabled = card.is_broken()
	buttons.add_child(place)
	buttons.add_child(_action("Turn", func() -> void:
		command_requested.emit(LcnBlueprintModel.transform_command(card.id, 1, false, false))))
	buttons.add_child(_action("Mirror", func() -> void:
		command_requested.emit(LcnBlueprintModel.transform_command(card.id, 0, true, false))))
	buttons.add_child(_action("Export", func() -> void:
		command_requested.emit(LcnBlueprintModel.export_command(card.id))))
	buttons.add_child(_action("Delete", func() -> void:
		command_requested.emit(LcnBlueprintModel.delete_command(card.id)), LcnUiStyle.BAD))
	return frame


func _rename(id: StringName, text: String) -> void:
	if store == null:
		return
	store.rename_blueprint(id, text)
	_signature = ""
	if model != null:
		model.rebuild(_cached_build, store.blueprint_overrides())
	refresh()


## The root hands the build system down once, so a rename can re-index without
## reaching for an autoload.
func bind_build(system: Object) -> void:
	_cached_build = system


func _action(text: String, action: Callable, colour: Color = LcnUiStyle.TEXT) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_TINY)
	b.add_theme_color_override(&"font_color", colour)
	b.add_theme_color_override(&"font_hover_color", LcnUiStyle.TEXT_BRIGHT)
	b.add_theme_stylebox_override(&"normal", LcnUiStyle.chip_box(
		LcnUiStyle.PANEL_DEEP, LcnUiStyle.RIM_SOFT))
	b.add_theme_stylebox_override(&"hover", LcnUiStyle.chip_box(
		LcnUiStyle.ROW_HOVER, LcnUiStyle.RIM_HOT))
	b.pressed.connect(action)
	return b


## The stamp, drawn. Two blueprints of different shapes must never look alike in
## a list, which is exactly what a generic icon would do.
class _Thumb extends Control:
	var card: LcnBlueprintModel.Card = null

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), LcnUiStyle.PANEL_DEEP, true)
		draw_rect(Rect2(Vector2.ZERO, size), LcnUiStyle.RIM_SOFT, false, 1.0)
		if card == null or card.thumb.is_empty():
			return
		var span := Vector2(maxf(1.0, float(card.size.x)), maxf(1.0, float(card.size.y)))
		var pad: float = 6.0
		var scale: float = minf((size.x - pad * 2.0) / span.x, (size.y - pad * 2.0) / span.y)
		var origin := Vector2(
			(size.x - span.x * scale) * 0.5,
			(size.y - span.y * scale) * 0.5)
		for piece: Dictionary in card.thumb:
			var r: Rect2i = piece["rect"]
			var colour: Color = piece["color"]
			var box := Rect2(
				origin + Vector2(float(r.position.x), float(r.position.y)) * scale,
				Vector2(float(r.size.x), float(r.size.y)) * scale)
			draw_rect(box, Color(colour.r, colour.g, colour.b, 0.55), true)
			draw_rect(box, Color(colour.r, colour.g, colour.b, 0.95), false, 1.0)
