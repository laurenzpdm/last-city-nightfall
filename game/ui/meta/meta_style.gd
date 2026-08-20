class_name LcnMetaStyle
extends RefCounted
## [P24] The look of the menus: title screen, pause, settings, saves.
##
## Same rules as the rest of the interface — no hex codes here, every colour
## comes from [P13]'s [LcnPalette] so the menus shift when the art direction
## does. The grammar, in one paragraph:
##
##   The menu sits on the cold dark. Type is snow-white, secondary type is the
##   snow shadow, and WARM_EDGE is the only saturated colour in the frame: it
##   means "this is the thing you are pointing at" and nothing else. Panels are
##   chamfered plate with a lit top edge, exactly like the HUD's, because the
##   pause menu is the same machine as the clock panel and should not look like
##   a different game's dialog box.
##
## Accessibility is applied HERE rather than in each screen, so there is one
## place to get it right:
##   * `accessibility/font_scale` scales every type size, and the row height
##     follows the type — that is what stops large text from clipping;
##   * `accessibility/high_contrast_overlays` raises plate opacity and text
##     contrast and thickens the focus ring;
##   * `accessibility/colorblind_mode` remaps the three status hues, using the
##     same tokens [P17] and [P19] read;
##   * `accessibility/reduce_motion` flattens every pulse to a constant, so
##     nothing in the menus breathes.

const P := preload("res://game/view/render/palette.gd")

## The layout is authored against this and scaled to the real viewport, so a
## number in a screen is a number on a 1920×1080 monitor.
const DESIGN_WIDTH: float = 1920.0
const DESIGN_HEIGHT: float = 1080.0

const CHAMFER: float = 8.0

const FS_TITLE: int = 64
const FS_HEAD: int = 22
const FS_ROW: int = 19
const FS_BODY: int = 16
const FS_SMALL: int = 14

var font: Font = null
var font_scale: float = 1.0
var ui_scale: float = 1.0
var high_contrast: bool = false
var reduce_motion: bool = false
var colorblind: StringName = &"off"
## Seconds since the menu appeared. Drives the one slow pulse; never the sim.
var beat: float = 0.0


func _init() -> void:
	font = ThemeDB.fallback_font
	refresh_from_settings()


## Re-read the player's settings. Called on creation and whenever a setting the
## menus care about changes, so a font-scale change is visible in the very
## screen that changed it.
func refresh_from_settings() -> void:
	var s: Node = _settings()
	if s == null:
		return
	ui_scale = clampf(float(s.call("get_value", "graphics", "ui_scale", 1.0)), 0.6, 2.0)
	font_scale = clampf(float(s.call("get_value", "accessibility", "font_scale", 1.0)), 0.7, 2.0)
	high_contrast = bool(s.call("get_value", "accessibility", "high_contrast_overlays", false))
	reduce_motion = bool(s.call("get_value", "accessibility", "reduce_motion", false))
	colorblind = StringName(String(s.call("get_value", "accessibility", "colorblind_mode", "off")))


func fs(base: int) -> int:
	return maxi(9, int(round(float(base) * font_scale)))


## Row height for a given type size. Derived from the type, never a constant —
## a fixed row height is exactly how a 1.6× font scale ends up clipped.
func row_height(base: int = FS_ROW) -> float:
	return float(fs(base)) * 2.0


# ------------------------------------------------------------------ colour ---

func ink() -> Color:
	return P.SNOW_LIT if high_contrast else P.SNOW


func ink_dim() -> Color:
	return P.SNOW_MID if high_contrast else P.SNOW_SHADOW


func ink_faint() -> Color:
	var c: Color = ink_dim()
	return Color(c.r, c.g, c.b, 0.62 if high_contrast else 0.45)


func accent() -> Color:
	return P.WARM_EDGE


## Good / caution / danger, remapped for colour vision deficiency. Uses the same
## short tokens [P17]'s HUD matches on, so one setting drives both.
func status(kind: StringName) -> Color:
	var c: Color = P.GOOD
	if kind == &"warn":
		c = P.CAUTION
	elif kind == &"bad":
		c = P.DANGER
	if colorblind == &"off" or colorblind == &"":
		return c
	if colorblind == &"tritan":
		if kind == &"warn":
			return Color(0.94, 0.55, 0.80)
		return c
	if colorblind == &"mono":
		var l: float = c.get_luminance()
		return Color(l, l, l)
	# protan / deutan: the good end leaves the green, the bad end stays red.
	if kind == &"good":
		return Color(0.42, 0.78, 0.94)
	if kind == &"warn":
		return Color(0.98, 0.85, 0.42)
	return c


## 0..1, flat when the player asked for reduced motion.
func pulse(speed: float = 1.6) -> float:
	if reduce_motion:
		return 0.5
	return 0.5 + 0.5 * sin(beat * speed)


# ----------------------------------------------------------------- drawing ---

## The chamfered plate every panel in this game shares.
static func plate_points(rect: Rect2, cut: float = CHAMFER) -> PackedVector2Array:
	var x0: float = rect.position.x
	var y0: float = rect.position.y
	var x1: float = rect.end.x
	var y1: float = rect.end.y
	var c: float = minf(cut, minf(rect.size.x, rect.size.y) * 0.5)
	return PackedVector2Array([
		Vector2(x0 + c, y0), Vector2(x1 - c, y0), Vector2(x1, y0 + c),
		Vector2(x1, y1 - c), Vector2(x1 - c, y1), Vector2(x0 + c, y1),
		Vector2(x0, y1 - c), Vector2(x0, y0 + c),
	])


## A panel: dark plate, cold rim, one lit edge along the top.
func draw_plate(on: CanvasItem, rect: Rect2, hot: bool = false) -> void:
	var pts: PackedVector2Array = plate_points(rect)
	var alpha: float = 0.995 if high_contrast else 0.975
	on.draw_colored_polygon(pts, Color(P.COLD_DEEP.r, P.COLD_DEEP.g, P.COLD_DEEP.b, alpha))
	var rim: Color = accent() if hot else P.COLD_RIM
	var closed: PackedVector2Array = pts.duplicate()
	closed.append(pts[0])
	on.draw_polyline(closed, rim, 1.5 if high_contrast else 1.0, true)
	on.draw_line(rect.position + Vector2(CHAMFER, 1.0),
		Vector2(rect.end.x - CHAMFER, rect.position.y + 1.0),
		Color(P.STEEL_LIGHT.r, P.STEEL_LIGHT.g, P.STEEL_LIGHT.b, 0.45), 1.0)


## A scrim over the world. The menus are modal; the city behind them must read
## as "not yours right now" without disappearing.
func draw_scrim(on: CanvasItem, rect: Rect2, strength: float = 1.0) -> void:
	# `strength` IS the alpha. It used to be a multiplier over 0.74, which put
	# the real coverage at 0.61 for a pause menu: [P22]'s event card and the
	# HUD's alert panel both read straight through the settings plate in the
	# first screenshots of this part, and small type over them was unreadable.
	# 0.9 at full strength, not 0.74. At 0.74 the [P22] event card and the HUD's
	# alert panel both read straight THROUGH the settings plate in the first
	# screenshots of this part — a modal you can read the game through is not a
	# modal, and the frame was unreadable at exactly the moment a player is
	# reading small type.
	var a: float = clampf(strength, 0.0, 1.0)
	on.draw_rect(rect, Color(P.COLD_ABYSS.r, P.COLD_ABYSS.g, P.COLD_ABYSS.b, a), true)


## The focus ring. Thick, warm, and drawn OUTSIDE the row so it never sits on a
## glyph. This is the only thing that tells a keyboard player where they are, so
## it is never subtle and never colour alone — the row's label brightens too.
func draw_focus(on: CanvasItem, rect: Rect2) -> void:
	var grown: Rect2 = rect.grow(2.0)
	var pts: PackedVector2Array = plate_points(grown, CHAMFER)
	pts.append(pts[0])
	var glow: float = 0.75 + 0.25 * pulse(2.0)
	on.draw_colored_polygon(plate_points(grown, CHAMFER),
		Color(accent().r, accent().g, accent().b, 0.14))
	on.draw_polyline(pts, Color(accent().r, accent().g, accent().b, glow),
		2.5 if high_contrast else 2.0, true)


## Left-aligned text. Returns the width drawn.
func text(on: CanvasItem, at: Vector2, s: String, size: int, colour: Color) -> float:
	if font == null:
		return 0.0
	var px: int = fs(size)
	on.draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, px, colour)
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, px).x


func text_right(on: CanvasItem, right_x: float, baseline_y: float, s: String, size: int, colour: Color) -> void:
	if font == null:
		return
	var px: int = fs(size)
	var w: float = font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, px).x
	on.draw_string(font, Vector2(right_x - w, baseline_y), s,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, px, colour)


func text_centre(on: CanvasItem, centre_x: float, baseline_y: float, s: String, size: int, colour: Color) -> void:
	if font == null:
		return
	var px: int = fs(size)
	var w: float = font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, px).x
	on.draw_string(font, Vector2(centre_x - w * 0.5, baseline_y), s,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, px, colour)


func measure(s: String, size: int) -> float:
	if font == null:
		return 0.0
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs(size)).x


## Small caps label — the game writes every field label this way.
func label(on: CanvasItem, at: Vector2, s: String, colour: Color) -> void:
	var spaced: String = ""
	var upper: String = s.to_upper()
	for i: int in upper.length():
		spaced += upper[i]
		if i < upper.length() - 1:
			spaced += " "
	var _w: float = text(on, at, spaced, FS_SMALL, colour)


func _settings() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath("Settings"))
