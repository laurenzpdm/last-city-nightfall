class_name LcnCoverageLens
extends LcnOverlayLayer
## [P19] Lens 6 — WHAT DO I ACTUALLY COVER.
##
## Three different kinds of reach, on one screen, because they are the same
## question asked three times:
##
##   * GUNS      every turret's weapon reach, unioned into a coverage field, and
##               a mark on every structure that no gun reaches
##   * CREW      which sites [P05] actually staffed, and which are short
##   * POWER     everything that wants heat and is on no grid, hatched
##
## The map's own approach lanes and chokepoints ride along: [P01] already
## computes where the dark comes in from and where the narrowest crossing on
## each lane is, which is exactly the information a defence line is built
## against. Drawing it turns "where do I put the wall" from a guess into a read.

const MAX_RANGE_RINGS: int = 64
const MAX_GAP_MARKS: int = 80

var _rings: PackedVector2Array = PackedVector2Array()
var _ring_cols: PackedColorArray = PackedColorArray()
var _hatch: PackedVector2Array = PackedVector2Array()
var _marks: PackedVector2Array = PackedVector2Array()
var _mark_cols: PackedColorArray = PackedColorArray()
var _covers: Array[Vector3] = []


func _init() -> void:
	super()
	name = "CoverageLens"


func _draw() -> void:
	if snap == null:
		return
	var t0: int = Time.get_ticks_usec()
	_rings.clear()
	_ring_cols.clear()
	_hatch.clear()
	_marks.clear()
	_mark_cols.clear()
	_covers.clear()
	draw_rect(view.grow(TILE * 2.0), Color(0.02, 0.03, 0.05, 0.34), true)
	_draw_turrets()
	_draw_crew()
	_draw_gaps()
	_draw_unpowered()
	_draw_lanes()
	_flush()
	draw_us = Time.get_ticks_usec() - t0


func _draw_turrets() -> void:
	var drawn: int = 0
	for i: int in snap.bld_count:
		if (snap.bld_flags[i] & LcnOverlaySnapshot.B_TURRET) == 0:
			continue
		var reach: float = snap.bld_reach[i]
		if reach <= 0.0:
			continue
		var centre: Vector2 = snap.bld_center(i)
		var radius: float = reach * TILE
		_covers.append(Vector3(centre.x, centre.y, radius))
		if not visible_rect(Rect2(centre - Vector2(radius, radius), Vector2(radius, radius) * 2.0)):
			continue
		if drawn >= MAX_RANGE_RINGS:
			continue
		drawn += 1
		var live: bool = snap.bld_state[i] != 4 and (snap.bld_flags[i] & LcnOverlaySnapshot.B_GHOST) == 0
		var c: Color = pal.good() if live else LcnOverlayPalette.INK_DIM
		# Low-alpha fill so overlapping fields add up to "well defended" instead
		# of a black disc, plus a hard rim so a single field still has an edge.
		draw_circle(centre, radius, LcnOverlayPalette.with_a(c, pal.fill(0.055)))
		LcnOverlayGeometry.ring(centre, radius, _ring_segments(radius), _rings)
		for _k: int in _ring_segments(radius):
			_ring_cols.append(LcnOverlayPalette.with_a(c, 0.55))
		if alt or wpp < 1.2:
			label(centre + Vector2(0.0, -radius - px(6.0)),
				"%.0f tiles" % reach, 13.0, c, true)


func _ring_segments(radius: float) -> int:
	return clampi(int(radius / maxf(px(4.0), 1.0)), 20, 96)


## Crew coverage. [P05] assigns citizens to sites, so "does anyone actually work
## here" is real data: a dashed ring means the building is short of the crew it
## needs, and the fraction is written next to it. Silent when no citizen system
## exists, because inventing an answer is worse than admitting there is none.
func _draw_crew() -> void:
	if not snap.probe.has_citizens():
		return
	var shown: int = 0
	for i: int in snap.bld_count:
		var need: int = snap.bld_need[i]
		if need <= 0 or snap.bld_workers[i] < 0:
			continue
		if (snap.bld_flags[i] & LcnOverlaySnapshot.B_GHOST) != 0:
			continue
		var r: Rect2 = snap.bld_rect(i)
		if not visible_rect(r):
			continue
		var have: int = snap.bld_workers[i]
		var full: bool = have >= need
		var c: Color = pal.good() if full else pal.warn()
		var pts := PackedVector2Array()
		if full:
			LcnOverlayGeometry.brackets(r.grow(px(4.0)), px(6.0), pts)
			push_lines(pts, LcnOverlayPalette.with_a(c, 0.55))
		else:
			var ring := PackedVector2Array()
			LcnOverlayGeometry.box(r.grow(px(4.0)), ring)
			var dashed := PackedVector2Array()
			var k: int = 0
			while k + 1 < ring.size():
				LcnOverlayGeometry.dashes(ring[k], ring[k + 1], 7.0, 6.0, 0.0, dashed)
				k += 2
			push_lines(dashed, LcnOverlayPalette.with_a(c, 0.9))
			if shown < 14 and (alt or wpp < 1.4):
				shown += 1
				label(r.position + Vector2(0.0, -px(8.0)),
					"crew %d/%d" % [have, need], 13.0, c)
	flush_lines(stroke(1.7))


## Structures no gun reaches. The mark is a bracket, not a fill, so the thing
## being diagnosed stays visible — that is the rule for this whole part.
func _draw_gaps() -> void:
	if _covers.is_empty():
		return
	var marked: int = 0
	for i: int in snap.bld_count:
		if marked >= MAX_GAP_MARKS:
			break
		if (snap.bld_flags[i] & LcnOverlaySnapshot.B_TURRET) != 0:
			continue
		var r: Rect2 = snap.bld_rect(i)
		if not visible_rect(r):
			continue
		var centre: Vector2 = snap.bld_center(i)
		var covered: bool = false
		for c: Vector3 in _covers:
			if centre.distance_squared_to(Vector2(c.x, c.y)) <= c.z * c.z:
				covered = true
				break
		if covered:
			continue
		marked += 1
		LcnOverlayGeometry.brackets(r.grow(px(2.0)), px(7.0), _marks)
		for _k: int in 8:
			_mark_cols.append(LcnOverlayPalette.with_a(pal.warn(), 0.85))


## Anything that wants heat and is on no grid at all. Hatch carries it, so the
## message survives greyscale and every colour deficiency.
func _draw_unpowered() -> void:
	for i: int in snap.node_count:
		var f: int = snap.node_flags[i]
		if (f & LcnOverlayDefs.F_NO_NETWORK) == 0 and (f & LcnOverlayDefs.F_UNREACHABLE) == 0:
			continue
		if (f & LcnOverlayDefs.F_CONSUMER) == 0:
			continue
		var r: Rect2 = snap.node_rect(i)
		if not visible_rect(r):
			continue
		LcnOverlayGeometry.hatch(r, px(6.0), _hatch)
		LcnOverlayGeometry.box(r, _marks)
		for _k: int in 4:
			_mark_cols.append(LcnOverlayPalette.with_a(pal.bad(), 0.9))


## Where the night comes in from, straight out of [P01]'s lane analysis.
func _draw_lanes() -> void:
	var grid: GridSystem = snap.grid
	if grid == null:
		return
	var chokes: Array[Vector2i] = grid.chokepoints()
	var shown: int = 0
	for c: Vector2i in chokes:
		if shown >= 12:
			break
		var r := Rect2(Vector2(c) * TILE - Vector2(TILE, TILE), Vector2(TILE, TILE) * 3.0)
		if not visible_rect(r):
			continue
		shown += 1
		LcnOverlayGeometry.ring(r.get_center(), TILE * 1.4, 24, _marks)
		for _k: int in 24:
			_mark_cols.append(LcnOverlayPalette.with_a(pal.bad(), 0.55))
		if alt:
			plate(r.get_center() + Vector2(px(12.0), 0.0), "CHOKEPOINT", 13.0, pal.bad())


func _flush() -> void:
	if _rings.size() >= 2:
		draw_multiline_colors(_rings, _ring_cols, stroke(1.8))
	if _hatch.size() >= 2:
		var hc := PackedColorArray()
		hc.resize(_hatch.size() / 2)
		hc.fill(LcnOverlayPalette.with_a(pal.bad(), 0.45))
		draw_multiline_colors(_hatch, hc, stroke(1.3))
	if _marks.size() >= 2:
		draw_multiline_colors(_marks, _mark_cols, stroke(2.0))
