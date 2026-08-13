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
const HEAD_ROW: float = 68.0
const ROW: float = 30.0
const TOP: float = 34.0

var alerts: LcnHudAlerts = null

var _rows: Array[Dictionary] = []
var _height: float = 0.0


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


func layout() -> void:
	_rows = alerts.top()
	clear_hot()
	var y: float = TOP
	for i: int in _rows.size():
		var h: float = HEAD_ROW if i == 0 else ROW
		var e: Dictionary = _rows[i]
		var body: String = String(e.get("body", ""))
		var fix: String = String(e.get("fix", ""))
		var tip: String = body
		if fix != "":
			tip += "  →  " + fix
		var focus: Vector2 = e.get("focus", Vector2.ZERO)
		if focus != Vector2.ZERO:
			tip += "  (click to look at it)"
		add_hot(Rect2(8.0, y, WIDTH - 16.0, h - 4.0), String(e.get("head", "")), tip,
			&"focus", focus)
		y += h
	if alerts.hidden_count() > 0:
		y += 18.0
	_height = y + 10.0
	custom_minimum_size = Vector2(WIDTH, _height)
	size = custom_minimum_size


func _draw() -> void:
	if alerts == null or style == null:
		return
	var worst: int = alerts.worst_severity()
	draw_frame("Attention", worst, 0.20 + 0.30 * float(worst) / 4.0)
	var y: float = TOP
	for i: int in _rows.size():
		var e: Dictionary = _rows[i]
		var h: float = HEAD_ROW if i == 0 else ROW
		_draw_row(e, Rect2(8.0, y, WIDTH - 16.0, h - 4.0), i == 0)
		y += h
	var hidden: int = alerts.hidden_count()
	if hidden > 0:
		style.draw_text(self, Vector2(16.0, y + 12.0),
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

	var x: float = rect.position.x + 12.0
	var baseline: float = rect.position.y + float(style.fs(13)) + 2.0
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
	var body: String = String(e.get("body", ""))
	var fix: String = String(e.get("fix", ""))
	var wrap_w: float = rect.size.x - 24.0
	var yy: float = baseline + float(style.fs(12)) * 1.3
	for line: String in _wrap(body, wrap_w, style.fs(12)):
		style.draw_text(self, Vector2(rect.position.x + 12.0, yy), line, style.fs(12),
			style.ink_dim())
		yy += float(style.fs(12)) * 1.25
		if yy > rect.position.y + rect.size.y - float(style.fs(12)) * 0.6:
			break
	if fix != "":
		var lines: PackedStringArray = _wrap(fix, wrap_w, style.fs(12))
		if not lines.is_empty():
			var warm: Color = style.ink_warm()
			style.draw_text(self, Vector2(rect.position.x + 12.0, yy), "→ " + lines[0],
				style.fs(12), Color(warm.r, warm.g, warm.b, 0.85))


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
