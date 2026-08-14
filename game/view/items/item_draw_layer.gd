class_name LcnItemDrawLayer
extends Node2D
## [D2] Shared frame context for the three surfaces that draw the factory.
##
## The root reads the world once per tick and hands every layer the same frame:
## the sample, the visible rect, how many screen pixels a world pixel is worth,
## the sub-tick interpolation factor and a view-side clock. Nothing below ever
## touches `Sim` or `SimClock` itself, which is what keeps the whole part one
## sample per tick no matter how many surfaces are drawing.
##
## SIZING RULE. Item geometry is specified in WORLD pixels, because an item has
## a real size on a real belt and a plate that stays 8 px on screen while the
## belt shrinks is a lie about density. Outlines and chevrons are specified in
## SCREEN pixels and divided by `scale`, because a hairline has to stay a
## hairline. Anything that must never fall under a pixel goes through `atleast`.

const TILE: float = 32.0

var read: LcnItemFlowRead = null
## Visible world rectangle in pixels, already grown by the root.
var view: Rect2 = Rect2()
## Screen pixels per world pixel. 1.0 is "one tile is 32 px". Named `zoom` and
## not `scale` because Node2D already owns `scale`, and shadowing it would
## silently transform every child of this layer instead of failing loudly.
var zoom: float = 1.0
## 0..1 through the current simulation tick.
var alpha: float = 0.0
## Seconds of wall time since this layer came up. View-side only: the simulation
## never sees it, so it can never perturb a replay.
var clock: float = 0.0
## Accessibility. Animation amplitude, not colour, is what this switches off.
var reduce_motion: bool = false
## 1 while individual items are worth drawing, 0 once density has replaced them.
var item_fade: float = 1.0
## Camera readability band, 0 close .. 3 strategic.
var band: int = 0

var draw_us: int = 0
var drawn: int = 0

var _tris: PackedVector2Array = PackedVector2Array()
var _cols: PackedColorArray = PackedColorArray()
var _lines: PackedVector2Array = PackedVector2Array()
var _line_cols: PackedColorArray = PackedColorArray()


func _init() -> void:
	z_as_relative = false
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


## Called by the root once per frame, before queue_redraw().
func sync(sample: LcnItemFlowRead, ctx: Dictionary) -> void:
	read = sample
	view = ctx["view"]
	zoom = maxf(0.0001, float(ctx["zoom"]))
	alpha = float(ctx["alpha"])
	clock = float(ctx["clock"])
	reduce_motion = bool(ctx["reduce_motion"])
	item_fade = float(ctx["item_fade"])
	band = int(ctx["band"])


## World pixels for a length specified in screen pixels.
func wpx(screen_px: float) -> float:
	return screen_px / zoom


## World-pixel length that is at least `screen_px` on screen. Used for anything
## that stops existing when it falls below a pixel.
func atleast(world_px: float, screen_px: float) -> float:
	return maxf(world_px, screen_px / zoom)


func on_screen(p: Vector2, margin: float) -> bool:
	return p.x >= view.position.x - margin and p.y >= view.position.y - margin \
		and p.x <= view.end.x + margin and p.y <= view.end.y + margin


# --- batched geometry --------------------------------------------------------
#
# Every surface here builds ONE triangle soup and ONE line soup per frame and
# emits each in a single command. A layer that issued a draw call per item would
# spend more time in the driver than [P03] spends simulating the belt.

func tris_reset(expected_vertices: int = 0) -> void:
	_tris.clear()
	_cols.clear()
	if expected_vertices > 0:
		_tris.resize(expected_vertices)
		_tris.resize(0)


## Appends a triangle list already centred on the origin, offset to `at`.
func tris_push(shape_tris: PackedVector2Array, at: Vector2, c: Color) -> void:
	var base: int = _tris.size()
	var n: int = shape_tris.size()
	_tris.resize(base + n)
	_cols.resize(base + n)
	for i: int in n:
		_tris[base + i] = shape_tris[i] + at
		_cols[base + i] = c


## Appends an axis-aligned quad given its four corners in order.
func tris_quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, col: Color) -> void:
	var base: int = _tris.size()
	_tris.resize(base + 6)
	_cols.resize(base + 6)
	_tris[base] = a
	_tris[base + 1] = b
	_tris[base + 2] = c
	_tris[base + 3] = a
	_tris[base + 4] = c
	_tris[base + 5] = d
	for i: int in 6:
		_cols[base + i] = col


## A quad `half_w` wide either side of the segment from `from` to `to`.
func tris_band(from: Vector2, to: Vector2, half_w: float, col: Color) -> void:
	var d: Vector2 = to - from
	if d.length_squared() < 0.000001:
		return
	var n: Vector2 = d.orthogonal().normalized() * half_w
	tris_quad(from + n, to + n, to - n, from - n, col)


func tris_flush() -> void:
	if _tris.size() < 3:
		return
	# Empty indices means "the points ARE the triangle list"; verified against
	# 4.7.1 rather than assumed, because the alternative silently draws nothing.
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(),
		PackedInt32Array(), _tris, _cols)
	_tris.clear()
	_cols.clear()


func lines_reset() -> void:
	_lines.clear()
	_line_cols.clear()


## One colour per SEGMENT, not per point: `draw_multiline_colors` wants
## `colors.size() * 2 == points.size()` and rejects the whole call otherwise —
## with an engine error per frame, which is how this first shipped.
func lines_push(from: Vector2, to: Vector2, c: Color) -> void:
	var base: int = _lines.size()
	_lines.resize(base + 2)
	_lines[base] = from
	_lines[base + 1] = to
	_line_cols.append(c)


func lines_flush(width: float) -> void:
	if _lines.size() < 2:
		return
	draw_multiline_colors(_lines, _line_cols, width)
	_lines.clear()
	_line_cols.clear()
