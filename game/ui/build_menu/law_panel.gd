class_name LcnLawPanel
extends LcnUiPanel
## [P18] The Book of Laws.
##
## This screen is supposed to feel heavy, so it is built the opposite way round
## from every other panel in this folder: prose first, at reading size, with the
## numbers underneath it in small type. A law is a paragraph you signed, not a
## row in a table.
##
## Three things are always on screen for every law, and the panel refuses to
## draw one without them:
##   the words         — the authored text, in full
##   the price         — what signing costs and what keeping it costs
##   what it buries    — every law this signature closes off, by name
##
## The last line is the one the model works hardest for: content states exclusive
## slots and explicit conflicts, and nobody was turning that into a sentence.

signal sign_requested(id: StringName)

const PANEL_W: float = 720.0
const PANEL_H: float = 620.0
const PROSE_W: float = 640.0

var model: LcnLawModel = null
var chapter: StringName = &""

var _tabs: HBoxContainer = null
var _scroll: ScrollContainer = null
var _list: VBoxContainer = null
var _footer: Label = null
var _signature: String = ""


func _init() -> void:
	panel_id = &"laws"
	panel_title = "The Book of Laws"
	hotkey_hint = "L  ·  a signature cannot be taken back"


func build_body() -> void:
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override(&"separation", 3)
	body.add_child(_tabs)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(PANEL_W - LcnUiStyle.PAD * 2.0, 480.0)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override(&"separation", 14)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)

	_footer = LcnUiStyle.label("", LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT)
	body.add_child(_footer)


func refresh() -> void:
	if model == null or _list == null:
		return
	if String(chapter) == "" and not model.chapters().is_empty():
		chapter = model.chapters()[0]
	var sig: String = "%d|%s|%d" % [model.revision(), String(chapter), model.signed_count()]
	for l: LcnLawModel.LawRecord in model.laws:
		sig += "%s%d" % [String(l.id), l.status]
	if sig == _signature:
		return
	_signature = sig

	_rebuild_tabs()
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	if model.is_empty():
		_list.add_child(_prose(
			"The book is empty. No laws have been written into this build yet — "
			+ "when they are, every one of them will appear here with its full text, "
			+ "its price, and the laws it closes off.", LcnUiStyle.TEXT_FAINT))
		_footer.text = "0 signed"
		return

	for law: LcnLawModel.LawRecord in model.laws_in(chapter):
		_list.add_child(_law_block(law))
	_footer.text = "%d of %d signed%s" % [
		model.signed_count(), model.laws.size(),
		"" if model.has_system() else "   ·   no society system in this build; signing is disabled"]


func _rebuild_tabs() -> void:
	for child: Node in _tabs.get_children():
		_tabs.remove_child(child)
		child.queue_free()
	for c: StringName in model.chapters():
		var b := Button.new()
		b.text = model.chapter_title(c)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_TINY)
		var active: bool = c == chapter
		b.add_theme_color_override(&"font_color",
			LcnUiStyle.TEXT_BRIGHT if active else LcnUiStyle.TEXT_DIM)
		b.add_theme_stylebox_override(&"normal", LcnUiStyle.chip_box(
			LcnUiStyle.ROW_ACTIVE if active else LcnUiStyle.PANEL_DEEP,
			LcnUiStyle.RIM_HOT if active else LcnUiStyle.RIM_SOFT))
		b.pressed.connect(func() -> void: set_chapter(c))
		_tabs.add_child(b)


func set_chapter(id: StringName) -> void:
	if chapter == id:
		return
	chapter = id
	if store != null:
		store.law_chapter = id
		store.mark_dirty()
	_signature = ""
	refresh()


func handle_key(_event: InputEventKey) -> bool:
	return false


func _law_block(law: LcnLawModel.LawRecord) -> Control:
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override(&"panel", LcnUiStyle.panel_box(
		law.status == LcnLawModel.Status.ENACTED, true))
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 5)
	frame.add_child(column)

	var head := HBoxContainer.new()
	head.add_theme_constant_override(&"separation", 10)
	column.add_child(head)
	head.add_child(LcnUiStyle.label(law.title, LcnUiStyle.FS_TITLE, LcnUiStyle.TEXT_BRIGHT))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(spacer)
	head.add_child(LcnUiStyle.label(LcnLawModel.status_word(law.status).to_upper(),
		LcnUiStyle.FS_TINY, LcnUiStyle.tone_color(LcnLawModel.status_tone(law.status))))

	if law.prose != "":
		column.add_child(_prose(law.prose, LcnUiStyle.TEXT))
	elif law.summary != "":
		column.add_child(_prose(law.summary, LcnUiStyle.TEXT))
	else:
		column.add_child(_prose("(no text was written for this law)", LcnUiStyle.TEXT_FAINT))

	if law.summary != "" and law.prose != "":
		column.add_child(LcnUiStyle.label(law.summary, LcnUiStyle.FS_SMALL, LcnUiStyle.ACCENT))

	for effect: String in law.effects:
		column.add_child(LcnUiStyle.label("·  %s" % effect, LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_DIM))

	var price: String = "Costs %s" % law.cost_label()
	if not law.upkeep.is_empty():
		price += "   ·   keeps costing %s per minute" % LcnUiFormat.items(law.upkeep)
	column.add_child(LcnUiStyle.label(price, LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT))

	var weight: Label = LcnUiStyle.label(law.weight_line(), LcnUiStyle.FS_SMALL,
		LcnUiStyle.BAD if not law.forecloses_titles.is_empty() else LcnUiStyle.TEXT_FAINT)
	weight.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	weight.custom_minimum_size = Vector2(PROSE_W, 0.0)
	column.add_child(weight)

	if law.blocked_reason != "":
		column.add_child(LcnUiStyle.label(law.blocked_reason, LcnUiStyle.FS_SMALL, LcnUiStyle.WARN))

	if law.status == LcnLawModel.Status.AVAILABLE and model.has_system():
		var sign_button := Button.new()
		sign_button.text = "Sign it"
		sign_button.focus_mode = Control.FOCUS_NONE
		sign_button.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_BODY)
		sign_button.add_theme_color_override(&"font_color", LcnUiStyle.ACCENT)
		sign_button.add_theme_stylebox_override(&"normal", LcnUiStyle.chip_box(
			LcnUiStyle.PANEL_DEEP, LcnUiStyle.RIM_HOT))
		sign_button.add_theme_stylebox_override(&"hover", LcnUiStyle.chip_box(
			LcnUiStyle.ROW_ACTIVE, LcnUiStyle.RIM_HOT))
		sign_button.pressed.connect(func() -> void: sign_requested.emit(law.id))
		column.add_child(sign_button)
	return frame


func _prose(text: String, colour: Color) -> Label:
	var l: Label = LcnUiStyle.label(text, LcnUiStyle.FS_BODY, colour)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(PROSE_W, 0.0)
	return l
