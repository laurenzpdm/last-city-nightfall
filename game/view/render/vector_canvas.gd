class_name LcnVectorCanvas
extends RefCounted
## A tiny supersampled vector rasteriser, so all placeholder art is *drawn*
## rather than being coloured rectangles. [P13]
##
## Everything is authored in final-pixel coordinates and rasterised at `ss` times
## that resolution, then box-filtered down. The result is clean anti-aliased
## vector art with no external asset pipeline and no binary blobs in the repo.
##
##   var c := LcnVectorCanvas.new(64, 80, 3)
##   c.fill_polygon(PackedVector2Array([...]), LcnPalette.STEEL)
##   c.stroke_polygon(pts, LcnPalette.COLD_ABYSS, 1.6)
##   var tex: ImageTexture = ImageTexture.create_from_image(c.to_image())

const FILL_SOLID: int = 0
const FILL_LINEAR: int = 1
const FILL_RADIAL: int = 2

var width: int = 0
var height: int = 0
var ss: int = 3

var _w: int = 0
var _h: int = 0
var _buf: PackedFloat32Array = PackedFloat32Array()


func _init(w: int, h: int, supersample: int = 3) -> void:
	width = maxi(1, w)
	height = maxi(1, h)
	ss = clampi(supersample, 1, 6)
	_w = width * ss
	_h = height * ss
	_buf = PackedFloat32Array()
	_buf.resize(_w * _h * 4)
	_buf.fill(0.0)


# ------------------------------------------------------------------ shapes --

## Fills a closed polygon (even-odd rule). Points in final-pixel space.
func fill_polygon(pts: PackedVector2Array, color: Color) -> void:
	_raster(pts, FILL_SOLID, color, color, Vector2.ZERO, Vector2.ZERO)


## Fills a polygon with a linear gradient running from `g0` to `g1`.
func fill_polygon_gradient(pts: PackedVector2Array, c0: Color, c1: Color, g0: Vector2, g1: Vector2) -> void:
	_raster(pts, FILL_LINEAR, c0, c1, g0, g1)


## Fills a polygon with a radial gradient centred on `centre`, `radius` long.
func fill_polygon_radial(pts: PackedVector2Array, c0: Color, c1: Color, centre: Vector2, radius: float) -> void:
	_raster(pts, FILL_RADIAL, c0, c1, centre, Vector2(maxf(0.001, radius), 0.0))


func fill_rect(r: Rect2, color: Color) -> void:
	fill_polygon(PackedVector2Array([
		r.position,
		Vector2(r.end.x, r.position.y),
		r.end,
		Vector2(r.position.x, r.end.y),
	]), color)


func fill_rect_gradient(r: Rect2, top: Color, bottom: Color) -> void:
	fill_polygon_gradient(PackedVector2Array([
		r.position,
		Vector2(r.end.x, r.position.y),
		r.end,
		Vector2(r.position.x, r.end.y),
	]), top, bottom, r.position, Vector2(r.position.x, r.end.y))


func fill_circle(centre: Vector2, radius: float, color: Color, segments: int = 0) -> void:
	fill_polygon(circle_points(centre, radius, radius, segments), color)


func fill_ellipse(centre: Vector2, rx: float, ry: float, color: Color, segments: int = 0) -> void:
	fill_polygon(circle_points(centre, rx, ry, segments), color)


## Soft radial falloff disc — the primitive behind every glow and light cookie.
func fill_glow(centre: Vector2, radius: float, inner: Color, outer: Color, segments: int = 0) -> void:
	fill_polygon_radial(circle_points(centre, radius, radius, segments), inner, outer, centre, radius)


## Rounded rectangle. `r` is the corner radius, clamped to half the short side.
func fill_round_rect(rect: Rect2, corner: float, color: Color) -> void:
	fill_polygon(round_rect_points(rect, corner), color)


# ------------------------------------------------------------------ strokes --

## Strokes an open polyline with butt caps and mitre-free round joins.
func stroke_polyline(pts: PackedVector2Array, color: Color, w: float) -> void:
	if pts.size() < 2:
		return
	var half: float = maxf(0.05, w * 0.5)
	for i: int in range(pts.size() - 1):
		_stroke_segment(pts[i], pts[i + 1], half, color)
	for i: int in range(1, pts.size() - 1):
		fill_circle(pts[i], half, color, 10)


func stroke_polygon(pts: PackedVector2Array, color: Color, w: float) -> void:
	if pts.size() < 2:
		return
	var closed: PackedVector2Array = pts.duplicate()
	closed.append(pts[0])
	stroke_polyline(closed, color, w)
	fill_circle(pts[0], maxf(0.05, w * 0.5), color, 10)


func stroke_rect(r: Rect2, color: Color, w: float) -> void:
	stroke_polygon(PackedVector2Array([
		r.position,
		Vector2(r.end.x, r.position.y),
		r.end,
		Vector2(r.position.x, r.end.y),
	]), color, w)


func _stroke_segment(a: Vector2, b: Vector2, half: float, color: Color) -> void:
	var d: Vector2 = b - a
	if d.length_squared() < 0.000001:
		return
	var n: Vector2 = Vector2(-d.y, d.x).normalized() * half
	fill_polygon(PackedVector2Array([a + n, b + n, b - n, a - n]), color)


# ------------------------------------------------------------------- helpers --

static func circle_points(centre: Vector2, rx: float, ry: float, segments: int = 0) -> PackedVector2Array:
	var n: int = segments
	if n <= 0:
		n = clampi(int(maxf(rx, ry) * 2.2) + 8, 10, 64)
	var out := PackedVector2Array()
	out.resize(n)
	for i: int in n:
		var a: float = TAU * float(i) / float(n)
		out[i] = centre + Vector2(cos(a) * rx, sin(a) * ry)
	return out


static func round_rect_points(rect: Rect2, corner: float, per_corner: int = 5) -> PackedVector2Array:
	var c: float = clampf(corner, 0.0, minf(rect.size.x, rect.size.y) * 0.5)
	var out := PackedVector2Array()
	var centres: Array[Vector2] = [
		Vector2(rect.end.x - c, rect.position.y + c),
		Vector2(rect.end.x - c, rect.end.y - c),
		Vector2(rect.position.x + c, rect.end.y - c),
		Vector2(rect.position.x + c, rect.position.y + c),
	]
	for k: int in 4:
		var base: float = -PI * 0.5 + float(k) * PI * 0.5
		for i: int in range(per_corner + 1):
			var a: float = base + PI * 0.5 * float(i) / float(per_corner)
			out.append(centres[k] + Vector2(cos(a), sin(a)) * c)
	return out


## Trapezoid helper — the shape most building bodies are built from.
static func trapezoid(cx: float, top_y: float, bottom_y: float, top_w: float, bottom_w: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(cx - top_w * 0.5, top_y),
		Vector2(cx + top_w * 0.5, top_y),
		Vector2(cx + bottom_w * 0.5, bottom_y),
		Vector2(cx - bottom_w * 0.5, bottom_y),
	])


static func offset_points(pts: PackedVector2Array, by: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i: int in pts.size():
		out[i] = pts[i] + by
	return out


static func scale_points(pts: PackedVector2Array, origin: Vector2, s: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i: int in pts.size():
		out[i] = origin + (pts[i] - origin) * s
	return out


# ---------------------------------------------------------------- rasteriser --

func _raster(pts: PackedVector2Array, mode: int, c0: Color, c1: Color, ga: Vector2, gb: Vector2) -> void:
	var n: int = pts.size()
	if n < 3:
		return

	var sx := PackedFloat32Array()
	var sy := PackedFloat32Array()
	sx.resize(n)
	sy.resize(n)
	var min_y: float = 1e20
	var max_y: float = -1e20
	for i: int in n:
		var p: Vector2 = pts[i]
		sx[i] = p.x * float(ss)
		sy[i] = p.y * float(ss)
		min_y = minf(min_y, sy[i])
		max_y = maxf(max_y, sy[i])

	var y0: int = clampi(int(floor(min_y)), 0, _h - 1)
	var y1: int = clampi(int(ceil(max_y)), 0, _h - 1)
	if y1 < y0:
		return

	# Gradient axes are authored in final pixels; work in supersampled space.
	var gax: float = ga.x * float(ss)
	var gay: float = ga.y * float(ss)
	var gbx: float = gb.x * float(ss)
	var gby: float = gb.y * float(ss)
	var axis_x: float = gbx - gax
	var axis_y: float = gby - gay
	var axis_len2: float = maxf(0.000001, axis_x * axis_x + axis_y * axis_y)
	var radius_ss: float = maxf(0.001, gb.x * float(ss))

	var xs := PackedFloat32Array()
	for y: int in range(y0, y1 + 1):
		var yc: float = float(y) + 0.5
		xs.clear()
		var j: int = n - 1
		for i: int in n:
			var ay: float = sy[j]
			var by: float = sy[i]
			if (ay <= yc and by > yc) or (by <= yc and ay > yc):
				var t: float = (yc - ay) / (by - ay)
				xs.append(sx[j] + t * (sx[i] - sx[j]))
			j = i
		if xs.size() < 2:
			continue
		var sorted: Array = Array(xs)
		sorted.sort()
		var k: int = 0
		while k + 1 < sorted.size():
			var xa: int = int(ceil(float(sorted[k]) - 0.5))
			var xb: int = int(floor(float(sorted[k + 1]) - 0.5))
			k += 2
			if xb < 0 or xa > _w - 1:
				continue
			xa = maxi(xa, 0)
			xb = mini(xb, _w - 1)
			var row: int = y * _w
			for x: int in range(xa, xb + 1):
				var col: Color = c0
				if mode == FILL_LINEAR:
					var px: float = float(x) + 0.5 - gax
					var py: float = yc - gay
					var t2: float = clampf((px * axis_x + py * axis_y) / axis_len2, 0.0, 1.0)
					col = c0.lerp(c1, t2)
				elif mode == FILL_RADIAL:
					var dx: float = float(x) + 0.5 - gax
					var dy: float = yc - gay
					var t3: float = clampf(sqrt(dx * dx + dy * dy) / radius_ss, 0.0, 1.0)
					col = c0.lerp(c1, t3 * t3 * (3.0 - 2.0 * t3))
				_blend(( row + x) * 4, col)


func _blend(idx: int, c: Color) -> void:
	var a: float = clampf(c.a, 0.0, 1.0)
	if a <= 0.0:
		return
	var inv: float = 1.0 - a
	_buf[idx] = c.r * a + _buf[idx] * inv
	_buf[idx + 1] = c.g * a + _buf[idx + 1] * inv
	_buf[idx + 2] = c.b * a + _buf[idx + 2] * inv
	_buf[idx + 3] = a + _buf[idx + 3] * inv


# ------------------------------------------------------------------- output --

## Box-filters the supersampled buffer down to the authored size.
## Averaging happens in premultiplied space, which is what stops dark fringes
## appearing around every anti-aliased edge.
func to_image() -> Image:
	var bytes := PackedByteArray()
	bytes.resize(width * height * 4)
	var inv: float = 1.0 / float(ss * ss)
	for y: int in height:
		for x: int in width:
			var r: float = 0.0
			var g: float = 0.0
			var b: float = 0.0
			var a: float = 0.0
			for oy: int in ss:
				var row: int = ((y * ss + oy) * _w + x * ss) * 4
				for ox: int in ss:
					var i: int = row + ox * 4
					r += _buf[i]
					g += _buf[i + 1]
					b += _buf[i + 2]
					a += _buf[i + 3]
			r *= inv
			g *= inv
			b *= inv
			a *= inv
			var o: int = (y * width + x) * 4
			if a > 0.0001:
				bytes[o] = int(clampf(r / a, 0.0, 1.0) * 255.0)
				bytes[o + 1] = int(clampf(g / a, 0.0, 1.0) * 255.0)
				bytes[o + 2] = int(clampf(b / a, 0.0, 1.0) * 255.0)
			else:
				bytes[o] = 0
				bytes[o + 1] = 0
				bytes[o + 2] = 0
			bytes[o + 3] = int(clampf(a, 0.0, 1.0) * 255.0)
	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, bytes)


func to_texture() -> ImageTexture:
	return ImageTexture.create_from_image(to_image())


# --------------------------------------------------------------- image post --

## Per-pixel grain applied AFTER downsampling, so it stays crisp instead of
## being blurred into mush by the box filter.
static func apply_grain(img: Image, amount: float, seed_value: int, keep_alpha: bool = true) -> void:
	if amount <= 0.0:
		return
	var w: int = img.get_width()
	var h: int = img.get_height()
	for y: int in h:
		for x: int in w:
			var c: Color = img.get_pixelv(Vector2i(x, y))
			if keep_alpha and c.a <= 0.004:
				continue
			var n: float = LcnNoise.shash3(x, y, seed_value) * amount
			img.set_pixelv(Vector2i(x, y), Color(
				clampf(c.r + n, 0.0, 1.0),
				clampf(c.g + n * 0.96, 0.0, 1.0),
				clampf(c.b + n * 0.88, 0.0, 1.0),
				c.a
			))


## Multiplies in a soft vertical light ramp — instant "lit from above" read.
static func apply_top_light(img: Image, top_gain: float, bottom_gain: float) -> void:
	var w: int = img.get_width()
	var h: int = img.get_height()
	for y: int in h:
		var f: float = float(y) / maxf(1.0, float(h - 1))
		var gain: float = lerpf(top_gain, bottom_gain, f)
		for x: int in w:
			var c: Color = img.get_pixelv(Vector2i(x, y))
			if c.a <= 0.004:
				continue
			img.set_pixelv(Vector2i(x, y), Color(
				clampf(c.r * gain, 0.0, 1.0),
				clampf(c.g * gain, 0.0, 1.0),
				clampf(c.b * gain, 0.0, 1.0),
				c.a
			))
