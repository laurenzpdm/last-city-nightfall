class_name LcnHudVitals
extends LcnHudWidget
## Who is still alive, and whether they still believe you. [P17]
##
## Population is the only number in this game that cannot be rebuilt: heat comes
## back, walls come back, people do not. So the count is large, the dead are
## named separately and permanently, and hope and discontent sit directly
## underneath as the two meters that decide whether the city holds together.
##
## The panel hides itself when neither [P05] nor [P06] is in the build. A panel
## confidently reporting a population of zero because nobody has written the
## population system yet is worse than no panel at all.

const PANEL_WIDTH: float = 322.0

var _content_height: float = 176.0


func should_show() -> bool:
	return probe != null and (probe.has_population or probe.has_society)


func desired_height() -> float:
	return _content_height


func signature() -> String:
	if probe == null:
		return ""
	return "%d|%d|%d|%d|%d|%.2f|%.1f|%.3f|%.3f" % [
		probe.population, probe.sick, probe.injured, probe.dead, probe.homeless,
		snappedf(probe.warmth01, 0.02), snappedf(probe.food_days, 0.1),
		snappedf(probe.hope, 0.01), snappedf(probe.discontent, 0.01),
	]


func layout() -> void:
	clear_hot()
	var y: float = 112.0
	if probe.has_population:
		add_hot(Rect2(14.0, 40.0, 150.0, 40.0), "Citizens",
			"Everyone alive in the city right now. They work your buildings, and "
			+ "they need warmth and food to keep doing it.")
		add_hot(Rect2(14.0, 86.0, size.x - 28.0, 20.0), "Condition",
			"Cold citizens fall sick, sick citizens stop working, and citizens "
			+ "who stay sick in the cold die. The dead never come back.")
		add_hot(Rect2(14.0, y - 16.0, size.x - 28.0, 22.0), "Body warmth",
			"How warm the average citizen actually is, not how warm the air is. "
			+ "Below 40% they start falling ill; below 12% the cold begins taking "
			+ "their health. Radiators, insulated homes and shorter walks raise it.")
		y += 28.0
		if probe.food_days >= 0.0:
			add_hot(Rect2(14.0, y - 16.0, size.x - 28.0, 22.0), "Food",
				"Days the city can keep eating at this population and this ration. "
				+ "Kitchens turn stores into meals; a long haul to the table wastes "
				+ "both.")
			y += 28.0
	if probe.has_society:
		add_hot(Rect2(14.0, y - 16.0, size.x - 28.0, 22.0), "Hope",
			"Whether the city believes it will survive the winter. It rises when "
			+ "people are warm, fed and see the place growing, and falls with every "
			+ "death and every cold night. " + _reason_line())
		y += 28.0
		add_hot(Rect2(14.0, y - 16.0, size.x - 28.0, 22.0), "Discontent",
			"How angry they are with you. Harsh laws and hard shifts raise it. "
			+ "Let it fill and the city stops doing what you tell it.")
	_content_height = y + 12.0
	custom_minimum_size = Vector2(PANEL_WIDTH, _content_height)
	size = custom_minimum_size


## [P06] already writes a sentence for every pressure on the meters. Showing its
## words instead of inventing new ones keeps the HUD and the sim telling the
## player the same story.
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
	if probe.freezing > 0 or (probe.has_society and probe.hope < 0.2):
		sev = S.Sev.DANGER
	elif probe.sick > 0 or (probe.has_society and probe.discontent > 0.6):
		sev = S.Sev.WARN
	draw_frame("The people", sev, 0.26)

	if probe.has_population:
		var x: float = 14.0
		x += style.draw_text(self, Vector2(x, 72.0), LcnHudFormat.count(probe.population),
			style.fs(30), style.ink()) + 8.0
		style.draw_text(self, Vector2(x, 72.0), "alive", style.fs(13), style.ink_faint())
		var dir: int = probe.trend.direction(&"__population", 0.4)
		if dir != 0:
			style.draw_arrow(self, Vector2(x + style.text_width("alive", style.fs(13)) + 12.0,
				66.0), dir, 9.0,
				style.health_colour(1.0) if dir > 0 else style.sev_colour(S.Sev.DANGER))

		var parts: Array[Dictionary] = []
		if probe.freezing > 0:
			parts.append({"t": "%d freezing" % probe.freezing, "c": style.sev_colour(S.Sev.DANGER)})
		elif probe.city_is_freezing():
			parts.append({"t": "freezing", "c": style.sev_colour(S.Sev.DANGER)})
		elif probe.city_is_cold():
			parts.append({"t": "cold", "c": style.sev_colour(S.Sev.WARN)})
		if probe.injured > 0:
			parts.append({"t": "%d hurt" % probe.injured, "c": style.sev_colour(S.Sev.WARN)})
		if probe.sick > 0:
			parts.append({"t": "%d sick" % probe.sick, "c": style.sev_colour(S.Sev.WARN)})
		if probe.hungry > 0:
			parts.append({"t": "%d hungry" % probe.hungry, "c": style.sev_colour(S.Sev.WARN)})
		if probe.homeless > 0:
			parts.append({"t": "%d unhoused" % probe.homeless, "c": style.ink_dim()})
		if probe.dead > 0:
			parts.append({"t": "%d dead" % probe.dead, "c": LcnHudStyle.P.SNOW_SHADOW})
		if parts.is_empty():
			parts.append({"t": "warm, fed and working", "c": style.health_colour(1.0)})
		var px: float = 14.0
		for i: int in parts.size():
			var p: Dictionary = parts[i]
			px += style.draw_text(self, Vector2(px, 102.0), String(p["t"]),
				style.fs(12), p["c"] as Color)
			if i < parts.size() - 1:
				px += style.draw_text(self, Vector2(px + 5.0, 102.0), "·",
					style.fs(12), style.ink_faint()) + 10.0

	var y: float = 112.0
	if probe.has_population:
		var warm_col: Color = style.health_colour(
			clampf(inverse_lerp(0.15, 0.55, probe.warmth01), 0.0, 1.0))
		_meter(y, "body warmth", probe.warmth01, warm_col)
		y += 28.0
		if probe.food_days >= 0.0:
			_food_row(y)
			y += 28.0
	if probe.has_society:
		_meter(y, "hope", probe.hope, style.health_colour(probe.hope))
		y += 28.0
		_meter(y, "discontent", probe.discontent,
			style.sev_colour(S.Sev.DANGER) if probe.discontent > 0.6
			else style.sev_colour(S.Sev.WARN))
	draw_marks()


## Days of food, which is a countdown wearing a number's clothes.
func _food_row(baseline: float) -> void:
	style.draw_caps(self, Vector2(14.0, baseline), "food", style.fs(9),
		style.ink_faint(), 1.8)
	var days: float = probe.food_days
	var col: Color = style.health_colour(clampf(days / 3.0, 0.0, 1.0))
	var text: String = "%.1f days" % days if days < 100.0 else "plenty"
	if days < 0.05:
		text = "none left"
	style.draw_text(self, Vector2(14.0 + 78.0, baseline), text, style.fs(13), col)


func _meter(baseline: float, label: String, value01: float, colour: Color) -> void:
	style.draw_caps(self, Vector2(14.0, baseline), label, style.fs(9),
		style.ink_faint(), 1.8)
	var left: float = 14.0 + 78.0
	style.draw_segments(self, Rect2(left, baseline - 9.0, size.x - left - 58.0, 8.0),
		value01, 10, colour)
	style.draw_text_right(self, size.x - 14.0, baseline, LcnHudFormat.percent(value01),
		style.fs(12), style.ink_dim())
