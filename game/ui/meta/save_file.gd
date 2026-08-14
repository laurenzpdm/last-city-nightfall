class_name LcnSaveFile
extends RefCounted
## [P24] The on-disk shape of a saved city. One file per slot, under user://saves/.
##
## A save is two things that want to be read at different times:
##
##   * the HEADER — name, timestamp, day, population, the thumbnail. The slot
##     browser reads this for every file on disk, every time it opens, so it must
##     be readable WITHOUT parsing the world. A 3 MB world payload parsed six
##     times to draw six rows is a menu that stutters.
##   * the WORLD — `Sim.serialize()`, verbatim. Only read when a slot is loaded.
##
## So the layout is length-prefixed and seekable:
##
##   "LCNSAVE1"   8 bytes, magic
##   u32          format version
##   u32 + bytes  header, UTF-8 JSON
##   u32 + bytes  thumbnail, PNG (may be empty on a headless save)
##   u64 + bytes  world, `var_to_bytes` of Sim.serialize()
##
## **The world payload is binary, not JSON, and that is not a performance
## choice.** `Rng.snapshot()` reports each stream's position as a full 64-bit
## integer. JSON numbers are doubles, so the first version of this file wrote
## `-4710635756903808991` and read back `-4710635756903809024` — the low seven
## bits of every RNG stream, gone. The city reloaded looking perfect and then
## rolled a different night. `var_to_bytes` round-trips int64 and float64
## exactly, which is the whole requirement.
##
## The header stays JSON because a human should be able to read it, and it holds
## nothing but small integers, strings and a wall-clock time.
##
## The header carries `world_sha256`, and [method read_world] refuses a payload
## whose digest disagrees. A half-loaded city is worse than a refused one: it
## comes up looking almost right, and the player finds out three days later.

const MAGIC: String = "LCNSAVE1"
const FORMAT_VERSION: int = 1
const DIR: String = "user://saves"
const EXT: String = "lcn"

## Sanity ceilings. A file claiming a 400 MB header is corrupt, not ambitious,
## and allocating what it asks for is how a bad file becomes a crash.
const MAX_HEADER_BYTES: int = 1 << 20
const MAX_THUMB_BYTES: int = 8 << 20
const MAX_WORLD_BYTES: int = 512 << 20


## Absolute-ish res-style path for a slot id. Slot ids are filename-safe by
## construction (see LcnSaveManager.sanitise_slot).
static func path_for(slot_id: String) -> String:
	return "%s/%s.%s" % [DIR, slot_id, EXT]


static func ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		var err: int = DirAccess.make_dir_recursive_absolute(DIR)
		if err != OK:
			Log.error("meta", "cannot create %s (err %d) — saving is impossible" % [DIR, err])


## Writes one save. Returns OK, or the FileAccess error.
##
## Written to a `.part` file and renamed on success, so a crash mid-write leaves
## the PREVIOUS save intact instead of a truncated one wearing its name. An
## autosave that eats the save it is replacing is the single worst bug this
## whole part could ship.
static func write(slot_id: String, header: Dictionary, world: Dictionary, thumbnail: PackedByteArray) -> int:
	ensure_dir()
	var final_path: String = path_for(slot_id)
	var tmp_path: String = final_path + ".part"
	var world_bytes: PackedByteArray = var_to_bytes(world)
	var full: Dictionary = header.duplicate(true)
	full["world_sha256"] = _sha256_of(world_bytes)
	full["world_bytes"] = world_bytes.size()
	full["format"] = FORMAT_VERSION
	var header_bytes: PackedByteArray = JSON.stringify(full).to_utf8_buffer()

	var f: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		var err: int = FileAccess.get_open_error()
		Log.error("meta", "save %s: cannot open %s (err %d)" % [slot_id, tmp_path, err])
		return err
	f.store_buffer(MAGIC.to_ascii_buffer())
	f.store_32(FORMAT_VERSION)
	f.store_32(header_bytes.size())
	f.store_buffer(header_bytes)
	f.store_32(thumbnail.size())
	if thumbnail.size() > 0:
		f.store_buffer(thumbnail)
	f.store_64(world_bytes.size())
	f.store_buffer(world_bytes)
	f.close()

	if FileAccess.file_exists(final_path):
		var rm: int = DirAccess.remove_absolute(ProjectSettings.globalize_path(final_path))
		if rm != OK and DirAccess.remove_absolute(final_path) != OK:
			Log.warn("meta", "save %s: could not remove the previous file" % slot_id)
	var mv: int = DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path), ProjectSettings.globalize_path(final_path))
	if mv != OK:
		Log.error("meta", "save %s: rename failed (err %d); the data is in %s" % [slot_id, mv, tmp_path])
		return mv
	return OK


## Header only — cheap enough to call for every file in the directory.
## Returns {} when the file is missing, not a save, or a version we cannot read.
static func read_header(slot_id: String) -> Dictionary:
	var path: String = path_for(slot_id)
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var head: Dictionary = _read_header_from(f, path)
	f.close()
	return head


## Header plus the thumbnail bytes. Two reads would mean two opens; the browser
## wants both at once.
static func read_header_and_thumb(slot_id: String) -> Dictionary:
	var path: String = path_for(slot_id)
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var head: Dictionary = _read_header_from(f, path)
	if head.is_empty():
		f.close()
		return {}
	var thumb_len: int = int(f.get_32())
	var thumb: PackedByteArray = PackedByteArray()
	if thumb_len > 0 and thumb_len <= MAX_THUMB_BYTES:
		thumb = f.get_buffer(thumb_len)
	head["thumbnail"] = thumb
	f.close()
	return head


## The world payload, verified against the digest in the header.
## Returns {} on any disagreement — see the class comment.
static func read_world(slot_id: String) -> Dictionary:
	var path: String = path_for(slot_id)
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		Log.error("meta", "load %s: no file at %s" % [slot_id, path])
		return {}
	var head: Dictionary = _read_header_from(f, path)
	if head.is_empty():
		f.close()
		return {}
	var thumb_len: int = int(f.get_32())
	if thumb_len < 0 or thumb_len > MAX_THUMB_BYTES:
		Log.error("meta", "load %s: thumbnail length %d is not credible" % [slot_id, thumb_len])
		f.close()
		return {}
	f.seek(f.get_position() + thumb_len)
	var world_len: int = int(f.get_64())
	if world_len <= 0 or world_len > MAX_WORLD_BYTES:
		Log.error("meta", "load %s: world length %d is not credible" % [slot_id, world_len])
		f.close()
		return {}
	var world_bytes: PackedByteArray = f.get_buffer(world_len)
	f.close()
	if world_bytes.size() != world_len:
		Log.error("meta", "load %s: file ends %d bytes early" % [
			slot_id, world_len - world_bytes.size()])
		return {}
	var want: String = String(head.get("world_sha256", ""))
	if want != "" and _sha256_of(world_bytes) != want:
		Log.error("meta", "load %s: the world payload does not match its digest — refusing it" % slot_id)
		return {}
	# allow_objects stays FALSE. A save file is data a player can be handed by
	# someone else, and decoding objects out of one is arbitrary code execution.
	var parsed: Variant = bytes_to_var(world_bytes)
	if typeof(parsed) != TYPE_DICTIONARY:
		Log.error("meta", "load %s: the world payload did not decode to a dictionary" % slot_id)
		return {}
	return parsed


static func _read_header_from(f: FileAccess, path: String) -> Dictionary:
	var magic: PackedByteArray = f.get_buffer(MAGIC.length())
	if magic.get_string_from_ascii() != MAGIC:
		Log.warn("meta", "%s is not a Last City save" % path)
		return {}
	var version: int = int(f.get_32())
	if version > FORMAT_VERSION:
		Log.error("meta", "%s was written by a newer build (format %d, this build reads %d)" % [
			path, version, FORMAT_VERSION])
		return {}
	var header_len: int = int(f.get_32())
	if header_len <= 0 or header_len > MAX_HEADER_BYTES:
		Log.error("meta", "%s: header length %d is not credible" % [path, header_len])
		return {}
	var raw: PackedByteArray = f.get_buffer(header_len)
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		Log.error("meta", "%s: the header is not a JSON object" % path)
		return {}
	var head: Dictionary = parsed
	head["format"] = version
	return head


static func _sha256_of(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if ctx.update(bytes) != OK:
		return ""
	return ctx.finish().hex_encode()
