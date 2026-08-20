class_name LcnBottleneckLens
extends LcnOverlayLayer
## [P19] Lens 2 — WHY IS THIS BUILDING COLD, AND WHOSE FAULT IS IT.
##
## This is the money lens. The solver already knows the answer: while it fills
## the network it records, for every consumer it had to freeze, the exact tile
## whose throughput or availability stopped the fill, and why. That data has
## been sitting in `HeatNode.bottleneck_node` / `bottleneck_kind` and in
## `HeatNetwork.bottlenecks` since [P02] shipped and no player has ever seen it.
##
## Here it becomes: a pulsing box on the choking tile, a ring around every
## building it starved, and a leader line from the victim to the culprit with
## the verdict written on it. Nobody has to understand max-min fair allocation
## to read "this pipe, 41 of 32 heat/s, six buildings".
##
## The rest of the frame is dimmed rather than hidden — you still see your base,
## it just stops competing with the diagnosis.

const SCRIM_ALPHA: float = 0.26
const MAX_LEADERS: int = 40
const MAX_LABELS: int = 8

var _rings: PackedVector2Array = PackedVector2Array()
var _ring_cols: PackedColorArray = PackedColorArray()
var _leads: PackedVector2Array = PackedVector2Array()
var _lead_cols: PackedColorArray = PackedColorArray()
var _marks: PackedVector2Array = PackedVector2Array()


func _init() -> void:
	super()
	name = "BottleneckLens"


func _draw() -> void:
	if snap == null or snap.node_count == 0:
		return
	var t0: int = Time.get_ticks_usec()
	_rings.clear()
	_ring_cols.clear()
	_leads.clear()
	_lead_cols.clear()
	_marks.clear()

	# Dim, never blank: the base has to stay recognisable behind the diagnosis.
	draw_rect(view.grow(TILE * 2.0),
		Color(0.02, 0.03, 0.055, SCRIM_ALPHA * (1.25 if pal.high_contrast else 1.0)), true)

	var victims: Array[int] = _victims()
	_draw_victims(victims)
	_draw_chokes()
	_draw_leaders(victims)
	_draw_verdicts()
	flush_labels()
	draw_us = Time.get_ticks_usec() - t0


## Every consumer that asked for heat and did not get all of it, worst first.
func _victims() -> Array[int]:
	var out: Array[int] = []
	for i: int in snap.node_count:
		var f: int = snap.node_flags[i]
		if (f & LcnOverlayDefs.F_STARVED) == 0 and (f & LcnOverlayDefs.F_NO_NETWORK) == 0:
			continue
		if not visible_rect(snap.node_rect(i).grow(TILE * 6.0)):
			continue
		out.append(i)
	out.sort_custom(func(a: int, b: int) -> bool:
		return snap.node_served[a] < snap.node_served[b])
	return out


func _draw_victims(victims: Array[int]) -> void:
	var beat: float = LcnOverlayGeometry.pulse(time_s, 0.7, pal.reduce_motion)
	for i: int in victims:
		var r: Rect2 = snap.node_rect(i)
		var served: float = snap.node_served[i]
		var c: Color = pal.served_color(served)
		var grow: float = px(3.0 + 3.0 * beat * (1.0 - served))
		# A ring, not a fill: the building keeps its own silhouette.
		LcnOverlayGeometry.box(r.grow(grow), _rings)
		var segs: int = 4
		for _k: int in segs:
			_ring_cols.append(LcnOverlayPalette.with_a(c, 0.55 + 0.45 * beat))
		# A dead-empty bar under the ring reads the served fraction at a glance,
		# with no colour required.
		var bar := Rect2(r.position + Vector2(0.0, r.size.y + px(3.0)),
			Vector2(r.size.x, px(4.0)))
		draw_rect(bar, Color(0.05, 0.06, 0.09, 0.85), true)
		if served > 0.001:
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * served, bar.size.y)),
				LcnOverlayPalette.with_a(c, 0.95), true)
	if _rings.size() >= 2:
		draw_multiline_colors(_rings, _ring_cols, stroke(2.4))
		_rings.clear()
		_ring_cols.clear()


## The culprits: every tile the solver named as binding, pulsing, with its load
## against its capacity spelled out.
func _draw_chokes() -> void:
	var beat: float = LcnOverlayGeometry.pulse(time_s, 1.15, pal.reduce_motion)
	for b: Dictionary in snap.bottlenecks:
		var row: int = snap.node_row.get(int(b.get("node", -1)), -1)
		if row < 0:
			continue
		var r: Rect2 = snap.node_rect(row)
		if not visible_rect(r.grow(TILE * 3.0)):
			continue
		var c: Color = pal.bad()
		var halo: float = px(2.0 + 9.0 * beat)
		draw_rect(r.grow(halo), LcnOverlayPalette.with_a(c, pal.fill(0.10 + 0.14 * beat)), true)
		draw_rect(r, LcnOverlayPalette.with_a(c, pal.fill(0.34)), true)
		LcnOverlayGeometry.box(r.grow(px(1.0)), _marks)
		LcnOverlayGeometry.box(r.grow(halo), _marks)
	if _marks.size() >= 2:
		var cols := PackedColorArray()
		cols.resize(_marks.size() / 2)
		cols.fill(LcnOverlayPalette.with_a(pal.bad(), 0.95))
		draw_multiline_colors(_marks, cols, stroke(2.6))
		_marks.clear()


## The wire between the dying building and the tile that is killing it. This is
## the sentence the whole part exists to say.
func _draw_leaders(victims: Array[int]) -> void:
	# Fallback culprit per grid. A consumer that was never admitted to the fill
	# (a frozen one, or one shed by priority) carries no tile of its own, but the
	# solver still named a binding constraint for its network — and pointing at
	# that is a truthful answer where drawing nothing is merely an unhelpful one.
	var per_net: Dictionary[int, Vector2] = {}
	for b: Dictionary in snap.bottlenecks:
		var nid: int = int(b.get("net", -1))
		if nid < 0 or per_net.has(nid):
			continue
		var cell: Array = b.get("cell", [0, 0])
		per_net[nid] = Vector2(float(cell[0]) + 0.5, float(cell[1]) + 0.5) * TILE

	var n: int = 0
	for i: int in victims:
		if n >= MAX_LEADERS:
			break
		var to: Vector2 = Vector2.ZERO
		var direct: bool = snap.node_bx[i] >= 0
		if direct:
			to = Vector2(float(snap.node_bx[i]) + 0.5, float(snap.node_by[i]) + 0.5) * TILE
		elif per_net.has(snap.node_net[i]):
			to = per_net[snap.node_net[i]]
		else:
			continue
		var from: Vector2 = snap.node_center(i)
		if from.distance_squared_to(to) < 4.0:
			continue
		n += 1
		var before: int = _leads.size()
		var dir: Vector2 = LcnOverlayGeometry.leader(from, to, _leads)
		LcnOverlayGeometry.arrow(to - dir * px(7.0), dir, px(8.0), _leads)
		var c: Color = LcnOverlayPalette.with_a(pal.bad(), 0.88 if direct else 0.5)
		for _k: int in (_leads.size() - before) / 2:
			_lead_cols.append(c)
	if _leads.size() >= 2:
		draw_multiline_colors(_leads, _lead_cols, stroke(2.2))


## The words. A handful only — a screen full of text is not legibility.
func _draw_verdicts() -> void:
	var n: int = 0
	for b: Dictionary in snap.bottlenecks:
		if n >= MAX_LABELS:
			break
		var row: int = snap.node_row.get(int(b.get("node", -1)), -1)
		if row < 0:
			continue
		var r: Rect2 = snap.node_rect(row)
		if not visible_rect(r.grow(TILE * 3.0)):
			continue
		n += 1
		var reason: String = String(b.get("reason", "capacity"))
		var text: String
		if reason == "capacity":
			text = "AT CAPACITY  %.0f/%.0f heat/s  ->  %d buildings draw through it" % [
				float(b.get("load", 0.0)), float(b.get("capacity", 0.0)),
				int(b.get("consumers", 0))]
		else:
			text = "SOURCE AT FULL OUTPUT  ->  %d buildings draw on it" % [
				int(b.get("consumers", 0))]
		word(r.position + Vector2(r.size.x + px(10.0), -px(6.0)), text, 15.0,
			pal.bad(), LcnLabelField.Rank.VERDICT, 3, "capacity", true)

	# Anything the router could not reach at all is a different failure and
	# deserves a different word.
	var orphan: int = 0
	for i: int in snap.node_count:
		if orphan >= 4:
			break
		var f: int = snap.node_flags[i]
		var lost: bool = (f & LcnOverlayDefs.F_NO_NETWORK) != 0
		var unreach: bool = (f & LcnOverlayDefs.F_UNREACHABLE) != 0 and (f & LcnOverlayDefs.F_CONSUMER) != 0
		if not (lost or unreach):
			continue
		var r2: Rect2 = snap.node_rect(i)
		if not visible_rect(r2.grow(TILE * 2.0)):
			continue
		orphan += 1
		# Four identical "NOT CONNECTED TO ANY SOURCE" plates used to be allowed,
		# one per orphan. It is one fact about the grid, not four about four tiles;
		# the rings already say WHICH tiles, and the legend says what to do.
		word(r2.position + Vector2(0.0, -px(22.0)),
			"NOT CONNECTED TO ANY SOURCE", 14.0, pal.void_color(),
			LcnLabelField.Rank.VERDICT, 1, "", true)
