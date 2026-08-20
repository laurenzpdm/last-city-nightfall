class_name LcnMetaScreen
extends Control
## [P24] Base class for every screen in the meta layer: title, pause, settings,
## saves, confirm.
##
## A screen is a scrim, a plate, a title, a list and a footer of key hints. It
## owns no input routing of its own — [LcnMetaRoot] hands the top of the stack
## every key, which is what makes "Esc always closes the thing on top" true
## rather than a convention each screen re-implements slightly differently.

signal request_close()
signal request_screen(id: StringName, args: Dictionary)

const MARGIN: float = 0.0

var style: LcnMetaStyle = null
var list: LcnMetaList = null

var screen_id: StringName = &"screen"
var title: String = ""
var subtitle: String = ""
var footer: String = "↑↓ move   ←→ change   Enter select   Esc back"
## When true the world behind is fully covered — the title screen, which must
## not show a city the player has not started yet.
var opaque: bool = false
## Fraction of the screen width the panel occupies.
var panel_width: float = 0.46
## Multiples of the heading type reserved above the list, and of the small type
## reserved below it. A screen that draws its own thing under the rows raises
## `foot_lines` so the rows are laid out ABOVE it instead of under it.
var head_lines: float = 2.6
var foot_lines: float = 3.0
var panel_max_height: float = 0.74


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	list = LcnMetaList.new()
	list.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(list)
	list.row_activated.connect(_on_row_activated)
	list.row_changed.connect(_on_row_changed)
	list.focus_moved.connect(func(_id: StringName) -> void: queue_redraw())


func attach_style(s: LcnMetaStyle) -> void:
	style = s
	list.style = s
	queue_redraw()


## Called every time the screen becomes the top of the stack.
func enter(_args: Dictionary) -> void:
	refresh()


## Called when it stops being the top of the stack.
func leave() -> void:
	pass


## Rebuild the rows from whatever the screen shows. Called by enter() and by
## anything that changes what is displayed.
func refresh() -> void:
	pass


## Return true to consume. The base handles nothing but the list's own keys.
func handle_key(event: InputEventKey) -> bool:
	return list.handle_key(event)


## Every input event, offered before [method handle_key] and before the mouse
## reaches the list. Only the rebinding screen wants this: while it is capturing
## it must see a mouse button or a modifier as a BINDING, not as a click.
func handle_any(_event: InputEvent) -> bool:
	return false


func _on_row_activated(_id: StringName) -> void:
	pass


func _on_row_changed(_id: StringName, _value: Variant) -> void:
	pass


# ----------------------------------------------------------------- layout ----

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()


func _layout() -> void:
	if style == null:
		return
	var r: Rect2 = panel_rect()
	var head: float = _head_height()
	var foot: float = float(style.fs(LcnMetaStyle.FS_SMALL)) * foot_lines
	list.position = r.position + Vector2(0.0, head)
	list.size = Vector2(r.size.x, maxf(0.0, r.size.y - head - foot))


func panel_rect() -> Rect2:
	var w: float = size.x * panel_width
	var content: float = list.content_height() if list != null else 0.0
	var head: float = _head_height()
	var foot: float = float(style.fs(LcnMetaStyle.FS_SMALL)) * foot_lines if style != null else 30.0
	var h: float = clampf(content + head + foot, 160.0, size.y * panel_max_height)
	return Rect2(Vector2((size.x - w) * 0.5, (size.y - h) * 0.5), Vector2(w, h))


## The heading band. A screen WITH a subtitle needs a line more than one
## without, and hard-coding one number for both printed "CALDERA NINE" through
## the first row of the save browser.
func _head_height() -> float:
	if style == null:
		return 60.0
	var h: float = float(style.fs(LcnMetaStyle.FS_HEAD)) * head_lines
	if subtitle != "":
		h += float(style.fs(LcnMetaStyle.FS_SMALL)) * 1.7
	return h


func relayout() -> void:
	_layout()
	queue_redraw()


# ------------------------------------------------------------------- draw ----

func _draw() -> void:
	if style == null:
		return
	var full := Rect2(Vector2.ZERO, size)
	# A title screen covers the world completely: there is no city behind it yet
	# and showing one through it is a lie about what pressing "A new city" does.
	style.draw_scrim(self, full, 1.0 if opaque else (0.92 if style.high_contrast else 0.86))
	var r: Rect2 = panel_rect()
	style.draw_plate(self, r)
	var x: float = r.position.x + LcnMetaList.PAD
	var y: float = r.position.y + float(style.fs(LcnMetaStyle.FS_HEAD)) * 1.7
	var _w: float = style.text(self, Vector2(x, y), title, LcnMetaStyle.FS_HEAD, style.ink())
	if subtitle != "":
		style.label(self, Vector2(x, y + float(style.fs(LcnMetaStyle.FS_SMALL)) * 1.6),
			subtitle, style.ink_faint())
	if footer != "":
		style.text(self, Vector2(x, r.end.y - float(style.fs(LcnMetaStyle.FS_SMALL)) * 1.1),
			footer, LcnMetaStyle.FS_SMALL, style.ink_faint())
	draw_extra(r)


## Anything a specific screen wants to draw inside the plate.
func draw_extra(_panel: Rect2) -> void:
	pass
