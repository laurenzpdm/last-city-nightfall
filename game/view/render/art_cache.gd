class_name LcnArtCache
extends RefCounted
## Disk cache for procedurally baked art. [P13]
##
## All placeholder art is *drawn in code*, which costs a second or two of CPU the
## first time. Baked images are written to user://art_cache/<version>/ and reused
## on every later launch, so the cost is paid once per art revision rather than
## once per run. Bump ART_VERSION whenever a draw routine changes, or the cache
## will happily serve you yesterday's silhouettes.

## Bump me when any procedural draw routine changes.
const ART_VERSION: String = "v14"

const DIR: String = "user://art_cache/%s" % ART_VERSION

static var _bake_ms: int = 0
static var _bakes: int = 0
static var _hits: int = 0
static var _enabled: bool = true


## Disables disk caching for a run (tests bake fresh so they test the baker).
static func set_enabled(on: bool) -> void:
	_enabled = on


## Returns the cached image for `key`, baking it with `baker` on a miss.
## `baker` must be a Callable taking no arguments and returning an Image.
static func get_image(key: String, baker: Callable) -> Image:
	var path: String = "%s/%s.png" % [DIR, key]
	if _enabled and FileAccess.file_exists(path):
		var cached: Image = Image.new()
		if cached.load(path) == OK and cached.get_width() > 0:
			_hits += 1
			return cached
	var t0: int = Time.get_ticks_usec()
	var img: Image = baker.call() as Image
	_bake_ms += int((Time.get_ticks_usec() - t0) / 1000)
	_bakes += 1
	if _enabled and img != null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
		img.save_png(ProjectSettings.globalize_path(path))
	return img


static func get_texture(key: String, baker: Callable) -> ImageTexture:
	var img: Image = get_image(key, baker)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


## One-line summary for the log so the art bake cost is never invisible.
static func report() -> String:
	return "art cache %s: %d baked (%d ms), %d loaded from disk" % [
		ART_VERSION, _bakes, _bake_ms, _hits,
	]


static func stats() -> Dictionary:
	return {"version": ART_VERSION, "baked": _bakes, "bake_ms": _bake_ms, "hits": _hits}


## Wipes every cached revision. Exposed for tooling and tests.
static func clear_all() -> void:
	var root: String = ProjectSettings.globalize_path("user://art_cache")
	var d := DirAccess.open(root)
	if d == null:
		return
	for sub: String in d.get_directories():
		var sd := DirAccess.open("%s/%s" % [root, sub])
		if sd == null:
			continue
		for f: String in sd.get_files():
			sd.remove(f)
		d.remove(sub)
