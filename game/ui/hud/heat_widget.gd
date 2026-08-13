class_name LcnHudHeat
extends LcnHudWidget
## The grid, as a balance sheet you can act on. [P17]
##
## [P02] solves a constrained flow problem every tick and knows, per building,
## exactly how much heat arrived and which tile stopped the rest. None of that
## reached a pixel before this panel. Here it is, in the order a player needs it:
##
##   what arrives  /  what is asked for      — the one ratio that decides the night
##   the hole                                — clickable, jumps to the tile causing it
##   the tank                                — thermal storage, and which way it is going
##   what the cold takes                     — distance loss, the automation lesson
##
## The bar carries a demand marker rather than a second bar, because the question
## is never "how much heat do I make", it is "am I keeping up".

const WIDTH: float = 372.0

var _served: float = 1.0
var _deficit_focus: Vector2 = Vector2.ZERO
var _bar_max: float = 1.0
var _y_ratio: float = 0.0
var _y_bar: float = 0.0
var _y_buffer: float = 0.0
var _y_foot: float = 0.0
var _height: float = 0.0


func should_show() -> bool:
	return probe != null and probe.has_heat


func signature() -> String:
	if probe == null:
		return ""
	return "%d|%d|%d|%d|%d|%d|%d|%d|%d" % [
		int(probe.heat_delivered), int(probe.heat_demand), int(probe.heat_supply),
		int(probe.heat_deficit), int(probe.heat_buffer), int(probe.heat_loss),
		probe.heat_frozen, probe.heat_networks,
		probe.trend.direction(&"__heat_buffer", 1.0),
	]


func layout() -> void:
	_served = 1.0
	if probe.heat_demand > 0.01:
		_served = clampf(probe.heat_delivered / probe.heat_demand, 0.0, 1.0)
	_bar_max = maxf(1.0, maxf(probe.heat_demand, probe.heat_supply))
	_deficit_focus = Vector2.ZERO
	if not probe.short_networks.is_empty():
		_deficit_focus = probe.network_focus(probe.short_networks[0])

	_y_ratio = content_top() + float(style.fs(30)) * 0.78
	_y_bar = _y_ratio + 12.0
	_y_buffer = _y_bar + 12.0 + float(style.fs(15))
	_y_foot = _y_buffer + 14.0 + float(style.fs(12))
	_height = _y_foot + 16.0
	custom_minimum_size = Vector2(WIDTH, _height)
	size = custom_minimum_size

	clear_hot()
	add_hot(Rect2(11.0, content_top() - 6.0, WIDTH - 22.0, _y_bar - content_top() + 16.0),
		"Heat delivered",
		"How much heat per second actually reaches your buildings, against how "
		+ "much they are asking for. The notch on the bar is demand. Raised by "
		+ "generators and fuel; lowered by distance, cold air and pipes too thin "
		+ "for what runs through them.")
	add_hot(Rect2(11.0, _y_buffer - float(style.fs(15)) - 12.0, 176.0,
		float(style.fs(15)) + 16.0), "Thermal buffer",
		"Heat banked in accumulators. It covers a shortfall for a while and then "
		+ "it does not — a falling buffer is the last warning you get before the "
		+ "grid browns out.")
	if probe.heat_deficit > 0.5:
		add_hot(Rect2(WIDTH - 150.0, _y_buffer - float(style.fs(15)) - 8.0, 139.0,
			float(style.fs(15)) + 12.0), "The hole",
			"Heat your city asked for and did not get, after buffers were drained. "
			+ "Buildings on the wrong side of it run slowly, then stop, then freeze. "
			+ "Click to jump to the tile causing the worst of it.",
			&"focus", _deficit_focus)
	add_hot(Rect2(11.0, _y_foot - float(style.fs(12)) - 6.0, 190.0,
		float(style.fs(12)) + 12.0), "Lost to the cold",
		"Heat that leaves the pipes on the way. Every tile of distance costs some; "
		+ "booster pumps reset the loss and insulated line loses less.")
	add_hot(Rect2(WIDTH - 175.0, _y_foot - float(style.fs(12)) - 6.0, 164.0,
		float(style.fs(12)) + 12.0), "Grids and freezing",
		"How many separate heat networks you are running, and how many buildings "
		+ "have already frozen. Separate grids do not share heat — one starving "
		+ "while another idles means they are not connected.")


func _draw() -> void:
	if probe == null or style == null:
		return
	var sev: int = S.Sev.CALM
	if probe.heat_frozen > 0 or _served < 0.75:
		sev = S.Sev.DANGER
	elif probe.heat_deficit > 0.5 or _served < 0.98:
		sev = S.Sev.WARN
	draw_frame("Heat grid", sev, 0.28 + 0.35 * (1.0 - _served))

	# --- the ratio ---------------------------------------------------------
	var x: float = 15.0
	var col: Color = style.ink() if _served > 0.99 else style.sev_colour(
		S.Sev.WARN if _served > 0.75 else S.Sev.DANGER)
	x += style.draw_text(self, Vector2(x, _y_ratio), LcnHudFormat.rate(probe.heat_delivered),
		style.fs(30), col) + 7.0
	x += style.draw_text(self, Vector2(x, _y_ratio),
		"/ %s" % LcnHudFormat.rate(probe.heat_demand), style.fs(17), style.ink_dim()) + 6.0
	style.draw_text(self, Vector2(x, _y_ratio), "heat/s", style.fs(12), style.ink_faint())
	if probe.heat_deficit > 0.5:
		var danger: Color = style.sev_colour(S.Sev.DANGER)
		style.draw_text_right(self, WIDTH - 15.0, _y_ratio,
			"−%s short" % LcnHudFormat.rate(probe.heat_deficit), style.fs(17),
			Color(danger.r, danger.g, danger.b, 0.78 + 0.22 * style.pulse(3.0)))
	elif probe.heat_supply > probe.heat_demand + 0.5:
		style.draw_text_right(self, WIDTH - 15.0, _y_ratio,
			"+%s spare" % LcnHudFormat.rate(probe.heat_supply - probe.heat_demand),
			style.fs(14), style.health_colour(1.0))

	var bar := Rect2(15.0, _y_bar, WIDTH - 30.0, 9.0)
	var fill: Color = LcnHudStyle.P.WARM_EDGE.lerp(LcnHudStyle.P.WARM_CORE,
		clampf(_served, 0.0, 1.0) * 0.6)
	if _served < 0.75:
		fill = style.sev_colour(S.Sev.DANGER)
	style.draw_bar(self, bar, probe.heat_delivered / _bar_max, fill,
		probe.heat_demand / _bar_max)

	# --- the tank ----------------------------------------------------------
	var bx: float = 15.0
	bx += style.draw_caps(self, Vector2(bx, _y_buffer), "buffer", style.fs(9),
		style.ink_faint(), 1.8) + 12.0
	bx += style.draw_text(self, Vector2(bx, _y_buffer), LcnHudFormat.rate(probe.heat_buffer),
		style.fs(15), style.ink()) + 9.0
	var dir: int = probe.trend.direction(&"__heat_buffer", 1.0)
	if dir != 0:
		style.draw_arrow(self, Vector2(bx + 5.0, _y_buffer - 5.0), dir, 8.0,
			style.health_colour(1.0) if dir > 0 else style.sev_colour(S.Sev.WARN))
		bx += 18.0
	if probe.heat_buffer_capacity > 1.0:
		style.draw_segments(self, Rect2(bx, _y_buffer - 10.0,
			maxf(40.0, WIDTH - bx - 100.0), 8.0),
			probe.heat_buffer / probe.heat_buffer_capacity, 8, LcnHudStyle.P.WARM_MID)

	# --- losses and grids --------------------------------------------------
	style.draw_text(self, Vector2(15.0, _y_foot),
		"cold takes %s/s" % LcnHudFormat.rate(probe.heat_loss), style.fs(12),
		style.ink_faint())
	var right: String = "%d grid%s" % [probe.heat_networks,
		"" if probe.heat_networks == 1 else "s"]
	if probe.heat_frozen > 0:
		right += "  ·  %d frozen" % probe.heat_frozen
	style.draw_text_right(self, WIDTH - 15.0, _y_foot, right, style.fs(12),
		style.sev_colour(S.Sev.DANGER) if probe.heat_frozen > 0 else style.ink_faint())
	draw_marks()
