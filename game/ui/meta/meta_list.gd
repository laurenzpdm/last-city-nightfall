class_name LcnMetaList
extends Control
## [P24] The one control every menu in this part is built from.
##
## There is exactly one widget because there is exactly one interaction contract,
## and writing it once is the only way both halves of it stay true:
##
##   KEYBOARD  up/down move the focus (skipping headers and disabled rows),
##             left/right adjust a value, Enter/Space activate, Home/End jump.
##   MOUSE     hover moves the focus to the row under the pointer, so the two
##             input methods can never disagree about where you are; a click
##             activates, or adjusts if it landed on a chevron or a slider track.
##
## The second half is what usually rots. A menu built out of Godot Buttons gets
## mouse for free and keyboard "for free" — until a focus neighbour is wrong and
## one entry becomes unreachable, which no screenshot shows. Here the focus is a
## single integer over one array, `tests/meta/run_meta_ui.tscn` drives it with
## real InputEventKeys, and a row that cannot be reached fails the suite.
##
## Row kinds and the keys they answer to:
##   HEADER   nothing — a caption between groups
##   ACTION   Enter/Space/click                     → row_activated(id)
##   TOGGLE   Enter/Space/click/left/right          → row_changed(id, bool)
##   CHOICE   left/right, click on ‹ ›, Enter cycles → row_changed(id, value)
##   SLIDER   left/right, click or drag on the track → row_changed(id, float)
##   KEYBIND  Enter/click starts capture            → row_activated(id)
##   SLOT     Enter/click                           → row_activated(id)
##   NOTE     nothing — a line of prose in the list

enum Kind { HEADER, ACTION, TOGGLE, CHOICE, SLIDER, KEYBIND, SLOT, NOTE }

signal row_activated(id: StringName)
signal row_changed(id: StringName, value: Variant)
signal focus_moved(id: StringName)

const ARROW_W: float = 26.0
const TRACK_W: float = 200.0
## Reserved for a slider's printed value. Without it "100%" is drawn on top of
## the right end of the track, which is where the number matters most.
const VALUE_W: float = 78.0
const PAD: float = 18.0

var style: LcnMetaStyle = null
var rows: Array[Dictionary] = []
var focus_index: int = -1
## Set false while a keybind row is capturing, so the capture owns the keyboard.
var accepts_input: bool = true

var _dragging: int = -1


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


## Replaces the rows and keeps the focus on the same row id when it still exists.
func set_rows(new_rows: Array[Dictionary]) -> void:
	var previous: StringName = focused_id()
	rows = new_rows
	var at: int = index_of(previous)
	focus_index = at if at >= 0 else first_selectable()
	queue_redraw()


func index_of(id: StringName) -> int:
	if id == &"":
		return -1
	for i: int in rows.size():
		if StringName(rows[i].get("id", &"")) == id:
			return i if is_selectable(i) else -1
	return -1


func focused_id() -> StringName:
	if focus_index < 0 or focus_index >= rows.size():
		return &""
	return StringName(rows[focus_index].get("id", &""))


func focused_row() -> Dictionary:
	if focus_index < 0 or focus_index >= rows.size():
		return {}
	return rows[focus_index]


func is_selectable(i: int) -> bool:
	if i < 0 or i >= rows.size():
		return false
	var row: Dictionary = rows[i]
	var kind: int = int(row.get("kind", Kind.ACTION))
	if kind == Kind.HEADER or kind == Kind.NOTE:
		return false
	return bool(row.get("enabled", true))


func first_selectable() -> int:
	for i: int in rows.size():
		if is_selectable(i):
			return i
	return -1


## Wraps, because a menu that stops at the bottom makes the player press down
## eleven times to get back to the top entry.
func move_focus(delta: int) -> void:
	if rows.is_empty():
		return
	var n: int = rows.size()
	var at: int = focus_index if focus_index >= 0 else -1
	for _step: int in n:
		at = posmod(at + delta, n)
		if is_selectable(at):
			if at != focus_index:
				focus_index = at
				focus_moved.emit(focused_id())
				queue_redraw()
			return


func focus_id(id: StringName) -> bool:
	var at: int = index_of(id)
	if at < 0:
		return false
	focus_index = at
	focus_moved.emit(id)
	queue_redraw()
	return true


# ------------------------------------------------------------------- input ---

## Returns true when the event was consumed. The owning screen decides whether
## to mark it handled, because only the screen knows if it is the top of the
## modal stack.
func handle_key(event: InputEventKey) -> bool:
	if not accepts_input or not event.pressed or rows.is_empty():
		return false
	match event.keycode:
		KEY_UP, KEY_W:
			move_focus(-1)
			return true
		KEY_DOWN, KEY_S:
			move_focus(1)
			return true
		KEY_HOME:
			focus_index = -1
			move_focus(1)
			return true
		KEY_END:
			focus_index = 0
			move_focus(-1)
			return true
		KEY_LEFT, KEY_A:
			return _adjust(-1)
		KEY_RIGHT, KEY_D:
			return _adjust(1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			return _activate()
	return false


func activate_focused() -> bool:
	return _activate()


func _activate() -> bool:
	var row: Dictionary = focused_row()
	if row.is_empty():
		return false
	var kind: int = int(row.get("kind", Kind.ACTION))
	match kind:
		Kind.TOGGLE:
			row_changed.emit(focused_id(), not bool(row.get("value", false)))
		Kind.CHOICE:
			return _adjust(1)
		Kind.SLIDER:
			return false
		_:
			row_activated.emit(focused_id())
	return true


func _adjust(dir: int) -> bool:
	var row: Dictionary = focused_row()
	if row.is_empty():
		return false
	var id: StringName = focused_id()
	match int(row.get("kind", Kind.ACTION)):
		Kind.TOGGLE:
			row_changed.emit(id, dir > 0)
			return true
		Kind.CHOICE:
			var values: Array = row.get("values", [])
			if values.is_empty():
				return false
			var at: int = maxi(0, values.find(row.get("value")))
			row_changed.emit(id, values[posmod(at + dir, values.size())])
			return true
		Kind.SLIDER:
			var step: float = float(row.get("step", 0.05))
			var lo: float = float(row.get("min", 0.0))
			var hi: float = float(row.get("max", 1.0))
			row_changed.emit(id, clampf(float(row.get("value", 0.0)) + step * float(dir), lo, hi))
			return true
	return false


func _gui_input(event: InputEvent) -> void:
	if not accepts_input:
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		var over: int = _row_at(motion.position)
		if over >= 0 and over != focus_index:
			focus_index = over
			focus_moved.emit(focused_id())
			queue_redraw()
		if _dragging >= 0:
			_drag_slider(_dragging, motion.position)
		return
	var click := event as InputEventMouseButton
	if click == null:
		return
	if click.button_index == MOUSE_BUTTON_LEFT and not click.pressed:
		_dragging = -1
		return
	if click.button_index != MOUSE_BUTTON_LEFT or not click.pressed:
		return
	var at: int = _row_at(click.position)
	if at < 0:
		return
	focus_index = at
	focus_moved.emit(focused_id())
	var row: Dictionary = rows[at]
	var kind: int = int(row.get("kind", Kind.ACTION))
	if kind == Kind.SLIDER:
		_dragging = at
		_drag_slider(at, click.position)
		accept_event()
		return
	if kind == Kind.CHOICE:
		# The chevrons are real targets: a mouse player must be able to go back
		# a step, and clicking the label cycling forward is not "back".
		var r: Rect2 = row_rect(at)
		if click.position.x >= r.end.x - PAD - ARROW_W:
			var _fwd: bool = _adjust(1)
			accept_event()
			return
		if click.position.x >= r.end.x - PAD - ARROW_W * 2.0 - TRACK_W:
			var _back: bool = _adjust(-1)
			accept_event()
			return
	var _did: bool = _activate()
	accept_event()


func _drag_slider(at: int, pos: Vector2) -> void:
	var row: Dictionary = rows[at]
	var r: Rect2 = row_rect(at)
	var track: Rect2 = _track_rect(r)
	var t: float = clampf((pos.x - track.position.x) / maxf(1.0, track.size.x), 0.0, 1.0)
	var lo: float = float(row.get("min", 0.0))
	var hi: float = float(row.get("max", 1.0))
	var step: float = float(row.get("step", 0.05))
	var value: float = lo + (hi - lo) * t
	if step > 0.0:
		value = snappedf(value, step)
	row_changed.emit(StringName(row.get("id", &"")), clampf(value, lo, hi))


func _row_at(pos: Vector2) -> int:
	for i: int in rows.size():
		if is_selectable(i) and row_rect(i).has_point(pos):
			return i
	return -1


# ----------------------------------------------------------------- layout ----

func row_height_of(row: Dictionary) -> float:
	if style == null:
		return 40.0
	var kind: int = int(row.get("kind", Kind.ACTION))
	match kind:
		Kind.HEADER:
			return style.row_height(LcnMetaStyle.FS_SMALL) * 1.2
		Kind.NOTE:
			return style.row_height(LcnMetaStyle.FS_BODY) * 0.9
		Kind.SLOT:
			return style.row_height(LcnMetaStyle.FS_ROW) * 2.4
	# A row with a hint is TALLER, always — not only while it is focused. Height
	# that depends on focus makes the whole list jump under the pointer, and a
	# hint drawn into a row sized without it lands on the label below: the first
	# screenshots of the title screen had "Caldera Nine, the morning of the first
	# day" printed through "Load a city".
	var h: float = style.row_height(LcnMetaStyle.FS_ROW)
	if String(row.get("hint", "")) != "":
		h += float(style.fs(LcnMetaStyle.FS_SMALL)) * 1.5
	return h


func row_rect(i: int) -> Rect2:
	var y: float = 0.0
	for k: int in rows.size():
		var h: float = row_height_of(rows[k])
		if k == i:
			return Rect2(Vector2(0.0, y), Vector2(size.x, h))
		y += h
	return Rect2()


## Total height the rows need. The screen uses it to size and centre the list.
func content_height() -> float:
	var y: float = 0.0
	for row: Dictionary in rows:
		y += row_height_of(row)
	return y


func _track_rect(r: Rect2) -> Rect2:
	var w: float = TRACK_W
	var h: float = maxf(6.0, style.row_height(LcnMetaStyle.FS_ROW) * 0.16)
	var mid: float = r.position.y + _label_offset(r) - float(style.fs(LcnMetaStyle.FS_ROW)) * 0.36 - h * 0.5
	return Rect2(Vector2(r.end.x - PAD - VALUE_W - w, mid), Vector2(w, h))


## Baseline for a row's label. A row with a hint keeps its label at the TOP of
## the taller row rather than floating in the middle of it.
func _label_offset(r: Rect2) -> float:
	var line: float = style.row_height(LcnMetaStyle.FS_ROW)
	return minf(line, r.size.y) * 0.5 + float(style.fs(LcnMetaStyle.FS_ROW)) * 0.36


# ------------------------------------------------------------------- draw ----

func _draw() -> void:
	if style == null:
		return
	for i: int in rows.size():
		_draw_row(i, rows[i], row_rect(i))


func _draw_row(i: int, row: Dictionary, r: Rect2) -> void:
	var kind: int = int(row.get("kind", Kind.ACTION))
	var enabled: bool = bool(row.get("enabled", true))
	var focused: bool = i == focus_index and is_selectable(i)
	var text_y: float = r.position.y + _label_offset(r)
	var label_text: String = String(row.get("label", ""))

	if kind == Kind.HEADER:
		style.label(self, Vector2(r.position.x + PAD, text_y), label_text, style.accent())
		var line_y: float = r.position.y + r.size.y - 4.0
		draw_line(Vector2(r.position.x + PAD, line_y), Vector2(r.end.x - PAD, line_y),
			Color(style.accent().r, style.accent().g, style.accent().b, 0.25), 1.0)
		return

	if kind == Kind.NOTE:
		var _w: float = style.text(self, Vector2(r.position.x + PAD, text_y), label_text,
			LcnMetaStyle.FS_BODY, style.ink_faint())
		return

	if focused:
		style.draw_focus(self, r.grow(-2.0))

	var ink: Color = style.ink() if enabled else style.ink_faint()
	if focused:
		ink = LcnMetaStyle.P.SNOW_LIT

	if kind == Kind.SLOT:
		_draw_slot(row, r, ink, focused)
		return

	# The focused row is prefixed with a mark as well as being lit, because a
	# ring and a brighter white are both colour, and colour is never the only
	# carrier of state in this build.
	var x: float = r.position.x + PAD
	if focused:
		var _mw: float = style.text(self, Vector2(x - 12.0, text_y), "›",
			LcnMetaStyle.FS_ROW, style.accent())
	var _lw: float = style.text(self, Vector2(x, text_y), label_text, LcnMetaStyle.FS_ROW, ink)

	match kind:
		Kind.TOGGLE:
			var on: bool = bool(row.get("value", false))
			var word: String = String(row.get("on_text", "on")) if on else String(row.get("off_text", "off"))
			style.text_right(self, r.end.x - PAD, text_y,
				("[×]  " if on else "[ ]  ") + word, LcnMetaStyle.FS_ROW,
				style.status(&"good") if on else style.ink_dim())
		Kind.CHOICE:
			var shown: String = String(row.get("value_text", str(row.get("value", ""))))
			style.text_right(self, r.end.x - PAD, text_y, "›", LcnMetaStyle.FS_ROW,
				style.accent() if focused else style.ink_faint())
			style.text_right(self, r.end.x - PAD - ARROW_W, text_y, shown,
				LcnMetaStyle.FS_ROW, ink)
			var back_x: float = r.end.x - PAD - ARROW_W - style.measure(shown, LcnMetaStyle.FS_ROW) - 12.0
			style.text_right(self, back_x, text_y, "‹", LcnMetaStyle.FS_ROW,
				style.accent() if focused else style.ink_faint())
		Kind.SLIDER:
			_draw_slider(row, r, focused)
		Kind.KEYBIND:
			var bind: String = String(row.get("value_text", "—"))
			var tone: Color = ink
			if bool(row.get("conflict", false)):
				tone = style.status(&"bad")
			elif bool(row.get("capturing", false)):
				tone = style.accent()
			style.text_right(self, r.end.x - PAD, text_y,
				"press a key…" if bool(row.get("capturing", false)) else bind,
				LcnMetaStyle.FS_ROW, tone)

	var hint: String = String(row.get("hint", ""))
	if hint != "":
		style.text(self, Vector2(x, text_y + float(style.fs(LcnMetaStyle.FS_SMALL)) * 1.5),
			hint, LcnMetaStyle.FS_SMALL,
			style.ink_dim() if focused else style.ink_faint())


func _draw_slider(row: Dictionary, r: Rect2, focused: bool) -> void:
	var track: Rect2 = _track_rect(r)
	var lo: float = float(row.get("min", 0.0))
	var hi: float = float(row.get("max", 1.0))
	var v: float = clampf(float(row.get("value", 0.0)), lo, hi)
	var t: float = (v - lo) / maxf(0.0001, hi - lo)
	draw_rect(track, Color(LcnMetaStyle.P.COLD_MID.r, LcnMetaStyle.P.COLD_MID.g,
		LcnMetaStyle.P.COLD_MID.b, 0.9), true)
	var filled: Rect2 = Rect2(track.position, Vector2(track.size.x * t, track.size.y))
	draw_rect(filled, style.accent() if focused else LcnMetaStyle.P.WARM_MID, true)
	draw_rect(track, Color(LcnMetaStyle.P.COLD_RIM.r, LcnMetaStyle.P.COLD_RIM.g,
		LcnMetaStyle.P.COLD_RIM.b, 0.9), false, 1.0)
	# The number, always. A bare bar tells a player nothing they can repeat.
	var text_y: float = r.position.y + _label_offset(r)
	style.text_right(self, r.end.x - PAD, text_y, String(row.get("value_text", "%d%%" % int(round(t * 100.0)))),
		LcnMetaStyle.FS_ROW, style.ink() if focused else style.ink_dim())


func _draw_slot(row: Dictionary, r: Rect2, ink: Color, focused: bool) -> void:
	var inner: Rect2 = r.grow(-6.0)
	style.draw_plate(self, inner, focused)
	var thumb_w: float = inner.size.y * (16.0 / 9.0)
	var thumb_rect := Rect2(inner.position + Vector2(6.0, 6.0),
		Vector2(thumb_w - 12.0, inner.size.y - 12.0))
	var tex: Texture2D = row.get("thumbnail")
	if tex != null:
		draw_texture_rect(tex, thumb_rect, false)
		draw_rect(thumb_rect, Color(LcnMetaStyle.P.COLD_RIM.r, LcnMetaStyle.P.COLD_RIM.g,
			LcnMetaStyle.P.COLD_RIM.b, 0.8), false, 1.0)
	else:
		draw_rect(thumb_rect, Color(LcnMetaStyle.P.COLD_MID.r, LcnMetaStyle.P.COLD_MID.g,
			LcnMetaStyle.P.COLD_MID.b, 0.8), true)
		style.text_centre(self, thumb_rect.get_center().x,
			thumb_rect.get_center().y, String(row.get("empty_text", "empty")),
			LcnMetaStyle.FS_SMALL, style.ink_faint())
	var x: float = thumb_rect.end.x + 16.0
	var top: float = inner.position.y + float(style.fs(LcnMetaStyle.FS_ROW)) * 1.4
	var _w: float = style.text(self, Vector2(x, top), String(row.get("label", "")),
		LcnMetaStyle.FS_ROW, ink)
	var sub: String = String(row.get("sub", ""))
	if sub != "":
		style.text(self, Vector2(x, top + float(style.fs(LcnMetaStyle.FS_SMALL)) * 1.6),
			sub, LcnMetaStyle.FS_SMALL, style.ink_dim())
	var right: String = String(row.get("right", ""))
	if right != "":
		style.text_right(self, inner.end.x - 14.0, top, right, LcnMetaStyle.FS_SMALL,
			style.ink_faint())
