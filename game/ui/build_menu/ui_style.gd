class_name LcnUiStyle
extends RefCounted
## [P18] The visual grammar of every panel in the build UI.
##
## Nothing in this folder types a hex code. Every colour comes from [P13]'s
## LcnPalette so the UI shifts with the art direction instead of drifting away
## from it. The rules, in one paragraph:
##
##   Panels are the cold dark (COLD_DEEP over a translucent scrim), rimmed with
##   a one-pixel COLD_RIM line. Text is SNOW, secondary text SNOW_SHADOW.
##   WARM_EDGE is the only saturated colour and it means "this is the thing you
##   are pointing at". Green/amber/red are reserved for verdicts — affordable,
##   tight, impossible — and never used decoratively. Locked content is drawn at
##   40% and still readable, because a player learns the game by reading what
##   they cannot build yet.

# ---------------------------------------------------------------- surfaces ---
const SCRIM: Color = Color(0.020, 0.031, 0.059, 0.86)
const PANEL: Color = Color(0.049, 0.078, 0.135, 0.965)
const PANEL_DEEP: Color = Color(0.033, 0.055, 0.099, 0.98)
const PANEL_RAISED: Color = Color(0.078, 0.118, 0.196, 1.0)
const ROW_ODD: Color = Color(1.0, 1.0, 1.0, 0.022)
const ROW_HOVER: Color = Color(1.0, 0.541, 0.239, 0.10)
const ROW_ACTIVE: Color = Color(1.0, 0.541, 0.239, 0.20)
const RIM: Color = Color(0.173, 0.255, 0.376, 0.90)
const RIM_SOFT: Color = Color(0.173, 0.255, 0.376, 0.45)
const RIM_HOT: Color = Color(1.0, 0.541, 0.239, 0.95)

# -------------------------------------------------------------------- text ---
const TEXT: Color = Color(0.910, 0.933, 0.969)
const TEXT_BRIGHT: Color = Color(0.976, 0.988, 1.000)
const TEXT_DIM: Color = Color(0.618, 0.688, 0.784)
const TEXT_FAINT: Color = Color(0.420, 0.490, 0.596)
const ACCENT: Color = Color(1.000, 0.541, 0.239)
const ACCENT_SOFT: Color = Color(1.000, 0.690, 0.400)
const GOOD: Color = Color(0.373, 0.784, 0.596)
const WARN: Color = Color(0.949, 0.729, 0.243)
const BAD: Color = Color(0.886, 0.255, 0.227)
const LINK: Color = Color(0.541, 0.749, 0.851)

## Severity of a fact row or a warning. The panels colour by this and nothing else.
enum Tone { NEUTRAL, DIM, GOOD, WARN, BAD, ACCENT, LINK }

# ------------------------------------------------------------------ metrics --
const PAD: float = 12.0
const GAP: float = 6.0
const ROW_H: float = 26.0
const TILE_ROW_H: float = 40.0
const HEADER_H: float = 34.0
const ICON: float = 28.0

const FS_TITLE: int = 20
const FS_HEAD: int = 15
const FS_BODY: int = 14
const FS_SMALL: int = 12
const FS_TINY: int = 11

## Ratio the whole UI is scaled by. Read from Settings, never written.
static func ui_scale() -> float:
	var s: float = 1.0
	var node: Node = Engine.get_main_loop().get("root") as Node
	if node != null:
		var settings: Node = node.get_node_or_null(^"/root/Settings")
		if settings != null:
			s = float(settings.call(&"get_value", "graphics", "ui_scale", 1.0))
	return clampf(s, 0.75, 2.0)


static func tone_color(tone: int) -> Color:
	match tone:
		Tone.DIM: return TEXT_DIM
		Tone.GOOD: return GOOD
		Tone.WARN: return WARN
		Tone.BAD: return BAD
		Tone.ACCENT: return ACCENT
		Tone.LINK: return LINK
	return TEXT


static func tone_name(tone: int) -> String:
	match tone:
		Tone.DIM: return "dim"
		Tone.GOOD: return "good"
		Tone.WARN: return "warn"
		Tone.BAD: return "bad"
		Tone.ACCENT: return "accent"
		Tone.LINK: return "link"
	return "neutral"


## Flat panel background with a hairline rim. `hot` marks the focused panel.
static func panel_box(hot: bool = false, deep: bool = false) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = PANEL_DEEP if deep else PANEL
	b.border_color = RIM_HOT if hot else RIM
	b.set_border_width_all(1)
	b.set_corner_radius_all(3)
	b.content_margin_left = PAD
	b.content_margin_right = PAD
	b.content_margin_top = PAD * 0.6
	b.content_margin_bottom = PAD * 0.6
	b.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
	b.shadow_size = 10
	b.shadow_offset = Vector2(0.0, 4.0)
	return b


static func chip_box(fill: Color, rim: Color) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = fill
	b.border_color = rim
	b.set_border_width_all(1)
	b.set_corner_radius_all(2)
	b.content_margin_left = 7.0
	b.content_margin_right = 7.0
	b.content_margin_top = 2.0
	b.content_margin_bottom = 2.0
	return b


static func flat_box(fill: Color) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = fill
	b.set_corner_radius_all(2)
	return b


## A label with the house typography applied. Every panel builds text through
## this so a font-size change is one edit.
static func label(text: String, size: int = FS_BODY, colour: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", size)
	l.add_theme_color_override(&"font_color", colour)
	l.add_theme_color_override(&"font_shadow_color", Color(0.0, 0.0, 0.0, 0.75))
	l.add_theme_constant_override(&"shadow_offset_x", 0)
	l.add_theme_constant_override(&"shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Colour for a heat/throughput ratio, on [P13]'s shared flow ramp so the UI and
## the world overlays agree about what "nearly full" looks like.
static func load_color(ratio: float) -> Color:
	return LcnPalette.flow_ramp(clampf(ratio, 0.0, 1.0))


## Verdict colour for "have vs need": green covered, amber tight, red short.
static func supply_tone(have: float, need: float) -> int:
	if need <= 0.0:
		return Tone.DIM
	if have >= need:
		return Tone.GOOD if have >= need * 1.25 else Tone.WARN
	return Tone.BAD


## The accent colour a building is drawn with everywhere: the palette icon, the
## blueprint thumbnail and [P13]'s ghost all read this one field.
static func building_color(def: Resource) -> Color:
	if def == null:
		return LcnPalette.STEEL_LIGHT
	var raw: Variant = def.get(&"tint")
	if typeof(raw) == TYPE_COLOR:
		return raw
	return LcnPalette.STEEL_LIGHT


## Deterministic glyph for a building: a footprint-shaped block with a category
## mark inside it. Real art replaces this the day [P13] ships building icons —
## the point is that 60 buildings are all legible from the first minute without
## waiting on 60 sprites.
static func draw_building_glyph(canvas: CanvasItem, rect: Rect2, def: Resource, dim: float = 1.0) -> void:
	var tint: Color = building_color(def)
	var category: StringName = &"infrastructure"
	var size := Vector2i.ONE
	var tags: Array = []
	if def != null:
		category = LcnUiFormat.as_name(def.get(&"category"))
		var s: Variant = def.get(&"size")
		if typeof(s) == TYPE_VECTOR2I:
			size = s
		var t: Variant = def.get(&"tags")
		if typeof(t) == TYPE_ARRAY:
			tags = t

	var span: int = maxi(1, maxi(size.x, size.y))
	var unit: float = rect.size.x / float(maxi(3, span + 1))
	var body := Rect2(
		rect.position + Vector2(rect.size.x - unit * float(size.x), rect.size.y - unit * float(size.y)) * 0.5,
		Vector2(unit * float(size.x), unit * float(size.y)))

	canvas.draw_rect(body, Color(tint.r, tint.g, tint.b, 0.28 * dim), true)
	canvas.draw_rect(body, Color(tint.r, tint.g, tint.b, 0.95 * dim), false, 1.0)

	var c: Vector2 = body.get_center()
	var r: float = minf(body.size.x, body.size.y) * 0.30
	var mark: Color = Color(tint.r, tint.g, tint.b, 0.95 * dim)
	if tags.has(&"heat_source") or category == &"power":
		canvas.draw_circle(c, r, Color(1.0, 0.541, 0.239, 0.85 * dim))
	elif tags.has(&"conduit") or category == &"heat":
		canvas.draw_line(Vector2(body.position.x + 2.0, c.y), Vector2(body.end.x - 2.0, c.y), mark, 2.0)
	elif category == &"extraction":
		canvas.draw_line(c + Vector2(-r, -r), c + Vector2(r, r), mark, 2.0)
		canvas.draw_line(c + Vector2(r, -r), c + Vector2(-r, r), mark, 2.0)
	elif category == &"defense":
		canvas.draw_line(c + Vector2(0.0, r), c + Vector2(0.0, -r * 1.4), mark, 2.0)
		canvas.draw_circle(c, r * 0.45, mark)
	elif category == &"housing":
		canvas.draw_line(c + Vector2(-r, r * 0.4), c + Vector2(0.0, -r), mark, 2.0)
		canvas.draw_line(c + Vector2(0.0, -r), c + Vector2(r, r * 0.4), mark, 2.0)
	elif category == &"storage":
		canvas.draw_rect(Rect2(c - Vector2(r, r) * 0.8, Vector2(r, r) * 1.6), mark, false, 1.5)
	elif category == &"production":
		canvas.draw_arc(c, r, 0.0, TAU, 12, mark, 1.5)
		canvas.draw_circle(c, r * 0.3, mark)
	else:
		canvas.draw_rect(Rect2(c - Vector2(r, r) * 0.55, Vector2(r, r) * 1.1), mark, false, 1.5)
