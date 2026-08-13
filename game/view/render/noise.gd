class_name LcnNoise
extends RefCounted
## Deterministic integer-hash value noise used by the procedural art pipeline.
##
## Intentionally NOT Godot's FastNoiseLite: this runs at sprite-bake time and
## must give byte-identical textures on every machine and every run, so a
## screenshot diff between builds means an art change and nothing else.

const _P1: int = 0x27d4eb2d
const _P2: int = 0x165667b1
const _P3: int = 0x9e3779b1


## Uniform 0..1 hash of three integers. The workhorse.
static func hash3(x: int, y: int, s: int) -> float:
	var h: int = (x * 374761393 + y * 668265263 + s * 2147483647) & 0x7FFFFFFF
	h = (h ^ (h >> 13)) * _P1 & 0x7FFFFFFF
	h = (h ^ (h >> 16)) * _P2 & 0x7FFFFFFF
	h = (h ^ (h >> 15)) & 0x7FFFFFFF
	return float(h % 1048576) / 1048575.0


## Signed -1..1 variant.
static func shash3(x: int, y: int, s: int) -> float:
	return hash3(x, y, s) * 2.0 - 1.0


## Smooth value noise sampled in continuous space.
static func value(x: float, y: float, s: int) -> float:
	var xi: int = int(floor(x))
	var yi: int = int(floor(y))
	var xf: float = x - float(xi)
	var yf: float = y - float(yi)
	var u: float = xf * xf * (3.0 - 2.0 * xf)
	var v: float = yf * yf * (3.0 - 2.0 * yf)
	var a: float = hash3(xi, yi, s)
	var b: float = hash3(xi + 1, yi, s)
	var c: float = hash3(xi, yi + 1, s)
	var d: float = hash3(xi + 1, yi + 1, s)
	return lerpf(lerpf(a, b, u), lerpf(c, d, u), v)


## Fractal sum. `octaves` is small on purpose — these bake in the hundreds of
## thousands of samples and we care about start-up time.
static func fbm(x: float, y: float, s: int, octaves: int = 3, gain: float = 0.5) -> float:
	var sum: float = 0.0
	var amp: float = 1.0
	var norm: float = 0.0
	var fx: float = x
	var fy: float = y
	for i: int in octaves:
		sum += value(fx, fy, s + i * 977) * amp
		norm += amp
		amp *= gain
		fx *= 2.03
		fy *= 2.01
	return sum / maxf(0.0001, norm)


## Ridged variant, used for wind-scoured snow drifts and rock facets.
static func ridge(x: float, y: float, s: int, octaves: int = 3) -> float:
	var sum: float = 0.0
	var amp: float = 1.0
	var norm: float = 0.0
	var fx: float = x
	var fy: float = y
	for i: int in octaves:
		var n: float = 1.0 - absf(value(fx, fy, s + i * 613) * 2.0 - 1.0)
		sum += n * n * amp
		norm += amp
		amp *= 0.45
		fx *= 2.11
		fy *= 2.07
	return sum / maxf(0.0001, norm)


## Cellular / worley distance field. Drives ice cracking and rubble clustering.
## Returns the distance to the nearest feature point, roughly 0..1.
static func worley(x: float, y: float, s: int) -> float:
	var xi: int = int(floor(x))
	var yi: int = int(floor(y))
	var best: float = 9.0
	for oy: int in range(-1, 2):
		for ox: int in range(-1, 2):
			var cx: int = xi + ox
			var cy: int = yi + oy
			var px: float = float(cx) + hash3(cx, cy, s)
			var py: float = float(cy) + hash3(cx, cy, s + 7919)
			var dx: float = px - x
			var dy: float = py - y
			var d: float = sqrt(dx * dx + dy * dy)
			if d < best:
				best = d
	return clampf(best, 0.0, 1.0)


## Distance to the nearest cell *border* (0 on a crack line, 1 in cell centre).
static func worley_edge(x: float, y: float, s: int) -> float:
	var xi: int = int(floor(x))
	var yi: int = int(floor(y))
	var d1: float = 9.0
	var d2: float = 9.0
	for oy: int in range(-2, 3):
		for ox: int in range(-2, 3):
			var cx: int = xi + ox
			var cy: int = yi + oy
			var px: float = float(cx) + hash3(cx, cy, s)
			var py: float = float(cy) + hash3(cx, cy, s + 7919)
			var dx: float = px - x
			var dy: float = py - y
			var d: float = sqrt(dx * dx + dy * dy)
			if d < d1:
				d2 = d1
				d1 = d
			elif d < d2:
				d2 = d
	return clampf(d2 - d1, 0.0, 1.0)
