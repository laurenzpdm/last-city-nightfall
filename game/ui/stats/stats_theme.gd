class_name LcnStatsTheme
extends RefCounted
## The look of the statistics screens, and the number formatting they share. [P20]
##
## Deliberately self-contained: it takes its colours from [P13]'s palette, which
## is data, and from nothing else. Reaching into [P17]'s HUD style would have
## given the same look for free and would also have meant that a change to the
## alert rim redrew every graph in the game.
##
## The rules the screens are built on:
##   * the chart is the brightest thing on the panel — chrome sits at 40 % ink,
##     axis labels at 60 %, the curves at 100 %;
##   * nights are shaded, never outlined, so the eye reads the shape of a run
##     before it reads a single number;
##   * every colour is paired with a position in a sorted legend, so a
##     colourblind player reads the same table in the same order.

const P := preload("res://game/view/render/palette.gd")

# --- surfaces ----------------------------------------------------------------
const SCRIM: Color = Color(0.012, 0.020, 0.039, 0.90)
const PANEL: Color = Color(0.035, 0.055, 0.098, 0.985)
const PANEL_HEAD: Color = Color(0.055, 0.082, 0.141, 1.0)
const PLOT_BG: Color = Color(0.024, 0.039, 0.071, 1.0)
const ROW_ODD: Color = Color(1.0, 1.0, 1.0, 0.026)
const ROW_HOVER: Color = Color(1.0, 0.541, 0.239, 0.10)
const ROW_SELECTED: Color = Color(1.0, 0.541, 0.239, 0.18)
const RIM: Color = Color(0.173, 0.255, 0.376, 0.85)
const RIM_SOFT: Color = Color(0.173, 0.255, 0.376, 0.38)
const GRID: Color = Color(0.353, 0.443, 0.573, 0.16)
const GRID_ZERO: Color = Color(0.353, 0.443, 0.573, 0.42)
const NIGHT_BAND: Color = Color(0.055, 0.086, 0.169, 0.62)
const NIGHT_EDGE: Color = Color(0.173, 0.255, 0.376, 0.55)

# --- ink ---------------------------------------------------------------------
const TEXT: Color = Color(0.910, 0.933, 0.969)
const TEXT_BRIGHT: Color = Color(0.976, 0.988, 1.000)
const TEXT_DIM: Color = Color(0.618, 0.688, 0.784)
const TEXT_FAINT: Color = Color(0.420, 0.490, 0.596)
const ACCENT: Color = Color(1.000, 0.541, 0.239)

# --- metrics -----------------------------------------------------------------
const PAD: float = 16.0
const GAP: float = 8.0
const ROW_H: float = 24.0
const HEAD_H: float = 44.0
const TAB_H: float = 32.0
const AXIS_L: float = 62.0
const AXIS_B: float = 22.0
const AXIS_T: float = 14.0

const FS_TITLE: int = 21
const FS_HEAD: int = 15
const FS_BODY: int = 13
const FS_SMALL: int = 12
const FS_TINY: int = 10

var font: Font = null


func _init() -> void:
	font = ThemeDB.fallback_font


func fs(base: int) -> int:
	return maxi(8, int(roundf(float(base) * _font_scale())))


func text_width(s: String, size: int) -> float:
	if font == null:
		return float(s.length()) * float(size) * 0.55
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x


## Left-baseline draw. Returns the width used, so callers can lay out beside it.
func text(ci: CanvasItem, pos: Vector2, s: String, size: int, colour: Color) -> float:
	if font == null or s == "":
		return 0.0
	ci.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, colour)
	return text_width(s, size)


func text_right(ci: CanvasItem, right_x: float, baseline: float, s: String,
		size: int, colour: Color) -> float:
	var w: float = text_width(s, size)
	text(ci, Vector2(right_x - w, baseline), s, size, colour)
	return w


func text_centre(ci: CanvasItem, centre_x: float, baseline: float, s: String,
		size: int, colour: Color) -> float:
	var w: float = text_width(s, size)
	text(ci, Vector2(centre_x - w * 0.5, baseline), s, size, colour)
	return w


## Letter-spaced small caps: the stencil on a machine panel. Section headings
## are drawn this way so they read as chrome rather than as data.
func caps(ci: CanvasItem, pos: Vector2, s: String, size: int, colour: Color,
		tracking: float = 1.6) -> float:
	if font == null or s == "":
		return 0.0
	var up: String = s.to_upper()
	var x: float = pos.x
	for i: int in up.length():
		ci.draw_string(font, Vector2(x, pos.y), up[i], HORIZONTAL_ALIGNMENT_LEFT,
			-1.0, size, colour)
		x += text_width(up[i], size) + tracking
	return maxf(0.0, x - pos.x - tracking)


func caps_width(s: String, size: int, tracking: float = 1.6) -> float:
	var up: String = s.to_upper()
	var w: float = 0.0
	for i: int in up.length():
		w += text_width(up[i], size) + tracking
	return maxf(0.0, w - tracking)


# ==================================================================  shapes ==

## The chamfered plate every panel in this part sits on.
func plate(ci: CanvasItem, rect: Rect2, fill: Color = PANEL, rim: Color = RIM) -> void:
	if rect.size.x < 4.0 or rect.size.y < 4.0:
		return
	var c: float = minf(8.0, minf(rect.size.x, rect.size.y) * 0.5)
	var x0: float = rect.position.x
	var y0: float = rect.position.y
	var x1: float = x0 + rect.size.x
	var y1: float = y0 + rect.size.y
	var pts := PackedVector2Array([
		Vector2(x0 + c, y0), Vector2(x1 - c, y0), Vector2(x1, y0 + c),
		Vector2(x1, y1 - c), Vector2(x1 - c, y1), Vector2(x0 + c, y1),
		Vector2(x0, y1 - c), Vector2(x0, y0 + c),
	])
	# A shallow top-to-bottom gradient, so a tall panel does not read as a slab.
	var cols := PackedColorArray()
	for pt: Vector2 in pts:
		var f: float = clampf((pt.y - y0) / maxf(1.0, rect.size.y), 0.0, 1.0)
		cols.append(fill.lerp(fill.darkened(0.30), f))
	ci.draw_polygon(pts, cols)
	var closed: PackedVector2Array = pts.duplicate()
	closed.append(pts[0])
	ci.draw_polyline(closed, rim, 1.0)


## A soft glow line: a wide faint pass under a crisp one. Two draw calls buy a
## curve that reads at a glance on a dark plate without a shader.
func glow_line(ci: CanvasItem, points: PackedVector2Array, colour: Color,
		width: float = 2.0) -> void:
	if points.size() < 2:
		return
	ci.draw_polyline(points, Color(colour.r, colour.g, colour.b, 0.18), width * 3.0)
	ci.draw_polyline(points, colour, width)


## Dashed vertical, for annotations and the hover crosshair.
func dashed_v(ci: CanvasItem, x: float, y0: float, y1: float, colour: Color,
		dash: float = 4.0, width: float = 1.0) -> void:
	var y: float = y0
	while y < y1:
		var b: float = minf(y + dash, y1)
		ci.draw_line(Vector2(x, y), Vector2(x, b), colour, width)
		y = b + dash


## Small pill behind a caption, so a label over a curve is still readable.
func pill(ci: CanvasItem, rect: Rect2, fill: Color, rim: Color) -> void:
	ci.draw_rect(rect, fill, true)
	ci.draw_rect(rect, rim, false, 1.0)


## The swatch beside a legend entry: a filled square with a lit top edge, which
## reads as a sample of the line rather than as a bullet.
func swatch(ci: CanvasItem, rect: Rect2, colour: Color) -> void:
	ci.draw_rect(rect, Color(colour.r, colour.g, colour.b, 0.35), true)
	ci.draw_rect(Rect2(rect.position, Vector2(rect.size.x, 2.0)), colour, true)
	ci.draw_rect(rect, Color(colour.r, colour.g, colour.b, 0.85), false, 1.0)


# ==================================================================  numbers ==

## Compact, human number. 1 234 567 -> "1.23 M". Never scientific notation and
## never more than four significant figures, because a chart axis with eight
## digits on it is a chart nobody reads.
static func compact(v: float) -> String:
	var a: float = absf(v)
	var sign_s: String = "-" if v < 0.0 else ""
	if a < 0.0005:
		return "0"
	if a < 1.0:
		return "%s%.2f" % [sign_s, a]
	if a < 10.0:
		return "%s%.1f" % [sign_s, a]
	if a < 1000.0:
		return "%s%.0f" % [sign_s, a]
	if a < 1000000.0:
		return "%s%.1f k" % [sign_s, a / 1000.0]
	if a < 1000000000.0:
		return "%s%.2f M" % [sign_s, a / 1000000.0]
	return "%s%.2f G" % [sign_s, a / 1000000000.0]


## An axis tick label. Integers stay integers; a 0.25 step keeps its decimals.
static func axis_label(v: float, step: float) -> String:
	if step >= 1.0:
		return compact(v)
	if step >= 0.1:
		return "%.1f" % v
	return "%.2f" % v


## Simulation ticks as a clock a player recognises. 20 ticks is one second.
static func ticks_as_clock(ticks: int) -> String:
	var total: int = int(float(maxi(0, ticks)) * 0.05)
	var h: int = total / 3600
	var m: int = (total % 3600) / 60
	var s: int = total % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s]
	return "%d:%02d" % [m, s]


## A duration, worded. "4 min 12 s", "38 s".
static func duration(seconds: float) -> String:
	var t: int = int(roundf(maxf(0.0, seconds)))
	if t < 60:
		return "%d s" % t
	if t < 3600:
		return "%d min %02d s" % [t / 60, t % 60]
	return "%d h %02d min" % [t / 3600, (t % 3600) / 60]


## A "nice" axis step: 1, 2, 2.5 or 5 times a power of ten. Without this the
## gridlines land on 0.7333 and the chart stops being readable.
static func nice_step(span: float, target_lines: int) -> float:
	if span <= 0.0 or target_lines <= 0:
		return 1.0
	var raw: float = span / float(target_lines)
	var mag: float = pow(10.0, floor(log(raw) / log(10.0)))
	var norm: float = raw / mag
	if norm <= 1.0:
		return mag
	if norm <= 2.0:
		return 2.0 * mag
	if norm <= 2.5:
		return 2.5 * mag
	if norm <= 5.0:
		return 5.0 * mag
	return 10.0 * mag


func _font_scale() -> float:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return 1.0
	var s: Node = tree.root.get_node_or_null(NodePath("Settings"))
	if s == null:
		return 1.0
	return clampf(float(s.call("get_value", "accessibility", "font_scale", 1.0)), 0.7, 1.6)
