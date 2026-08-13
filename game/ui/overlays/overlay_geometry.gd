class_name LcnOverlayGeometry
extends RefCounted
## [P19] Pure geometry for the lenses. No drawing, no sim, no nodes — which is
## exactly why the contour tracer and the leader-line router can be tested
## headlessly instead of judged from a screenshot.
##
## Everything appends into caller-owned buffers so a frame that draws two
## thousand dashes allocates nothing.

## Marching-squares case table: for each of the 16 corner masks, the pairs of
## edges a contour segment connects. Edges are 0 top, 1 right, 2 bottom, 3 left.
const MS_CASES: Array = [
	[], [2, 3], [1, 2], [1, 3],
	[0, 1], [0, 1, 2, 3], [0, 2], [0, 3],
	[0, 3], [0, 2], [0, 1, 2, 3], [0, 1],
	[1, 3], [1, 2], [2, 3], [],
]


## Traces the `level` isoline of a scalar field into line-segment pairs.
##
## `field` is row-major, `w` by `h` samples. The output is in field coordinates
## (sample units), so the caller scales it to world space. Segments come out as
## consecutive pairs, ready for draw_multiline.
static func contour(field: PackedFloat32Array, w: int, h: int, level: float,
		out: PackedVector2Array) -> void:
	if w < 2 or h < 2 or field.size() < w * h:
		return
	for y: int in range(h - 1):
		var row: int = y * w
		var next_row: int = row + w
		for x: int in range(w - 1):
			var tl: float = field[row + x]
			var tr: float = field[row + x + 1]
			var br: float = field[next_row + x + 1]
			var bl: float = field[next_row + x]
			var mask: int = 0
			if tl > level:
				mask |= 8
			if tr > level:
				mask |= 4
			if br > level:
				mask |= 2
			if bl > level:
				mask |= 1
			var edges: Array = MS_CASES[mask]
			if edges.is_empty():
				continue
			var fx: float = float(x)
			var fy: float = float(y)
			var i: int = 0
			while i + 1 < edges.size():
				out.append(_edge_point(int(edges[i]), fx, fy, tl, tr, br, bl, level))
				out.append(_edge_point(int(edges[i + 1]), fx, fy, tl, tr, br, bl, level))
				i += 2


static func _edge_point(edge: int, x: float, y: float,
		tl: float, tr: float, br: float, bl: float, level: float) -> Vector2:
	match edge:
		0:
			return Vector2(x + _lerp_t(tl, tr, level), y)
		1:
			return Vector2(x + 1.0, y + _lerp_t(tr, br, level))
		2:
			return Vector2(x + _lerp_t(bl, br, level), y + 1.0)
		_:
			return Vector2(x, y + _lerp_t(tl, bl, level))


static func _lerp_t(a: float, b: float, level: float) -> float:
	var d: float = b - a
	if absf(d) < 0.00001:
		return 0.5
	return clampf((level - a) / d, 0.0, 1.0)


## Appends a dashed run from `a` to `b` as line-segment pairs.
## `phase` slides the pattern along the line — that is the flow animation.
## A dash of 0 length degenerates to one solid segment, which is what a solid
## network slot wants.
static func dashes(a: Vector2, b: Vector2, dash: float, gap: float, phase: float,
		out: PackedVector2Array) -> void:
	var span: float = a.distance_to(b)
	if span <= 0.001:
		return
	if dash <= 0.0 or gap <= 0.0:
		out.append(a)
		out.append(b)
		return
	var dir: Vector2 = (b - a) / span
	var period: float = dash + gap
	var start: float = -fposmod(phase, period)
	var t: float = start
	var guard: int = 0
	while t < span and guard < 512:
		guard += 1
		var s: float = maxf(t, 0.0)
		var e: float = minf(t + dash, span)
		if e > s:
			out.append(a + dir * s)
			out.append(b if e >= span else a + dir * e)
		t += period


## Appends an arrowhead (two short strokes) at `tip` pointing along `dir`.
static func arrow(tip: Vector2, dir: Vector2, size: float, out: PackedVector2Array) -> void:
	if dir.length_squared() < 0.000001:
		return
	var d: Vector2 = dir.normalized()
	var n: Vector2 = Vector2(-d.y, d.x)
	var back: Vector2 = tip - d * size
	out.append(tip)
	out.append(back + n * size * 0.55)
	out.append(tip)
	out.append(back - n * size * 0.55)


## Appends an open ring as line-segment pairs. Cheaper than draw_arc when a
## frame has forty of them, because the whole batch is one draw call.
static func ring(center: Vector2, radius: float, segments: int, out: PackedVector2Array) -> void:
	var n: int = maxi(6, segments)
	var step: float = TAU / float(n)
	var prev: Vector2 = center + Vector2(radius, 0.0)
	for i: int in range(1, n + 1):
		var p: Vector2 = center + Vector2(cos(step * float(i)), sin(step * float(i))) * radius
		out.append(prev)
		out.append(p)
		prev = p


## Appends a rectangle outline as line-segment pairs.
static func box(rect: Rect2, out: PackedVector2Array) -> void:
	var a: Vector2 = rect.position
	var b: Vector2 = Vector2(rect.end.x, rect.position.y)
	var c: Vector2 = rect.end
	var d: Vector2 = Vector2(rect.position.x, rect.end.y)
	out.append(a)
	out.append(b)
	out.append(b)
	out.append(c)
	out.append(c)
	out.append(d)
	out.append(d)
	out.append(a)


## Appends the corner brackets of a rectangle — an outline that reads as
## "this thing is selected" without covering the thing's own silhouette.
static func brackets(rect: Rect2, arm: float, out: PackedVector2Array) -> void:
	var a: float = minf(arm, minf(rect.size.x, rect.size.y) * 0.45)
	var p: Vector2 = rect.position
	var e: Vector2 = rect.end
	var corners: Array[Vector2] = [p, Vector2(e.x, p.y), e, Vector2(p.x, e.y)]
	var xdir: Array[float] = [1.0, -1.0, -1.0, 1.0]
	var ydir: Array[float] = [1.0, 1.0, -1.0, -1.0]
	for i: int in 4:
		var c: Vector2 = corners[i]
		out.append(c)
		out.append(c + Vector2(a * xdir[i], 0.0))
		out.append(c)
		out.append(c + Vector2(0.0, a * ydir[i]))


## Appends diagonal hatching clipped to a rectangle. Hatching is the pattern
## channel that carries "frozen" and "unpowered" without relying on colour.
static func hatch(rect: Rect2, spacing: float, out: PackedVector2Array) -> void:
	if spacing <= 0.5:
		return
	var w: float = rect.size.x
	var h: float = rect.size.y
	var total: float = w + h
	var t: float = spacing
	var guard: int = 0
	while t < total and guard < 256:
		guard += 1
		# Line x + y = t, clipped to the rect in local coordinates.
		var x0: float = maxf(0.0, t - h)
		var y0: float = t - x0
		var y1: float = maxf(0.0, t - w)
		var x1: float = t - y1
		if x1 <= x0:
			t += spacing
			continue
		out.append(rect.position + Vector2(x0, y0))
		out.append(rect.position + Vector2(x1, y1))
		t += spacing


## An elbow route from a building to the tile that is choking it: out along the
## dominant axis first, then in. Straight lines through a dense base read as
## noise; an elbow reads as a wire.
static func leader(from: Vector2, to: Vector2, out: PackedVector2Array) -> Vector2:
	var d: Vector2 = to - from
	if d.length_squared() < 1.0:
		return Vector2.RIGHT
	var mid: Vector2
	if absf(d.x) >= absf(d.y):
		mid = Vector2(from.x + d.x * 0.62, from.y)
	else:
		mid = Vector2(from.x, from.y + d.y * 0.62)
	out.append(from)
	out.append(mid)
	out.append(mid)
	out.append(to)
	return (to - mid).normalized() if (to - mid).length_squared() > 0.01 else (to - from).normalized()


## Screen-stable pulse in 0..1. Returns a constant when motion is reduced, so a
## player who cannot tolerate flashing still sees the emphasis as a steady ring.
static func pulse(time_s: float, speed: float, reduce_motion: bool) -> float:
	if reduce_motion:
		return 0.72
	return 0.5 + 0.5 * sin(time_s * speed * TAU)


## Buckets a world position into a coarse cluster key. Used when the camera is
## far enough out that per-building badges would collide.
static func cluster_key(pos: Vector2, size: float) -> Vector2i:
	return Vector2i(int(floor(pos.x / size)), int(floor(pos.y / size)))
