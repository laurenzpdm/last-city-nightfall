class_name LcnHudResources
extends LcnHudWidget
## Stocks, and — the part that matters — which way they are going. [P17]
##
## A number on its own ("stone 1,400") tells a player nothing they can use. The
## same number with a slope ("1,400, falling 90 a minute, empty in fifteen")
## tells them whether to go mining now or keep building. So the arrow is the
## loudest thing in a chip, the rate sits next to it, and a stock heading for
## zero inside three minutes turns amber whatever its absolute size.
##
## Trends come from LcnHudTrend, which fits a line through the last minute of
## in-world samples rather than differencing the last two — one delivery landing
## must not read as a boom.

const CHIP := Vector2(126.0, 46.0)
const PAD: float = 13.0
const MAX_CHIPS: int = 9
const ALWAYS_SHOW: int = 5

var _shown: Array[StringName] = []
var _top: float = 34.0
var _height: float = 96.0


func should_show() -> bool:
	return probe != null and probe.has_build and not probe.stock_order.is_empty()


func signature() -> String:
	if probe == null:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for id: StringName in _pick():
		parts.append("%s:%d:%d:%d" % [id, probe.stock.get(id, 0),
			probe.trend.direction(id, _deadzone(id)),
			int(roundf(probe.trend.sustained_per_minute(id)))])
	return "|".join(parts)


## Priority items always have a slot, so "we are out of coal" is visible as a
## zero rather than as an absence. Everything else earns its place by existing.
func _pick() -> Array[StringName]:
	var out: Array[StringName] = []
	var i: int = 0
	for id: StringName in probe.stock_order:
		var amount: int = probe.stock.get(id, 0)
		if amount > 0 or i < ALWAYS_SHOW:
			out.append(id)
		i += 1
		if out.size() >= MAX_CHIPS:
			break
	return out


func layout() -> void:
	_shown = _pick()
	_top = content_top() - float(style.fs(9)) - 2.0
	_height = _top + CHIP.y + 12.0
	var w: float = PAD * 2.0 + float(_shown.size()) * CHIP.x
	custom_minimum_size = Vector2(w, _height)
	size = custom_minimum_size
	clear_hot()
	for i: int in _shown.size():
		var id: StringName = _shown[i]
		add_hot(_chip_rect(i), LcnHudFormat.item_title(id), _explain(id))


func _chip_rect(i: int) -> Rect2:
	return Rect2(PAD + float(i) * CHIP.x, _top, CHIP.x - 7.0, CHIP.y)


## The tooltip is where the distinction between "what I measured" and "what I am
## willing to predict" gets spelled out, because that is exactly the distinction
## the old HUD collapsed. The window length is named so the player can judge the
## claim rather than take it on trust.
func _explain(id: StringName) -> String:
	var amount: int = probe.stock.get(id, 0)
	var per_minute: float = probe.trend.per_minute(id)
	var window: String = LcnHudFormat.clock(probe.trend.span_seconds(id))
	var body: String = "%s in store." % LcnHudFormat.count(amount)
	if probe.trend.samples(id) < 3:
		body += " Not watched for long enough to say which way it is going yet."
	elif absf(per_minute) < _deadzone(id):
		body += " Holding steady over the last %s." % window
	elif per_minute > 0.0:
		body += " Up %s over the last %s." % [
			LcnHudFormat.amount(per_minute * probe.trend.span_seconds(id) / 60.0), window]
	else:
		body += " Down %s over the last %s." % [
			LcnHudFormat.amount(-per_minute * probe.trend.span_seconds(id) / 60.0), window]
		var empty: float = probe.trend.seconds_to_zero(id)
		if empty >= 0.0:
			body += " It has been draining steadily at %s a minute, so at that rate " \
				% LcnHudFormat.amount(probe.trend.sustained_per_minute(id))
			body += "it is empty in %s." % LcnHudFormat.clock(empty)
		else:
			body += " That was spent rather than drained, so there is no countdown "
			body += "on it."
	return body + " Construction takes from this store; so does anything that "\
		+ "burns it."


func _deadzone(id: StringName) -> float:
	return maxf(1.0, float(probe.stock.get(id, 0)) * 0.01)


func _draw() -> void:
	if probe == null or style == null:
		return
	var worst: int = S.Sev.CALM
	for id: StringName in _shown:
		if probe.trend.seconds_to_zero(id) >= 0.0 \
				and probe.trend.seconds_to_zero(id) < 180.0:
			worst = maxi(worst, S.Sev.WARN)
	draw_frame("Stores", worst, 0.22)
	for i: int in _shown.size():
		_draw_chip(_shown[i], _chip_rect(i))
		if i > 0:
			var scribe: Color = LcnHudStyle.P.COLD_RIM
			var x: float = PAD + float(i) * CHIP.x - 5.0
			draw_line(Vector2(x, _top + 6.0), Vector2(x, _top + CHIP.y - 6.0),
				Color(scribe.r, scribe.g, scribe.b, 0.45), 1.0)
	draw_marks()


func _draw_chip(id: StringName, rect: Rect2) -> void:
	var amount: int = probe.stock.get(id, 0)
	var dir: int = probe.trend.direction(id, _deadzone(id))
	var empty_in: float = probe.trend.seconds_to_zero(id)
	var alarmed: bool = amount == 0 or (empty_in >= 0.0 and empty_in < 180.0)

	_draw_glyph(id, Vector2(rect.position.x + 9.0, rect.position.y + 11.0), alarmed)
	style.draw_caps(self, Vector2(rect.position.x + 22.0, rect.position.y + 14.0),
		LcnHudFormat.item_title(id), style.fs(9),
		style.sev_colour(S.Sev.WARN) if alarmed else style.ink_faint(), 1.0)

	var value_col: Color = style.ink()
	if amount == 0:
		value_col = style.sev_colour(S.Sev.DANGER)
	elif alarmed:
		value_col = style.sev_colour(S.Sev.WARN)
	var x: float = rect.position.x + 8.0
	var baseline: float = rect.position.y + 20.0 + float(style.fs(17))
	x += style.draw_text(self, Vector2(x, baseline), LcnHudFormat.stock(amount),
		style.fs(17), value_col) + 10.0

	var arrow_col: Color = style.ink_faint()
	if dir > 0:
		arrow_col = style.health_colour(1.0)
	elif dir < 0:
		arrow_col = style.sev_colour(S.Sev.WARN if not alarmed else S.Sev.DANGER)
	style.draw_arrow(self, Vector2(x + 4.0, baseline - 5.0), dir, 8.0, arrow_col)
	# The NUMBER only appears for a rate that survived LcnHudTrend's gates. A
	# one-off spend still tilts the arrow — the stock really did move — but it no
	# longer prints "▼ 1.1k" beside a stock of 495 that is about to sit flat for
	# three minutes. The tooltip carries the measured window either way.
	var sustained: float = probe.trend.sustained_per_minute(id)
	if dir != 0 and absf(sustained) >= 0.05:
		style.draw_text(self, Vector2(x + 13.0, baseline),
			LcnHudFormat.rate(absf(sustained)), style.fs(11), arrow_col)
	elif dir != 0:
		style.draw_text(self, Vector2(x + 13.0, baseline), "—", style.fs(11),
			style.ink_faint())


## A shape per material family, so the rail can be read at a glance without
## reading. Plates are flat bars, ore is a lump, gears are cogs, fuel is a
## chunk with an ember in it.
func _draw_glyph(id: StringName, centre: Vector2, alarmed: bool) -> void:
	var s: String = String(id)
	var col: Color = LcnHudStyle.P.STEEL_LIGHT
	if alarmed:
		col = style.sev_colour(S.Sev.WARN)
	if s.contains("coal") or s.contains("fuel"):
		draw_circle(centre, 5.0, LcnHudStyle.P.ASH)
		draw_circle(centre + Vector2(1.0, -1.0), 2.0,
			LcnHudStyle.P.EMBER if not alarmed else col)
		return
	if s.contains("plate") or s.contains("steel") or s.contains("iron"):
		draw_rect(Rect2(centre - Vector2(5.5, 3.0), Vector2(11.0, 6.0)), col, true)
		draw_line(centre - Vector2(4.0, 1.0), centre + Vector2(4.0, -1.0),
			LcnHudStyle.P.SNOW_SHADOW, 1.0)
		return
	if s.contains("gear") or s.contains("coil") or s.contains("part"):
		draw_arc(centre, 5.0, 0.0, TAU, 16, col, 2.0)
		draw_circle(centre, 1.6, col)
		return
	if s.contains("stone") or s.contains("ore") or s.contains("scrap"):
		var pts := PackedVector2Array([
			centre + Vector2(-5.0, 2.0), centre + Vector2(-2.0, -4.0),
			centre + Vector2(4.0, -3.0), centre + Vector2(5.0, 3.0),
		])
		draw_colored_polygon(pts, col)
		return
	if s.contains("timber") or s.contains("wood"):
		draw_rect(Rect2(centre - Vector2(5.5, 2.5), Vector2(11.0, 5.0)),
			LcnHudStyle.P.RUST if not alarmed else col, true)
		return
	if s.contains("food") or s.contains("ration") or s.contains("grain"):
		draw_circle(centre, 4.5, col)
		draw_line(centre + Vector2(0.0, -4.5), centre + Vector2(0.0, 4.5),
			LcnHudStyle.P.COLD_DEEP, 1.0)
		return
	draw_rect(Rect2(centre - Vector2(4.0, 4.0), Vector2(8.0, 8.0)), col, false, 1.5)
