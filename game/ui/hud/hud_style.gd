class_name LcnHudStyle
extends RefCounted
## The look of the interface. [P17]
##
## Everything the HUD draws goes through this object, for three reasons:
##
##   1. **It belongs to the world.** Colours come from [P13]'s palette
##      (game/view/render/palette.gd), never from hex codes typed here, so when
##      the art direction shifts the interface shifts with it. Panels are drawn,
##      not themed: chamfered steel plate, a lit top edge, rivets in the corners
##      and scratches that stay in the same place forever because they are
##      hashed, not rolled.
##   2. **It scales.** Settings `graphics/ui_scale` scales geometry (applied once
##      on the CanvasLayer by LcnHud) and `accessibility/font_scale` scales type
##      independently, so a player can enlarge the text without inflating the
##      whole frame.
##   3. **It carries urgency.** One float, `urgency` 0..1, moves the entire HUD
##      from calm (dim plate, cold ink, no chrome) to alarmed (lit plate, ember
##      rim, warning ink). Widgets read it instead of inventing their own idea
##      of "bad", which is what keeps a healthy city quiet.
##
## Accessibility is not a coat of paint here: `high_contrast` raises plate
## opacity and ink contrast, `colorblind` remaps the three status hues, and every
## status is paired with a glyph so colour is never the only carrier.

const P := preload("res://game/view/render/palette.gd")

## Design-space width the layout is authored against. LcnHud keeps the logical
## viewport at this scale divided by ui_scale, so widgets can use plain numbers.
const DESIGN_WIDTH: float = 1920.0
const DESIGN_HEIGHT: float = 1080.0

const CHAMFER: float = 7.0
const RIVET_INSET: float = 9.0
const RIVET_RADIUS: float = 2.6

## Severity ladder shared by alerts, selection rows and the status glyphs.
enum Sev { CALM, INFO, WARN, DANGER, CRITICAL }

const SEV_GLYPH: Array[String] = ["", "i", "!", "!!", "!!!"]

var ui_scale: float = 1.0
var font_scale: float = 1.0
var reduce_motion: bool = false
var high_contrast: bool = false
var colorblind: StringName = &"off"

## 0 = the city is fine, 1 = the city is dying. Set once per refresh by LcnHud.
var urgency: float = 0.0
## Seconds of wall time since the HUD was created. Drives pulses; never the sim.
var beat: float = 0.0

var font: Font = null
var font_bold: Font = null


func _init() -> void:
	font = ThemeDB.fallback_font
	font_bold = ThemeDB.fallback_font
	refresh_from_settings()


## Re-reads the user's settings. Called on creation and on Bus.ui_scale_changed.
func refresh_from_settings() -> void:
	var s: Node = _settings()
	if s == null:
		return
	ui_scale = clampf(float(s.call("get_value", "graphics", "ui_scale", 1.0)), 0.6, 2.0)
	font_scale = clampf(float(s.call("get_value", "accessibility", "font_scale", 1.0)), 0.7, 2.0)
	reduce_motion = bool(s.call("get_value", "accessibility", "reduce_motion", false))
	high_contrast = bool(s.call("get_value", "accessibility", "high_contrast_overlays", false))
	colorblind = StringName(String(s.call("get_value", "accessibility", "colorblind_mode", "off")))


func tooltip_delay() -> float:
	var s: Node = _settings()
	if s == null:
		return 0.35
	return maxf(0.0, float(s.call("get_value", "gameplay", "tooltip_delay", 0.35)))


func _settings() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath("Settings"))


# =====================================================================  type ==

## Font size in design pixels, after the accessibility font scale.
func fs(base: int) -> int:
	return maxi(8, int(roundf(float(base) * font_scale)))


func text_width(s: String, size: int) -> float:
	if font == null:
		return float(s.length()) * float(size) * 0.55
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x


## Baseline-relative draw. `pos` is the LEFT BASELINE, which is what every
## widget in this folder positions against.
func draw_text(ci: CanvasItem, pos: Vector2, s: String, size: int, colour: Color) -> float:
	if font == null or s == "":
		return 0.0
	ci.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, colour)
	return text_width(s, size)


func draw_text_right(ci: CanvasItem, right_x: float, baseline_y: float, s: String,
		size: int, colour: Color) -> float:
	var w: float = text_width(s, size)
	draw_text(ci, Vector2(right_x - w, baseline_y), s, size, colour)
	return w


func draw_text_centered(ci: CanvasItem, centre_x: float, baseline_y: float, s: String,
		size: int, colour: Color) -> float:
	var w: float = text_width(s, size)
	draw_text(ci, Vector2(centre_x - w * 0.5, baseline_y), s, size, colour)
	return w


## Letter-spaced small capitals — the stencilled label on a machine panel.
## Returns the width drawn, so callers can lay out beside it.
func draw_caps(ci: CanvasItem, pos: Vector2, s: String, size: int, colour: Color,
		tracking: float = 1.8) -> float:
	if font == null or s == "":
		return 0.0
	var up: String = s.to_upper()
	var x: float = pos.x
	for i: int in up.length():
		var ch: String = up[i]
		ci.draw_string(font, Vector2(x, pos.y), ch, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, colour)
		x += text_width(ch, size) + tracking
	return x - pos.x - tracking


func caps_width(s: String, size: int, tracking: float = 1.8) -> float:
	if font == null:
		return 0.0
	var up: String = s.to_upper()
	var w: float = 0.0
	for i: int in up.length():
		w += text_width(up[i], size) + tracking
	return maxf(0.0, w - tracking)


# ===================================================================  colour ==

func ink() -> Color:
	return P.SNOW_LIT if high_contrast else P.SNOW


func ink_dim() -> Color:
	return P.SNOW_MID if high_contrast else P.SNOW_SHADOW


func ink_faint() -> Color:
	var c: Color = ink_dim()
	return Color(c.r, c.g, c.b, 0.62 if high_contrast else 0.45)


func ink_warm() -> Color:
	return P.WARM_CORE


## Status colour for a severity, already remapped for the colourblind mode.
func sev_colour(sev: int) -> Color:
	match sev:
		Sev.CRITICAL:
			return _cb(P.EMBER)
		Sev.DANGER:
			return _cb(P.DANGER)
		Sev.WARN:
			return _cb(P.CAUTION)
		Sev.INFO:
			return P.ICE_BLUE
	return P.STEEL_LIGHT


## Green-good to red-bad ramp for a 0..1 health value, colourblind-safe.
func health_colour(good01: float) -> Color:
	var f: float = clampf(good01, 0.0, 1.0)
	if f >= 0.66:
		return _cb(P.GOOD)
	if f >= 0.33:
		return _cb(P.CAUTION)
	return _cb(P.DANGER)


## Deuteranopia and protanopia cannot separate the green from the red, so the
## "good" end becomes cyan and the "bad" end stays red; tritanopia keeps the
## red/green split and moves the caution amber toward magenta.
func _cb(c: Color) -> Color:
	if colorblind == &"off" or colorblind == &"":
		return c
	if colorblind == &"tritan":
		if c.is_equal_approx(P.CAUTION):
			return Color(0.94, 0.55, 0.80)
		return c
	if c.is_equal_approx(P.GOOD):
		return Color(0.42, 0.78, 0.94)
	if c.is_equal_approx(P.CAUTION):
		return Color(0.98, 0.85, 0.42)
	return c


## The whole HUD dims when the city is calm. This is the single knob that makes
## a healthy base almost invisible, Factorio-style.
func plate_alpha() -> float:
	var base: float = 0.88 if high_contrast else 0.74
	return clampf(base + urgency * 0.14, 0.0, 0.98)


## 0..1 pulse for anything that should breathe when things are bad. Flat when
## the player asked for reduced motion, so nothing on screen ever throbs.
func pulse(speed: float = 2.2) -> float:
	if reduce_motion:
		return 0.5
	return 0.5 + 0.5 * sin(beat * speed)


# ====================================================================  plate ==

## The chamfered outline every panel shares. Cut corners read as cut steel.
static func plate_points(rect: Rect2, cut: float = CHAMFER) -> PackedVector2Array:
	var x0: float = rect.position.x
	var y0: float = rect.position.y
	var x1: float = rect.position.x + rect.size.x
	var y1: float = rect.position.y + rect.size.y
	var c: float = minf(cut, minf(rect.size.x, rect.size.y) * 0.5)
	return PackedVector2Array([
		Vector2(x0 + c, y0), Vector2(x1 - c, y0), Vector2(x1, y0 + c),
		Vector2(x1, y1 - c), Vector2(x1 - c, y1), Vector2(x0 + c, y1),
		Vector2(x0, y1 - c), Vector2(x0, y0 + c),
	])


## Draws one panel: gradient plate, lit top edge, dark underside, rivets, a
## lamp wash from the top-left and — only when things are going wrong — an
## ember rim. `lit` 0..1 is how much lamplight falls on this particular panel;
## `sev` raises the rim.
## `alpha_floor` is for the one panel that must never be a window. The whole HUD
## is translucent on purpose — a calm base should be almost invisible chrome —
## but "translucent" and "the world reads through it" are the same sentence, and
## in `artifacts/CRIT/shots/build.png` the world-space badge `= GRID 3 0/0 heat/s
## NO SOURCE` reads across the top of the clock and `| GRID 1 47/47 heat/s`
## crosses the "2:21" numeral. [P19] now keeps its words off the clock's
## rectangle entirely, which is the real fix; this is the other half of it,
## because the WORLD is still back there and the clock is the one thing on screen
## a player checks in half a glance.
func draw_plate(ci: CanvasItem, rect: Rect2, lit: float = 0.35, sev: int = Sev.CALM,
		seed_value: int = 1, alpha_floor: float = 0.0) -> void:
	if rect.size.x <= 2.0 or rect.size.y <= 2.0:
		return
	var pts: PackedVector2Array = plate_points(rect)
	var a: float = maxf(plate_alpha(), alpha_floor)
	var top: Color = P.COLD_MID.lerp(P.COLD_HIGH, clampf(lit, 0.0, 1.0) * 0.7)
	var bottom: Color = P.COLD_ABYSS.lerp(P.COLD_DEEP, 0.55)
	var cols := PackedColorArray()
	for pt: Vector2 in pts:
		var f: float = clampf((pt.y - rect.position.y) / maxf(1.0, rect.size.y), 0.0, 1.0)
		var c: Color = top.lerp(bottom, f)
		cols.append(Color(c.r, c.g, c.b, a))
	ci.draw_polygon(pts, cols)

	# A lamp above the left shoulder. Three flat discs are cheaper than a shader
	# and, at these alphas, indistinguishable from one.
	var lamp: Vector2 = rect.position + Vector2(rect.size.x * 0.22, -2.0)
	var warm: Color = P.WARM_EDGE
	for i: int in 3:
		var r: float = rect.size.y * (0.55 + float(i) * 0.45)
		ci.draw_circle(lamp, r, Color(warm.r, warm.g, warm.b, 0.030 * lit * (3.0 - float(i))))

	_draw_scratches(ci, rect, seed_value)

	# Bevel: light along the top and left, shadow along the bottom and right.
	var hi: Color = P.STEEL_LIGHT
	ci.draw_line(pts[0], pts[1], Color(hi.r, hi.g, hi.b, 0.30 + 0.25 * lit), 1.0)
	ci.draw_line(pts[7], pts[0], Color(hi.r, hi.g, hi.b, 0.16), 1.0)
	var lo: Color = P.COLD_ABYSS
	ci.draw_line(pts[4], pts[5], Color(lo.r, lo.g, lo.b, 0.75), 1.0)
	ci.draw_line(pts[2], pts[3], Color(lo.r, lo.g, lo.b, 0.55), 1.0)

	var rim: Color = P.COLD_RIM
	var rim_w: float = 1.0
	if sev >= Sev.WARN:
		rim = sev_colour(sev)
		rim_w = 1.0 + float(sev - Sev.WARN) * 0.5
		var glow: float = 0.35 + 0.35 * pulse(2.6 + float(sev))
		rim = Color(rim.r, rim.g, rim.b, glow)
	else:
		rim = Color(rim.r, rim.g, rim.b, 0.55)
	var closed: PackedVector2Array = pts.duplicate()
	closed.append(pts[0])
	ci.draw_polyline(closed, rim, rim_w)

	_draw_rivets(ci, rect)


func _draw_rivets(ci: CanvasItem, rect: Rect2) -> void:
	if rect.size.x < 44.0 or rect.size.y < 26.0:
		return
	var body: Color = P.STEEL
	var shine: Color = P.STEEL_LIGHT
	for corner: Vector2 in [
		rect.position + Vector2(RIVET_INSET, RIVET_INSET),
		rect.position + Vector2(rect.size.x - RIVET_INSET, RIVET_INSET),
		rect.position + Vector2(RIVET_INSET, rect.size.y - RIVET_INSET),
		rect.position + Vector2(rect.size.x - RIVET_INSET, rect.size.y - RIVET_INSET),
	]:
		ci.draw_circle(corner + Vector2(0.6, 0.8), RIVET_RADIUS, Color(0.0, 0.0, 0.0, 0.45))
		ci.draw_circle(corner, RIVET_RADIUS, Color(body.r, body.g, body.b, 0.85))
		ci.draw_circle(corner - Vector2(0.7, 0.8), RIVET_RADIUS * 0.45,
			Color(shine.r, shine.g, shine.b, 0.75))


## Scratches are hashed from the panel's seed, never rolled: the same panel wears
## the same marks in every screenshot, on every machine, forever.
func _draw_scratches(ci: CanvasItem, rect: Rect2, seed_value: int) -> void:
	var n: int = clampi(int(rect.size.x * rect.size.y / 2600.0), 2, 9)
	var pale: Color = P.SNOW_SHADOW
	for i: int in n:
		var ax: float = rect.position.x + hash01(seed_value, i * 7 + 1) * rect.size.x
		var ay: float = rect.position.y + hash01(seed_value, i * 7 + 2) * rect.size.y
		var ang: float = hash01(seed_value, i * 7 + 3) * TAU
		var len_px: float = 6.0 + hash01(seed_value, i * 7 + 4) * rect.size.x * 0.28
		var b: Vector2 = Vector2(ax, ay) + Vector2(cos(ang), sin(ang) * 0.35) * len_px
		b.x = clampf(b.x, rect.position.x + 2.0, rect.position.x + rect.size.x - 2.0)
		b.y = clampf(b.y, rect.position.y + 2.0, rect.position.y + rect.size.y - 2.0)
		var alpha: float = 0.03 + hash01(seed_value, i * 7 + 5) * 0.05
		ci.draw_line(Vector2(ax, ay), b, Color(pale.r, pale.g, pale.b, alpha), 1.0)


## Deterministic 0..1 from two ints. No Rng, no randf: a HUD that reshuffles its
## own wear every frame looks like static.
static func hash01(seed_value: int, salt: int) -> float:
	var h: int = (seed_value * 374761393 + salt * 668265263) & 0x7FFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	return float(h % 100003) / 100003.0


# =====================================================================  parts ==

## Horizontal meter with a machined channel, a fill, and an optional second
## "demand" marker. Returns nothing; draws inside `rect`.
func draw_bar(ci: CanvasItem, rect: Rect2, fill01: float, colour: Color,
		ghost01: float = -1.0) -> void:
	var groove: Color = P.COLD_ABYSS
	ci.draw_rect(rect, Color(groove.r, groove.g, groove.b, 0.75), true)
	var f: float = clampf(fill01, 0.0, 1.0)
	if f > 0.0:
		var inner := Rect2(rect.position, Vector2(rect.size.x * f, rect.size.y))
		var pts := PackedVector2Array([
			inner.position, inner.position + Vector2(inner.size.x, 0.0),
			inner.position + inner.size, inner.position + Vector2(0.0, inner.size.y),
		])
		var hot: Color = colour
		var cool: Color = colour.darkened(0.35)
		ci.draw_polygon(pts, PackedColorArray([hot, hot, cool, cool]))
	if ghost01 >= 0.0:
		var gx: float = rect.position.x + rect.size.x * clampf(ghost01, 0.0, 1.0)
		ci.draw_line(Vector2(gx, rect.position.y - 1.0),
			Vector2(gx, rect.position.y + rect.size.y + 1.0), ink(), 1.5)
	var edge: Color = P.COLD_RIM
	ci.draw_rect(rect, Color(edge.r, edge.g, edge.b, 0.7), false, 1.0)


## Segmented meter — reads as a gauge rather than a progress bar, and stays
## legible for players who cannot separate the fill colour from the groove.
func draw_segments(ci: CanvasItem, rect: Rect2, fill01: float, segments: int,
		colour: Color) -> void:
	var n: int = maxi(1, segments)
	var gap: float = 2.0
	var w: float = (rect.size.x - gap * float(n - 1)) / float(n)
	var lit_count: float = clampf(fill01, 0.0, 1.0) * float(n)
	# One continuous groove behind the whole run, then only the lit segments on
	# top: ten separate dark rectangles read as static at small sizes.
	var groove: Color = P.COLD_ABYSS
	ci.draw_rect(rect.grow(1.0), Color(groove.r, groove.g, groove.b, 0.55), true)
	for i: int in n:
		var on: float = clampf(lit_count - float(i), 0.0, 1.0)
		if on <= 0.01:
			continue
		var r := Rect2(rect.position + Vector2(float(i) * (w + gap), 0.0),
			Vector2(w * on, rect.size.y))
		ci.draw_rect(r, Color(colour.r, colour.g, colour.b, 0.55 + 0.45 * on), true)
	var edge: Color = P.COLD_RIM
	ci.draw_rect(rect.grow(1.0), Color(edge.r, edge.g, edge.b, 0.45), false, 1.0)


## Up / down / flat arrow. A stock falling is the information, so the arrow is
## the loudest thing in a resource chip.
func draw_arrow(ci: CanvasItem, centre: Vector2, dir: int, size: float, colour: Color) -> void:
	if dir == 0:
		ci.draw_line(centre - Vector2(size * 0.55, 0.0), centre + Vector2(size * 0.55, 0.0),
			colour, 1.5)
		return
	var s: float = float(signi(dir))
	var pts := PackedVector2Array([
		centre + Vector2(0.0, -size * 0.6 * s),
		centre + Vector2(size * 0.55, size * 0.4 * s),
		centre + Vector2(-size * 0.55, size * 0.4 * s),
	])
	ci.draw_colored_polygon(pts, colour)


## The keyboard focus ring. Deliberately loud: a HUD that can be driven from the
## keyboard has to say where the keyboard is.
func draw_focus(ci: CanvasItem, rect: Rect2) -> void:
	var c: Color = P.WARM_CORE
	var grown: Rect2 = rect.grow(2.0)
	var pts: PackedVector2Array = plate_points(grown, 5.0)
	var closed: PackedVector2Array = pts.duplicate()
	closed.append(pts[0])
	ci.draw_polyline(closed, Color(c.r, c.g, c.b, 0.55 + 0.35 * pulse(3.4)), 1.6)


## Hover wash for an interactive row.
func draw_hover(ci: CanvasItem, rect: Rect2) -> void:
	var c: Color = P.STEEL_LIGHT
	ci.draw_polygon(plate_points(rect, 5.0),
		PackedColorArray(_repeat_colour(Color(c.r, c.g, c.b, 0.10), 8)))


func _repeat_colour(c: Color, n: int) -> Array[Color]:
	var out: Array[Color] = []
	for _i: int in n:
		out.append(c)
	return out
