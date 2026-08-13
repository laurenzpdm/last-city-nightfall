class_name LcnHudClock
extends LcnHudWidget
## The day arc and the one number that matters. [P17]
##
## Everything else on screen is a resource. This is a deadline. The city has a
## finite amount of daylight to get ready in, and the single most prominent
## number in the whole interface is how much of it is left — set in type twice
## the size of anything else, on an arc that shows at a glance where in the day
## you are and how much of it is night.
##
## The arc is not decoration: the cold segment is the real night length from
## [P09], the marker sits at the real day progress, and when the countdown drops
## under a minute the number itself starts to burn.

const PANEL := Vector2(500.0, 196.0)

const ARC_RADIUS: float = 200.0
const ARC_CENTRE_Y: float = 250.0
const ARC_FROM: float = 235.0
const ARC_TO: float = 305.0

var _countdown: String = "—"
var _label: String = ""
var _sub: String = ""
var _urgent: float = 0.0


func should_show() -> bool:
	return probe != null and probe.has_climate


func desired_height() -> float:
	return PANEL.y


func signature() -> String:
	if probe == null:
		return ""
	var seconds: float = probe.countdown_seconds()
	return "%d|%d|%s|%d|%s|%d|%.2f" % [
		int(seconds), probe.day, probe.phase, int(roundf(probe.ambient_c)),
		probe.weather_label, int(_speed_state()), snappedf(probe.day_progress, 0.002),
	]


func layout() -> void:
	custom_minimum_size = PANEL
	size = PANEL
	var seconds: float = probe.countdown_seconds()
	_countdown = LcnHudFormat.clock(seconds) if seconds >= 0.0 else "—:—"
	_label = probe.countdown_label()
	_sub = "%s · %s · %s" % [probe.phase_label,
		LcnHudFormat.temperature(probe.ambient_c), probe.weather_label]
	_urgent = 0.0
	if not probe.is_night and seconds >= 0.0:
		_urgent = clampf(inverse_lerp(120.0, 15.0, seconds), 0.0, 1.0)

	clear_hot()
	var centre_x: float = size.x * 0.5
	add_hot(Rect2(centre_x - 130.0, 36.0, 260.0, 58.0), "The day",
		"One day is %s long, and %s of that is night. The marker is where you "
		% [LcnHudFormat.clock(_day_length()), LcnHudFormat.clock(_night_length())]
		+ "are now; the cold half of the arc is the part you have to survive.")
	add_hot(Rect2(centre_x - 120.0, 96.0, 240.0, 74.0), _label.to_lower(),
		"Everything gets harder after dark: it is colder, so every building "
		+ "burns more heat to stay alive, and whatever is out there comes in. "
		+ "Build for the night while it is still light.")
	add_hot(Rect2(14.0, 172.0, size.x - 28.0, 22.0), "Outside",
		"Air temperature, and the weather driving it. Cold air raises what every "
		+ "building has to draw from the grid just to keep itself warm.")


func _draw() -> void:
	if probe == null or style == null:
		return
	var sev: int = S.Sev.CALM
	if _urgent > 0.66:
		sev = S.Sev.DANGER
	elif _urgent > 0.25 or probe.is_night:
		sev = S.Sev.WARN
	draw_frame("", sev, 0.30 + 0.4 * _urgent)

	_draw_arc()
	_draw_speed_chip()

	var centre_x: float = size.x * 0.5
	var warm: Color = style.ink_warm()
	var caps_col: Color = style.ink_faint()
	if _urgent > 0.05:
		caps_col = style.sev_colour(S.Sev.WARN if _urgent < 0.66 else S.Sev.DANGER)
	style.draw_caps(self, Vector2(centre_x - style.caps_width(_label, style.fs(11), 3.0) * 0.5,
		106.0), _label, style.fs(11), caps_col, 3.0)

	var number_col: Color = style.ink()
	if probe.is_night:
		number_col = LcnHudStyle.P.ICE_BLUE
	elif _urgent > 0.05:
		var hot_col: Color = style.sev_colour(S.Sev.DANGER if _urgent > 0.66 else S.Sev.WARN)
		number_col = number_col.lerp(hot_col, _urgent)
		if _urgent > 0.66:
			number_col = number_col.lerp(warm, style.pulse(5.0) * 0.5)
	style.draw_text_centered(self, centre_x, 162.0, _countdown, style.fs(46), number_col)

	# Day number rides in the corner like a stamped plate serial.
	style.draw_caps(self, Vector2(18.0, 30.0), "Day %d" % probe.day, style.fs(12),
		style.ink_dim(), 2.4)
	if probe.era_title != "":
		style.draw_caps(self, Vector2(18.0, 46.0), probe.era_title, style.fs(9),
			style.ink_faint(), 1.6)

	var temp_col: Color = LcnHudStyle.P.ICE_BLUE if probe.ambient_c < -25.0 else style.ink_dim()
	style.draw_text_centered(self, centre_x, 186.0, _sub, style.fs(13), temp_col)
	draw_marks()


## The arc: steel for daylight, deep cold for night, a marker for now.
func _draw_arc() -> void:
	var centre := Vector2(size.x * 0.5, ARC_CENTRE_Y)
	var a0: float = deg_to_rad(ARC_FROM)
	var a1: float = deg_to_rad(ARC_TO)
	var night_at: float = clampf(probe.night_start_fraction, 0.05, 0.98)
	var split: float = lerp(a0, a1, night_at)

	var groove: Color = LcnHudStyle.P.COLD_ABYSS
	draw_arc(centre, ARC_RADIUS, a0, a1, 96, Color(groove.r, groove.g, groove.b, 0.8), 9.0, true)
	var day_col: Color = LcnHudStyle.P.STEEL
	draw_arc(centre, ARC_RADIUS, a0, split, 72, Color(day_col.r, day_col.g, day_col.b, 0.95),
		5.0, true)
	var night_col: Color = LcnHudStyle.P.COLD_HIGH
	draw_arc(centre, ARC_RADIUS, split, a1, 48, Color(night_col.r, night_col.g, night_col.b, 1.0),
		7.0, true)
	# The lip where day tips into night — the moment the whole game is about.
	var lip: Vector2 = centre + Vector2(cos(split), sin(split)) * ARC_RADIUS
	var edge: Color = LcnHudStyle.P.ICE_BLUE
	draw_line(lip + Vector2(cos(split), sin(split)) * -9.0,
		lip + Vector2(cos(split), sin(split)) * 9.0,
		Color(edge.r, edge.g, edge.b, 0.9), 2.0)

	var now: float = lerp(a0, a1, clampf(probe.day_progress, 0.0, 1.0))
	var marker: Vector2 = centre + Vector2(cos(now), sin(now)) * ARC_RADIUS
	if probe.is_night:
		var moon: Color = LcnHudStyle.P.SNOW_MID
		draw_circle(marker, 7.0, Color(moon.r, moon.g, moon.b, 0.25))
		draw_circle(marker, 4.0, moon)
	else:
		var sun: Color = LcnHudStyle.P.WARM_CORE
		var glow: float = 0.35 + 0.25 * probe.light_level
		draw_circle(marker, 13.0, Color(sun.r, sun.g, sun.b, 0.10 * glow))
		draw_circle(marker, 8.0, Color(sun.r, sun.g, sun.b, 0.22 * glow))
		draw_circle(marker, 4.5, LcnHudStyle.P.WARM_EDGE.lerp(sun, probe.light_level))


## Pause and fast-forward, because a player who cannot see that time is stopped
## will believe the game is broken.
func _draw_speed_chip() -> void:
	var state: int = _speed_state()
	var text: String = ""
	var col: Color = style.ink_faint()
	match state:
		0:
			text = "paused"
			col = style.sev_colour(S.Sev.WARN)
		2:
			text = "fast ×2"
		3:
			text = "fast ×3"
	if text == "":
		return
	var w: float = style.caps_width(text, style.fs(10), 2.0)
	style.draw_caps(self, Vector2(size.x - 18.0 - w, 30.0), text, style.fs(10), col, 2.0)


func _speed_state() -> int:
	var clock: Node = _clock()
	if clock == null:
		return 1
	if not bool(clock.get("running")) or float(clock.get("speed")) <= 0.0:
		return 0
	return int(roundf(float(clock.get("speed"))))


func _day_length() -> float:
	if probe.night_start_fraction <= 0.0:
		return 0.0
	return _night_length() / maxf(0.001, 1.0 - probe.night_start_fraction)


func _night_length() -> float:
	var seconds: float = probe.seconds_to_dawn if probe.is_night else 0.0
	if seconds > 0.0 and probe.day_progress > probe.night_start_fraction:
		var done: float = (probe.day_progress - probe.night_start_fraction) \
			/ maxf(0.001, 1.0 - probe.night_start_fraction)
		return seconds / maxf(0.001, 1.0 - done)
	# Daytime: derive it from how much daylight is left and where we are in it.
	if probe.seconds_to_night > 0.0 and probe.day_progress < probe.night_start_fraction:
		var left: float = 1.0 - probe.day_progress / maxf(0.001, probe.night_start_fraction)
		var whole: float = probe.seconds_to_night / maxf(0.001, left)
		return whole / maxf(0.001, probe.night_start_fraction) \
			* (1.0 - probe.night_start_fraction)
	return 0.0


func _clock() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath("SimClock"))
