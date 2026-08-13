class_name LcnFeelScreenFx
extends CanvasLayer
## The screen-space treatment. [P15]
##
## LAYER 61, and the number is an argument. [P13]'s post stack is 60 and [P17]'s
## HUD is 65 (see game/core/ui_layers.gd). A hit flash that sits UNDER the grade
## gets graded away at exactly the hour it matters, and one that sits OVER the
## HUD washes out the clock while the player is trying to read it. 61 is the one
## slot where a full-screen response reads at full strength and still cannot
## cover a single readable number. `follow_viewport_enabled` stays false: this is
## screen space, so by LcnLayers' rule it is allowed above the world.
##
## What it does:
##   * WASH — a full-frame tint on an IMPACT envelope. Damage, freezing, a law.
##   * VIGNETTE — edge pressure that persists. Night, an incoming wave, a city
##     about to go dark. This is the one that does the emotional work, because
##     it is continuous: the player feels the night arriving for thirty seconds
##     rather than being told about it for one.
##   * SWEEP — a soft band that crosses the frame once. Nightfall and dawn.
##
## All three are one textured quad each, so the cost is three draw calls at the
## absolute worst and zero when nothing is happening.

const LAYER: int = 61
const VIGNETTE_PX: int = 64
const SWEEP_PX: int = 64

## Continuous pressures, 0..1, set by LcnFeel from the simulation.
var night_pressure: float = 0.0
var threat_pressure: float = 0.0
var cold_pressure: float = 0.0

var _canvas: Control = null
var _vignette_tex: ImageTexture = null
var _sweep_tex: ImageTexture = null

var _wash := LcnImpulse.new(LcnEase.Kind.QUART_OUT)
var _wash_col: Color = Color(1.0, 1.0, 1.0, 0.0)
var _edge := LcnImpulse.new(LcnEase.Kind.QUART_OUT)
var _edge_col: Color = Color(1.0, 1.0, 1.0, 0.0)

var _sweep_active: bool = false
var _sweep_t: float = 0.0
var _sweep_span: float = LcnTiming.EVENT
var _sweep_col: Color = Color(0.043, 0.071, 0.125, 0.85)
var _sweep_down: bool = true

var _draw_us: int = 0


func _ready() -> void:
	name = "FeelScreen"
	layer = LAYER
	follow_viewport_enabled = false
	_vignette_tex = _bake_vignette()
	_sweep_tex = _bake_sweep()
	_canvas = _Canvas.new()
	(_canvas as _Canvas).host = self
	_canvas.name = "FeelScreenCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_canvas)


## A full-frame tint that is at full strength on the frame it is asked for.
## Never use this for anything the player did not cause or the world did not do
## to them — a screen flash is the loudest thing the game can say.
func wash(tint: Color, strength: float, seconds: float = LcnTiming.QUICK) -> void:
	if LcnTiming.reduce_motion():
		return
	_wash_col = tint
	_wash.kick(clampf(strength, 0.0, 1.0), seconds, LcnEase.Kind.QUART_OUT)


## Pressure at the edges of the frame that decays. Use for a one-off alert; use
## the `*_pressure` fields for a state that persists.
func edge_pulse(tint: Color, strength: float, seconds: float = LcnTiming.HEAVY) -> void:
	_edge_col = tint
	_edge.kick(clampf(strength, 0.0, 1.0), seconds, LcnEase.Kind.QUART_OUT)


## The band that crosses the frame. `down` false runs it upward, for dawn.
func sweep(tint: Color, seconds: float = LcnTiming.EVENT, down: bool = true) -> void:
	if LcnTiming.reduce_motion():
		return
	_sweep_col = tint
	_sweep_span = maxf(seconds, 0.2)
	_sweep_t = 0.0
	_sweep_down = down
	_sweep_active = true


func refresh(ui_dt: float) -> void:
	if _sweep_active and LcnTiming.reduce_motion():
		# Turning reduce motion on mid-run has to stop the motion that is already
		# in flight, not only refuse the next one. A player who reaches for that
		# setting is asking for the thing on screen right now to stop.
		_sweep_active = false
	_wash.advance(ui_dt)
	_edge.advance(ui_dt)
	if _sweep_active:
		_sweep_t += ui_dt
		if _sweep_t >= _sweep_span:
			_sweep_active = false
	if _canvas != null:
		_canvas.queue_redraw()


func busy() -> bool:
	return _wash.active() or _edge.active() or _sweep_active \
		or night_pressure > 0.001 or threat_pressure > 0.001 or cold_pressure > 0.001


func stats() -> Dictionary:
	return {
		"wash": snappedf(_wash.value(), 0.001),
		"edge": snappedf(_edge.value(), 0.001),
		"sweep": snappedf(_sweep_t / maxf(_sweep_span, 0.001) if _sweep_active else 0.0, 0.001),
		"night": snappedf(night_pressure, 0.001),
		"threat": snappedf(threat_pressure, 0.001),
		"draw_us": _draw_us,
	}


# --- drawing -------------------------------------------------------------------

func _paint(c: Control) -> void:
	var t0: int = Time.get_ticks_usec()
	var size: Vector2 = c.size
	if size.x <= 0.0:
		size = Vector2(get_viewport().get_visible_rect().size)
	var full := Rect2(Vector2.ZERO, size)

	# 1. persistent edge pressure. Night is cold and comes from everywhere;
	#    threat is hot and comes from the edges harder.
	var night: float = clampf(night_pressure, 0.0, 1.0)
	var threat: float = clampf(threat_pressure, 0.0, 1.0)
	var cold: float = clampf(cold_pressure, 0.0, 1.0)
	if night > 0.002:
		var nc: Color = LcnPalette.COLD_DEEP
		c.draw_texture_rect(_vignette_tex, full, false,
			Color(nc.r, nc.g, nc.b, 0.55 * night))
	if cold > 0.002:
		var ic: Color = LcnPalette.ICE_BLUE
		c.draw_texture_rect(_vignette_tex, full, false,
			Color(ic.r, ic.g, ic.b, 0.22 * cold))
	if threat > 0.002:
		# The threat vignette BREATHES, and it breathes faster the closer the
		# wave is. Nothing else in the frame does that, so it is unmistakable.
		var beat: float = 0.55 + 0.45 * LcnEase.breathe(LcnTiming.ui_now * (0.35 + threat * 1.1))
		var tc: Color = LcnPalette.DANGER
		c.draw_texture_rect(_vignette_tex, full, false,
			Color(tc.r, tc.g, tc.b, 0.34 * threat * beat))

	# 2. the one-off edge pulse
	var e: float = _edge.value()
	if e > 0.002:
		c.draw_texture_rect(_vignette_tex, full, false,
			Color(_edge_col.r, _edge_col.g, _edge_col.b, _edge_col.a * e))

	# 3. the sweep
	if _sweep_active:
		_paint_sweep(c, size)

	# 4. the wash, last, because it is the loudest
	var w: float = _wash.value()
	if w > 0.002:
		c.draw_rect(full, Color(_wash_col.r, _wash_col.g, _wash_col.b, _wash_col.a * w), true)
	_draw_us = Time.get_ticks_usec() - t0


## The band is 55% of the frame tall and travels one and a half frame heights, so
## its trailing edge is still on screen when the leading edge leaves. Position
## rides SINE_IN_OUT: the night does not arrive at constant speed.
func _paint_sweep(c: Control, size: Vector2) -> void:
	var k: float = clampf(_sweep_t / _sweep_span, 0.0, 1.0)
	var e: float = LcnEase.apply(LcnEase.Kind.SINE_IN_OUT, k)
	var band: float = size.y * 0.72
	var y: float = lerpf(-band, size.y, e) if _sweep_down else lerpf(size.y, -band, e)
	# Fade the band in and out at the ends of its travel so it does not pop.
	var a: float = LcnEase.apply(LcnEase.Kind.PULSE, k)
	var col := Color(_sweep_col.r, _sweep_col.g, _sweep_col.b, _sweep_col.a * a)
	var rect := Rect2(Vector2(0.0, y), Vector2(size.x, band))
	if not _sweep_down:
		# Flip the gradient with the direction so the soft edge always leads.
		c.draw_set_transform(Vector2(0.0, y + band), 0.0, Vector2(1.0, -1.0))
		c.draw_texture_rect(_sweep_tex, Rect2(Vector2.ZERO, Vector2(size.x, band)), false, col)
		c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	c.draw_texture_rect(_sweep_tex, rect, false, col)


# --- baked gradients -----------------------------------------------------------

## A radial alpha ramp: transparent in the middle, opaque at the corners.
## Baked once at 64x64 and stretched; a vignette has no detail to lose.
func _bake_vignette() -> ImageTexture:
	var img := Image.create(VIGNETTE_PX, VIGNETTE_PX, false, Image.FORMAT_RGBA8)
	var half: float = float(VIGNETTE_PX) * 0.5
	for y: int in VIGNETTE_PX:
		for x: int in VIGNETTE_PX:
			var d: float = Vector2((float(x) - half) / half, (float(y) - half) / half).length()
			# Starts at 42% of the way out, so the readable centre stays clean.
			var a: float = LcnEase.apply(LcnEase.Kind.QUAD_IN,
				clampf((d - 0.42) / 0.72, 0.0, 1.0))
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


## A vertical ramp that reaches zero at BOTH ends and is densest just behind the
## leading edge. The first version ramped 0 -> 1 top to bottom, which put a hard
## horizontal line across the whole frame at the band's leading edge and read as
## a rendering bug rather than as weather. A sweep must have no edges at all.
func _bake_sweep() -> ImageTexture:
	var img := Image.create(4, SWEEP_PX, false, Image.FORMAT_RGBA8)
	for y: int in SWEEP_PX:
		var t: float = float(y) / float(SWEEP_PX - 1)
		var a: float = pow(sin(t * PI), 0.75) * (0.28 + 0.72 * t)
		for x: int in 4:
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


## The drawing surface. A separate class rather than a script on the CanvasLayer
## because CanvasLayer is not a CanvasItem and cannot draw.
class _Canvas extends Control:
	var host: LcnFeelScreenFx = null

	func _draw() -> void:
		if host != null:
			host._paint(self)
