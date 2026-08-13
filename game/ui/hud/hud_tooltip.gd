class_name LcnHudTooltip
extends Control
## The explanation layer. [P17]
##
## The brief for this HUD is that every number has a tooltip explaining what it
## means and what changes it, so this is not decoration — it is half the reason
## the interface is legible at all. It is drawn, not themed, so it looks like the
## rest of the panelling, and it obeys the player's `gameplay/tooltip_delay`.
##
## It never covers the thing it explains: the card flips to whichever side of the
## anchor has room, and it is clamped inside the viewport.

const S := LcnHudStyle

const PAD: float = 12.0
const MAX_WIDTH: float = 340.0
const GAP: float = 10.0

var style: LcnHudStyle = null

var _title: String = ""
var _body: String = ""
var _anchor: Rect2 = Rect2()
var _wait: float = 0.0
var _shown: bool = false
var _alpha: float = 0.0
var _lines: PackedStringArray = PackedStringArray()
var _box: Rect2 = Rect2()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func setup(hud_style: LcnHudStyle) -> void:
	style = hud_style


## Requests the card for a region. Repeated calls with the same content are
## free, so a widget may call this on every mouse move.
func show_for(anchor: Rect2, title: String, body: String) -> void:
	if title == "" and body == "":
		hide_tip()
		return
	if title == _title and body == _body and anchor == _anchor:
		return
	_title = title
	_body = body
	_anchor = anchor
	_wait = style.tooltip_delay() if style != null else 0.35
	if _shown:
		# Already open: slide straight to the next card, no second wait. This is
		# what makes scanning a row of numbers feel instant.
		_wait = 0.0
		_relayout()
	queue_redraw()


func hide_tip() -> void:
	if _title == "" and _body == "" and not _shown:
		return
	_title = ""
	_body = ""
	_shown = false
	_wait = 0.0
	queue_redraw()


func _process(delta: float) -> void:
	var want: bool = _title != "" or _body != ""
	if want and not _shown:
		_wait -= delta
		if _wait <= 0.0:
			_shown = true
			_relayout()
	var target: float = 1.0 if (_shown and want) else 0.0
	if is_equal_approx(_alpha, target):
		if not want and _alpha <= 0.001:
			return
	else:
		var speed: float = 12.0 if style == null or not style.reduce_motion else 1000.0
		_alpha = move_toward(_alpha, target, delta * speed)
		queue_redraw()


func _relayout() -> void:
	if style == null:
		return
	var body_size: int = style.fs(12)
	var title_size: int = style.fs(13)
	var inner: float = MAX_WIDTH - PAD * 2.0
	_lines = _wrap(_body, inner, body_size)
	var w: float = 0.0
	for l: String in _lines:
		w = maxf(w, style.text_width(l, body_size))
	w = maxf(w, style.caps_width(_title, title_size, 1.6))
	w = minf(w + PAD * 2.0, MAX_WIDTH)
	var line_h: float = float(body_size) * 1.42
	var h: float = PAD * 2.0 + float(title_size) * 1.5 + float(_lines.size()) * line_h
	if _title == "":
		h -= float(title_size) * 1.5

	var x: float = _anchor.position.x
	var y: float = _anchor.position.y + _anchor.size.y + GAP
	if y + h > size.y - 8.0:
		y = _anchor.position.y - h - GAP
	x = clampf(x, 8.0, maxf(8.0, size.x - w - 8.0))
	y = clampf(y, 8.0, maxf(8.0, size.y - h - 8.0))
	_box = Rect2(Vector2(x, y), Vector2(w, h))


func _draw() -> void:
	if style == null or _alpha <= 0.01 or not _shown:
		return
	var was: float = style.plate_alpha()
	# The card is opaque on purpose: it is text over a busy map.
	var pts: PackedVector2Array = LcnHudStyle.plate_points(_box, 6.0)
	var body_col: Color = LcnHudStyle.P.COLD_DEEP
	var cols := PackedColorArray()
	for p: Vector2 in pts:
		var f: float = clampf((p.y - _box.position.y) / maxf(1.0, _box.size.y), 0.0, 1.0)
		var c: Color = LcnHudStyle.P.COLD_MID.lerp(body_col, f)
		cols.append(Color(c.r, c.g, c.b, (0.93 if was > 0.0 else 0.93) * _alpha))
	draw_polygon(pts, cols)
	var closed: PackedVector2Array = pts.duplicate()
	closed.append(pts[0])
	var rim: Color = LcnHudStyle.P.STEEL
	draw_polyline(closed, Color(rim.r, rim.g, rim.b, 0.85 * _alpha), 1.0)

	var x: float = _box.position.x + PAD
	var y: float = _box.position.y + PAD
	var title_size: int = style.fs(13)
	var body_size: int = style.fs(12)
	if _title != "":
		y += float(title_size)
		var warm: Color = style.ink_warm()
		style.draw_caps(self, Vector2(x, y), _title, title_size,
			Color(warm.r, warm.g, warm.b, _alpha), 1.6)
		y += float(title_size) * 0.5
	var ink: Color = style.ink_dim()
	var line_h: float = float(body_size) * 1.42
	for l: String in _lines:
		y += line_h
		style.draw_text(self, Vector2(x, y - line_h * 0.28), l, body_size,
			Color(ink.r, ink.g, ink.b, _alpha))


## Greedy word wrap. No BBCode, no RichTextLabel, no theme: one measured string.
func _wrap(text: String, width: float, font_size: int) -> PackedStringArray:
	var out := PackedStringArray()
	if text == "":
		return out
	var words: PackedStringArray = text.split(" ", false)
	var line: String = ""
	for w: String in words:
		var candidate: String = w if line == "" else line + " " + w
		if style.text_width(candidate, font_size) <= width or line == "":
			line = candidate
		else:
			out.append(line)
			line = w
	if line != "":
		out.append(line)
	return out
