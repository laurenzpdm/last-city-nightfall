class_name LcnFeelHoverFx
extends Node2D
## Everything the cursor touches answers within one frame. [P15]
##
## The complaint this exists to answer: a city builder where structures do not
## respond to the pointer feels like a spreadsheet with a wallpaper. Hovering a
## building here does three things at once, all on INTERFACE time so they keep
## working while the game is paused:
##
##   1. it LIFTS — the sprite is redrawn a few pixels higher on a BACK_OUT
##      spring, with a shadow that grows underneath it, so the building looks
##      picked up rather than tinted;
##   2. it OUTLINES — a bracketed footprint snaps on in FLICK, which is the
##      whole legibility payload: you can see the shape you are about to affect;
##   3. it WARMS — a faint rim in the hour's key colour, so hover reads as light
##      landing on the building rather than as a UI decal.
##
## Selection is the same language one step louder: the brackets stay, they are
## brighter, and they pulse very slowly so a selected building is still legible
## after you have stopped looking at it.
##
## Draws at z 6, one step above the world FX layer, because the thing under the
## cursor is the thing that must never be occluded.

const Z: int = 6
const TILE: float = 32.0
## How far a hovered structure rises, in world pixels at zoom 1.
const LIFT_PX: float = 5.0

var sprites: LcnSpriteFactory = null
var grade: Dictionary = {}
var zoom: float = 1.0
var enabled: bool = true

## Current hover, filled by LcnFeel from the camera and the build system.
var hover_id: int = -1
var hover_rect: Rect2 = Rect2()
var hover_arch: StringName = &""
var hover_tiles: Vector2i = Vector2i.ONE
var hover_lift_px: float = 0.0
## Cell the cursor is on even when there is no building there, so empty ground
## still acknowledges the pointer.
var hover_cell: Vector2i = Vector2i.ZERO
var hover_on_ground: bool = false

var selection: Array[Rect2] = []

var _lift := LcnImpulse.new(LcnEase.Kind.BACK_OUT)
var _outline := LcnImpulse.new(LcnEase.Kind.QUART_OUT)
var _select := LcnImpulse.new(LcnEase.Kind.BACK_OUT)
var _ground := LcnImpulse.new(LcnEase.Kind.QUART_OUT)
var _pulse_t: float = 0.0
var _draw_us: int = 0


func _ready() -> void:
	name = "FeelHoverFx"
	z_index = Z
	z_as_relative = false
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


## Hover changed to a real structure. Idempotent: calling it with the same id
## every frame does not restart the animation.
func set_hover(id: int, rect: Rect2, arch: StringName, tiles: Vector2i) -> void:
	if id == hover_id:
		hover_rect = rect
		return
	hover_id = id
	hover_rect = rect
	hover_arch = arch
	hover_tiles = tiles
	_lift.hold(1.0, LcnTiming.SNAP, LcnEase.Kind.BACK_OUT)
	_outline.hold(1.0, LcnTiming.FLICK, LcnEase.Kind.QUART_OUT)


func clear_hover() -> void:
	if hover_id == -1:
		return
	hover_id = -1
	_lift.release(LcnTiming.SNAP)
	_outline.release(LcnTiming.FLICK)


## The cursor is over open ground. A much quieter response — a single thin
## square — but never nothing: an unresponsive cursor is the bug.
func set_ground(cell: Vector2i, inside: bool) -> void:
	hover_cell = cell
	if inside == hover_on_ground:
		return
	hover_on_ground = inside
	if inside:
		_ground.hold(1.0, LcnTiming.FLICK, LcnEase.Kind.QUART_OUT)
	else:
		_ground.release(LcnTiming.FLICK)


func set_selection(rects: Array[Rect2]) -> void:
	selection = rects
	if rects.is_empty():
		_select.release(LcnTiming.SNAP)
	else:
		_select.hold(1.0, LcnTiming.SETTLE, LcnEase.Kind.BACK_OUT)


## Once per frame, on INTERFACE time.
func refresh(ui_dt: float, day_grade: Dictionary, camera_zoom: float) -> void:
	grade = day_grade
	zoom = maxf(0.01, camera_zoom)
	_pulse_t += ui_dt
	_lift.advance(ui_dt)
	_outline.advance(ui_dt)
	_select.advance(ui_dt)
	_ground.advance(ui_dt)
	hover_lift_px = _lift.value() * LIFT_PX
	queue_redraw()


func stats() -> Dictionary:
	return {
		"hover_id": hover_id,
		"lift": snappedf(_lift.value(), 0.001),
		"outline": snappedf(_outline.value(), 0.001),
		"selected": selection.size(),
		"draw_us": _draw_us,
	}


func _draw() -> void:
	var t0: int = Time.get_ticks_usec()
	if not enabled:
		_draw_us = 0
		return
	var key: Color = LcnPalette.WARM_CORE
	if grade.has("sun_col"):
		key = (grade["sun_col"] as Color).lerp(LcnPalette.WARM_CORE, 0.55)

	if _ground.active() and hover_id == -1:
		_draw_ground_cursor(_ground.value())
	if _outline.active() and hover_rect.size.x > 0.0:
		_draw_hovered(_lift.value(), _outline.value(), key)
	if _select.active():
		_draw_selection(_select.value(), key)
	_draw_us = Time.get_ticks_usec() - t0


## Open ground: one thin square that fades in over FLICK. Deliberately quiet.
func _draw_ground_cursor(k: float) -> void:
	var r := Rect2(Vector2(hover_cell) * TILE, Vector2(TILE, TILE))
	draw_rect(r, Color(1.0, 1.0, 1.0, 0.10 * k), false, 1.0)


func _draw_hovered(lift01: float, outline01: float, key: Color) -> void:
	var lift: float = lift01 * LIFT_PX
	# 1. the shadow the lift casts. It grows and softens as the thing rises,
	#    which is the cue that sells the height.
	var base := Rect2(hover_rect.position, hover_rect.size)
	var shadow_pad: float = 2.0 + lift * 0.9
	var shadow := Rect2(
		base.position + Vector2(lift * 0.35, shadow_pad * 0.4),
		base.size + Vector2(shadow_pad, shadow_pad * 0.5))
	draw_rect(shadow, Color(0.02, 0.03, 0.06, 0.30 * lift01), true)

	# 2. the sprite again, lifted. This is a real lift, not a tint: the copy is
	#    the same atlas texture [P13] already baked, drawn 5 px higher.
	if sprites != null and hover_arch != &"":
		var sp: Dictionary = sprites.building(hover_arch, hover_tiles)
		var tex: Texture2D = sp.get("texture")
		if tex != null:
			# `offset` already carries [P13]'s atlas padding and the sprite's own
			# perspective lift; this only adds the hover rise on top of it.
			var at: Vector2 = base.position + (sp.get("offset", Vector2.ZERO) as Vector2) \
				- Vector2(0.0, lift)
			draw_texture(tex, at, Color(1.0, 1.0, 1.0, 1.0))
			# a rim of the hour's key colour over the lifted copy
			draw_texture(tex, at, Color(key.r, key.g, key.b, 0.18 * lift01))

	# 3. the brackets. Corner arms, not a closed box: a box says "selected", the
	#    arms say "this is the shape under your cursor".
	var out: Rect2 = base.grow(1.5 + 2.0 * lift01)
	_brackets(out, Color(key.r, key.g, key.b, 0.85 * outline01), 2.0)


func _draw_selection(k: float, key: Color) -> void:
	# A slow breath so a selection stays alive without pulling the eye.
	var breath: float = 0.82 + 0.18 * LcnEase.breathe(_pulse_t * 0.45)
	var col := Color(key.r, key.g, key.b, 0.95 * k * breath)
	for r: Rect2 in selection:
		var grown: Rect2 = r.grow(3.0)
		_brackets(grown, col, 2.5)
		draw_rect(grown, Color(col.r, col.g, col.b, 0.07 * k), true)


func _brackets(r: Rect2, col: Color, width: float) -> void:
	var arm: float = clampf(minf(r.size.x, r.size.y) * 0.34, 6.0, 22.0)
	var corners: Array[Vector2] = [
		r.position,
		r.position + Vector2(r.size.x, 0.0),
		r.position + Vector2(0.0, r.size.y),
		r.position + r.size,
	]
	var dirs: Array[Vector2] = [
		Vector2(1.0, 1.0), Vector2(-1.0, 1.0), Vector2(1.0, -1.0), Vector2(-1.0, -1.0),
	]
	for c: int in 4:
		var o: Vector2 = corners[c]
		var d: Vector2 = dirs[c]
		draw_line(o, o + Vector2(arm * d.x, 0.0), col, width, true)
		draw_line(o, o + Vector2(0.0, arm * d.y), col, width, true)
