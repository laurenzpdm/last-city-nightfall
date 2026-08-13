class_name LcnHudWave
extends LcnHudWidget
## What is coming, from where, and how long you have. [P17]
##
## Reads [P08]'s `next_wave_preview()` when it exists and falls back to the Bus
## countdown when it does not, so the panel is honest in both builds. Three facts,
## because three is what a player can act on before it arrives: direction (which
## wall), strength (how much) and time (whether there is time at all).
##
## [P08] REDACTS that preview by how much the player has scouted, and this panel
## respects it: with `known` false the dial shows a question mark and the line
## reads "no word from the plain yet". Inventing a direction the game deliberately
## withheld would be worse than admitting there isn't one.
##
## Clicking the dial puts the camera where they will come from.

const WIDTH: float = 322.0
const DIAL_RADIUS: float = 33.0

var _seconds: float = -1.0
var _urgent: float = 0.0
var _y_time: float = 0.0
var _y_where: float = 0.0
var _y_force: float = 0.0
var _height: float = 128.0
var _dial: Vector2 = Vector2.ZERO


func should_show() -> bool:
	return probe != null and (probe.wave_active or probe.wave_seconds >= 0.0)


func desired_height() -> float:
	return _height


func signature() -> String:
	if probe == null:
		return ""
	return "%d|%d|%.2f|%s|%d|%d|%d|%s|%s" % [
		int(probe.wave_seconds), probe.wave_number, snappedf(probe.wave_strength, 0.05),
		LcnHudFormat.compass_short(probe.wave_direction),
		int(probe.wave_active), probe.enemies_alive, int(probe.wave_known),
		probe.wave_phrase, probe.wave_band,
	]


func layout() -> void:
	_seconds = probe.wave_seconds
	_urgent = 0.0
	if _seconds >= 0.0:
		_urgent = clampf(inverse_lerp(120.0, 10.0, _seconds), 0.0, 1.0)
	if probe.wave_active:
		_urgent = 1.0

	_dial = Vector2(15.0 + DIAL_RADIUS + 4.0, content_top() + DIAL_RADIUS + 2.0)
	_y_time = content_top() + float(style.fs(30)) * 0.80
	_y_where = _y_time + 12.0 + float(style.fs(12))
	_y_force = _y_where + 14.0 + float(style.fs(9))
	_height = maxf(_y_force + 14.0, _dial.y + DIAL_RADIUS + 14.0)
	custom_minimum_size = Vector2(WIDTH, _height)
	size = custom_minimum_size

	clear_hot()
	add_hot(Rect2(_dial.x - DIAL_RADIUS - 4.0, _dial.y - DIAL_RADIUS - 4.0,
		DIAL_RADIUS * 2.0 + 8.0, DIAL_RADIUS * 2.0 + 8.0), "Where from",
		("The side of the city they are heading for. Walls, turrets and the heat "
		+ "to run them all need to be on that side before the countdown ends."
		+ ("" if probe.wave_origin == Vector2.ZERO else " Click to look at it."))
		if probe.wave_known else
		"Nothing has been seen yet. Watchtowers, and simply surviving another "
		+ "night, buy you the direction before it arrives.",
		&"focus", probe.wave_origin)
	var right: float = _dial.x + DIAL_RADIUS + 12.0
	add_hot(Rect2(right, content_top() - 4.0, WIDTH - right - 11.0,
		_y_time - content_top() + 12.0), "Time left",
		"How long until they reach the city. A turret with no heat is a wall with "
		+ "a hole in it, so keep the grid ahead of this number.")
	add_hot(Rect2(right, _y_force - float(style.fs(9)) - 8.0, WIDTH - right - 11.0,
		float(style.fs(9)) + 14.0), "Strength",
		"How hard this wave hits compared to the ones before it. It grows with the "
		+ "night, with the era, and with how comfortable your city looks.")


func _draw() -> void:
	if probe == null or style == null:
		return
	var sev: int = S.Sev.WARN
	if _urgent > 0.6:
		sev = S.Sev.CRITICAL if probe.wave_active else S.Sev.DANGER
	draw_frame("Under attack" if probe.wave_active else "Next wave", sev,
		0.24 + 0.4 * _urgent)
	_draw_dial()

	var right_x: float = WIDTH - 15.0
	var col: Color = style.ink()
	if _urgent > 0.35:
		col = style.sev_colour(S.Sev.DANGER)
		if _urgent > 0.8:
			col = col.lerp(style.ink_warm(), style.pulse(5.0) * 0.4)
	if probe.wave_active:
		style.draw_text_right(self, right_x, _y_time,
			"%d in the city" % probe.enemies_alive, style.fs(22), col)
	else:
		style.draw_text_right(self, right_x, _y_time,
			LcnHudFormat.clock(maxf(0.0, _seconds)), style.fs(30), col)
	style.draw_text_right(self, right_x, _y_where, _where_line(), style.fs(12),
		style.ink_faint())

	if probe.wave_band != "":
		style.draw_caps(self, Vector2(_dial.x + DIAL_RADIUS + 12.0, _y_force),
			probe.wave_band, style.fs(9), style.sev_colour(S.Sev.WARN), 1.6)
	if probe.wave_strength > 0.0 and probe.wave_known:
		var strength01: float = clampf(probe.wave_strength, 0.0, 1.0)
		if probe.wave_strength > 1.0:
			strength01 = clampf(probe.wave_strength / 10.0, 0.0, 1.0)
		style.draw_segments(self, Rect2(WIDTH - 129.0, _y_force - 9.0, 114.0, 7.0),
			strength01, 10, style.sev_colour(S.Sev.DANGER))
	draw_marks()


## Exactly as much as [P08] is willing to tell the player, and no more.
func _where_line() -> String:
	if not probe.wave_known:
		return "wave %d · no word yet" % maxi(1, probe.wave_number)
	if probe.wave_phrase != "":
		# [P08] hands out the bare places ("the north and the east"); the
		# preposition is the HUD's job.
		var phrase: String = probe.wave_phrase
		if not phrase.begins_with("from"):
			phrase = "from " + phrase
		return "wave %d %s" % [maxi(1, probe.wave_number), phrase]
	return "wave %d from the %s" % [maxi(1, probe.wave_number),
		LcnHudFormat.compass(probe.wave_direction)]


## A compass with the approach lit. Eight ticks and a wedge; it only redraws
## when the preview changes.
func _draw_dial() -> void:
	var rim: Color = LcnHudStyle.P.COLD_RIM
	draw_arc(_dial, DIAL_RADIUS, 0.0, TAU, 40, Color(rim.r, rim.g, rim.b, 0.85), 1.5)
	draw_arc(_dial, DIAL_RADIUS * 0.62, 0.0, TAU, 32, Color(rim.r, rim.g, rim.b, 0.35), 1.0)
	for i: int in 8:
		var a: float = float(i) * TAU / 8.0
		var d := Vector2(cos(a), sin(a))
		var long: bool = i % 2 == 0
		draw_line(_dial + d * (DIAL_RADIUS - (8.0 if long else 4.0)), _dial + d * DIAL_RADIUS,
			Color(rim.r, rim.g, rim.b, 0.9 if long else 0.5), 1.0)

	var dir: Vector2 = probe.wave_direction
	if not probe.wave_known or dir.length_squared() < 0.0001:
		style.draw_text_centered(self, _dial.x, _dial.y + 6.0, "?", style.fs(17),
			style.ink_faint())
		return
	var n: Vector2 = dir.normalized()
	var base: float = atan2(n.y, n.x)
	var spread: float = 0.42
	var danger: Color = style.sev_colour(S.Sev.DANGER)
	var wedge := PackedVector2Array([_dial])
	for i2: int in 9:
		var a2: float = base - spread + spread * 2.0 * float(i2) / 8.0
		wedge.append(_dial + Vector2(cos(a2), sin(a2)) * (DIAL_RADIUS - 2.0))
	draw_colored_polygon(wedge,
		Color(danger.r, danger.g, danger.b, 0.30 + 0.30 * _urgent * style.pulse(3.6)))
	draw_line(_dial, _dial + n * (DIAL_RADIUS - 2.0), danger, 2.0)
	style.draw_text_centered(self, _dial.x + n.x * (DIAL_RADIUS * 0.42),
		_dial.y + n.y * (DIAL_RADIUS * 0.42) + 4.0,
		LcnHudFormat.compass_short(n), style.fs(11), danger)
