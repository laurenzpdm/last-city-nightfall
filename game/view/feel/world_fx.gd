class_name LcnFeelWorldFx
extends Node2D
## The world-space effect layer. [P15]
##
## One Node2D, one `_draw`, one pooled array. Every puff of dust, every spark,
## every ring and every piece of debris in the game is drawn from here, in world
## coordinates, so the camera moves it and [P13]'s post stack grades it. It sits
## at z 5: above the entity main pass (z 0) so a puff reads over the building it
## came from, below the placement ghost (z 60) so it never obscures the thing the
## player is aiming.
##
## THE COST RULE. This layer is allowed one millisecond and gets nowhere near
## it. Everything is culled against the view rect before a single primitive is
## issued, the pool is fixed at construction, and no effect may live longer than
## LcnTiming.MAX_EFFECT_LIFE. `stats()` reports what it actually spent so the
## claim is a measurement, not a promise.

const Z: int = 5
## Effects are culled this far outside the view, so one that spawned just off
## screen still drifts in rather than popping.
const CULL_MARGIN: float = 96.0

var pool: LcnFxPool = null
var view_rect: Rect2 = Rect2(Vector2(-1.0e6, -1.0e6), Vector2(2.0e6, 2.0e6))
## The hour's colour grade from [P13], so a spark at dusk is not the same spark
## as a spark at noon. Empty is fine; the effects fall back to their own colour.
var grade: Dictionary = {}
var zoom: float = 1.0

var _now: float = 0.0
var _drawn: int = 0
var _draw_us: int = 0


func _init(capacity: int = 256) -> void:
	pool = LcnFxPool.new(capacity)


func _ready() -> void:
	name = "FeelWorldFx"
	z_index = Z
	z_as_relative = false
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


## Called once per frame by LcnFeel before the redraw.
func refresh(now: float, view: Rect2, day_grade: Dictionary, camera_zoom: float) -> void:
	_now = now
	view_rect = view
	grade = day_grade
	zoom = maxf(0.01, camera_zoom)
	pool.prune(now)
	queue_redraw()


func stats() -> Dictionary:
	return {
		"alive": pool.count(),
		"drawn": _drawn,
		"draw_us": _draw_us,
		"spawned": pool.spawned,
		"dropped": pool.dropped,
	}


# --- spawning ------------------------------------------------------------------
#
# Every spawner is a one-liner for the caller and does its own budget thinking,
# so a Bus handler running inside a simulation tick stays a few float writes.

## A soft ground puff. The workhorse: placement, impact, collapse, footfall.
func dust(at: Vector2, amount: float = 1.0, tint: Color = Color(0.78, 0.82, 0.88, 0.55)) -> void:
	var n: int = clampi(int(round(3.0 + amount * 5.0)), 2, 10)
	for i: int in n:
		var a: float = float(i) / float(n) * TAU + amount
		var speed: float = 16.0 + 26.0 * amount
		var v := Vector2(cos(a), sin(a) * 0.55) * speed
		pool.spawn(LcnFxPool.Kind.DUST, at, v,
			LcnTiming.SETTLE + 0.22 * amount, 5.0 + 9.0 * amount, tint,
			0.0, 0.0, float(i) + at.x)


## An expanding outline. `weight` 0..1 makes it thicker, slower and brighter.
func ring(at: Vector2, radius: float, tint: Color, weight: float = 0.5,
		seconds: float = LcnTiming.SETTLE) -> void:
	pool.spawn(LcnFxPool.Kind.RING, at, Vector2.ZERO, seconds, radius, tint,
		clampf(weight, 0.0, 1.0), 0.0, at.x + at.y)


## Grit thrown off an impact. Streaks with gravity, so it reads as matter.
func sparks(at: Vector2, count: int, tint: Color, spread: Vector2 = Vector2.ZERO,
		speed: float = 130.0) -> void:
	var n: int = clampi(count, 1, 14)
	for i: int in n:
		var base: float = spread.angle() if spread != Vector2.ZERO else -PI * 0.5
		var a: float = base + (float(i) / float(n) - 0.5) * 2.2
		var s: float = speed * (0.55 + 0.45 * float((i * 7919) % 100) / 100.0)
		pool.spawn(LcnFxPool.Kind.SPARK, at, Vector2(cos(a), sin(a)) * s,
			LcnTiming.QUICK + 0.14, 7.0, tint, 0.0, 0.0, float(i * 31) + at.y)


## A filled rectangle that fades. Completion, damage, a muzzle.
func flash(at: Vector2, size: Vector2, tint: Color,
		seconds: float = LcnTiming.QUICK) -> void:
	pool.spawn(LcnFxPool.Kind.FLASH, at, Vector2.ZERO, seconds, size.x, tint,
		size.y, 0.0, at.x)


## Warm motes that rise and wink out. Death, fire, the hearth breathing out.
func embers(at: Vector2, count: int, tint: Color, rise: float = 42.0) -> void:
	var n: int = clampi(count, 1, 12)
	for i: int in n:
		var side: float = (float(i) / float(n) - 0.5) * 26.0
		pool.spawn(LcnFxPool.Kind.EMBER, at + Vector2(side, 0.0),
			Vector2(side * 0.35, -rise * (0.7 + 0.5 * float(i % 5) / 5.0)),
			LcnTiming.HEAVY + 0.5, 3.0, tint, 0.0, 0.0, float(i * 613) + at.x)


## Debris. Spins, falls, lands. The difference between a building being removed
## and a building being DESTROYED.
func shards(at: Vector2, count: int, tint: Color, force: float = 120.0) -> void:
	var n: int = clampi(count, 1, 12)
	for i: int in n:
		var a: float = float(i) / float(n) * TAU
		pool.spawn(LcnFxPool.Kind.SHARD, at,
			Vector2(cos(a), sin(a) * 0.6 - 0.9) * force,
			LcnTiming.HEAVY + 0.25, 6.0 + 4.0 * float(i % 3), tint,
			0.0, 0.0, float(i * 977) + at.y)


## A cold bloom. Reserved for freezing, so the player learns the shape.
func frost(at: Vector2, radius: float, tint: Color) -> void:
	pool.spawn(LcnFxPool.Kind.FROST, at, Vector2.ZERO, LcnTiming.EVENT * 0.4,
		radius, tint, 0.0, 0.0, at.x - at.y)


## A shot. Fades from the muzzle end first, so the eye follows it outward.
func tracer(from: Vector2, to: Vector2, tint: Color,
		seconds: float = LcnTiming.FLICK + 0.04) -> void:
	pool.spawn(LcnFxPool.Kind.TRACER, from, to - from, seconds, 2.0, tint)


## The confirmation that a placement took: a rect that snaps inward onto the
## footprint. It is the single most important effect in the file, because it is
## the one the player causes by hand and the one that says "yes, that happened".
func stamp(rect: Rect2, tint: Color) -> void:
	pool.spawn(LcnFxPool.Kind.STAMP, rect.position, Vector2.ZERO,
		LcnTiming.SETTLE, rect.size.x, tint, rect.size.y, 0.0, rect.position.x)


# --- drawing -------------------------------------------------------------------

func _draw() -> void:
	var t0: int = Time.get_ticks_usec()
	_drawn = 0
	if pool.count() == 0:
		_draw_us = 0
		return
	var cull: Rect2 = view_rect.grow(CULL_MARGIN)
	# The hour's key light, used to keep every effect inside [P13]'s palette
	# instead of glowing the same white at midnight and at noon.
	var key: Color = Color(1.0, 1.0, 1.0, 1.0)
	if grade.has("sun_col"):
		key = (grade["sun_col"] as Color).lerp(Color.WHITE, 0.45)

	for i: int in pool.capacity:
		if not pool.alive_at(i):
			continue
		var p: Vector2 = pool.position_at(i)
		if not cull.has_point(p):
			# TRACER carries its far end in the velocity field, so it can be
			# on screen with its origin off it.
			if pool.kind_at(i) != int(LcnFxPool.Kind.TRACER):
				continue
			if not cull.has_point(p + pool.velocity_at(i)):
				continue
		var k: float = pool.age01(i, _now)
		_drawn += 1
		match pool.kind_at(i):
			int(LcnFxPool.Kind.DUST): _draw_dust(i, p, k)
			int(LcnFxPool.Kind.RING): _draw_ring(i, p, k)
			int(LcnFxPool.Kind.SPARK): _draw_spark(i, p, k, key)
			int(LcnFxPool.Kind.FLASH): _draw_flash(i, p, k)
			int(LcnFxPool.Kind.EMBER): _draw_ember(i, p, k, key)
			int(LcnFxPool.Kind.SHARD): _draw_shard(i, p, k)
			int(LcnFxPool.Kind.FROST): _draw_frost(i, p, k)
			int(LcnFxPool.Kind.TRACER): _draw_tracer(i, p, k, key)
			int(LcnFxPool.Kind.STAMP): _draw_stamp(i, p, k)
	_draw_us = Time.get_ticks_usec() - t0


## Dust expands fast and stops, exactly like real dust: EXPO_OUT on the radius,
## QUAD_IN on the fade so it lingers before it goes.
func _draw_dust(i: int, p: Vector2, k: float) -> void:
	var col: Color = pool.color_at(i)
	var grow: float = LcnEase.apply(LcnEase.Kind.EXPO_OUT, k)
	var pos: Vector2 = p + pool.velocity_at(i) * grow * 0.5
	var r: float = pool.field(i, LcnFxPool.F_SIZE) * (0.35 + grow * 1.25)
	col.a *= 1.0 - LcnEase.apply(LcnEase.Kind.QUAD_IN, k)
	draw_circle(pos, r, col)


## The ring is drawn twice: a bright thin edge and a wide soft halo behind it,
## because one circle at one width reads as a UI element and two read as light.
func _draw_ring(i: int, p: Vector2, k: float) -> void:
	var col: Color = pool.color_at(i)
	var weight: float = pool.field(i, LcnFxPool.F_P0)
	var grow: float = LcnEase.apply(LcnEase.Kind.EXPO_OUT, k)
	var r: float = pool.field(i, LcnFxPool.F_SIZE) * (0.18 + grow * 0.92)
	var fade: float = 1.0 - LcnEase.apply(LcnEase.Kind.CUBIC_OUT, k)
	var edge: Color = Color(col.r, col.g, col.b, col.a * fade)
	var halo: Color = Color(col.r, col.g, col.b, col.a * fade * 0.28)
	draw_arc(p, r + 2.0, 0.0, TAU, 20, halo, 3.0 + 5.0 * weight, true)
	draw_arc(p, r, 0.0, TAU, 20, edge, 1.0 + 2.0 * weight, true)


func _draw_spark(i: int, p: Vector2, k: float, key: Color) -> void:
	var col: Color = pool.color_at(i).lerp(key, 0.25)
	var v: Vector2 = pool.velocity_at(i)
	var travel: float = LcnEase.apply(LcnEase.Kind.EXPO_OUT, k)
	var gravity: float = 220.0 * k * k
	var pos: Vector2 = p + v * travel * 0.32 + Vector2(0.0, gravity * 0.32)
	var tail: Vector2 = v.normalized() * pool.field(i, LcnFxPool.F_SIZE) * (1.0 - k)
	col.a *= 1.0 - LcnEase.apply(LcnEase.Kind.QUART_OUT, k)
	draw_line(pos, pos - tail, col, 1.6, true)


## IMPACT envelope: full on the frame it exists, then gone. A flash that fades in
## is not a flash.
func _draw_flash(i: int, p: Vector2, k: float) -> void:
	var col: Color = pool.color_at(i)
	var w: float = pool.field(i, LcnFxPool.F_SIZE)
	var h: float = pool.field(i, LcnFxPool.F_P0)
	var a: float = LcnEase.apply(LcnEase.Kind.IMPACT, k)
	var swell: float = 1.0 + 0.16 * (1.0 - a)
	var size := Vector2(w, h) * swell
	draw_rect(Rect2(p - size * 0.5, size), Color(col.r, col.g, col.b, col.a * a), true)


func _draw_ember(i: int, p: Vector2, k: float, key: Color) -> void:
	var col: Color = pool.color_at(i).lerp(key, 0.15)
	var rise: float = LcnEase.apply(LcnEase.Kind.SINE_OUT, k)
	var sway: float = pool.wobble(i, 3) * 7.0 * sin(k * 7.0 + pool.field(i, LcnFxPool.F_SEED))
	var pos: Vector2 = p + pool.velocity_at(i) * rise + Vector2(sway, 0.0)
	# Embers do not fade out, they wink: a spiked flicker on top of the decay is
	# the whole difference between an ember and a dot.
	var flick: float = 0.62 + 0.38 * sin(k * 34.0 + pool.field(i, LcnFxPool.F_SEED))
	col.a *= (1.0 - LcnEase.apply(LcnEase.Kind.QUAD_IN, k)) * flick
	var r: float = pool.field(i, LcnFxPool.F_SIZE) * (1.0 - 0.5 * k)
	draw_circle(pos, r * 2.2, Color(col.r, col.g, col.b, col.a * 0.22))
	draw_circle(pos, r, col)


func _draw_shard(i: int, p: Vector2, k: float) -> void:
	var col: Color = pool.color_at(i)
	var v: Vector2 = pool.velocity_at(i)
	var fly: float = LcnEase.apply(LcnEase.Kind.CUBIC_OUT, k)
	var pos: Vector2 = p + v * fly * 0.42 + Vector2(0.0, 300.0 * k * k * 0.42)
	var s: float = pool.field(i, LcnFxPool.F_SIZE) * (1.0 - 0.35 * k)
	var spin: float = pool.wobble(i, 5) * 9.0 * k + pool.field(i, LcnFxPool.F_SEED)
	col.a *= 1.0 - LcnEase.apply(LcnEase.Kind.QUAD_IN, k)
	var pts := PackedVector2Array([
		pos + Vector2(cos(spin), sin(spin)) * s,
		pos + Vector2(cos(spin + 2.2), sin(spin + 2.2)) * s * 0.8,
		pos + Vector2(cos(spin + 4.3), sin(spin + 4.3)) * s * 0.9,
	])
	draw_colored_polygon(pts, col)


## A hexagon, not a circle. Freezing is the one state that must be identifiable
## from its silhouette at strategic zoom.
func _draw_frost(i: int, p: Vector2, k: float) -> void:
	var col: Color = pool.color_at(i)
	var grow: float = LcnEase.apply(LcnEase.Kind.EXPO_OUT, k)
	var r: float = pool.field(i, LcnFxPool.F_SIZE) * (0.3 + grow * 0.85)
	col.a *= 1.0 - LcnEase.apply(LcnEase.Kind.CUBIC_IN_OUT, k)
	var pts := PackedVector2Array()
	for c: int in 7:
		var a: float = float(c) / 6.0 * TAU - PI * 0.5
		pts.append(p + Vector2(cos(a), sin(a) * 0.62) * r)
	draw_polyline(pts, col, 2.0, true)


func _draw_tracer(i: int, p: Vector2, k: float, key: Color) -> void:
	var col: Color = pool.color_at(i).lerp(key, 0.3)
	var to: Vector2 = p + pool.velocity_at(i)
	var a: float = LcnEase.apply(LcnEase.Kind.IMPACT, k)
	# The muzzle end retracts as it fades, so the shot reads as travelling out.
	var head: Vector2 = p.lerp(to, LcnEase.apply(LcnEase.Kind.QUAD_IN, k) * 0.55)
	draw_line(head, to, Color(col.r, col.g, col.b, col.a * a), 2.0, true)
	draw_line(head, to, Color(col.r, col.g, col.b, col.a * a * 0.25), 5.0, true)


## SETTLE, from 1.9x the footprint down onto it, with the corner brackets
## reaching in last. This is the placement's whole personality.
func _draw_stamp(i: int, p: Vector2, k: float) -> void:
	var col: Color = pool.color_at(i)
	var size := Vector2(pool.field(i, LcnFxPool.F_SIZE), pool.field(i, LcnFxPool.F_P0))
	var e: float = LcnEase.apply(LcnEase.Kind.SETTLE, k)
	var scale_now: float = lerpf(1.9, 1.0, e)
	var centre: Vector2 = p + size * 0.5
	var s: Vector2 = size * scale_now
	var r := Rect2(centre - s * 0.5, s)
	var fade: float = 1.0 - LcnEase.apply(LcnEase.Kind.QUAD_IN, k)
	draw_rect(r, Color(col.r, col.g, col.b, col.a * fade * 0.16), true)
	# Corner brackets rather than a full outline: a closed rectangle reads as a
	# selection box, four corners read as something being set down.
	var arm: float = minf(s.x, s.y) * 0.32
	var edge := Color(col.r, col.g, col.b, col.a * fade)
	var corners: Array[Vector2] = [
		r.position, r.position + Vector2(s.x, 0.0),
		r.position + Vector2(0.0, s.y), r.position + s,
	]
	var dirs: Array[Vector2] = [
		Vector2(1.0, 1.0), Vector2(-1.0, 1.0), Vector2(1.0, -1.0), Vector2(-1.0, -1.0),
	]
	for c: int in 4:
		var o: Vector2 = corners[c]
		var d: Vector2 = dirs[c]
		draw_line(o, o + Vector2(arm * d.x, 0.0), edge, 2.0, true)
		draw_line(o, o + Vector2(0.0, arm * d.y), edge, 2.0, true)
