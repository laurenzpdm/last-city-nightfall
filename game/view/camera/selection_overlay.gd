class_name SelectionOverlay
extends Node2D
## The thin line of feedback that makes the cursor feel connected to the world:
## the hovered tile, the live box-select, the committed selection, and a one-shot
## ring when the camera is thrown at an alert.
##
## Deliberately minimal and switchable (`enabled`). [P13] owns art direction; this is
## the functional layer that must exist for selection to be usable at all, drawn in
## world space with screen-constant line widths so it reads the same at every zoom.

const HOVER_COLOR: Color = Color(0.98, 0.72, 0.38, 0.55)
const SELECT_COLOR: Color = Color(1.0, 0.78, 0.42, 0.9)
const BOX_FILL: Color = Color(0.42, 0.70, 0.96, 0.10)
const BOX_EDGE: Color = Color(0.62, 0.86, 1.0, 0.85)
const PING_COLOR: Color = Color(1.0, 0.62, 0.28, 0.9)
const PING_DURATION: float = 0.55

var enabled: bool = true
var reduce_motion: bool = false
var tile_size: int = CameraTuning.TILE_SIZE
var view_zoom: float = 1.0

var hover_cell: Vector2i = Vector2i.ZERO
var hover_visible: bool = false
var box_rect: Rect2 = Rect2()
var box_visible: bool = false
var selection_rect: Rect2i = Rect2i()
var selection_visible: bool = false

var _ping_pos: Vector2 = Vector2.ZERO
var _ping_t: float = -1.0
var _dirty: bool = true


func _ready() -> void:
	top_level = true
	z_index = 900
	z_as_relative = false
	set_process(true)


## Called once per frame by GameCamera with everything the overlay needs to draw.
func sync(zoom_value: float, cell: Vector2i, hovering: bool, box: Rect2, box_on: bool,
		selection: Rect2i, selection_on: bool) -> void:
	if not is_equal_approx(zoom_value, view_zoom):
		view_zoom = zoom_value
		_dirty = true
	if cell != hover_cell or hovering != hover_visible:
		hover_cell = cell
		hover_visible = hovering
		_dirty = true
	if box_on != box_visible or (box_on and box != box_rect):
		box_rect = box
		box_visible = box_on
		_dirty = true
	if selection_on != selection_visible or (selection_on and selection != selection_rect):
		selection_rect = selection
		selection_visible = selection_on
		_dirty = true
	if _dirty:
		_dirty = false
		queue_redraw()


## One-shot ring at a world position; how an alert says "here, look".
func ping(world_pos: Vector2) -> void:
	if reduce_motion or not enabled:
		return
	_ping_pos = world_pos
	_ping_t = 0.0
	queue_redraw()


func _process(delta: float) -> void:
	if _ping_t < 0.0:
		return
	_ping_t += delta
	if _ping_t > PING_DURATION:
		_ping_t = -1.0
	queue_redraw()


func _draw() -> void:
	if not enabled:
		return
	var px: float = 1.0 / maxf(view_zoom, 0.0001)   # one screen pixel in world units

	if hover_visible:
		var t: float = float(tile_size)
		var r: Rect2 = Rect2(Vector2(hover_cell) * t, Vector2(t, t)).grow(-px)
		draw_rect(r, HOVER_COLOR, false, 1.5 * px)
		_draw_corners(r, HOVER_COLOR, t * 0.28, 2.0 * px)

	if selection_visible and selection_rect.size.x > 0 and selection_rect.size.y > 0:
		var sr: Rect2 = Rect2(
			Vector2(selection_rect.position) * float(tile_size),
			Vector2(selection_rect.size) * float(tile_size))
		draw_rect(sr, SELECT_COLOR, false, 2.0 * px)

	if box_visible:
		draw_rect(box_rect, BOX_FILL, true)
		draw_rect(box_rect, BOX_EDGE, false, 1.5 * px)
		_draw_corners(box_rect, BOX_EDGE, minf(box_rect.size.x, box_rect.size.y) * 0.2, 2.5 * px)

	if _ping_t >= 0.0:
		var k: float = clampf(_ping_t / PING_DURATION, 0.0, 1.0)
		# Constant on screen: the ring is a UI gesture, not a world object.
		var radius: float = lerpf(8.0, 96.0, k) * px
		var color: Color = PING_COLOR
		color.a *= 1.0 - k
		draw_arc(_ping_pos, radius, 0.0, TAU, 48, color, 2.0 * px, true)


func _draw_corners(rect: Rect2, color: Color, length: float, width: float) -> void:
	var l: float = minf(length, minf(rect.size.x, rect.size.y) * 0.5)
	if l <= 0.0:
		return
	var p: Vector2 = rect.position
	var e: Vector2 = rect.end
	draw_line(p, p + Vector2(l, 0.0), color, width)
	draw_line(p, p + Vector2(0.0, l), color, width)
	draw_line(Vector2(e.x, p.y), Vector2(e.x - l, p.y), color, width)
	draw_line(Vector2(e.x, p.y), Vector2(e.x, p.y + l), color, width)
	draw_line(Vector2(p.x, e.y), Vector2(p.x + l, e.y), color, width)
	draw_line(Vector2(p.x, e.y), Vector2(p.x, e.y - l), color, width)
	draw_line(e, e - Vector2(l, 0.0), color, width)
	draw_line(e, e - Vector2(0.0, l), color, width)
