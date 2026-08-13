class_name LcnTechPanel
extends LcnUiPanel
## [P18] The tech tree screen.
##
## A drawn graph on the left, a full read-out on the right. Columns are depth,
## so "what can I do next" is always the leftmost unfinished column, and the
## edges are drawn as elbows rather than diagonals because a right-angled graph
## stays readable when forty nodes overlap and a spaghetti one does not.
##
## Colour is the whole legend: warm = done, bright = available now, dim = still
## locked, a pulsing rim = currently being researched. The detail pane answers
## "why now" out of the live city, not out of the content file.

signal research_requested(id: StringName)
signal building_requested(kind: StringName)

const PANEL_W: float = 900.0
const PANEL_H: float = 600.0

var model: LcnTechModel = null
var build_system: Object = null
var research_system: Object = null

var selected: StringName = &""

var _graph: _Graph = null
var _detail: VBoxContainer = null
var _footer: Label = null
var _signature: String = ""


func _init() -> void:
	panel_id = &"tech"
	panel_title = "Research"
	hotkey_hint = "T  ·  click a node"


func build_body() -> void:
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override(&"separation", 12)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(columns)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560.0, 460.0)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(scroll)

	_graph = _Graph.new()
	_graph.node_clicked.connect(_on_node_clicked)
	scroll.add_child(_graph)

	# The detail column gets its own opaque plate: without one the graph draws
	# straight through the text behind it and both become unreadable.
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override(&"panel", LcnUiStyle.panel_box(false, true))
	plate.custom_minimum_size = Vector2(320.0, 460.0)
	plate.mouse_filter = Control.MOUSE_FILTER_STOP
	columns.add_child(plate)

	var right := ScrollContainer.new()
	right.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	plate.add_child(right)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override(&"separation", 3)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_detail)

	_footer = LcnUiStyle.label("", LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT)
	body.add_child(_footer)


func refresh() -> void:
	if model == null:
		return
	if String(selected) == "" and not model.nodes.is_empty():
		selected = model.nodes[0].id
	# Rebuilding forty labels six times a second for a screen that has not
	# changed is exactly the kind of cost a UI has no excuse for.
	var done: int = 0
	var sig: String = "%d|%s|" % [model.revision(), String(selected)]
	for n: LcnTechModel.TechNode in model.nodes:
		if n.is_done():
			done += 1
		sig += "%d%d" % [n.state, int(n.progress * 100.0)]
	if sig == _signature:
		return
	_signature = sig

	_graph.model = model
	_graph.selected = selected
	_graph.rebuild_layout()
	_rebuild_detail()
	_footer.text = "%d of %d complete   ·   tree read from %s" % [
		done, model.nodes.size(), String(model.source())]


func select(id: StringName) -> void:
	selected = id
	_signature = ""
	if store != null:
		store.tech_focus = id
		store.mark_dirty()
	if _graph != null:
		_graph.selected = id
		_graph.queue_redraw()
	_rebuild_detail()


func _on_node_clicked(id: StringName) -> void:
	select(id)


func handle_key(event: InputEventKey) -> bool:
	if model == null or model.nodes.is_empty():
		return false
	var at: int = 0
	for i: int in model.nodes.size():
		if model.nodes[i].id == selected:
			at = i
			break
	match event.physical_keycode:
		KEY_DOWN:
			select(model.nodes[posmod(at + 1, model.nodes.size())].id)
			return true
		KEY_UP:
			select(model.nodes[posmod(at - 1, model.nodes.size())].id)
			return true
		KEY_ENTER, KEY_KP_ENTER:
			if String(selected) != "":
				research_requested.emit(selected)
			return true
	return false


func _rebuild_detail() -> void:
	if _detail == null or model == null:
		return
	for child: Node in _detail.get_children():
		_detail.remove_child(child)
		child.queue_free()
	var n: LcnTechModel.TechNode = model.node(selected)
	if n == null:
		_detail.add_child(LcnUiStyle.label("The tree is empty. No research content in this build yet.",
			LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_FAINT))
		return

	_detail.add_child(LcnUiStyle.label(n.display_name, LcnUiStyle.FS_TITLE, LcnUiStyle.TEXT_BRIGHT))
	var badge: String = n.state_word if n.state_word != "" else _state_word(n.state)
	if String(n.branch) != "":
		badge = "%s  ·  %s  ·  tier %d" % [badge, LcnUiFormat.item_name(n.branch), n.tier]
	_detail.add_child(LcnUiStyle.label(badge, LcnUiStyle.FS_SMALL, _state_colour(n.state)))
	if n.flavour != "":
		_detail.add_child(_wrapped(n.flavour, LcnUiStyle.ACCENT_SOFT))
	if n.description != "":
		_detail.add_child(_wrapped(n.description, LcnUiStyle.TEXT_DIM))

	var why_text: String = n.why_now()
	if why_text != "":
		_detail.add_child(_heading("Why now"))
		_detail.add_child(_wrapped(why_text, LcnUiStyle.tone_color(
			LcnUiStyle.Tone.ACCENT if n.reason != "" or n.urgency != "" else n.relevance_tone)))
	if model.suggestion.has("id") and LcnUiFormat.as_name(model.suggestion["id"]) == n.id:
		_detail.add_child(LcnUiStyle.label("Your engineers would pick this next.",
			LcnUiStyle.FS_SMALL, LcnUiStyle.GOOD))

	_detail.add_child(_heading("Cost"))
	_detail.add_child(LcnUiStyle.label(n.cost_label(), LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT))
	var owed: String = n.owed_label()
	if owed != "":
		_detail.add_child(LcnUiStyle.label("still owed: %s" % owed, LcnUiStyle.FS_SMALL,
			LcnUiStyle.GOOD if n.affordable else LcnUiStyle.BAD))
	if n.state == LcnTechModel.State.ACTIVE:
		var line: String = "%s — %s" % [n.state_word, LcnUiFormat.percent(n.progress)]
		if n.eta_label() != "":
			line += "   ·   %s left" % n.eta_label()
		_detail.add_child(LcnUiStyle.label(line, LcnUiStyle.FS_SMALL, LcnUiStyle.ACCENT))

	var missing: PackedStringArray = model.missing_prereqs(n, research_system, build_system)
	if not missing.is_empty():
		_detail.add_child(_heading("In the way"))
		_detail.add_child(LcnUiStyle.label(LcnUiFormat.prose_list(missing),
			LcnUiStyle.FS_SMALL, LcnUiStyle.WARN))

	if not n.unlocks.is_empty():
		_detail.add_child(_heading("Opens"))
		for kind: StringName in n.unlocks:
			var label: String = LcnUiFormat.item_name(kind)
			var detail: String = ""
			if build_system != null and build_system.has_method(&"def_of"):
				var def: Resource = build_system.call(&"def_of", kind) as Resource
				if def != null:
					label = LcnUiFormat.as_text(def.get(&"display_name"))
					detail = LcnUiFormat.category_name(LcnUiFormat.as_name(def.get(&"category")))
			var b := Button.new()
			b.text = label if detail == "" else "%s   ·   %s" % [label, detail]
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.flat = true
			b.focus_mode = Control.FOCUS_NONE
			b.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_SMALL)
			b.add_theme_color_override(&"font_color", LcnUiStyle.LINK)
			b.add_theme_color_override(&"font_hover_color", LcnUiStyle.TEXT_BRIGHT)
			b.pressed.connect(func() -> void: building_requested.emit(kind))
			_detail.add_child(b)

	if not n.grants.is_empty():
		_detail.add_child(_heading("Also grants"))
		var names: PackedStringArray = PackedStringArray()
		for g: StringName in n.grants:
			names.append(LcnUiFormat.item_name(g))
		_detail.add_child(LcnUiStyle.label(LcnUiFormat.prose_list(names),
			LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_DIM))

	if n.state == LcnTechModel.State.AVAILABLE and research_system != null:
		var go := Button.new()
		go.text = "Begin this research"
		go.focus_mode = Control.FOCUS_NONE
		go.add_theme_font_size_override(&"font_size", LcnUiStyle.FS_SMALL)
		go.add_theme_color_override(&"font_color", LcnUiStyle.ACCENT)
		go.add_theme_stylebox_override(&"normal", LcnUiStyle.chip_box(
			LcnUiStyle.PANEL_DEEP, LcnUiStyle.RIM_HOT))
		go.pressed.connect(func() -> void: research_requested.emit(n.id))
		_detail.add_child(go)
	elif research_system == null:
		_detail.add_child(LcnUiStyle.label("No research system in this build — this tree is derived from content.",
			LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT))


func _wrapped(text: String, colour: Color) -> Label:
	var l: Label = LcnUiStyle.label(text, LcnUiStyle.FS_SMALL, colour)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(280.0, 0.0)
	return l


func _heading(text: String) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, 6.0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(gap)
	box.add_child(LcnUiStyle.label(text.to_upper(), LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT))
	return box


static func _state_word(state: int) -> String:
	match state:
		LcnTechModel.State.DONE: return "researched"
		LcnTechModel.State.ACTIVE: return "in progress"
		LcnTechModel.State.AVAILABLE: return "available now"
	return "locked"


static func _state_colour(state: int) -> Color:
	match state:
		LcnTechModel.State.DONE: return LcnUiStyle.GOOD
		LcnTechModel.State.ACTIVE: return LcnUiStyle.ACCENT
		LcnTechModel.State.AVAILABLE: return LcnUiStyle.TEXT_BRIGHT
	return LcnUiStyle.TEXT_FAINT


# ------------------------------------------------------------------ graph ----

## The drawn tree. Kept as a single custom-drawn Control rather than one node per
## tech: forty Buttons with forty StyleBoxes cost more to lay out than one _draw
## that walks a list, and this thing has to open instantly.
class _Graph extends Control:
	signal node_clicked(id: StringName)

	const NODE_W: float = 168.0
	const NODE_H: float = 54.0
	const COL_GAP: float = 44.0
	const ROW_GAP: float = 16.0

	var model: LcnTechModel = null
	var selected: StringName = &""

	var _rects: Dictionary[StringName, Rect2] = {}

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func rebuild_layout() -> void:
		_rects.clear()
		if model == null:
			custom_minimum_size = Vector2(200.0, 100.0)
			queue_redraw()
			return
		var max_row: int = 0
		for n: LcnTechModel.TechNode in model.nodes:
			_rects[n.id] = Rect2(
				Vector2(float(n.column) * (NODE_W + COL_GAP) + 8.0,
					float(n.row) * (NODE_H + ROW_GAP) + 8.0),
				Vector2(NODE_W, NODE_H))
			max_row = maxi(max_row, n.row)
		custom_minimum_size = Vector2(
			float(maxi(1, model.columns())) * (NODE_W + COL_GAP) + 16.0,
			float(max_row + 1) * (NODE_H + ROW_GAP) + 16.0)
		size = custom_minimum_size
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		var b := event as InputEventMouseButton
		if b == null or not b.pressed or b.button_index != MOUSE_BUTTON_LEFT:
			return
		var keys: Array = _rects.keys()
		keys = LcnUiFormat.sorted_names(keys)
		for k: Variant in keys:
			if (_rects[k] as Rect2).has_point(b.position):
				node_clicked.emit(StringName(String(k)))
				accept_event()
				return

	func _draw() -> void:
		if model == null:
			return
		for edge: Dictionary in model.edges():
			var from: StringName = StringName(String(edge["from"]))
			var to: StringName = StringName(String(edge["to"]))
			if not _rects.has(from) or not _rects.has(to):
				continue
			var a: Rect2 = _rects[from]
			var c: Rect2 = _rects[to]
			var p0 := Vector2(a.end.x, a.position.y + a.size.y * 0.5)
			var p1 := Vector2(c.position.x, c.position.y + c.size.y * 0.5)
			var mid: float = (p0.x + p1.x) * 0.5
			var done: bool = _is_done(from)
			var colour: Color = LcnUiStyle.ACCENT_SOFT if done else LcnUiStyle.RIM
			draw_line(p0, Vector2(mid, p0.y), colour, 1.5)
			draw_line(Vector2(mid, p0.y), Vector2(mid, p1.y), colour, 1.5)
			draw_line(Vector2(mid, p1.y), p1, colour, 1.5)

		var font: Font = get_theme_default_font()
		var font_size: int = LcnUiStyle.FS_SMALL
		for n: LcnTechModel.TechNode in model.nodes:
			var r: Rect2 = _rects.get(n.id, Rect2())
			if r.size.x <= 0.0:
				continue
			var fill: Color = LcnUiStyle.PANEL_DEEP
			var rim: Color = LcnUiStyle.RIM_SOFT
			var text_colour: Color = LcnUiStyle.TEXT_FAINT
			match n.state:
				LcnTechModel.State.DONE:
					fill = Color(LcnUiStyle.GOOD.r, LcnUiStyle.GOOD.g, LcnUiStyle.GOOD.b, 0.16)
					rim = LcnUiStyle.GOOD
					text_colour = LcnUiStyle.TEXT
				LcnTechModel.State.ACTIVE:
					fill = Color(LcnUiStyle.ACCENT.r, LcnUiStyle.ACCENT.g, LcnUiStyle.ACCENT.b, 0.22)
					rim = LcnUiStyle.ACCENT
					text_colour = LcnUiStyle.TEXT_BRIGHT
				LcnTechModel.State.AVAILABLE:
					fill = LcnUiStyle.PANEL_RAISED
					rim = LcnUiStyle.RIM
					text_colour = LcnUiStyle.TEXT_BRIGHT
			if n.id == selected:
				rim = LcnUiStyle.RIM_HOT
			draw_rect(r, fill, true)
			draw_rect(r, rim, false, 1.0 if n.id != selected else 2.0)
			if n.state == LcnTechModel.State.ACTIVE and n.progress > 0.0:
				draw_rect(Rect2(r.position + Vector2(0.0, r.size.y - 3.0),
					Vector2(r.size.x * clampf(n.progress, 0.0, 1.0), 3.0)), LcnUiStyle.ACCENT, true)
			if font == null:
				continue
			draw_string(font, r.position + Vector2(8.0, 20.0), n.display_name,
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 16.0, font_size, text_colour)
			draw_string(font, r.position + Vector2(8.0, 38.0), _node_subtitle(n),
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 16.0, LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT)

	## One line under the name, in a box 168 pixels wide. What it opens if it
	## opens anything, otherwise what it costs to think about.
	static func _node_subtitle(n: LcnTechModel.TechNode) -> String:
		if not n.unlocks.is_empty():
			return "%d building%s" % [n.unlocks.size(), "" if n.unlocks.size() == 1 else "s"]
		if not n.grants.is_empty():
			return "%d unlock%s" % [n.grants.size(), "" if n.grants.size() == 1 else "s"]
		if n.cost_points > 0.0:
			return "%s insight" % LcnUiFormat.num(n.cost_points)
		return LcnUiFormat.item_name(n.branch)

	func _is_done(id: StringName) -> bool:
		if model == null:
			return false
		var n: LcnTechModel.TechNode = model.node(id)
		return n != null and n.is_done()
