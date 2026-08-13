class_name LcnTerrainAtlas
extends RefCounted
## Builds the ground TileSet procedurally. [P13]
##
## Terrain is textural, not geometric, so unlike buildings it is generated
## per-pixel with tileable value noise rather than with the vector rasteriser.
## Every lattice lookup is wrapped to the tile period, so tiles butt against
## each other without visible seams while still carrying real surface detail.
##
## Layout (4 columns of variants):
##   rows 0..8   base terrain, one row per LcnPalette.Terrain
##   rows 9..11  snow accumulation overlays, light -> heavy
##   row  12     ice fracture overlays
##   row  13     industrial soot overlays
##   row  14     trodden path / frost rim overlays

const TILE: int = 32
const VARIANTS: int = 4
const PAD: int = 2
const STRIDE: int = TILE + PAD * 2

const ROW_SNOW: int = 9
const ROW_CRACK: int = 12
const ROW_SOOT: int = 13
const ROW_PATH: int = 14
const ROWS: int = 15

const SNOW_LEVELS: int = 3

var tile_set: TileSet = null
var source_id: int = 0

var _image: Image = null
var _texture: ImageTexture = null


## Builds (or loads from the art cache) the atlas and the TileSet around it.
func build() -> void:
	if tile_set != null:
		return
	_image = LcnArtCache.get_image("terrain_atlas", _bake_atlas)
	_texture = ImageTexture.create_from_image(_image)
	var src := TileSetAtlasSource.new()
	src.texture = _texture
	src.texture_region_size = Vector2i(TILE, TILE)
	src.margins = Vector2i(PAD, PAD)
	src.separation = Vector2i(PAD * 2, PAD * 2)
	for row: int in ROWS:
		for col: int in VARIANTS:
			src.create_tile(Vector2i(col, row))
	tile_set = TileSet.new()
	tile_set.tile_size = Vector2i(TILE, TILE)
	source_id = tile_set.add_source(src, 0)


func texture() -> ImageTexture:
	return _texture


func atlas_image() -> Image:
	return _image


func tile_count() -> int:
	return ROWS * VARIANTS


## Atlas cell for a base terrain kind. `variant` is any int; it is wrapped, so
## callers can pass a cell hash straight through.
static func base_coords(kind: int, variant: int) -> Vector2i:
	return Vector2i(posmod(variant, VARIANTS), clampi(kind, 0, LcnPalette.TERRAIN_COUNT - 1))


## Snow accumulation overlay. `level` 1..3, deeper is whiter and more covering.
static func snow_coords(level: int, variant: int) -> Vector2i:
	return Vector2i(posmod(variant, VARIANTS), ROW_SNOW + clampi(level - 1, 0, SNOW_LEVELS - 1))


static func crack_coords(variant: int) -> Vector2i:
	return Vector2i(posmod(variant, VARIANTS), ROW_CRACK)


static func soot_coords(variant: int) -> Vector2i:
	return Vector2i(posmod(variant, VARIANTS), ROW_SOOT)


static func path_coords(variant: int) -> Vector2i:
	return Vector2i(posmod(variant, VARIANTS), ROW_PATH)


# ------------------------------------------------------------------- baking --

func _bake_atlas() -> Image:
	var w: int = VARIANTS * STRIDE
	var h: int = ROWS * STRIDE
	var atlas: Image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	for row: int in ROWS:
		for col: int in VARIANTS:
			var tile: Image = _bake_tile(row, col)
			_blit_padded(atlas, tile, col * STRIDE, row * STRIDE)
	return atlas


## Copies a 32x32 tile into the atlas with its edge pixels extended into the
## 2px gutter, so linear filtering at zoomed-out scale cannot bleed neighbours.
func _blit_padded(atlas: Image, tile: Image, ox: int, oy: int) -> void:
	for y: int in STRIDE:
		for x: int in STRIDE:
			var sx: int = clampi(x - PAD, 0, TILE - 1)
			var sy: int = clampi(y - PAD, 0, TILE - 1)
			atlas.set_pixel(ox + x, oy + y, tile.get_pixel(sx, sy))


func _bake_tile(row: int, col: int) -> Image:
	if row < LcnPalette.TERRAIN_COUNT:
		return _bake_terrain(row, col)
	if row < ROW_CRACK:
		return _bake_snow_overlay(row - ROW_SNOW + 1, col)
	if row == ROW_CRACK:
		return _bake_crack_overlay(col)
	if row == ROW_SOOT:
		return _bake_soot_overlay(col)
	return _bake_path_overlay(col)


func _bake_terrain(kind: int, variant: int) -> Image:
	var t: Dictionary = LcnPalette.terrain_tones(kind)
	var base: Color = t["base"]
	var low: Color = t["low"]
	var high: Color = t["high"]
	var grain: float = t["grain"]
	var ridges: float = t["ridges"]
	var s: int = 1000 + kind * 131 + variant * 17
	var img: Image = Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)

	for y: int in TILE:
		for x: int in TILE:
			var fx: float = float(x) / float(TILE)
			var fy: float = float(y) / float(TILE)
			var n: float = _tfbm(fx * 4.0, fy * 4.0, 4, s, 3)
			var col: Color = low.lerp(high, clampf(n * 1.15 + 0.06, 0.0, 1.0))
			col = col.lerp(base, 0.45)

			if ridges > 0.0:
				# Wind-scoured drift lines, sheared so they never look like a grid.
				var r: float = _tridge((fx + fy * 0.35) * 3.0, fy * 7.0, 8, s + 51)
				col = col.lerp(high, clampf((r - 0.55) * 1.8, 0.0, 1.0) * 0.55 * ridges)
				col = col.lerp(low, clampf((0.35 - r) * 1.6, 0.0, 1.0) * 0.30 * ridges)

			match kind:
				LcnPalette.Terrain.ICE:
					var e: float = _tworley_edge(fx * 2.4, fy * 2.4, 3, s + 7)
					if e < 0.12:
						col = col.lerp(high, (0.12 - e) / 0.12 * 0.85)
					var sheen: float = _tfbm(fx * 1.5, fy * 1.5, 2, s + 200, 2)
					col = col.lerp(LcnPalette.ICE_BLUE, sheen * 0.16)
				LcnPalette.Terrain.WATER_FROZEN:
					var e2: float = _tworley_edge(fx * 1.6, fy * 1.6, 2, s + 11)
					if e2 < 0.09:
						col = col.lerp(Color(0.78, 0.87, 0.94), (0.09 - e2) / 0.09 * 0.62)
				LcnPalette.Terrain.ROCK:
					# Broken plates: lit centres, hard fissures along the seams.
					var d0: float = _tworley(fx * 2.0, fy * 2.0, 2, s + 23)
					var e0: float = _tworley_edge(fx * 2.0, fy * 2.0, 2, s + 23)
					col = col.lerp(high, clampf(1.0 - d0 * 1.9, 0.0, 1.0) * 0.50)
					if e0 < 0.07:
						col = col.lerp(Color(0.020, 0.031, 0.055), (1.0 - e0 / 0.07) * 0.70)
				LcnPalette.Terrain.GRAVEL, LcnPalette.Terrain.RUBBLE:
					var d: float = _tworley(fx * 6.0, fy * 6.0, 6, s + 31)
					col = col.lerp(high, clampf(1.0 - d * 2.4, 0.0, 1.0) * 0.55)
					col = col.lerp(low, clampf(d * 1.4 - 0.4, 0.0, 1.0) * 0.5)
				LcnPalette.Terrain.PAVED:
					# Cast slabs: joints on the tile border read as a real grid.
					var edge: float = minf(minf(float(x), float(TILE - 1 - x)), minf(float(y), float(TILE - 1 - y)))
					if edge < 1.5:
						col = col.lerp(low.darkened(0.3), 0.8)
					elif edge < 2.6:
						col = col.lerp(high, 0.22)
					if x == 15 or x == 16 or y == 15 or y == 16:
						col = col.lerp(low, 0.35)
				LcnPalette.Terrain.ASH_FIELD:
					var em: float = _tfbm(fx * 9.0, fy * 9.0, 9, s + 77, 2)
					if em > 0.93:
						col = col.lerp(LcnPalette.EMBER, (em - 0.93) / 0.07 * 0.55)

			var g: float = LcnNoise.shash3(x, y, s) * grain
			img.set_pixel(x, y, Color(
				clampf(col.r + g, 0.0, 1.0),
				clampf(col.g + g * 0.96, 0.0, 1.0),
				clampf(col.b + g * 0.90, 0.0, 1.0),
				1.0
			))

	# Sparkle: a handful of blown-out specks make snow read as crystalline.
	if kind == LcnPalette.Terrain.SNOW or kind == LcnPalette.Terrain.SNOW_DEEP:
		for i: int in 7:
			var px: int = int(LcnNoise.hash3(i, variant, s) * float(TILE)) % TILE
			var py: int = int(LcnNoise.hash3(i, variant + 40, s + 5) * float(TILE)) % TILE
			img.set_pixel(px, py, Color(1.0, 1.0, 1.0, 1.0))
	return img


func _bake_snow_overlay(level: int, variant: int) -> Image:
	var img: Image = Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	var s: int = 4400 + level * 91 + variant * 13
	var cover: float = lerpf(0.34, 0.86, float(level - 1) / float(SNOW_LEVELS - 1))
	var bright: float = lerpf(0.55, 0.95, float(level - 1) / float(SNOW_LEVELS - 1))
	for y: int in TILE:
		for x: int in TILE:
			var fx: float = float(x) / float(TILE)
			var fy: float = float(y) / float(TILE)
			var n: float = _tfbm(fx * 3.0, fy * 3.0, 3, s, 3)
			var a: float = smoothstep(1.0 - cover - 0.16, 1.0 - cover + 0.16, n)
			if a <= 0.004:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			# Lit crest / cool trough shading inside the drift itself.
			var shade: float = clampf((n - (1.0 - cover)) * 2.4, 0.0, 1.0)
			var c: Color = LcnPalette.SNOW_MID.lerp(LcnPalette.SNOW_LIT, shade)
			var g: float = LcnNoise.shash3(x, y, s) * 0.05
			img.set_pixel(x, y, Color(
				clampf(c.r + g, 0.0, 1.0), clampf(c.g + g, 0.0, 1.0), clampf(c.b + g, 0.0, 1.0),
				a * bright
			))
	return img


func _bake_crack_overlay(variant: int) -> Image:
	var img: Image = Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	var s: int = 7700 + variant * 37
	for y: int in TILE:
		for x: int in TILE:
			var fx: float = float(x) / float(TILE)
			var fy: float = float(y) / float(TILE)
			var e: float = _tworley_edge(fx * 2.0 + 0.3, fy * 2.0, 2, s)
			var a: float = clampf((0.085 - e) / 0.085, 0.0, 1.0)
			if a <= 0.02:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			# A dark fissure with a frost-bright shoulder either side.
			var core: float = clampf((0.035 - e) / 0.035, 0.0, 1.0)
			var c: Color = Color(0.70, 0.85, 0.96).lerp(Color(0.06, 0.12, 0.22), core)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, a * 0.78))
	return img


func _bake_soot_overlay(variant: int) -> Image:
	var img: Image = Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	var s: int = 9100 + variant * 53
	for y: int in TILE:
		for x: int in TILE:
			var fx: float = float(x) / float(TILE)
			var fy: float = float(y) / float(TILE)
			var n: float = _tfbm(fx * 2.6, fy * 2.6, 3, s, 3)
			var a: float = smoothstep(0.34, 0.86, n) * 0.82
			var speck: float = LcnNoise.hash3(x, y, s + 3)
			if speck > 0.985:
				a = maxf(a, 0.65)
			if a <= 0.004:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var c: Color = LcnPalette.ASH.lerp(Color(0.055, 0.047, 0.043), n)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, a))
	return img


func _bake_path_overlay(variant: int) -> Image:
	var img: Image = Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	var s: int = 5500 + variant * 29
	for y: int in TILE:
		for x: int in TILE:
			var fx: float = float(x) / float(TILE)
			var fy: float = float(y) / float(TILE)
			var n: float = _tfbm(fx * 4.5, fy * 4.5, 5, s, 2)
			var a: float = smoothstep(0.42, 0.80, n) * 0.55
			if a <= 0.004:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var c: Color = LcnPalette.SNOW_SHADOW.lerp(LcnPalette.STEEL, n)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, a))
	return img


# ------------------------------------------------------- tileable noise ------
# Lattice coordinates wrap modulo `period`, which is what makes every tile
# seamless against a copy of itself and against its neighbours.

static func _tvalue(x: float, y: float, period: int, s: int) -> float:
	var xi: int = int(floor(x))
	var yi: int = int(floor(y))
	var xf: float = x - float(xi)
	var yf: float = y - float(yi)
	var u: float = xf * xf * (3.0 - 2.0 * xf)
	var v: float = yf * yf * (3.0 - 2.0 * yf)
	var x0: int = posmod(xi, period)
	var y0: int = posmod(yi, period)
	var x1: int = posmod(xi + 1, period)
	var y1: int = posmod(yi + 1, period)
	var a: float = LcnNoise.hash3(x0, y0, s)
	var b: float = LcnNoise.hash3(x1, y0, s)
	var c: float = LcnNoise.hash3(x0, y1, s)
	var d: float = LcnNoise.hash3(x1, y1, s)
	return lerpf(lerpf(a, b, u), lerpf(c, d, u), v)


static func _tfbm(x: float, y: float, period: int, s: int, octaves: int) -> float:
	var sum: float = 0.0
	var amp: float = 1.0
	var norm: float = 0.0
	var p: int = period
	var fx: float = x
	var fy: float = y
	for i: int in octaves:
		sum += _tvalue(fx, fy, p, s + i * 977) * amp
		norm += amp
		amp *= 0.5
		fx *= 2.0
		fy *= 2.0
		p *= 2
	return sum / maxf(0.0001, norm)


static func _tridge(x: float, y: float, period: int, s: int) -> float:
	var sum: float = 0.0
	var amp: float = 1.0
	var norm: float = 0.0
	var p: int = period
	var fx: float = x
	var fy: float = y
	for i: int in 3:
		var n: float = 1.0 - absf(_tvalue(fx, fy, p, s + i * 613) * 2.0 - 1.0)
		sum += n * n * amp
		norm += amp
		amp *= 0.45
		fx *= 2.0
		fy *= 2.0
		p *= 2
	return sum / maxf(0.0001, norm)


static func _feature_point(cx: int, cy: int, period: int, s: int) -> Vector2:
	var wx: int = posmod(cx, period)
	var wy: int = posmod(cy, period)
	return Vector2(float(cx) + LcnNoise.hash3(wx, wy, s), float(cy) + LcnNoise.hash3(wx, wy, s + 7919))


static func _tworley(x: float, y: float, period: int, s: int) -> float:
	var xi: int = int(floor(x))
	var yi: int = int(floor(y))
	var best: float = 9.0
	for oy: int in range(-1, 2):
		for ox: int in range(-1, 2):
			var p: Vector2 = _feature_point(xi + ox, yi + oy, period, s)
			best = minf(best, p.distance_to(Vector2(x, y)))
	return clampf(best, 0.0, 1.0)


static func _tworley_edge(x: float, y: float, period: int, s: int) -> float:
	var xi: int = int(floor(x))
	var yi: int = int(floor(y))
	var d1: float = 9.0
	var d2: float = 9.0
	for oy: int in range(-2, 3):
		for ox: int in range(-2, 3):
			var p: Vector2 = _feature_point(xi + ox, yi + oy, period, s)
			var d: float = p.distance_to(Vector2(x, y))
			if d < d1:
				d2 = d1
				d1 = d
			elif d < d2:
				d2 = d
	return clampf(d2 - d1, 0.0, 1.0)
