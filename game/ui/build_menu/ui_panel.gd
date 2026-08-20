class_name LcnUiPanel
extends PanelContainer
## [P18] The frame every build-UI panel lives in.
##
## The contract the brief asks for, implemented once here instead of five times:
##
##   * openable by hotkey, closable by Escape
##   * remembers whether it was open and where it was dragged to
##   * NEVER blocks the game — the panel swallows the clicks that land on it and
##     nothing else; the simulation keeps ticking, the camera keeps panning, and
##     no panel is ever modal
##
## Subclasses fill `body` and override `refresh()` and `handle_key()`.

signal opened()
signal closed()
signal focus_wanted()

const DRAG_HANDLE_H: float = 26.0

## Stable id used for persistence and for the Escape stack.
var panel_id: StringName = &"panel"
var panel_title: String = "Panel"
var hotkey_hint: String = ""
var store: LcnUiStore = null

var body: VBoxContainer = null

## Open state is tracked explicitly rather than read back off `visible`.
## A Control's visibility is also driven by its parents and by the engine, and
## a panel that disagreed with the store about whether it was open turned every
## hotkey into an "open" and never an "close".
var _is_open: bool = false
var _title_label: Label = null
var _hint_label: Label = null
var _header: HBoxContainer = null
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _built: bool = false


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Panels are laid out by hand (they are draggable), so they must not be
	# stretched by a parent container.
	set_anchors_preset(Control.PRESET_TOP_LEFT)


func _ready() -> void:
	_ensure_built()


## Idempotent construction. Called from _ready, and directly by tests that never
## enter a scene tree.
func _ensure_built() -> void:
	if _built:
		return
	_built = true
	visible = _is_open
	add_theme_stylebox_override(&"panel", LcnUiStyle.panel_box())

	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", int(LcnUiStyle.GAP))
	add_child(column)

	_header = HBoxContainer.new()
	_header.custom_minimum_size = Vector2(0.0, DRAG_HANDLE_H)
	_header.add_theme_constant_override(&"separation", int(LcnUiStyle.GAP))
	_header.mouse_filter = Control.MOUSE_FILTER_STOP
	column.add_child(_header)

	_title_label = LcnUiStyle.label(panel_title, LcnUiStyle.FS_TITLE, LcnUiStyle.TEXT_BRIGHT)
	_header.add_child(_title_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.add_child(spacer)

	_hint_label = LcnUiStyle.label(hotkey_hint, LcnUiStyle.FS_SMALL, LcnUiStyle.TEXT_FAINT)
	_header.add_child(_hint_label)

	var rule := ColorRect.new()
	rule.color = LcnUiStyle.RIM_SOFT
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(rule)

	body = VBoxContainer.new()
	body.add_theme_constant_override(&"separation", int(LcnUiStyle.GAP))
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)

	build_body()


## Subclass hook: add the panel's own content to `body`.
func build_body() -> void:
	pass


## Subclass hook: pull fresh numbers out of the sim. Called at the panel's own
## refresh rate, never per frame.
func refresh() -> void:
	pass


## Subclass hook: return true when the key was consumed.
func handle_key(_event: InputEventKey) -> bool:
	return false


## Subclass hook: called right after the panel becomes visible.
func on_opened() -> void:
	pass


func set_title(text: String) -> void:
	panel_title = text
	if _title_label != null:
		_title_label.text = text


func set_hint(text: String) -> void:
	hotkey_hint = text
	if _hint_label != null:
		_hint_label.text = text


func is_open() -> bool:
	return _is_open


func set_open(value: bool) -> void:
	if _is_open == value:
		return
	_ensure_built()
	_is_open = value
	visible = value
	if store != null:
		store.set_open(panel_id, value)
	if value:
		refresh()
		on_opened()
		opened.emit()
		focus_wanted.emit()
	else:
		closed.emit()


func toggle() -> void:
	set_open(not visible)


## Places the panel, honouring a remembered position when there is one.
func place(default_pos: Vector2, panel_size: Vector2) -> void:
	_ensure_built()
	custom_minimum_size = panel_size
	size = panel_size
	var pos: Vector2 = default_pos
	if store != null and store.placement.has(panel_id):
		pos = store.placement[panel_id]
	position = pos
	clamp_into(get_viewport_rect().size if is_inside_tree() else Vector2(1920.0, 1080.0))


## Shrinks the panel so it ends within `room` pixels of its own top, by taking
## the difference out of its scrolling list rather than off the bottom.
##
## A panel cannot be made shorter than its children demand — Godot enforces
## `size >= get_combined_minimum_size()` — so setting `size.y` on a panel whose
## body carries `custom_minimum_size.y = 380` does nothing at all, silently. That
## is exactly what happened at ui_scale 1.6 on a 21:9 display: [P17]'s bigger
## chrome left the stage 508 px tall, the palette insisted on 517, and the extra
## nine landed on [P18]'s own hotkey strip. A list is the right thing to take the
## loss — it already scrolls, and the rows it stops showing are one wheel-notch
## away. Everything else in the panel is chrome that has to stay.
##
## Returns true when it found a list to shrink.
func fit_to_height(room: float) -> bool:
	_ensure_built()
	var list: ScrollContainer = _first_scroll(self)
	if list == null:
		return false
	var chrome: float = maxf(0.0, size.y - list.custom_minimum_size.y)
	var want: float = clampf(room - chrome, MIN_LIST_HEIGHT, 100000.0)
	if is_equal_approx(want, list.custom_minimum_size.y):
		return true
	list.custom_minimum_size = Vector2(list.custom_minimum_size.x, want)
	# Both halves are needed. Lowering the list's minimum only makes the smaller
	# size LEGAL; the panel keeps whatever height it already had until something
	# assigns one, and `custom_minimum_size` on the panel itself would put the old
	# floor straight back.
	custom_minimum_size = Vector2(custom_minimum_size.x, 0.0)
	size = Vector2(size.x, want + chrome)
	return true


## Four rows and a scrollbar. Below this a list stops being a list.
const MIN_LIST_HEIGHT: float = 132.0


func _first_scroll(from: Node) -> ScrollContainer:
	for child: Node in from.get_children():
		var sc := child as ScrollContainer
		if sc != null:
			return sc
		var found: ScrollContainer = _first_scroll(child)
		if found != null:
			return found
	return null


func clamp_into(screen: Vector2) -> void:
	if screen.x <= 0.0 or screen.y <= 0.0:
		return
	position = Vector2(
		clampf(position.x, 0.0, maxf(0.0, screen.x - size.x)),
		clampf(position.y, 0.0, maxf(0.0, screen.y - size.y)))


# ------------------------------------------------------------------ drag -----

func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		var local: Vector2 = button.position
		if button.pressed and local.y <= DRAG_HANDLE_H + LcnUiStyle.PAD:
			_dragging = true
			_drag_offset = local
			accept_event()
		elif not button.pressed and _dragging:
			_dragging = false
			if store != null:
				store.remember_placement(panel_id, position)
			accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _dragging:
		position += motion.relative
		clamp_into(get_viewport_rect().size)
		accept_event()
