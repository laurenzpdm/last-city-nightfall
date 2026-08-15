class_name LcnHeatNetworkLens
extends LcnOverlayLayer
## [P19] Lens 1 — WHICH GRID IS WHICH, AND WHERE THE HEAT IS GOING.
##
## The one question this lens exists to answer in half a second: *are these two
## halves of my base on the same grid?* Every network gets its own hue AND its
## own dash pattern, its own badge with its own balance sheet, and its pipes
## animate in the direction the solver is actually pushing heat. Two colours on
## screen means two grids, and two grids means the hearth on the left is not
## feeding the houses on the right — which is the single most common thing a new
## player gets wrong and the hardest thing to see without a lens.
##
## Everything drawn here comes out of the solver's own routing tree:
##   * the flow arrows follow parent -> child in the BFS, not a guess
##   * the pipe brightness is throughput / capacity on that tile
##   * a pipe the router could not reach from any live source is drawn dead grey
##     and hatched, which is what "you built a spur off nothing" looks like

const FLOW_SPEED: float = 46.0        ## world px per second the dashes travel
const WIDTH_BUCKETS: Array[float] = [2.6, 3.8, 5.2, 7.0]
const BADGE_LIMIT: int = 10

var _bucket_pts: Array[PackedVector2Array] = []
var _bucket_cols: Array[PackedColorArray] = []
var _flow: PackedVector2Array = PackedVector2Array()
var _flow_cols: PackedColorArray = PackedColorArray()
var _dead: PackedVector2Array = PackedVector2Array()


func _init() -> void:
	super()
	name = "HeatNetworkLens"
	for i: int in WIDTH_BUCKETS.size():
		_bucket_pts.append(PackedVector2Array())
		_bucket_cols.append(PackedColorArray())


func _draw() -> void:
	if snap == null or snap.node_count == 0:
		return
	var t0: int = Time.get_ticks_usec()
	for i: int in WIDTH_BUCKETS.size():
		_bucket_pts[i].clear()
		_bucket_cols[i].clear()
	_flow.clear()
	_flow_cols.clear()
	_dead.clear()

	_draw_tiles()
	_draw_spines()
	_draw_flow()
	_draw_badges()
	draw_us = Time.get_ticks_usec() - t0


## The claim layer: a translucent wash over every tile a network owns, so the
## SHAPE of a grid is readable even where no pipe is drawn (generators, tanks,
## radiators). Kept under 25% alpha — the building underneath must stay visible.
func _draw_tiles() -> void:
	var wash_ok: bool = wpp < 3.0   # below strategic zoom the wash turns to mud
	for i: int in snap.node_count:
		var r: Rect2 = snap.node_rect(i)
		if not visible_rect(r):
			continue
		var slot: int = snap.node_slot[i]
		var flags: int = snap.node_flags[i]
		var dead: bool = (flags & LcnOverlayDefs.F_UNREACHABLE) != 0 or slot < 0
		var c: Color = pal.void_color() if dead else pal.network_color(slot)
		if wash_ok:
			var a: float = 0.16 + 0.20 * snap.node_load[i]
			if (flags & LcnOverlayDefs.F_CONDUIT) == 0:
				a = 0.20
			if dead:
				a = 0.24
			draw_rect(r, LcnOverlayPalette.with_a(c, pal.fill(a)), true)
		if dead:
			LcnOverlayGeometry.hatch(r.grow(-px(1.0)), px(6.0), _dead)
			continue
		if (flags & LcnOverlayDefs.F_CONDUIT) == 0:
			# A source, a tank or a consumer: bracket it in its grid's colour so
			# membership is legible without covering the art.
			var pts := PackedVector2Array()
			LcnOverlayGeometry.brackets(r.grow(-px(1.5)), px(7.0), pts)
			push_lines(pts, LcnOverlayPalette.with_a(c, 0.95))
	flush_lines(stroke(2.0))
	if _dead.size() >= 2:
		var grey: PackedColorArray = PackedColorArray()
		grey.resize(_dead.size() / 2)
		grey.fill(LcnOverlayPalette.with_a(pal.void_color(), 0.55))
		draw_multiline_colors(_dead, grey, stroke(1.2))


## The spine: half-tile stubs from each conduit centre toward every neighbour it
## is wired to. Width is bucketed into four classes so the whole city is four
## draw calls instead of one per pipe, and the class IS the throughput read.
func _draw_spines() -> void:
	for i: int in snap.node_count:
		var flags: int = snap.node_flags[i]
		if (flags & LcnOverlayDefs.F_CONDUIT) == 0:
			continue
		if (flags & LcnOverlayDefs.F_UNREACHABLE) != 0:
			continue
		var r: Rect2 = snap.node_rect(i)
		if not visible_rect(r.grow(TILE)):
			continue
		var links: int = snap.node_link[i]
		var slot: int = snap.node_slot[i]
		var load: float = snap.node_load[i]
		var b: int = clampi(int(load * float(WIDTH_BUCKETS.size())), 0, WIDTH_BUCKETS.size() - 1)
		var base: Color = pal.network_color(slot)
		# A saturated pipe burns toward white: "this line is the limit" has to be
		# visible without reading a number.
		var c: Color = base.lerp(Color(1.0, 1.0, 1.0), load * 0.45)
		if (flags & LcnOverlayDefs.F_FROZEN) != 0 or (flags & LcnOverlayDefs.F_DISABLED) != 0:
			c = pal.void_color()
		if (flags & LcnOverlayDefs.F_CHOKED) != 0:
			c = pal.bad()
			b = WIDTH_BUCKETS.size() - 1
		var centre: Vector2 = snap.node_center(i)
		var pts: PackedVector2Array = _bucket_pts[b]
		var cols: PackedColorArray = _bucket_cols[b]
		for d: int in 4:
			if (links & (1 << d)) == 0:
				continue
			var dv2 := Vector2(LcnOverlayDefs.DIR_VECTORS[d])
			var root: Vector2 = centre + dv2 * _edge_offset(i, dv2)
			pts.append(root)
			pts.append(root + dv2 * (TILE * 0.52))
			cols.append(LcnOverlayPalette.with_a(c, 0.94))
		if links == 0:
			pts.append(centre - Vector2(TILE, 0.0) * 0.22)
			pts.append(centre + Vector2(TILE, 0.0) * 0.22)
			cols.append(LcnOverlayPalette.with_a(c, 0.94))
	for i2: int in WIDTH_BUCKETS.size():
		var pts2: PackedVector2Array = _bucket_pts[i2]
		if pts2.size() < 2:
			continue
		# Casing first: a dark stroke under the bright one, so a pipe is legible
		# on white snow at noon and on black ground at three in the morning.
		var casing := PackedColorArray()
		casing.resize(pts2.size() / 2)
		casing.fill(Color(0.02, 0.03, 0.05, 0.75))
		draw_multiline_colors(pts2, casing, stroke(WIDTH_BUCKETS[i2] + 2.6))
		draw_multiline_colors(pts2, _bucket_cols[i2], stroke(WIDTH_BUCKETS[i2]))


## How far from a node's centre the outgoing stub starts, so a multi-tile
## building connects from its edge and a 1x1 pipe is unchanged.
func _edge_offset(i: int, dv: Vector2) -> float:
	var half_w: float = float(snap.node_w[i]) * TILE * 0.5
	var half_h: float = float(snap.node_h[i]) * TILE * 0.5
	var ext: float = half_w if absf(dv.x) > 0.5 else half_h
	return maxf(0.0, ext - TILE * 0.5)


## Flow: dashes travelling from each tile toward the neighbour the router feeds
## through it. Only downstream edges are drawn, so every edge is drawn exactly
## once and the direction on screen is the direction in the solver.
func _draw_flow() -> void:
	if wpp > 2.6:
		return   # at strategic zoom the dashes alias into noise
	var phase: float = 0.0 if pal.reduce_motion else time_s * FLOW_SPEED
	for i: int in snap.node_count:
		var dirs: int = snap.node_dirs[i]
		if dirs == 0:
			continue
		var load: float = snap.node_load[i]
		if load <= 0.002:
			continue
		var r: Rect2 = snap.node_rect(i)
		if not visible_rect(r.grow(TILE)):
			continue
		var centre: Vector2 = snap.node_center(i)
		var slot: int = snap.node_slot[i]
		var dash: Vector2 = pal.network_dash(slot)
		var c: Color = LcnOverlayPalette.with_a(
			pal.network_color(slot).lerp(Color(1.0, 1.0, 1.0), 0.55),
			0.55 + 0.45 * load)
		var before: int = _flow.size()
		for d: int in 4:
			if (dirs & (1 << d)) == 0:
				continue
			var dv := Vector2(LcnOverlayDefs.DIR_VECTORS[d])
			# Leave from the EDGE of the footprint, not the middle of it: a 3x3
			# hearth pushing east would otherwise animate inside its own body.
			var from: Vector2 = centre + dv * _edge_offset(i, dv)
			var to: Vector2 = from + dv * TILE
			if pal.reduce_motion:
				# No motion: a static arrowhead says the same thing.
				LcnOverlayGeometry.arrow(from.lerp(to, 0.78), dv, px(5.0), _flow)
			else:
				LcnOverlayGeometry.dashes(from, to,
					maxf(4.0, dash.x * 0.55), maxf(6.0, dash.y + 8.0), phase, _flow)
		var added: int = (_flow.size() - before) / 2
		for _k: int in added:
			_flow_cols.append(c)
	if _flow.size() >= 2:
		draw_multiline_colors(_flow, _flow_cols, stroke(3.0))


## One badge per grid, on its northernmost visible member. This is the part that
## makes "these two halves are NOT connected" a fact rather than an inference:
## two badges, two ids, two balance sheets, two colours, two dash patterns.
func _draw_badges() -> void:
	if snap.nets.is_empty():
		return
	var top: Dictionary[int, int] = {}
	for i: int in snap.node_count:
		var nid: int = snap.node_net[i]
		if nid < 0:
			continue
		var r: Rect2 = snap.node_rect(i)
		if not visible_rect(r):
			continue
		var best: int = top.get(nid, -1)
		if best < 0 or snap.node_y[i] < snap.node_y[best]:
			top[nid] = i
	var keys: Array = top.keys()
	keys.sort()
	var drawn: int = 0
	for nid2: int in keys:
		if drawn >= BADGE_LIMIT:
			break
		drawn += 1
		var row: int = top[nid2]
		var stats: Dictionary = snap.stats_of_network(nid2)
		var slot: int = snap.node_slot[row]
		var c: Color = pal.network_color(slot)
		var supply: float = float(stats.get("supply", 0.0))
		var demand: float = float(stats.get("demand", 0.0))
		var deficit: float = float(stats.get("deficit", 0.0))
		var producers: int = int(stats.get("producers", 0))
		var text: String = "%s GRID %d   %.0f/%.0f heat/s" % [
			pal.network_mark(slot), nid2, float(stats.get("delivered", 0.0)), demand]
		if producers == 0:
			text += "   NO SOURCE"
		elif deficit > 0.5:
			text += "   short %.0f" % deficit
		elif supply > demand + 0.5:
			text += "   spare %.0f" % (supply - demand)
		var anchor: Vector2 = Vector2(
			snap.node_center(row).x,
			snap.node_rect(row).position.y - px(24.0))
		var tint: Color = pal.bad() if (producers == 0 or deficit > 0.5) else c
		plate(anchor - Vector2(plate_width(text, 15.0) * 0.5, 0.0), text, 15.0, tint)
