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

const PANEL := Vector2(322.0, 176.0)


func should_show() -> bool:
	return probe != null and (probe.has_population or probe.has_society)


func desired_height() -> float:
	return PANEL.y


func signature() -> String:
	if probe == null:
		return ""
	return "%d|%d|%d|%d|%d|%d|%.3f|%.3f" % [
		probe.population, probe.sick, probe.dead, probe.homeless, probe.freezing,
		probe.hungry, snappedf(probe.hope, 0.01), snappedf(probe.discontent, 0.01),
	]


func layout() -> void:
	custom_minimum_size = PANEL
	size = PANEL
	clear_hot()
	if probe.has_population:
		add_hot(Rect2(14.0, 40.0, 150.0, 40.0), "Citizens",
			"Everyone alive in the city right now. They work your buildings, and "
			+ "they need warmth and food to keep doing it.")
		add_hot(Rect2(14.0, 86.0, size.x - 28.0, 20.0), "Condition",
			"Cold citizens fall sick, sick citizens stop working, and citizens "
			+ "who stay sick in the cold die. The dead never come back.")
	if probe.has_society:
		add_hot(Rect2(14.0, 112.0, size.x - 28.0, 22.0), "Hope",
			"Whether the city believes it will survive the winter. It rises when "
			+ "people are warm, fed and see the place growing, and falls with "
			+ "every death, every cold night and every promise you break.")
		add_hot(Rect2(14.0, 140.0, size.x - 28.0, 22.0), "Discontent",
			"How angry they are with you. Harsh laws and hard shifts raise it. "
			+ "Let it fill and the city stops doing what you tell it.")


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

	if probe.has_society:
		_meter(128.0, "hope", probe.hope, style.health_colour(probe.hope))
		_meter(156.0, "discontent", probe.discontent,
			style.sev_colour(S.Sev.DANGER) if probe.discontent > 0.6
			else style.sev_colour(S.Sev.WARN))
	draw_marks()


func _meter(baseline: float, label: String, value01: float, colour: Color) -> void:
	style.draw_caps(self, Vector2(14.0, baseline), label, style.fs(9),
		style.ink_faint(), 1.8)
	var left: float = 14.0 + 78.0
	style.draw_segments(self, Rect2(left, baseline - 9.0, size.x - left - 58.0, 8.0),
		value01, 10, colour)
	style.draw_text_right(self, size.x - 14.0, baseline, LcnHudFormat.percent(value01),
		style.fs(12), style.ink_dim())
