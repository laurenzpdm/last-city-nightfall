class_name LcnFreezeLens
extends LcnOverlayLayer
## [P19] Lens 4 — HOW COLD IS EVERY BUILDING, AND HOW LONG HAS IT GOT.
##
## The thermal model gives each building an internal temperature that chases the
## warmth it receives, a freeze threshold, a hold time before the freeze
## actually lands, and a thaw margin. Losing a generator to the cold takes a
## network down with it, so "which building is closest to the line" is a real
## tactical question — and until now the only way to answer it was to watch a
## building die.
##
## Each building gets a thermometer scaled to ITS OWN freeze threshold (a pipe
## and a workshop do not freeze at the same temperature), a countdown derived
## from the measured cooling rate between two samples, and a hatch when it has
## already gone. Structural damage rides along on the same lens because the two
## failures look identical from across the map and are not.

const COLD_HEADROOM: float = 8.0     ## degrees below the line the gauge shows
const WARM_HEADROOM: float = 26.0    ## degrees above the line the gauge shows
const ALARM_SECONDS: float = 90.0    ## below this ETA the building starts shouting
const MAX_COUNTDOWNS: int = 14
## Anything colder than this never "freezes" — pipes and tanks are passive.
const PASSIVE_LINE: float = -50.0

var _hatch: PackedVector2Array = PackedVector2Array()
var _rings: PackedVector2Array = PackedVector2Array()
var _ring_cols: PackedColorArray = PackedColorArray()


func _init() -> void:
	super()
	name = "FreezeLens"


func _draw() -> void:
	if snap == null:
		return
	var t0: int = Time.get_ticks_usec()
	_hatch.clear()
	_rings.clear()
	_ring_cols.clear()
	draw_rect(view.grow(TILE * 2.0), Color(0.02, 0.035, 0.06, 0.30), true)
	_draw_buildings()
	_draw_damage()
	_flush()
	draw_us = Time.get_ticks_usec() - t0


func _draw_buildings() -> void:
	var beat: float = LcnOverlayGeometry.pulse(time_s, 0.9, pal.reduce_motion)
	var countdowns: int = 0
	var gauges: int = 0
	for i: int in snap.node_count:
		var r: Rect2 = snap.node_rect(i)
		if not visible_rect(r):
			continue
		var line: float = snap.node_freeze[i]
		var temp: float = snap.node_temp[i]
		var frozen: bool = (snap.node_flags[i] & LcnOverlayDefs.F_FROZEN) != 0
		var active: bool = line > PASSIVE_LINE

		if frozen:
			LcnOverlayGeometry.hatch(r, px(7.0), _hatch)
			draw_rect(r, LcnOverlayPalette.with_a(pal.ice(), pal.fill(0.20)), true)
			LcnOverlayGeometry.box(r.grow(px(2.0 + 3.0 * beat)), _rings)
			for _k: int in 4:
				_ring_cols.append(LcnOverlayPalette.with_a(pal.ice(), 0.95))
			plate(r.position + Vector2(0.0, -px(20.0)), "FROZEN  %.0f C" % temp, 14.0, pal.ice())
			continue
		if not active:
			continue

		# The gauge. Scaled to this building's own threshold, so the zero point
		# on every bar means the same thing: "this one is about to stop".
		if gauges < 220 and wpp < 2.2:
			gauges += 1
			_gauge(r, temp, line)

		var eta: float = snap.freeze_eta(i)
		if eta >= 0.0 and eta < ALARM_SECONDS:
			var urgency: float = 1.0 - clampf(eta / ALARM_SECONDS, 0.0, 1.0)
			var c: Color = pal.warn().lerp(pal.bad(), urgency)
			LcnOverlayGeometry.box(r.grow(px(2.0 + 4.0 * beat * urgency)), _rings)
			for _k2: int in 4:
				_ring_cols.append(LcnOverlayPalette.with_a(c, 0.6 + 0.4 * beat))
			if countdowns < MAX_COUNTDOWNS:
				countdowns += 1
				plate(r.position + Vector2(0.0, -px(20.0)),
					"freezes in %ds" % maxi(1, int(round(eta))), 14.0, c)
		elif alt:
			label(r.position + Vector2(px(2.0), -px(6.0)), "%.0f C" % temp, 13.0, LcnOverlayPalette.INK_DIM)


## A vertical thermometer against the building's own freeze line. The tick mark
## IS the line; the fill is where the building currently sits.
func _gauge(r: Rect2, temp: float, line: float) -> void:
	var h: float = px(34.0)
	var w: float = px(5.0)
	var pos := Vector2(r.position.x - px(9.0), r.position.y + (r.size.y - h) * 0.5)
	var track := Rect2(pos, Vector2(w, h))
	draw_rect(track, Color(0.04, 0.055, 0.085, 0.9), true)
	var lo: float = line - COLD_HEADROOM
	var hi: float = line + WARM_HEADROOM
	var t: float = clampf((temp - lo) / maxf(1.0, hi - lo), 0.0, 1.0)
	var fill_h: float = h * t
	draw_rect(Rect2(Vector2(pos.x, pos.y + h - fill_h), Vector2(w, fill_h)),
		pal.thermal_color(temp), true)
	# The freeze line itself, drawn across the gauge.
	var ly: float = pos.y + h - h * clampf((line - lo) / maxf(1.0, hi - lo), 0.0, 1.0)
	draw_line(Vector2(pos.x - px(2.0), ly), Vector2(pos.x + w + px(2.0), ly),
		LcnOverlayPalette.with_a(pal.bad(), 0.95), stroke(1.6))


## Structural damage shares this lens: from across the map a burning workshop
## and a frozen one look the same, and they are not the same problem.
func _draw_damage() -> void:
	var shown: int = 0
	for i: int in snap.bld_count:
		if shown >= 60:
			break
		var hp: float = snap.bld_hp[i]
		# A ghost is not a wreck: construction sites start below full hp on
		# purpose, and a damage bar on every one of them is a lie.
		if hp >= 0.999 or (snap.bld_flags[i] & LcnOverlaySnapshot.B_GHOST) != 0:
			continue
		var r: Rect2 = snap.bld_rect(i)
		if not visible_rect(r):
			continue
		shown += 1
		var bar := Rect2(r.position + Vector2(0.0, r.size.y + px(2.0)),
			Vector2(r.size.x, px(4.0)))
		draw_rect(bar, Color(0.05, 0.06, 0.09, 0.9), true)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * hp, bar.size.y)),
			pal.bad() if hp < 0.4 else pal.warn(), true)
		if hp < 0.45 and alt:
			label(bar.position + Vector2(0.0, px(13.0)), "%d%% hp" % int(hp * 100.0),
				13.0, pal.bad())


func _flush() -> void:
	if _hatch.size() >= 2:
		var hc := PackedColorArray()
		hc.resize(_hatch.size() / 2)
		hc.fill(LcnOverlayPalette.with_a(pal.ice(), 0.55))
		draw_multiline_colors(_hatch, hc, stroke(1.3))
	if _rings.size() >= 2:
		draw_multiline_colors(_rings, _ring_cols, stroke(2.4))
