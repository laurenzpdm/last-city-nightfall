class_name LcnHudAlertStack
extends LcnHudWidget
## The list of what is wrong, worst first. [P17]
##
## Shape follows the way people actually triage: the worst problem gets a
## sentence explaining itself and a line telling you what to do about it, and
## everything below it gets one line. Nothing here is a log — an entry exists
## only while its cause exists, and clicking any of them puts the camera on the
## tile responsible.
##
## When the city is fine this panel is empty and invisible, which is the point.

const WIDTH: float = 372.0

var alerts: LcnHudAlerts = null

var _rows: Array[Dictionary] = []
var _height: float = 0.0
var _row_rects: Array[Rect2] = []


func bind_alerts(model: LcnHudAlerts) -> void:
	alerts = model


func should_show() -> bool:
	return alerts != null and not alerts.entries.is_empty()


func desired_height() -> float:
	return _height


func signature() -> String:
	if alerts == null:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for e: Dictionary in alerts.top():
		parts.append("%s:%d:%d:%s" % [e.get("key", ""), int(e.get("sev", 0)),
			int(e.get("count", 1)), e.get("head", "")])
	parts.append("+%d" % alerts.hidden_count())
	return "|".join(parts)


## The worst entry gets its explanation and its fix printed under the headline;
## everything below it gets one line and keeps its detail in the tooltip. That
## way the row heights depend only on the content, never on where the mouse is,
## so hovering the list cannot make it jump under the cursor.
func layout() -> void:
	_rows = alerts.top()
	_row_rects.clear()
	clear_hot()
	var line_h: float = float(style.fs(12)) * 1.28
	var head_h: float = float(style.fs(13)) + 12.0
	var y: float = content_top() - float(style.fs(13)) - 4.0
	for i: int in _rows.size():
		var e: Dictionary = _rows[i]
		var body: String = String(e.get("body", ""))
		var fix: String = String(e.get("fix", ""))
		var h: float = head_h
		if i == 0:
			h += float(_wrap(body, WIDTH - 46.0, style.fs(12)).size()) * line_h
			if fix != "":
				h += float(_wrap(fix, WIDTH - 46.0, style.fs(12)).size()) * line_h + 2.0
			h += 6.0
		var rect := Rect2(9.0, y, WIDTH - 18.0, h)
		_row_rects.append(rect)
		var tip: String = body
		if fix != "":
			tip += "  →  " + fix
		var focus: Vector2 = e.get("focus", Vector2.ZERO)
		if focus != Vector2.ZERO:
			tip += "  (click to look at it)"
		add_hot(rect, String(e.get("head", "")), tip, &"focus", focus)
		y += h + 4.0
	if alerts.hidden_count() > 0:
		y += float(style.fs(11)) + 10.0
	_height = y + 8.0
	custom_minimum_size = Vector2(WIDTH, _height)
	size = custom_minimum_size


func _draw() -> void:
	if alerts == null or style == null:
		return
	var worst: int = alerts.worst_severity()
	draw_frame("Attention", worst, 0.20 + 0.30 * float(worst) / 4.0)
	var y: float = content_top()
	for i: int in mini(_rows.size(), _row_rects.size()):
		_draw_row(_rows[i], _row_rects[i], i == 0)
		y = _row_rects[i].position.y + _row_rects[i].size.y
	var hidden: int = alerts.hidden_count()
	if hidden > 0:
		style.draw_text(self, Vector2(17.0, y + float(style.fs(11)) + 6.0),
			"and %d more" % hidden, style.fs(11), style.ink_faint())
	draw_marks()


func _draw_row(e: Dictionary, rect: Rect2, expanded: bool) -> void:
	var sev: int = int(e.get("sev", 0))
	var col: Color = style.sev_colour(sev)
	# A severity tab down the left edge: colour AND position AND a glyph, so the
	# ranking survives any colour-vision deficiency.
	var tab := Rect2(rect.position, Vector2(3.0, rect.size.y))
	var tab_alpha: float = 0.85
	if sev >= S.Sev.DANGER:
		tab_alpha = 0.6 + 0.4 * style.pulse(3.2 + float(sev))
	draw_rect(tab, Color(col.r, col.g, col.b, tab_alpha), true)

	var x: float = rect.position.x + 13.0
	var baseline: float = rect.position.y + float(style.fs(13)) + 4.0
	var glyph: String = S.SEV_GLYPH[clampi(sev, 0, 4)]
	if glyph != "":
		x += style.draw_text(self, Vector2(x, baseline), glyph, style.fs(13), col) + 7.0
	var head: String = String(e.get("head", ""))
	var count: int = int(e.get("count", 1))
	x += style.draw_text(self, Vector2(x, baseline), head, style.fs(13),
		style.ink() if sev >= S.Sev.WARN else style.ink_dim())
	if count > 1:
		style.draw_text_right(self, rect.position.x + rect.size.x - 8.0, baseline,
			"×%d" % count, style.fs(11), style.ink_faint())

	if not expanded:
		return
	var wrap_w: float = rect.size.x - 28.0
	var line_h: float = float(style.fs(12)) * 1.28
	var yy: float = baseline + line_h
	for line: String in _wrap(String(e.get("body", "")), wrap_w, style.fs(12)):
		style.draw_text(self, Vector2(rect.position.x + 13.0, yy), line, style.fs(12),
			style.ink_dim())
		yy += line_h
	var fix: String = String(e.get("fix", ""))
	if fix == "":
		return
	var warm: Color = style.ink_warm()
	var first: bool = true
	for line2: String in _wrap(fix, wrap_w, style.fs(12)):
		yy += 2.0 if first else 0.0
		style.draw_text(self, Vector2(rect.position.x + (13.0 if first else 25.0), yy),
			("→ " if first else "") + line2, style.fs(12),
			Color(warm.r, warm.g, warm.b, 0.88))
		yy += line_h
		first = false


func _wrap(text: String, width: float, font_size: int) -> PackedStringArray:
	var out := PackedStringArray()
	if text == "":
		return out
	var line: String = ""
	for w: String in text.split(" ", false):
		var candidate: String = w if line == "" else line + " " + w
		if style.text_width(candidate, font_size) <= width or line == "":
			line = candidate
		else:
			out.append(line)
			line = w
	if line != "":
		out.append(line)
	return out
