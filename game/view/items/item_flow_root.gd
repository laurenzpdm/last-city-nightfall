class_name LcnItemFlowRoot
extends Node2D
## [D2] THE FACTORY, MADE VISIBLE. Root of the belt-item view.
##
## Three world-space surfaces, one sample per simulation tick:
##
##   z 1  LcnBeltFlowLayer      what every belt is doing — starved, flowing,
##                              saturated, jammed — painted onto the belt
##   z 3  LcnItemLayer          every item, at its real sub-tile position
##   z 4  LcnMachineMotionLayer arms swinging, splitters choosing, tunnels
##                              swallowing and spitting
##
## WHY z 1..4 AND NOT A CANVAS LAYER OF ITS OWN. This is world-space paint on
## world-space objects: it has to pan and zoom with the belts and sit between
## [P13]'s entity pass (z 0) and [P15]'s world juice (z 5). `game/core/ui_layers.gd`
## is the allocation table and it is not this part's to edit; there is no row in
## it for "items on belts", because a canvas layer is the wrong shape for
## something that must be occluded by nothing and must never leave the world.
## So this takes the WORLD canvas (`LcnLayers.WORLD` = 0), which is the closest
## existing entry, and asks for no new one. That request is in the part report.
##
## WHY THE SAMPLE IS ON THE TICK AND THE DRAW IS ON THE FRAME. The simulation is
## 20 Hz and fixed; the view is whatever the machine gives it. Reading the world
## once per tick and interpolating in between is both cheaper and smoother than
## reading per frame, and it is the only version that cannot make the view a
## function of frame rate.
##
## THE ZOOM CONTRACT, which is the part of this that is easiest to get wrong.
## Individual items stop being information somewhere around three screen pixels
## and start being noise. Rather than let that happen gradually and badly, the
## handover is explicit: items are drawn at full strength above `FADE_HI`, fade
## out across `FADE_HI..FADE_LO`, and are gone below it — while over the same
## band the belt layer widens its bands by density, so what replaces a stream of
## nuggets is a thicker, brighter ribbon that says the same thing at map scale.
## The thresholds line up with [P16]'s readability bands (1.0 / 0.55 / 0.32) so
## the whole view changes character at the same zoom, not at four different ones.

const GROUP: StringName = &"lcn_item_flow"

## Readability bands, matching CameraTuning's detail_close/normal/far. Read from
## [P16] when a camera exists; these are the fallback for a suite that has none.
const BAND_CLOSE: float = 1.0
const BAND_NORMAL: float = 0.55
const BAND_FAR: float = 0.32

## Items are at full strength at or above this zoom.
const FADE_HI: float = 0.46
## And entirely replaced by flow density below this one.
const FADE_LO: float = 0.30

const Z_BELTS: int = 1
const Z_ITEMS: int = 3
const Z_MACHINES: int = 4

## How much world, in cells, is asked for beyond the visible rect. A segment
## that starts off screen still has items on screen.
const CULL_MARGIN_CELLS: int = 3

var belts: LcnBeltFlowLayer = null
var items: LcnItemLayer = null
var machines: LcnMachineMotionLayer = null
var read: LcnItemFlowRead = LcnItemFlowRead.new()

var _logi: Object = null
var _clock: float = 0.0
var _view: Rect2 = Rect2()
var _scale: float = 1.0
var _band: int = 0
var _fade: float = 1.0
var _frames: int = 0
var _samples: int = 0
var _logged: bool = false
var _reduce_motion: bool = false
var _settings_timer: float = 0.0


## The instance in the tree, or null.
static func current() -> LcnItemFlowRoot:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.get_first_node_in_group(GROUP) as LcnItemFlowRoot


func _ready() -> void:
	add_to_group(GROUP)
	name = "ItemFlow"
	z_index = 0
	z_as_relative = false

	belts = LcnBeltFlowLayer.new()
	belts.z_index = Z_BELTS
	add_child(belts)

	items = LcnItemLayer.new()
	items.z_index = Z_ITEMS
	add_child(items)

	machines = LcnMachineMotionLayer.new()
	machines.z_index = Z_MACHINES
	add_child(machines)

	_refresh_settings()
	Bus.world_ready.connect(_on_world_ready)
	Bus.world_created.connect(_on_world_created)
	_logi = LcnItemFlowRead.system()


func _on_world_created(_seed_value: int) -> void:
	_logi = null
	_logged = false
	read = LcnItemFlowRead.new()


func _on_world_ready() -> void:
	_logi = LcnItemFlowRead.system()
	_logged = false


func _process(delta: float) -> void:
	_clock += delta
	_frames += 1
	_settings_timer -= delta
	if _settings_timer <= 0.0:
		_settings_timer = 0.5
		_refresh_settings()

	if _logi == null:
		_logi = LcnItemFlowRead.system()
		if _logi == null:
			return

	_measure_view()
	if read.sample(_logi, _cull_bounds(), false, _fade > 0.02):
		_samples += 1
	if not _logged and not read.belts.is_empty():
		_logged = true
		Log.info("items", "drawing the factory — %s" % read.summary())

	var ctx: Dictionary = {
		"view": _view, "zoom": _scale, "alpha": SimClock.alpha, "clock": _clock,
		"reduce_motion": _reduce_motion, "item_fade": _fade, "band": _band,
	}
	belts.sync(read, ctx)
	items.sync(read, ctx)
	machines.sync(read, ctx)
	belts.queue_redraw()
	items.queue_redraw()
	machines.queue_redraw()


## Visible world rect and the zoom, taken from the canvas transform this node is
## actually drawn under. Deliberately NOT from [P13] or [P16]: a layer that asks
## someone else where the camera is draws the wrong rectangle for exactly one
## frame every time that someone else moves it, and one frame of wrong culling
## is a flicker across the whole factory.
func _measure_view() -> void:
	var xf: Transform2D = get_viewport_transform() * get_global_transform()
	var s: Vector2 = xf.get_scale()
	_scale = maxf(0.0001, (absf(s.x) + absf(s.y)) * 0.5)
	var size: Vector2 = get_viewport_rect().size
	var inv: Transform2D = xf.affine_inverse()
	var r := Rect2(inv * Vector2.ZERO, Vector2.ZERO)
	r = r.expand(inv * Vector2(size.x, 0.0))
	r = r.expand(inv * size)
	r = r.expand(inv * Vector2(0.0, size.y))
	_view = r.grow(float(CULL_MARGIN_CELLS) * LcnItemDrawLayer.TILE)
	_band = _band_for(_scale)
	_fade = fade_for(_scale)


## Readability band for a zoom. Uses [P16]'s own answer when a camera is in the
## tree — one source of truth, with the hysteresis that stops a hovering zoom
## strobing the whole view — and the matching thresholds when there is not.
func _band_for(s: float) -> int:
	var cam: Object = GameCamera.current()
	if cam != null and cam.has_method("detail_level"):
		return int(cam.call("detail_level"))
	if s >= BAND_CLOSE:
		return 0
	if s >= BAND_NORMAL:
		return 1
	if s >= BAND_FAR:
		return 2
	return 3


## 1 where an item is worth drawing, 0 where density has replaced it.
static func fade_for(s: float) -> float:
	return clampf((s - FADE_LO) / maxf(FADE_HI - FADE_LO, 0.0001), 0.0, 1.0)


func _cull_bounds() -> Rect2i:
	var t: float = LcnItemDrawLayer.TILE
	var lo := Vector2i(int(floor(_view.position.x / t)), int(floor(_view.position.y / t)))
	var hi := Vector2i(int(ceil(_view.end.x / t)), int(ceil(_view.end.y / t)))
	return Rect2i(lo, Vector2i(maxi(1, hi.x - lo.x), maxi(1, hi.y - lo.y)))


func _refresh_settings() -> void:
	_reduce_motion = bool(Settings.get_value("accessibility", "reduce_motion", false))


## What this part is doing, for the frame suites and the log. Every number here
## is measured this frame, not declared.
func stats() -> Dictionary:
	return {
		"frames": _frames,
		"samples": _samples,
		"zoom": snappedf(_scale, 0.001),
		"band": _band,
		"item_fade": snappedf(_fade, 0.001),
		"items_on_belts": read.items.size(),
		"items_drawn": items.items_drawn,
		"kinds_drawn": items.kinds_drawn,
		"rimmed": items.rimmed,
		"belt_tiles": read.belts.size(),
		"belts_drawn": belts.drawn,
		"chevrons": belts.chevrons,
		"arms_drawn": machines.arms_drawn,
		"splitters_drawn": machines.splitters_drawn,
		"tunnels_drawn": machines.tunnels_drawn,
		"starved": read.counts[LcnItemFlowRead.Flow.STARVED],
		"flowing": read.counts[LcnItemFlowRead.Flow.FLOWING],
		"saturated": read.counts[LcnItemFlowRead.Flow.SATURATED],
		"backed_up": read.counts[LcnItemFlowRead.Flow.BACKED_UP],
		"read_us": read.read_us,
		"draw_us": belts.draw_us + items.draw_us + machines.draw_us,
	}
