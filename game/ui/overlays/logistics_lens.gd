class_name LcnLogisticsLens
extends LcnOverlayLayer
## [P19] Lens 5 — WHAT IS MOVING, WHAT IS STUCK, AND WHAT IS EMPTY.
##
## [P03] logistics and [P04] production are being written in parallel with this
## part, so this lens is built against a duck-typed contract (see
## LcnOverlayProbe) and is honest when nobody answers it: it says so on screen,
## in words, instead of showing an empty overlay that looks like "everything is
## fine".
##
## What it always has, because [P02] owns it: FUEL. Every burner has a bunker,
## a burn rate and a fuel factor, and a generator running its bunker dry is the
## most common silent failure in the game — the network browns out and every
## downstream lens blames the pipes. So the fuel read is first-class here.
##
## What it adds the moment a belt system exists:
##   * belt tiles tinted by saturation, Factorio-style: empty is dim, saturated
##     is hot, and a backed-up run is unmistakable
##   * a direction chevron per belt tile
##   * a ring and a reason on every stalled machine

const BUNKER_LOW: float = 0.25
const MAX_STALL_LABELS: int = 10

var _belts: PackedVector2Array = PackedVector2Array()
var _belt_cols: PackedColorArray = PackedColorArray()
var _rings: PackedVector2Array = PackedVector2Array()
var _ring_cols: PackedColorArray = PackedColorArray()


func _init() -> void:
	super()
	name = "LogisticsLens"


func _draw() -> void:
	if snap == null:
		return
	var t0: int = Time.get_ticks_usec()
	_belts.clear()
	_belt_cols.clear()
	_rings.clear()
	_ring_cols.clear()
	draw_rect(view.grow(TILE * 2.0), Color(0.02, 0.03, 0.05, 0.34), true)
	_draw_belts()
	_draw_stalls()
	_draw_fuel()
	if _belts.size() >= 2:
		draw_multiline_colors(_belts, _belt_cols, stroke(2.4))
	if _rings.size() >= 2:
		draw_multiline_colors(_rings, _ring_cols, stroke(2.4))
	flush_labels()
	draw_us = Time.get_ticks_usec() - t0


func _draw_belts() -> void:
	var probe: LcnOverlayProbe = snap.probe
	if not probe.has_logistics():
		return
	var phase: float = 0.0 if pal.reduce_motion else time_s * 40.0
	for b: Dictionary in probe.belts():
		var cell: Vector2i = b["cell"]
		var r := Rect2(Vector2(cell) * TILE, Vector2(TILE, TILE))
		if not visible_rect(r):
			continue
		var load: float = float(b["load"])
		var stuck: bool = bool(b["stalled"]) or bool(b["backed_up"])
		var c: Color = pal.good().lerp(pal.warn(), load)
		if stuck:
			c = pal.bad()
		draw_rect(r, LcnOverlayPalette.with_a(c, pal.fill(0.10 + 0.28 * load)), true)
		var dir: int = int(b["dir"])
		if dir < 0 or dir > 3:
			continue
		var centre: Vector2 = r.get_center()
		var to: Vector2 = centre + Vector2(LcnOverlayDefs.DIR_VECTORS[dir]) * TILE * 0.5
		var before: int = _belts.size()
		if stuck or pal.reduce_motion:
			LcnOverlayGeometry.arrow(to, to - centre, px(6.0), _belts)
		else:
			LcnOverlayGeometry.dashes(centre - (to - centre), to, 6.0, 7.0, phase * load, _belts)
		for _k: int in (_belts.size() - before) / 2:
			_belt_cols.append(LcnOverlayPalette.with_a(c, 0.95))


func _draw_stalls() -> void:
	var probe: LcnOverlayProbe = snap.probe
	if not probe.has_stalls():
		return
	var beat: float = LcnOverlayGeometry.pulse(time_s, 1.0, pal.reduce_motion)
	var labels: int = 0
	for s: Dictionary in probe.stalls():
		var row: int = snap.bld_row.get(int(s.get("id", -1)), -1)
		if row < 0:
			continue
		var r: Rect2 = snap.bld_rect(row)
		if not visible_rect(r):
			continue
		LcnOverlayGeometry.box(r.grow(px(2.0 + 3.0 * beat)), _rings)
		for _k: int in 4:
			_ring_cols.append(LcnOverlayPalette.with_a(pal.bad(), 0.55 + 0.45 * beat))
		if labels < MAX_STALL_LABELS:
			labels += 1
			word(r.position + Vector2(0.0, -px(20.0)),
				String(s.get("reason", "stalled")).to_upper(), 14.0, pal.bad(),
				LcnLabelField.Rank.VERDICT, 2, "stall")


## Fuel is logistics whether or not a belt exists: a burner with an empty bunker
## takes its whole network down and blames the pipes on every other lens.
func _draw_fuel() -> void:
	var shown: int = 0
	for i: int in snap.node_count:
		if (snap.node_flags[i] & LcnOverlayDefs.F_PRODUCER) == 0:
			continue
		var r: Rect2 = snap.node_rect(i)
		if not visible_rect(r):
			continue
		var fuel: float = snap.node_fuel[i]
		var starved: bool = (snap.node_flags[i] & LcnOverlayDefs.F_STARVED_FUEL) != 0
		shown += 1
		var bar := Rect2(r.position + Vector2(px(2.0), r.size.y + px(3.0)),
			Vector2(r.size.x - px(4.0), px(6.0)))
		draw_rect(bar, Color(0.05, 0.06, 0.09, 0.9), true)
		var c: Color = pal.good()
		if starved or fuel <= 0.02:
			c = pal.bad()
		elif fuel < BUNKER_LOW:
			c = pal.warn()
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * maxf(fuel, 0.02), bar.size.y)), c, true)
		LcnOverlayGeometry.box(bar, _rings)
		for _k: int in 4:
			_ring_cols.append(LcnOverlayPalette.with_a(LcnOverlayPalette.INK_DIM, 0.5))
		if starved and shown <= 8:
			word(r.position + Vector2(0.0, -px(20.0)), "OUT OF FUEL", 14.0, pal.bad(),
				LcnLabelField.Rank.VERDICT, 2, "", true)
		elif alt:
			word(bar.position + Vector2(0.0, px(16.0)), "fuel %d%%" % int(fuel * 100.0),
				12.0, LcnOverlayPalette.INK_DIM, LcnLabelField.Rank.AMBIENT, 6, "fuel")
