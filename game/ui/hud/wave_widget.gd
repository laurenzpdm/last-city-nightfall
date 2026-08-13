class_name LcnHudWave
extends LcnHudWidget
## What is coming, from where, and how long you have. [P17]
##
## Reads [P08]'s `next_wave_preview()` when it exists and falls back to the
## Bus countdown when it does not, so the panel is honest in both builds. Three
## facts, because three is what a player can act on before it arrives:
## direction (which wall to reinforce), strength (how much) and time (whether
## there is time at all).
##
## Clicking the dial puts the camera where they will come from.

const PANEL := Vector2(322.0, 128.0)
const DIAL_RADIUS: float = 34.0

var _seconds: float = -1.0
var _urgent: float = 0.0


func should_show() -> bool:
	return probe != null and (probe.wave_active or probe.wave_seconds >= 0.0)


func desired_height() -> float:
	return PANEL.y


func signature() -> String:
	if probe == null:
		return ""
	return "%d|%d|%.2f|%s|%d|%d" % [
		int(probe.wave_seconds), probe.wave_number, snappedf(probe.wave_strength, 0.05),
		LcnHudFormat.compass_short(probe.wave_direction),
		int(probe.wave_active), probe.enemies_alive,
	]


func layout() -> void:
	custom_minimum_size = PANEL
	size = PANEL
	_seconds = probe.wave_seconds
	_urgent = 0.0
	if _seconds >= 0.0:
		_urgent = clampf(inverse_lerp(120.0, 10.0, _seconds), 0.0, 1.0)
	if probe.wave_active:
		_urgent = 1.0
	clear_hot()
	var focus: Vector2 = probe.wave_origin
	add_hot(Rect2(14.0, 40.0, DIAL_RADIUS * 2.0 + 12.0, DIAL_RADIUS * 2.0 + 12.0),
		"Where from",
		"The side of the city they are heading for. Walls, turrets and the heat "
		+ "to run them all need to be on that side before the countdown ends."
		+ ("" if focus == Vector2.ZERO else " Click to look at it."),
		&"focus", focus)
	add_hot(Rect2(size.x - 168.0, 44.0, 154.0, 40.0), "Time left",
		"How long until they reach the city. A turret with no heat is a wall with "
		+ "a hole in it, so keep the grid ahead of this number.")
	add_hot(Rect2(size.x - 168.0, 92.0, 154.0, 22.0), "Strength",
		"How hard this wave hits compared to the last ones. It grows with the "
		+ "night, with the era, and with how comfortable your city looks.")


func _draw() -> void:
	if probe == null or style == null:
		return
	var sev: int = S.Sev.WARN
	if _urgent > 0.6:
		sev = S.Sev.CRITICAL if probe.wave_active else S.Sev.DANGER
	draw_frame("Next wave" if not probe.wave_active else "Under attack", sev,
		0.24 + 0.4 * _urgent)
	_draw_dial()

	var right_x: float = size.x - 14.0
	var col: Color = style.ink()
	if _urgent > 0.35:
		col = style.sev_colour(S.Sev.DANGER)
		if _urgent > 0.8:
			col = col.lerp(style.ink_warm(), style.pulse(5.0) * 0.4)
	if probe.wave_active:
		style.draw_text_right(self, right_x, 74.0, "%d in the city" % probe.enemies_alive,
			style.fs(22), col)
	else:
		style.draw_text_right(self, right_x, 74.0, LcnHudFormat.clock(maxf(0.0, _seconds)),
			style.fs(30), col)
	style.draw_text_right(self, right_x, 94.0,
		"wave %d from the %s" % [maxi(1, probe.wave_number),
			LcnHudFormat.compass(probe.wave_direction)],
		style.fs(12), style.ink_faint())

	if probe.wave_strength > 0.0:
		var strength01: float = clampf(probe.wave_strength / 10.0, 0.0, 1.0) \
			if probe.wave_strength > 1.0 else clampf(probe.wave_strength, 0.0, 1.0)
		style.draw_segments(self, Rect2(size.x - 128.0, 104.0, 114.0, 7.0), strength01, 10,
			style.sev_colour(S.Sev.DANGER))
		style.draw_caps(self, Vector2(size.x - 168.0, 111.0), "force", style.fs(9),
			style.ink_faint(), 1.6)
	if probe.wave_note != "":
		style.draw_text(self, Vector2(14.0, size.y - 10.0), probe.wave_note,
			style.fs(11), style.ink_faint())
	draw_marks()


## A compass with the approach lit. The rose is drawn every time because it is
## eight lines and a wedge, and it only redraws when the preview changes.
func _draw_dial() -> void:
	var centre := Vector2(14.0 + DIAL_RADIUS + 6.0, 46.0 + DIAL_RADIUS)
	var rim: Color = LcnHudStyle.P.COLD_RIM
	draw_arc(centre, DIAL_RADIUS, 0.0, TAU, 40, Color(rim.r, rim.g, rim.b, 0.85), 1.5)
	draw_arc(centre, DIAL_RADIUS * 0.62, 0.0, TAU, 32, Color(rim.r, rim.g, rim.b, 0.35), 1.0)
	for i: int in 8:
		var a: float = float(i) * TAU / 8.0
		var d := Vector2(cos(a), sin(a))
		var long: bool = i % 2 == 0
		draw_line(centre + d * (DIAL_RADIUS - (8.0 if long else 4.0)), centre + d * DIAL_RADIUS,
			Color(rim.r, rim.g, rim.b, 0.9 if long else 0.5), 1.0)

	var dir: Vector2 = probe.wave_direction
	if dir.length_squared() < 0.0001:
		style.draw_text_centered(self, centre.x, centre.y + 4.0, "?", style.fs(16),
			style.ink_faint())
		return
	var n: Vector2 = dir.normalized()
	var base: float = atan2(n.y, n.x)
	var spread: float = 0.42
	var danger: Color = style.sev_colour(S.Sev.DANGER)
	var wedge := PackedVector2Array([centre])
	for i2: int in 9:
		var a2: float = base - spread + spread * 2.0 * float(i2) / 8.0
		wedge.append(centre + Vector2(cos(a2), sin(a2)) * (DIAL_RADIUS - 2.0))
	var alpha: float = 0.30 + 0.30 * _urgent * style.pulse(3.6)
	draw_colored_polygon(wedge, Color(danger.r, danger.g, danger.b, alpha))
	draw_line(centre, centre + n * (DIAL_RADIUS - 2.0), danger, 2.0)
	style.draw_text_centered(self, centre.x + n.x * (DIAL_RADIUS + 12.0),
		centre.y + n.y * (DIAL_RADIUS + 12.0) + 4.0,
		LcnHudFormat.compass_short(n), style.fs(11), danger)
