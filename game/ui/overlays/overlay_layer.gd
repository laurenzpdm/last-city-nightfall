class_name LcnOverlayLayer
extends Node2D
## [P19] Base class for every world-space lens.
##
## Holds the frame context the root hands down (snapshot, palette, view rect,
## zoom, animation clock) and the reusable draw buffers. Buffers are members,
## not locals: a lens that allocates a fresh PackedVector2Array per frame
## allocates a megabyte a second at 60 fps, and this layer draws every frame the
## player has an overlay up.
##
## Sizing rule for the whole part: **every stroke, glyph and label is specified
## in SCREEN pixels and divided by zoom on the way out**, so a lens is exactly
## as readable at strategic zoom as it is with your nose on a pipe.

const TILE: float = 32.0

var snap: LcnOverlaySnapshot = null
var pal: LcnOverlayPalette = null
var view: Rect2 = Rect2()
## World units per screen pixel — 1.0 / camera zoom.
var wpp: float = 1.0
## Seconds of wall time since the overlay came up. View-side only; the sim never
## sees it, so it cannot perturb a replay.
var time_s: float = 0.0
## The player is holding the detail key.
var alt: bool = false
var detail: int = 1

var font: Font = null
var draw_us: int = 0

var _lines: PackedVector2Array = PackedVector2Array()
var _cols: PackedColorArray = PackedColorArray()
## Plates already placed this frame. Callouts are drawn worst-first, so a later
## one that would land on top of an earlier one is dropped rather than smeared
## over it — two overlapping verdicts are less readable than one.
var _plates: Array[Rect2] = []


func _init() -> void:
	z_as_relative = false
	font = ThemeDB.fallback_font


## Called by the root once per frame before queue_redraw().
func sync(s: LcnOverlaySnapshot, p: LcnOverlayPalette, v: Rect2, world_per_px: float,
		t: float, alt_held: bool, detail_level: int) -> void:
	snap = s
	pal = p
	view = v
	wpp = maxf(0.0001, world_per_px)
	time_s = t
	alt = alt_held
	detail = detail_level
	_plates.clear()


## Screen px -> world px.
func px(screen_px: float) -> float:
	return screen_px * wpp


func stroke(screen_px: float) -> float:
	return pal.stroke(screen_px, wpp)


func visible_rect(r: Rect2) -> bool:
	return view.intersects(r)


# --- batched line drawing --------------------------------------------------
#
# push_lines() accumulates; flush_lines() emits ONE draw_multiline_colors for
# everything pushed since the last flush. A lens that issues a draw call per
# ring would spend more time in the driver than in the simulation it explains.

## Appends every segment already in `pts` with one colour.
func push_lines(pts: PackedVector2Array, c: Color) -> void:
	var base: int = _lines.size()
	_lines.resize(base + pts.size())
	_cols.resize(_lines.size() / 2)
	for i: int in pts.size():
		_lines[base + i] = pts[i]
	var from: int = base / 2
	for j: int in range(from, _lines.size() / 2):
		_cols[j] = c


## One draw call for everything pushed since the last flush.
func flush_lines(width: float) -> void:
	if _lines.size() < 2:
		return
	draw_multiline_colors(_lines, _cols, width)
	_lines.clear()
	_cols.clear()


# --- text ------------------------------------------------------------------

## A label that stays the same size on screen at every zoom, with a dark halo so
## it survives both the snow and the night.
func label(at: Vector2, text: String, size_px: float, c: Color, centered: bool = false) -> void:
	if font == null or text == "":
		return
	var s: int = maxi(8, int(round(size_px)))
	var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, s).x
	var scale: float = wpp
	var pos: Vector2 = at
	if centered:
		pos.x -= w * 0.5 * scale
	draw_set_transform(pos, 0.0, Vector2(scale, scale))
	var outline: int = 6 if pal.high_contrast else 4
	font.draw_string_outline(get_canvas_item(), Vector2.ZERO, text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, s, outline, Color(0.0, 0.0, 0.0, 0.9))
	font.draw_string(get_canvas_item(), Vector2.ZERO, text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, s, c)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## A label with a solid plate behind it. Used for the few callouts that must be
## readable over any background — bottleneck verdicts, network badges.
func plate(at: Vector2, text: String, size_px: float, c: Color, centered: bool = false) -> void:
	if font == null or text == "":
		return
	var s: int = maxi(8, int(round(size_px)))
	var m: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, s)
	var padx: float = 6.0
	var pady: float = 3.0
	var w: float = (m.x + padx * 2.0) * wpp
	var h: float = (float(s) + pady * 2.0) * wpp
	var pos: Vector2 = at
	if centered:
		pos.x -= w * 0.5
	var box := Rect2(pos, Vector2(w, h))
	for taken: Rect2 in _plates:
		if taken.intersects(box):
			return
	_plates.append(box)
	draw_rect(box, Color(0.02, 0.035, 0.063, 0.88), true)
	draw_rect(box, LcnOverlayPalette.with_a(c, 0.9), false, stroke(1.5))
	draw_set_transform(pos + Vector2(padx, float(s) * 0.82 + pady) * wpp, 0.0, Vector2(wpp, wpp))
	font.draw_string(get_canvas_item(), Vector2.ZERO, text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, s, c)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Width the plate() above would occupy, in world px.
func plate_width(text: String, size_px: float) -> float:
	if font == null:
		return 0.0
	var s: int = maxi(8, int(round(size_px)))
	return (font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, s).x + 12.0) * wpp
