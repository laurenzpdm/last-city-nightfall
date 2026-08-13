class_name LcnHudVitals
extends LcnHudWidget
## Who is still alive, and whether they still believe you. [P17]
##
## Population is the only number in this game that cannot be rebuilt: heat comes
## back, walls come back, people do not. So the count is large, the dead are
## listed separately and permanently, and the meters underneath are the ones that
## decide whether the city holds together — body warmth, food, hope, discontent.
##
## Body warmth rather than an air temperature on purpose: [P05] tracks what each
## citizen actually feels, and a city can have a warm district and still be
## freezing its people on the walk to work.
##
## The panel hides itself when neither [P05] nor [P06] is in the build. A panel
## confidently reporting a population of zero because nobody has written the
## population system yet is worse than no panel at all.

const WIDTH: float = 322.0
const ROW: float = 26.0
const LABEL_COL: float = 104.0

var _y_pop: float = 0.0
var _y_cond: float = 0.0
var _rows: Array[Dictionary] = []
var _height: float = 176.0


func should_show() -> bool:
	return probe != null and (probe.has_population or probe.has_society)


func signature() -> String:
	if probe == null:
		return ""
	return "%d|%d|%d|%d|%d|%d|%d|%.2f|%.1f|%.3f|%.3f" % [
		probe.population, probe.sick, probe.injured, probe.dead, probe.homeless,
		probe.idle, probe.freezing, snappedf(probe.warmth01, 0.02),
		snappedf(probe.food_days, 0.1), snappedf(probe.hope, 0.01),
		snappedf(probe.discontent, 0.01),
	]


func layout() -> void:
	clear_hot()
	_rows.clear()
	var y: float = content_top()
	if probe.has_population:
		_y_pop = y + float(style.fs(30)) * 0.78
		_y_cond = _y_pop + 14.0 + float(style.fs(12))
		y = _y_cond + 18.0
		add_hot(Rect2(11.0, content_top() - 4.0, 180.0, _y_pop - content_top() + 14.0),
			"Citizens",
			"Everyone alive in the city right now. They work your buildings, and "
			+ "they need warmth and food to keep doing it.")
		add_hot(Rect2(11.0, _y_cond - float(style.fs(12)) - 6.0, WIDTH - 22.0,
			float(style.fs(12)) + 12.0), "Condition",
			"Cold citizens fall sick, sick citizens stop working, and citizens who "
			+ "stay sick in the cold die. The dead never come back. Average health "
			+ "%s, average morale %s." % [LcnHudFormat.percent(probe.health01),
				LcnHudFormat.percent(probe.morale01)])
		_row(y, "body warmth", "Body warmth",
			"How warm the average citizen actually is, not how warm the air is. "
			+ "Below 40% they start falling ill; below 12% the cold begins taking "
			+ "their health. Radiators, insulated homes and shorter walks raise it.")
		y += ROW
		if probe.food_days >= 0.0:
			_row(y, "food", "Food",
				"Days the city can keep eating at this population and this ration. "
				+ "Kitchens turn stores into meals; a long haul to the table wastes "
				+ "both.")
			y += ROW
	if probe.has_society:
		_row(y, "hope", "Hope",
			"Whether the city believes it will survive the winter. It rises when "
			+ "people are warm, fed and see the place growing, and falls with every "
			+ "death and every cold night. " + _reason_line())
		y += ROW
		_row(y, "discontent", "Discontent",
			"How angry they are with you. Harsh laws and hard shifts raise it. Let "
			+ "it fill and the city stops doing what you tell it. %s of the city is "
			+ "already bitter enough to make trouble."
			% LcnHudFormat.percent(probe.unrest01))
		y += ROW
	_height = y + 6.0
	custom_minimum_size = Vector2(WIDTH, _height)
	size = custom_minimum_size


func _row(baseline: float, key: String, title: String, tip: String) -> void:
	_rows.append({"y": baseline, "key": key})
	add_hot(Rect2(11.0, baseline - float(style.fs(12)) - 5.0, WIDTH - 22.0,
		float(style.fs(12)) + 11.0), title, tip)


## [P06] already writes a sentence for every pressure on its meters. Showing its
## words instead of inventing new ones keeps the HUD and the simulation telling
## the player the same story.
func _reason_line() -> String:
	if probe.hope_reasons.is_empty():
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for r: Dictionary in probe.hope_reasons:
		var label: String = String(r.get("label", ""))
		if label != "":
			parts.append(label)
	if parts.is_empty():
		return ""
	return "Right now: %s." % ", ".join(parts)


func _draw() -> void:
	if probe == null or style == null:
		return
	var sev: int = S.Sev.CALM
	if probe.freezing > 0 or probe.city_is_freezing() \
			or (probe.has_society and probe.hope < 0.2):
		sev = S.Sev.DANGER
	elif probe.sick > 0 or probe.city_is_cold() \
			or (probe.has_society and probe.discontent > 0.6):
		sev = S.Sev.WARN
	draw_frame("The people", sev, 0.26)

	if probe.has_population:
		var x: float = 15.0
		x += style.draw_text(self, Vector2(x, _y_pop), LcnHudFormat.count(probe.population),
			style.fs(30), style.ink()) + 9.0
		x += style.draw_text(self, Vector2(x, _y_pop), "alive", style.fs(13),
			style.ink_faint()) + 10.0
		var dir: int = probe.trend.direction(&"__population", 0.4)
		if dir != 0:
			style.draw_arrow(self, Vector2(x + 5.0, _y_pop - 6.0), dir, 9.0,
				style.health_colour(1.0) if dir > 0 else style.sev_colour(S.Sev.DANGER))
		if probe.dead > 0:
			style.draw_text_right(self, WIDTH - 15.0, _y_pop,
				"%s dead" % LcnHudFormat.count(probe.dead), style.fs(13),
				LcnHudStyle.P.SNOW_SHADOW)
		_draw_condition()

	for r: Dictionary in _rows:
		var y: float = float(r["y"])
		match String(r["key"]):
			"body warmth":
				_meter(y, "body warmth", probe.warmth01, style.health_colour(
					clampf(inverse_lerp(0.15, 0.55, probe.warmth01), 0.0, 1.0)))
			"food":
				_food(y)
			"hope":
				_meter(y, "hope", probe.hope, style.health_colour(probe.hope))
			"discontent":
				_meter(y, "discontent", probe.discontent,
					style.sev_colour(S.Sev.DANGER) if probe.discontent > 0.6
					else style.sev_colour(S.Sev.WARN))
	draw_marks()


## One line naming everything wrong with the people, or one line saying nothing
## is. Never a wall of zeroes.
func _draw_condition() -> void:
	var parts: Array[Dictionary] = []
	if probe.freezing > 0:
		parts.append({"t": "%d freezing" % probe.freezing,
			"c": style.sev_colour(S.Sev.DANGER)})
	elif probe.city_is_freezing():
		parts.append({"t": "freezing", "c": style.sev_colour(S.Sev.DANGER)})
	elif probe.city_is_cold():
		parts.append({"t": "cold", "c": style.sev_colour(S.Sev.WARN)})
	if probe.sick > 0:
		parts.append({"t": "%d sick" % probe.sick, "c": style.sev_colour(S.Sev.WARN)})
	if probe.injured > 0:
		parts.append({"t": "%d hurt" % probe.injured, "c": style.sev_colour(S.Sev.WARN)})
	if probe.homeless > 0:
		parts.append({"t": "%d unhoused" % probe.homeless, "c": style.ink_dim()})
	if probe.idle > 0:
		parts.append({"t": "%d idle" % probe.idle, "c": style.ink_faint()})
	if parts.is_empty():
		parts.append({"t": "warm, fed and working", "c": style.health_colour(1.0)})
	var px: float = 15.0
	for i: int in parts.size():
		var p: Dictionary = parts[i]
		px += style.draw_text(self, Vector2(px, _y_cond), String(p["t"]),
			style.fs(12), p["c"] as Color)
		if px > WIDTH - 70.0:
			break
		if i < parts.size() - 1:
			px += style.draw_text(self, Vector2(px + 6.0, _y_cond), "·", style.fs(12),
				style.ink_faint()) + 11.0


func _meter(baseline: float, label: String, value01: float, colour: Color) -> void:
	var label_w: float = style.draw_caps(self, Vector2(15.0, baseline), label,
		style.fs(9), style.ink_faint(), 1.6)
	# The column widens for the label rather than the label running into the
	# meter: at font_scale 1.5 "DISCONTENT" is wider than any fixed column.
	var left: float = 15.0 + maxf(LABEL_COL, label_w + 12.0)
	style.draw_segments(self, Rect2(left, baseline - 9.0, WIDTH - left - 62.0, 8.0),
		value01, 10, colour)
	style.draw_text_right(self, WIDTH - 15.0, baseline, LcnHudFormat.percent(value01),
		style.fs(12), style.ink_dim())


## Days of food, which is a countdown wearing a number's clothes.
func _food(baseline: float) -> void:
	var label_w: float = style.draw_caps(self, Vector2(15.0, baseline), "food",
		style.fs(9), style.ink_faint(), 1.6)
	var days: float = probe.food_days
	var col: Color = style.health_colour(clampf(days / 3.0, 0.0, 1.0))
	var text: String = "%.1f days" % days
	if days >= 100.0:
		text = "plenty"
		col = style.health_colour(1.0)
	elif days < 0.05:
		text = "none left"
	style.draw_text(self, Vector2(15.0 + maxf(LABEL_COL, label_w + 12.0), baseline),
		text, style.fs(13), col)
