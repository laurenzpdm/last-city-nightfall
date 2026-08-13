class_name LcnFeelIdleLife
extends Node2D
## The city breathes when nothing is happening. [P15]
##
## A base that is perfectly still between events reads as a diagram. This layer
## gives a settled city a resting heartbeat, and it does it from data the
## simulation already produces, so nothing here is a lie:
##
##   * every warm structure BREATHES — its glow swells and falls on a sine
##     whose period depends on how much heat it actually makes, so a hearth is
##     slow and heavy and a radiator ticks along;
##   * heat pipes PULSE — a bright travelling phase runs along a run, keyed to
##     the cell coordinate, so the eye reads flow direction without a lens open;
##   * the hearth BREATHES OUT — a slow ember every few seconds, the one piece
##     of idle motion allowed to be loud, because it is the thing keeping
##     everyone alive.
##
## Additive, under the sprite pass (z -18, between [P13]'s glow at -20 and the
## main pass at 0), so it augments the existing light rather than painting over
## the art.
##
## COST. The anchor list is rebuilt on a slow timer, not every frame, and it is
## capped. At the 1700-building stress city this draws the same 96 anchors it
## draws at 90 buildings, which is the only way an idle layer can be free.

const Z: int = -18
const TILE: float = 32.0
## Hard cap on breathing anchors. Beyond this the city is legible without more.
const MAX_ANCHORS: int = 96
## Seconds between anchor rebuilds. A building placed now starts breathing
## within half a second, which nobody can perceive as a delay.
const REBUILD_EVERY: float = 0.5
## Below this camera zoom the whole layer switches off: at strategic zoom the
## individual breaths merge into noise and cost frames for nothing.
const MIN_ZOOM: float = 0.42

var enabled: bool = true
var grade: Dictionary = {}
var zoom: float = 1.0
var night01: float = 0.0

## anchor rows: {pos, radius, warm, period, phase, pipe}
var _anchors: Array[Dictionary] = []
var _rebuild_in: float = 0.0
var _t: float = 0.0
var _draw_us: int = 0
var _model: LcnWorldModel = null
var _view: Rect2 = Rect2()
## Diagnostics for the rebuild, so "0 anchors" is answerable without a debugger:
## how many structures the model offered, and how many survived the view cull.
var _seen: int = 0
var _in_view: int = 0


func _ready() -> void:
	name = "FeelIdleLife"
	z_index = Z
	z_as_relative = false
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	# Unshaded for the same reason [P13]'s glow pass is: the night light rig must
	# not crush the warmth exactly when the warmth is the point.
	mat.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	material = mat


func bind(model: LcnWorldModel) -> void:
	_model = model
	_rebuild_in = 0.0


## Once per frame. `dt` is WORLD time — the city's pulse belongs to the world and
## stops when the world does — while `ui_dt` is interface time and drives the
## anchor rebuild timer. Using world time for both meant a paused session (and a
## harness run, where the clock is manual and never "running") rebuilt the anchor
## list on every single frame instead of twice a second.
func refresh(dt: float, ui_dt: float, view: Rect2, day_grade: Dictionary,
		camera_zoom: float, night: float) -> void:
	grade = day_grade
	zoom = maxf(0.01, camera_zoom)
	night01 = clampf(night, 0.0, 1.0)
	_view = view
	_t += dt
	_rebuild_in -= maxf(ui_dt, dt)
	if _rebuild_in <= 0.0:
		_rebuild_in = REBUILD_EVERY
		_rebuild()
	queue_redraw()


func stats() -> Dictionary:
	return {
		"anchors": _anchors.size(),
		"seen": _seen,
		"in_view": _in_view,
		"zoom": snappedf(zoom, 0.001),
		"view": "%.0f,%.0f %.0fx%.0f" % [_view.position.x, _view.position.y, _view.size.x, _view.size.y],
		"draw_us": _draw_us,
	}


## Walks the renderer's cached building list once, keeps what is on screen and
## warm, and stops at MAX_ANCHORS. The walk is the only O(buildings) work in the
## whole feel layer and it happens twice a second.
func _rebuild() -> void:
	_anchors.clear()
	_seen = 0
	_in_view = 0
	if _model == null or zoom < MIN_ZOOM:
		return
	# An empty view rect means the renderer has not computed one yet (this layer
	# ticks BEFORE it, by design, so the cursor is answered in the same frame it
	# moved). Culling against a zero rect would silently drop the whole city, so
	# on those frames nothing is culled at all.
	var cull: Rect2 = _view.grow(96.0)
	var cull_on: bool = _view.size.x > 1.0 and _view.size.y > 1.0
	var pipes: int = 0
	for b: Dictionary in _model.buildings():
		if _anchors.size() >= MAX_ANCHORS:
			break
		_seen += 1
		var centre: Vector2 = b["centre"]
		if cull_on and not cull.has_point(centre):
			continue
		_in_view += 1
		var state: int = int(b.get("state", LcnWorldModel.BUILD_OPERATIONAL))
		if state != LcnWorldModel.BUILD_OPERATIONAL:
			continue
		var warm: float = float(b.get("warm", 0.0))
		var kind: String = String(b.get("kind", ""))
		var is_pipe: bool = kind.contains("pipe") or kind.contains("trunk")
		if is_pipe:
			# Pipes are cheap and numerous; take a bounded sample of them so a
			# hundred-tile run still reads as a run without a hundred draws.
			pipes += 1
			if pipes % 2 == 1:
				continue
			var c: Vector2i = b["cell"]
			_anchors.append({
				"pos": centre,
				"radius": TILE * 0.55,
				"warm": 0.35,
				"period": 1.9,
				# Phase from the cell, so the bright band travels ALONG a run
				# instead of every pipe blinking together.
				"phase": float(c.x + c.y) * 0.16,
				"pipe": true,
			})
			continue
		if warm < 0.18:
			continue
		var tiles: Vector2i = b.get("tiles", Vector2i.ONE)
		# Heavy things breathe slowly. This is the whole trick: one constant
		# derived from what the building actually does, and a hearth reads
		# different from a radiator without a single special case.
		var period: float = 2.4 + warm * 4.2 + float(maxi(tiles.x, tiles.y)) * 0.35
		_anchors.append({
			"pos": centre,
			"radius": maxf(float(b.get("radius", 96.0)) * 0.42, TILE),
			"warm": warm,
			"period": period,
			"phase": float(int(b.get("seed", 0)) % 997) * 0.0063,
			"pipe": false,
		})


func _draw() -> void:
	var t0: int = Time.get_ticks_usec()
	_draw_us = 0
	if not enabled or _anchors.is_empty() or zoom < MIN_ZOOM:
		return
	if LcnTiming.reduce_motion():
		# Reduced motion keeps the warmth and drops the movement: the light is
		# information, the breathing is decoration.
		_draw_static()
		_draw_us = Time.get_ticks_usec() - t0
		return
	# Firelight is firelight: it does not take the hour's grade, which is exactly
	# why a lit window reads as warm at noon and as a beacon at midnight.
	var warm_col: Color = LcnPalette.heat_light_color(0.72)
	# Night is when a breathing city is worth seeing; midday washes it out.
	var strength: float = lerpf(0.30, 1.0, night01)
	for a: Dictionary in _anchors:
		var pos: Vector2 = a["pos"]
		var period: float = a["period"]
		var b: float = LcnEase.breathe(_t / period + float(a["phase"]))
		if bool(a["pipe"]):
			# A pipe's pulse is sharper than a building's breath — it is flow,
			# not respiration.
			var p: float = pow(b, 3.0)
			var col := Color(warm_col.r, warm_col.g, warm_col.b,
				0.10 * strength * (0.25 + 0.75 * p))
			draw_circle(pos, float(a["radius"]) * (0.8 + 0.35 * p), col)
			continue
		var w: float = float(a["warm"])
		var r: float = float(a["radius"]) * (0.86 + 0.14 * b)
		var alpha: float = 0.055 * strength * w * (0.55 + 0.45 * b)
		draw_circle(pos, r, Color(warm_col.r, warm_col.g, warm_col.b, alpha))
		draw_circle(pos, r * 0.45, Color(warm_col.r, warm_col.g, warm_col.b, alpha * 1.5))
	_draw_us = Time.get_ticks_usec() - t0


func _draw_static() -> void:
	var warm_col: Color = LcnPalette.heat_light_color(0.72)
	var strength: float = lerpf(0.30, 1.0, night01)
	for a: Dictionary in _anchors:
		if bool(a["pipe"]):
			continue
		var alpha: float = 0.05 * strength * float(a["warm"])
		draw_circle(a["pos"], float(a["radius"]) * 0.9,
			Color(warm_col.r, warm_col.g, warm_col.b, alpha))
