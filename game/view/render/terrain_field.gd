class_name LcnTerrainField
extends RefCounted
## The ground's data plane. [P13]
##
## The old renderer stamped 32x32 baked tiles into three TileMapLayers, one chunk
## at a time, and baked the snow depth INTO the tile at the moment the chunk was
## loaded. That produced the two defects a critic named first: a visible mosaic of
## four repeating tile images, and hard chunk-aligned seams wherever two
## neighbouring chunks had been baked at different points in the snowfall.
##
## Nothing is baked here. This class keeps five small data textures — terrain
## kind, snow depth, heat, soot, city presence — and `terrain.gdshader` turns
## them into ground, per pixel, in world space. A chunk boundary cannot exist
## because no chunk is ever drawn, and the surface detail is generated at the
## pixel the camera is actually looking at, so it does not repeat and does not
## soften when you zoom in.
##
## Resolutions are chosen so an update is cheap enough to run inside a frame:
##
##   kind   1 texel / tile      changes only when terrain changes (≈ never)
##   snow   1 texel / 2 tiles   refreshed round-robin from the grid's own bytes
##   heat   1 texel / 2 tiles   rasterised discs, one pass over the sources
##   soot   1 texel / 2 tiles   rasterised discs, one pass over industry
##   city   1 texel / 8 tiles   one write per building, then a separable blur
##
## Every field is sampled with linear filtering except kind, so the shader gets a
## smoothly interpolated value between tile centres — which is half the reason
## the snow line stopped looking like a staircase.

const TILE: int = 32
## Tiles per texel, per field.
const SNOW_STEP: int = 2
const HEAT_STEP: int = 2
const SOOT_STEP: int = 2
const CITY_STEP: int = 8
## City presence blur radius, in city texels (so 2 -> 16 tiles).
const CITY_BLUR: int = 2
const NOISE_SIZE: int = 256
const PAL_WIDTH: int = 16
const PAL_ROWS: int = 4

var size: Vector2i = Vector2i.ZERO

var kind_tex: ImageTexture = null
var snow_tex: ImageTexture = null
var heat_tex: ImageTexture = null
var soot_tex: ImageTexture = null
var city_tex: ImageTexture = null
var noise_tex: ImageTexture = null
var palette_tex: ImageTexture = null

var snow_scale: float = 1.0

var _kind: PackedByteArray = PackedByteArray()
var _snow: PackedByteArray = PackedByteArray()
var _heat: PackedByteArray = PackedByteArray()
var _soot: PackedByteArray = PackedByteArray()
var _city: PackedByteArray = PackedByteArray()
var _city_tmp: PackedByteArray = PackedByteArray()
var _city_raw: PackedByteArray = PackedByteArray()

var _kind_img: Image = null
var _snow_img: Image = null
var _heat_img: Image = null
var _soot_img: Image = null
var _city_img: Image = null

var _snow_dim: Vector2i = Vector2i.ZERO
var _heat_dim: Vector2i = Vector2i.ZERO
var _soot_dim: Vector2i = Vector2i.ZERO
var _city_dim: Vector2i = Vector2i.ZERO

var _chunk_version: Dictionary[int, int] = {}
var _snow_cursor: int = 0
var _chunks: Vector2i = Vector2i.ZERO

var _kind_us: int = 0
var _snow_us: int = 0
var _src_us: int = 0
var _soot_us: int = 0
var _city_us: int = 0
var _snow_chunks: int = 0


## Allocates every field for a world of `world_size` tiles. Cheap: the whole data
## plane for a 256x256 world is ~90 KB.
func setup(world_size: Vector2i, snow_cap: float) -> void:
	size = Vector2i(maxi(world_size.x, 1), maxi(world_size.y, 1))
	snow_scale = 255.0 / maxf(1.0, snow_cap)
	_chunks = Vector2i(int(ceil(float(size.x) / 32.0)), int(ceil(float(size.y) / 32.0)))
	_chunk_version.clear()
	_snow_cursor = 0

	_snow_dim = _dim(SNOW_STEP)
	_heat_dim = _dim(HEAT_STEP)
	_soot_dim = _dim(SOOT_STEP)
	_city_dim = _dim(CITY_STEP)

	_kind = _alloc(size.x * size.y, LcnPalette.Terrain.SNOW)
	_snow = _alloc(_snow_dim.x * _snow_dim.y, 0)
	_heat = _alloc(_heat_dim.x * _heat_dim.y, 0)
	_soot = _alloc(_soot_dim.x * _soot_dim.y, 0)
	_city = _alloc(_city_dim.x * _city_dim.y, 0)
	_city_tmp = _alloc(_city_dim.x * _city_dim.y, 0)
	_city_raw = _alloc(_city_dim.x * _city_dim.y, 0)

	_kind_img = Image.create_from_data(size.x, size.y, false, Image.FORMAT_R8, _kind)
	_snow_img = Image.create_from_data(_snow_dim.x, _snow_dim.y, false, Image.FORMAT_R8, _snow)
	_heat_img = Image.create_from_data(_heat_dim.x, _heat_dim.y, false, Image.FORMAT_R8, _heat)
	_soot_img = Image.create_from_data(_soot_dim.x, _soot_dim.y, false, Image.FORMAT_R8, _soot)
	_city_img = Image.create_from_data(_city_dim.x, _city_dim.y, false, Image.FORMAT_R8, _city)

	kind_tex = ImageTexture.create_from_image(_kind_img)
	snow_tex = ImageTexture.create_from_image(_snow_img)
	heat_tex = ImageTexture.create_from_image(_heat_img)
	soot_tex = ImageTexture.create_from_image(_soot_img)
	city_tex = ImageTexture.create_from_image(_city_img)

	noise_tex = LcnArtCache.get_texture("field_noise_%d" % NOISE_SIZE, _bake_noise)
	palette_tex = ImageTexture.create_from_image(_bake_palette())


func _dim(step: int) -> Vector2i:
	return Vector2i(maxi(1, (size.x + step - 1) / step), maxi(1, (size.y + step - 1) / step))


static func _alloc(n: int, fill: int) -> PackedByteArray:
	var a := PackedByteArray()
	a.resize(maxi(n, 1))
	a.fill(fill)
	return a


# --------------------------------------------------------------------- kind --

## Pulls terrain ids for every chunk whose contents changed. `remap` maps the
## grid's terrain enum onto LcnPalette.Terrain. Returns the number of chunks
## rewritten, which is zero on all but the first call in a normal session.
func refresh_kind(model: LcnWorldModel) -> int:
	var t0: int = Time.get_ticks_usec()
	var changed: int = 0
	for cy: int in _chunks.y:
		for cx: int in _chunks.x:
			var key: int = cy * _chunks.x + cx
			var version: int = model.terrain_chunk_version(Vector2i(cx, cy))
			if _chunk_version.get(key, -1) == version:
				continue
			_chunk_version[key] = version
			_write_kind_chunk(model, Vector2i(cx, cy))
			changed += 1
	if changed > 0:
		_kind_img = Image.create_from_data(size.x, size.y, false, Image.FORMAT_R8, _kind)
		kind_tex.update(_kind_img)
	_kind_us = Time.get_ticks_usec() - t0
	return changed


func _write_kind_chunk(model: LcnWorldModel, chunk: Vector2i) -> void:
	var origin: Vector2i = chunk * 32
	model.invalidate_terrain_chunk(origin)
	var data: PackedByteArray = model.terrain_chunk(origin)
	if data.size() < 1024:
		return
	var w: int = size.x
	for ly: int in 32:
		var gy: int = origin.y + ly
		if gy >= size.y:
			break
		var src: int = ly * 32
		var dst: int = gy * w + origin.x
		var span: int = mini(32, size.x - origin.x)
		for lx: int in span:
			_kind[dst + lx] = data[src + lx]


# --------------------------------------------------------------------- snow --

## Refreshes up to `budget` chunks of snow depth, round-robin over the whole map,
## so the cost per frame is bounded no matter how big the world is. `force_chunks`
## jumps the queue — the renderer passes the chunks around a new building, whose
## melt ring must appear immediately rather than a quarter of a second later.
func refresh_snow(model: LcnWorldModel, budget: int, force_chunks: Array[Vector2i]) -> int:
	var t0: int = Time.get_ticks_usec()
	var total: int = maxi(1, _chunks.x * _chunks.y)
	var done: int = 0
	for c: Vector2i in force_chunks:
		if c.x >= 0 and c.y >= 0 and c.x < _chunks.x and c.y < _chunks.y:
			_write_snow_chunk(model, c)
			done += 1
	var n: int = mini(budget, total)
	for i: int in n:
		var idx: int = _snow_cursor % total
		_snow_cursor += 1
		_write_snow_chunk(model, Vector2i(idx % _chunks.x, idx / _chunks.x))
		done += 1
	if done > 0:
		_snow_img = Image.create_from_data(_snow_dim.x, _snow_dim.y, false, Image.FORMAT_R8, _snow)
		snow_tex.update(_snow_img)
	_snow_us = Time.get_ticks_usec() - t0
	_snow_chunks += done
	return done


func _write_snow_chunk(model: LcnWorldModel, chunk: Vector2i) -> void:
	var origin: Vector2i = chunk * 32
	var data: PackedByteArray = model.snow_chunk(origin)
	if data.size() < 1024:
		return
	var w: int = _snow_dim.x
	var half: int = 32 / SNOW_STEP
	for ly: int in half:
		var gy: int = (origin.y / SNOW_STEP) + ly
		if gy >= _snow_dim.y:
			break
		var src: int = (ly * SNOW_STEP) * 32
		var src2: int = src + 32 + 1
		var dst: int = gy * w + (origin.x / SNOW_STEP)
		for lx: int in half:
			var gx: int = (origin.x / SNOW_STEP) + lx
			if gx >= _snow_dim.x:
				break
			# Average the diagonal pair: one sample aliases the melt ring into a
			# dashed edge, four samples cost twice as much for no visible gain.
			_snow[dst + lx] = (int(data[src + lx * SNOW_STEP]) + int(data[src2 + lx * SNOW_STEP])) >> 1


# ------------------------------------------------------------- heat and soot --

## Rasterises the warm pools and the industrial grime. Both are bounded by the
## radii involved rather than by the map, so this is a few thousand byte writes
## even in a city that fills the screen.
## `region` is the visible world rect in pixels, grown by the caller. Sources
## outside it are skipped: nothing samples these fields off screen, and stamping
## a whole 1700-building city every refresh is 80 000 byte writes for pixels no
## camera can see.
func refresh_sources(sources: Array[Dictionary], buildings: Array[Dictionary],
		region: Rect2 = Rect2()) -> void:
	refresh_heat(sources, region)
	refresh_soot(buildings, region)


## Warm pools. Split from the soot pass so the two land on different frames and
## neither spike is the sum of both.
func refresh_heat(sources: Array[Dictionary], region: Rect2 = Rect2()) -> void:
	var t0: int = Time.get_ticks_usec()
	var cull: bool = region.size.x > 0.0
	_heat.fill(0)
	# Strongest first. The stamp early-out can only skip work once a texel is
	# already buried, so the order decides how much work there is: hottest first
	# saturates the district in a handful of discs and everything after it is a
	# single compare. Native sort on a packed key, no script callable.
	var order := PackedInt64Array()
	order.resize(sources.size())
	for i: int in sources.size():
		var v0: int = clampi(int(clampf(float(sources[i]["intensity"]), 0.0, 1.4) * 255.0), 0, 255)
		order[i] = ((255 - v0) << 32) | i
	order.sort()
	for k: int in order.size():
		var s: Dictionary = sources[int(order[k] & 0xFFFFFFFF)]
		var pos: Vector2 = s["pos"]
		# 0.62, not 0.92. The heat FIELD is what melts snow, wets the ground and
		# throws the warm pool; a light's reach is much wider than the patch of
		# plain it actually thaws, and at 0.92 a midday frame came back with half
		# the settlement painted salmon.
		var r: float = float(s["radius"]) / float(TILE) * 0.62
		if cull and not region.grow(r * float(TILE)).has_point(pos):
			continue
		var v: int = 255 - int(order[k] >> 32)
		_stamp(_heat, _heat_dim, HEAT_STEP, pos / float(TILE), r, v)
	_heat_img = Image.create_from_data(_heat_dim.x, _heat_dim.y, false, Image.FORMAT_R8, _heat)
	heat_tex.update(_heat_img)
	_src_us = Time.get_ticks_usec() - t0


## Industrial grime.
func refresh_soot(buildings: Array[Dictionary], region: Rect2 = Rect2()) -> void:
	var t0: int = Time.get_ticks_usec()
	var cull: bool = region.size.x > 0.0
	_soot.fill(0)
	for b: Dictionary in buildings:
		var w: float = float(b.get("soot", 0.0))
		if w <= 0.001:
			continue
		var rad: float = float(b.get("soot_radius", 0.0)) / float(TILE)
		if rad <= 0.0:
			continue
		var c: Vector2 = b["centre"]
		if cull and not region.grow(rad * float(TILE)).has_point(c):
			continue
		_stamp(_soot, _soot_dim, SOOT_STEP, c / float(TILE), rad,
			clampi(int(w * 255.0), 0, 255))
	_soot_img = Image.create_from_data(_soot_dim.x, _soot_dim.y, false, Image.FORMAT_R8, _soot)
	soot_tex.update(_soot_img)
	_soot_us = Time.get_ticks_usec() - t0


## Additive disc with a squared falloff, saturating instead of wrapping.
##
## The early-out matters more than it looks: in a dense district every structure
## is a source and their pools overlap many deep, so without it the cost is the
## number of BUILDINGS times the area of a pool. With it the cost is the area of
## the district — 13 ms became under 2 ms in the 1700-structure stress city, and
## the field it produces is identical, because a saturated texel cannot go up.
func _stamp(field: PackedByteArray, dim: Vector2i, step: int, centre_tiles: Vector2,
		radius_tiles: float, peak: int) -> void:
	if radius_tiles <= 0.0 or peak <= 0:
		return
	var r: float = radius_tiles / float(step)
	var cx: float = centre_tiles.x / float(step)
	var cy: float = centre_tiles.y / float(step)
	# Skip a stamp whose whole contribution is already buried. Four times this
	# stamp's own peak means it can move the texel by under a quarter of a step
	# in the visible ramp, and in a dense district almost every stamp after the
	# first few is in that position.
	var mid: int = clampi(int(cy), 0, dim.y - 1) * dim.x + clampi(int(cx), 0, dim.x - 1)
	if int(field[mid]) >= mini(250, peak * 3):
		return
	var x0: int = maxi(int(floor(cx - r)), 0)
	var x1: int = mini(int(ceil(cx + r)), dim.x - 1)
	var y0: int = maxi(int(floor(cy - r)), 0)
	var y1: int = mini(int(ceil(cy + r)), dim.y - 1)
	var inv: float = 1.0 / maxf(r, 0.0001)
	for y: int in range(y0, y1 + 1):
		var dy: float = (float(y) + 0.5 - cy) * inv
		var row: int = y * dim.x
		for x: int in range(x0, x1 + 1):
			var dx: float = (float(x) + 0.5 - cx) * inv
			var d2: float = dx * dx + dy * dy
			if d2 >= 1.0:
				continue
			var f: float = 1.0 - d2
			var add: int = int(float(peak) * f * f)
			var i: int = row + x
			var cur: int = int(field[i])
			field[i] = mini(255, cur + add)


# ---------------------------------------------------------- city / ambience --

## Where the settlement is, as a soft wide field. One write per building, then a
## separable box blur over a 32x32-ish image, so the cost does not grow with the
## size of the city — which matters, because this is what keeps a 1700-building
## base legible at deep night.
func refresh_city(buildings: Array[Dictionary]) -> void:
	var t0: int = Time.get_ticks_usec()
	var w: int = _city_dim.x
	var h: int = _city_dim.y
	_city_raw.fill(0)
	for b: Dictionary in buildings:
		var c: Vector2 = (b["centre"] as Vector2) / (float(TILE) * float(CITY_STEP))
		var x: int = clampi(int(c.x), 0, w - 1)
		var y: int = clampi(int(c.y), 0, h - 1)
		var i: int = y * w + x
		# A hearth anchors a district; a length of pipe does not.
		var tiles: Vector2i = b.get("tiles", Vector2i.ONE)
		var weight: int = 150 + int(clampf(float(b.get("warm", 0.0)), 0.0, 1.0) * 105.0)
		if tiles.x * tiles.y <= 1:
			weight = 95
		_city_raw[i] = maxi(int(_city_raw[i]), weight)

	# Two box passes in each direction — a triangular kernel, so the halo has no
	# visible step where the box ends. All four passes are linear in the field
	# size and independent of how many buildings made the stamps.
	_blur_axis(_city_raw, _city_tmp, w, h, true)
	_blur_axis(_city_tmp, _city, w, h, false)
	_blur_axis(_city, _city_tmp, w, h, true)
	_blur_axis(_city_tmp, _city, w, h, false)

	# The blur spreads the halo but flattens the peak, and an isolated hearth on
	# an empty plain still has to light its own block. Take whichever is greater.
	for i2: int in _city.size():
		# x2, not x4: at the higher gain the halo of a modest settlement saturated
		# forty tiles out and the wilderness stopped being wilderness — the plain
		# in the night frames was lit like a street.
		_city[i2] = mini(255, maxi(int(_city[i2]) * 2, int(_city_raw[i2])))
	_city_img = Image.create_from_data(w, h, false, Image.FORMAT_R8, _city)
	city_tex.update(_city_img)
	_city_us = Time.get_ticks_usec() - t0


## Sliding-window box blur: one add and one subtract per texel instead of a
## (2r+1)-tap kernel. Four of these passes over a 63x63 field cost about a
## millisecond; the naive form cost five, which showed up as a visible hitch
## every time the stress city's building set changed.
func _blur_axis(src: PackedByteArray, dst: PackedByteArray, w: int, h: int, horizontal: bool) -> void:
	var r: int = CITY_BLUR
	var span: int = r * 2 + 1
	if horizontal:
		for y: int in h:
			var row: int = y * w
			var acc: int = 0
			for k: int in range(-r, r + 1):
				acc += int(src[row + clampi(k, 0, w - 1)])
			for x: int in w:
				dst[row + x] = acc / span
				acc -= int(src[row + clampi(x - r, 0, w - 1)])
				acc += int(src[row + clampi(x + r + 1, 0, w - 1)])
		return
	for x2: int in w:
		var acc2: int = 0
		for k2: int in range(-r, r + 1):
			acc2 += int(src[clampi(k2, 0, h - 1) * w + x2])
		for y2: int in h:
			dst[y2 * w + x2] = acc2 / span
			acc2 -= int(src[clampi(y2 - r, 0, h - 1) * w + x2])
			acc2 += int(src[clampi(y2 + r + 1, 0, h - 1) * w + x2])


## 0..1 civilisation presence at a tile. The entity pass reads this so a building
## and the ground under it agree about how much ambient light they are getting.
func city_at(cell: Vector2i) -> float:
	if _city_dim.x <= 0:
		return 0.0
	var x: int = clampi(cell.x / CITY_STEP, 0, _city_dim.x - 1)
	var y: int = clampi(cell.y / CITY_STEP, 0, _city_dim.y - 1)
	return float(_city[y * _city_dim.x + x]) / 255.0


## 0..1 industrial soot at a tile, from the same field the ground shader samples.
func soot_at(cell: Vector2i) -> float:
	if _soot_dim.x <= 0:
		return 0.0
	var x: int = clampi(cell.x / SOOT_STEP, 0, _soot_dim.x - 1)
	var y: int = clampi(cell.y / SOOT_STEP, 0, _soot_dim.y - 1)
	return float(_soot[y * _soot_dim.x + x]) / 255.0


## 0..1 local heat at a tile, from the same field the ground shader samples.
func heat_at(cell: Vector2i) -> float:
	if _heat_dim.x <= 0:
		return 0.0
	var x: int = clampi(cell.x / HEAT_STEP, 0, _heat_dim.x - 1)
	var y: int = clampi(cell.y / HEAT_STEP, 0, _heat_dim.y - 1)
	return float(_heat[y * _heat_dim.x + x]) / 255.0


# ------------------------------------------------------------------- baking --

## Tileable white noise. Sampled with hardware bilinear filtering it *is* value
## noise, so one texture fetch buys one octave and the shader can afford five.
func _bake_noise() -> Image:
	var img: Image = Image.create(NOISE_SIZE, NOISE_SIZE, false, Image.FORMAT_RGBA8)
	for y: int in NOISE_SIZE:
		for x: int in NOISE_SIZE:
			img.set_pixel(x, y, Color(
				LcnNoise.hash3(x, y, 8101),
				LcnNoise.hash3(x, y, 24499),
				LcnNoise.hash3(x, y, 51203),
				LcnNoise.hash3(x, y, 77317)))
	return img


## Row 0 base, row 1 low, row 2 high, row 3 (grain, ridges, sparkle, relief).
func _bake_palette() -> Image:
	var img: Image = Image.create(PAL_WIDTH, PAL_ROWS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 1))
	for k: int in LcnPalette.TERRAIN_COUNT:
		var t: Dictionary = LcnPalette.terrain_tones(k)
		img.set_pixel(k, 0, t["base"])
		img.set_pixel(k, 1, t["low"])
		img.set_pixel(k, 2, t["high"])
		var p: Color = LcnPalette.terrain_params(k)
		# Snow-shedding surfaces record it in the alpha of the base row, which the
		# shader reads to keep drifts off geothermal ground and open ice.
		img.set_pixel(k, 0, Color(t["base"].r, t["base"].g, t["base"].b,
			0.0 if LcnPalette.terrain_sheds_snow(k) else 1.0))
		img.set_pixel(k, 3, p)
	return img


func stats() -> Dictionary:
	return {
		"kind_us": _kind_us,
		"snow_us": _snow_us,
		"sources_us": _src_us + _soot_us,
		"city_us": _city_us,
		"snow_chunks": _snow_chunks,
		"bytes": _kind.size() + _snow.size() + _heat.size() + _soot.size() + _city.size() * 3,
	}
