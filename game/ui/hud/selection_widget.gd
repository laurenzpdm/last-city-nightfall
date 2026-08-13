class_name LcnHudSelection
extends LcnHudWidget
## What that thing is doing, what it needs, and why it is not working. [P17]
##
## The simulation already knows all three. [P02] records, per building, how much
## of its heat arrived, its internal temperature, its network, and the exact tile
## that choked it; [P11] knows its lifecycle and its damage; [P04] and [P05] know
## its recipe and its crew. This panel is where those become one answer, in
## sentences, with a click that takes the camera to the cause.
##
## It never guesses. A field only appears when a system actually answered.

const WIDTH: float = 400.0
const LINE: float = 24.0

var _info: Dictionary = {}
var _kind: StringName = &""
var _height: float = 0.0
var _lines: Array[Dictionary] = []
var _problems: Array[String] = []
var _status: String = ""
var _status_sev: int = S.Sev.CALM
var _is_citizen: bool = false
var _y_title: float = 0.0
var _y_status: float = 0.0
var _y_first: float = 0.0


## Called by LcnHud when the player's selection changes.
func show_entity(info: Dictionary, is_citizen: bool) -> void:
	_info = info
	_is_citizen = is_citizen
	invalidate()


func clear_entity() -> void:
	_info = {}
	invalidate()


func should_show() -> bool:
	return not _info.is_empty()


func desired_height() -> float:
	return _height


func signature() -> String:
	if _info.is_empty():
		return ""
	return "%d|%s|%d|%.2f|%d|%.2f|%d" % [
		int(_info.get("id", -1)), _info.get("title", ""), int(_info.get("state", -1)),
		snappedf(float(_info.get("served", 1.0)), 0.02),
		(_info.get("problems", []) as Array).size(),
		snappedf(float(_info.get("progress", 1.0)), 0.02),
		int(_info.get("workers", 0)),
	]


func layout() -> void:
	_lines = _info.get("lines", [] as Array[Dictionary])
	_problems = _info.get("problems", [] as Array[String])
	_kind = StringName(String(_info.get("kind", "")))
	_status = _status_text()
	clear_hot()

	_y_title = content_top() + float(style.fs(18)) * 0.80
	_y_status = _y_title + 10.0 + float(style.fs(10))
	_y_first = _y_status + 12.0 + float(style.fs(13))

	var y: float = _y_first
	for i: int in _lines.size():
		var l: Dictionary = _lines[i]
		add_hot(Rect2(12.0, y - 16.0, WIDTH - 24.0, LINE - 2.0),
			String(l.get("label", "")), String(l.get("tip", "")))
		y += LINE
	if not _problems.is_empty():
		y += 6.0
		var focus: Vector2 = _info.get("problem_focus", Vector2.ZERO)
		for p: String in _problems:
			var h: float = _wrap_height(p, WIDTH - 40.0, style.fs(12))
			add_hot(Rect2(12.0, y - 14.0, WIDTH - 24.0, h + 6.0), "Why it is not working",
				p + ("  (click to look at the cause)" if focus != Vector2.ZERO else ""),
				&"focus", focus)
			y += h + 10.0
	var progress: float = float(_info.get("progress", 1.0))
	if progress < 1.0:
		y += 18.0
	var hp: float = float(_info.get("hp", 1.0))
	var max_hp: float = maxf(1.0, float(_info.get("max_hp", 1.0)))
	if hp < max_hp - 0.5:
		y += 18.0
	_height = y + 12.0
	custom_minimum_size = Vector2(WIDTH, _height)
	size = custom_minimum_size


func _status_text() -> String:
	_status_sev = S.Sev.CALM
	if _is_citizen:
		var task: String = String(_info.get("task", _info.get("activity", "")))
		return LcnHudFormat.titleize(task) if task != "" else "Alive"
	var state: int = int(_info.get("state", 2))
	match state:
		0:
			return "Waiting for materials"
		1:
			_status_sev = S.Sev.CALM
			return "Under construction"
		3:
			_status_sev = S.Sev.WARN
			return "Switched off"
		4:
			_status_sev = S.Sev.DANGER
			return "Frozen solid"
		5:
			return "Being taken apart"
	var served: float = float(_info.get("served", 1.0))
	if served < 0.999 and _info.has("served"):
		_status_sev = S.Sev.DANGER if served < 0.5 else S.Sev.WARN
		return "Browned out — %s of its heat" % LcnHudFormat.percent(served)
	return "Running"


func _draw() -> void:
	if _info.is_empty() or style == null:
		return
	draw_frame("Selected", _status_sev, 0.30)

	var title: String = String(_info.get("title", "—"))
	style.draw_text(self, Vector2(15.0, _y_title), title, style.fs(18), style.ink())
	var sub: String = "#%d" % int(_info.get("id", 0))
	if _info.has("cell"):
		sub += "  ·  %s" % LcnHudFormat.cell(_info["cell"] as Vector2i)
	style.draw_text_right(self, WIDTH - 15.0, _y_title, sub, style.fs(11), style.ink_faint())

	var pill_col: Color = style.ink_dim() if _status_sev == S.Sev.CALM \
		else style.sev_colour(_status_sev)
	style.draw_caps(self, Vector2(15.0, _y_status), _status, style.fs(10), pill_col, 1.8)

	var y: float = _y_first
	for l: Dictionary in _lines:
		style.draw_caps(self, Vector2(15.0, y), String(l.get("label", "")), style.fs(10),
			style.ink_faint(), 1.6)
		var good: float = float(l.get("good", 1.0))
		var col: Color = style.ink() if good > 0.66 else style.health_colour(good)
		style.draw_text(self, Vector2(120.0, y), String(l.get("value", "")), style.fs(13), col)
		y += LINE

	if not _problems.is_empty():
		y += 6.0
		var danger: Color = style.sev_colour(S.Sev.DANGER)
		for p: String in _problems:
			var lines: PackedStringArray = _wrap(p, WIDTH - 40.0, style.fs(12))
			var first: bool = true
			for line: String in lines:
				if first:
					style.draw_text(self, Vector2(14.0, y), "!", style.fs(12), danger)
					first = false
				style.draw_text(self, Vector2(28.0, y), line, style.fs(12),
					style.ink_dim())
				y += float(style.fs(12)) * 1.3
			y += 6.0

	var progress: float = float(_info.get("progress", 1.0))
	if progress < 1.0:
		y += 6.0
		style.draw_caps(self, Vector2(14.0, y), "building", style.fs(9), style.ink_faint(), 1.6)
		style.draw_bar(self, Rect2(100.0, y - 9.0, WIDTH - 160.0, 8.0), progress,
			LcnHudStyle.P.STEEL_LIGHT)
		style.draw_text_right(self, WIDTH - 14.0, y, LcnHudFormat.percent(progress),
			style.fs(11), style.ink_dim())
		y += 18.0

	var hp: float = float(_info.get("hp", 1.0))
	var max_hp: float = maxf(1.0, float(_info.get("max_hp", 1.0)))
	if hp < max_hp - 0.5:
		y += 6.0
		style.draw_caps(self, Vector2(14.0, y), "damage", style.fs(9), style.ink_faint(), 1.6)
		style.draw_bar(self, Rect2(100.0, y - 9.0, WIDTH - 160.0, 8.0), hp / max_hp,
			style.health_colour(hp / max_hp))
		style.draw_text_right(self, WIDTH - 14.0, y, "%d%%" % int(roundf(hp / max_hp * 100.0)),
			style.fs(11), style.ink_dim())
	draw_marks()


func _wrap_height(text: String, width: float, font_size: int) -> float:
	return float(_wrap(text, width, font_size).size()) * float(font_size) * 1.3


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
