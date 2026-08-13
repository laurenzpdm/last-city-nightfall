class_name LcnVfxArt
extends RefCounted
## Procedurally baked particle art. [P14]
##
## Two products, for two very different consumers:
##
##   texture(name)  ONE small texture per GPU emitter. A GPUParticles2D draws a
##                  single texture for every particle it owns, so an atlas would
##                  be useless to it.
##   atlas()        ONE sheet plus regions, for the CPU-stepped burst buffer,
##                  which draws every transient particle out of a single texture
##                  and therefore batches into a handful of draw calls the way
##                  [P13]'s entity passes do.
##
## Everything is drawn in code and cached to disk through [LcnArtCache], so the
## bake cost is paid once per art revision rather than once per launch. Keys are
## namespaced `vfx_*` so they can never collide with [P13]'s sheet.

## Bump when a draw routine below changes.
const VERSION: String = "a1"

## Regions in the burst sheet, in draw order. Each is (x, y, w, h) in the sheet.
const SHEET_W: int = 256
const SHEET_H: int = 128

const R_DOT: Rect2 = Rect2(0, 0, 64, 64)          ## soft round core
const R_PUFF: Rect2 = Rect2(64, 0, 64, 64)        ## irregular smoke puff
const R_CHIP: Rect2 = Rect2(128, 0, 32, 32)       ## hard debris fleck
const R_SHARD: Rect2 = Rect2(160, 0, 32, 32)      ## ice shard, bright edge
const R_STAR: Rect2 = Rect2(192, 0, 32, 32)       ## four-point spark flare
const R_RING: Rect2 = Rect2(128, 32, 64, 64)      ## thin shockwave ring
const R_SPLAT: Rect2 = Rect2(192, 32, 32, 32)     ## settled-snow splat

static var _sheet: ImageTexture = null
static var _textures: Dictionary[String, ImageTexture] = {}


## Single texture for a GPU emitter. Names: dot, flake, puff, haze, mote.
static func texture(name: String) -> ImageTexture:
	var cached: ImageTexture = _textures.get(name)
	if cached != null:
		return cached
	var key: String = "vfx_%s_%s" % [name, VERSION]
	var tex: ImageTexture = LcnArtCache.get_texture(key, func() -> Image:
		return _bake_single(name))
	_textures[name] = tex
	return tex


## The burst sheet. One texture for every transient particle in the game.
static func atlas() -> ImageTexture:
	if _sheet != null:
		return _sheet
	_sheet = LcnArtCache.get_texture("vfx_sheet_%s" % VERSION, func() -> Image:
		return _bake_sheet())
	return _sheet


static func _bake_single(name: String) -> Image:
	match name:
		"dot":
			return _soft_dot(64, 2.1)
		"mote":
			return _soft_dot(32, 3.4)
		"flake":
			return _flake(32)
		"puff":
			return _puff(64, 9931)
		"haze":
			return _soft_dot(64, 5.5)
		_:
			return _soft_dot(32, 2.0)


static func _bake_sheet() -> Image:
	var sheet: Image = Image.create(SHEET_W, SHEET_H, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(1, 1, 1, 0))
	_blit(sheet, _soft_dot(64, 2.1), R_DOT)
	_blit(sheet, _puff(64, 4242), R_PUFF)
	_blit(sheet, _chip(32), R_CHIP)
	_blit(sheet, _shard(32), R_SHARD)
	_blit(sheet, _star(32), R_STAR)
	_blit(sheet, _ring(64), R_RING)
	_blit(sheet, _splat(32), R_SPLAT)
	return sheet


static func _blit(dst: Image, src: Image, at: Rect2) -> void:
	dst.blit_rect(src, Rect2i(Vector2i.ZERO, src.get_size()),
		Vector2i(int(at.position.x), int(at.position.y)))


# ------------------------------------------------------------------- shapes --

## White, alpha falls off as (1 - d)^power. `power` is the whole look: 2.1 is an
## ember, 5.5 is a haze you can barely see the edge of.
static func _soft_dot(size: int, power: float) -> Image:
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r: float = float(size) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) + 0.5 - r) / r
			var dy: float = (float(y) + 0.5 - r) / r
			var d: float = sqrt(dx * dx + dy * dy)
			var a: float = pow(clampf(1.0 - d, 0.0, 1.0), power)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return img


## A six-armed crystal with a soft halo. Small on screen, but the silhouette is
## what stops heavy snow reading as television static.
static func _flake(size: int) -> Image:
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r: float = float(size) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) + 0.5 - r) / r
			var dy: float = (float(y) + 0.5 - r) / r
			var d: float = sqrt(dx * dx + dy * dy)
			if d > 1.0:
				img.set_pixel(x, y, Color(1, 1, 1, 0))
				continue
			var ang: float = atan2(dy, dx)
			# Six arms: the cosine of 3*angle has six lobes over a full turn.
			var arm: float = absf(cos(ang * 3.0))
			var spine: float = pow(arm, 26.0)
			var halo: float = pow(1.0 - d, 2.6) * 0.42
			var a: float = clampf(spine * (1.0 - d) * 1.35 + halo, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return img


## Lumpy, so a plume never looks like a column of circles.
static func _puff(size: int, seed_value: int) -> Image:
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r: float = float(size) * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var lobes: Array[Vector3] = []
	for i: int in 5:
		lobes.append(Vector3(
			rng.randf_range(-0.34, 0.34), rng.randf_range(-0.34, 0.34),
			rng.randf_range(0.42, 0.72)))
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) + 0.5 - r) / r
			var dy: float = (float(y) + 0.5 - r) / r
			var a: float = 0.0
			for l: Vector3 in lobes:
				var d: float = sqrt((dx - l.x) * (dx - l.x) + (dy - l.y) * (dy - l.y))
				a = maxf(a, pow(clampf(1.0 - d / l.z, 0.0, 1.0), 1.9))
			a *= clampf(1.0 - smoothstep(0.72, 1.0, sqrt(dx * dx + dy * dy)), 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return img


## A hard-edged fleck of masonry. Debris must not be soft or it reads as smoke.
static func _chip(size: int) -> Image:
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r: float = float(size) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = absf(float(x) + 0.5 - r) / r
			var dy: float = absf(float(y) + 0.5 - r) / r
			# Diamond, not a circle: chips tumble and a diamond reads as facets.
			var d: float = dx * 0.78 + dy
			img.set_pixel(x, y, Color(1, 1, 1, 1.0 if d < 0.82 else 0.0))
	return img


## An ice shard: bright rim, translucent body, so shatter reads as glass.
static func _shard(size: int) -> Image:
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r: float = float(size) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) + 0.5 - r) / r
			var dy: float = (float(y) + 0.5 - r) / r
			# Tall sliver.
			var d: float = absf(dx) * 2.4 + absf(dy) * 0.85
			var inside: float = clampf(1.0 - d, 0.0, 1.0)
			if inside <= 0.0:
				img.set_pixel(x, y, Color(1, 1, 1, 0))
				continue
			var rim: float = pow(1.0 - inside, 3.0)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(0.30 + rim * 0.95, 0.0, 1.0)))
	return img


## Four-point flare. A muzzle flash and a spark impact both use it.
static func _star(size: int) -> Image:
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r: float = float(size) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) + 0.5 - r) / r
			var dy: float = (float(y) + 0.5 - r) / r
			var d: float = sqrt(dx * dx + dy * dy)
			var core: float = pow(clampf(1.0 - d, 0.0, 1.0), 3.4)
			var horiz: float = pow(clampf(1.0 - absf(dx), 0.0, 1.0), 1.6) \
				* pow(clampf(1.0 - absf(dy) * 7.0, 0.0, 1.0), 1.2)
			var vert: float = pow(clampf(1.0 - absf(dy), 0.0, 1.0), 1.6) \
				* pow(clampf(1.0 - absf(dx) * 7.0, 0.0, 1.0), 1.2)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(core + horiz * 0.7 + vert * 0.7, 0.0, 1.0)))
	return img


## Thin ring, for a shockwave that expands and thins.
static func _ring(size: int) -> Image:
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r: float = float(size) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) + 0.5 - r) / r
			var dy: float = (float(y) + 0.5 - r) / r
			var d: float = sqrt(dx * dx + dy * dy)
			var a: float = pow(clampf(1.0 - absf(d - 0.80) / 0.20, 0.0, 1.0), 1.7)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return img


## Where a flake landed. Wide, flat, gone in a second.
static func _splat(size: int) -> Image:
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r: float = float(size) * 0.5
	for y: int in size:
		for x: int in size:
			var dx: float = (float(x) + 0.5 - r) / r
			# Flattened vertically: this is snow seen from a top-down camera at a
			# shallow angle, not a sphere.
			var dy: float = (float(y) + 0.5 - r) / r * 2.3
			var d: float = sqrt(dx * dx + dy * dy)
			img.set_pixel(x, y, Color(1, 1, 1, pow(clampf(1.0 - d, 0.0, 1.0), 1.5)))
	return img
