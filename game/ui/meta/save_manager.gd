class_name LcnSaveManager
extends RefCounted
## [P24] Saving and loading a city. The only place in the build that turns a
## running world into a file and back.
##
## The simulation already knew how to describe itself: every `SimSystem` has
## `serialize()` / `deserialize()` and `Sim.serialize()` walks them. Nothing here
## re-implements any of that — this class is the part that was missing, which is
## the *order of operations* around it:
##
##   1. `Sim.create_world(seed)` rebuilds the systems and runs setup/post_setup,
##      so every cross-system reference is wired before any state lands;
##   2. `SimClock.tick` is restored BEFORE the systems deserialize, because
##      several of them stamp the current tick into what they rebuild
##      (`EnemySwarm.deserialize(rows, SimClock.tick)` is the loudest example);
##   3. systems deserialize in SORTED name order — not dictionary order — so a
##      load is as replayable as the run that produced it;
##   4. `Rng.restore()` last, because `create_world` reseeds every stream and a
##      restore before it would be thrown away.
##
## Get that order wrong and the failure is invisible: the city comes up, looks
## right, and diverges. `tests/meta/test_save_roundtrip.gd` is the check — it
## compares `Sim.serialize()` after a load against the bytes that were saved.

const AUTOSAVE_PREFIX: String = "autosave"
const QUICKSAVE_SLOT: String = "quicksave"
const AUTOSAVE_KEEP: int = 3
const THUMB_WIDTH: int = 384
const THUMB_HEIGHT: int = 216

## Every slot on disk, newest first. One dictionary per file:
##   {slot, name, day, population, tick, seed, saved_unix, saved_text, autosave,
##    playtime_s, city, build, world_bytes}
static func slots() -> Array[Dictionary]:
	LcnSaveFile.ensure_dir()
	var out: Array[Dictionary] = []
	var dir: DirAccess = DirAccess.open(LcnSaveFile.DIR)
	if dir == null:
		return out
	var names: Array[String] = []
	for f: String in dir.get_files():
		if f.ends_with("." + LcnSaveFile.EXT):
			names.append(f.get_basename())
	names.sort()
	for slot: String in names:
		var head: Dictionary = LcnSaveFile.read_header(slot)
		if head.is_empty():
			continue
		head["slot"] = slot
		out.append(head)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ta: float = float(a.get("saved_unix", 0.0))
		var tb: float = float(b.get("saved_unix", 0.0))
		if not is_equal_approx(ta, tb):
			return ta > tb
		return String(a.get("slot", "")) < String(b.get("slot", "")))
	return out


static func exists(slot_id: String) -> bool:
	return FileAccess.file_exists(LcnSaveFile.path_for(slot_id))


## True when at least one save exists — what "Continue" on the main menu asks.
static func has_any() -> bool:
	return not slots().is_empty()


## The slot "Continue" resumes: the most recently written one.
static func most_recent() -> Dictionary:
	var all: Array[Dictionary] = slots()
	return all[0] if not all.is_empty() else {}


# ==================================================================== save ===

## Writes the live world to `slot_id`. Returns the header written, or {} on
## failure. `display_name` is what the browser shows; empty takes the slot id.
static func save(slot_id: String, display_name: String = "", thumbnail: PackedByteArray = PackedByteArray()) -> Dictionary:
	var slot: String = sanitise_slot(slot_id)
	if slot == "":
		Log.error("meta", "save: refused an empty slot name")
		return {}
	if not Sim.alive:
		Log.error("meta", "save %s: there is no world to save" % slot)
		return {}
	var world: Dictionary = Sim.serialize()
	var header: Dictionary = describe_world()
	header["name"] = display_name if display_name != "" else _pretty(slot)
	header["autosave"] = slot.begins_with(AUTOSAVE_PREFIX)
	header["saved_unix"] = Time.get_unix_time_from_system()
	header["saved_text"] = Time.get_datetime_string_from_system(false, true)
	header["build"] = String(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	var thumb: PackedByteArray = thumbnail
	if thumb.is_empty():
		thumb = capture_thumbnail()
	var err: int = LcnSaveFile.write(slot, header, world, thumb)
	if err != OK:
		return {}
	header["slot"] = slot
	header["world_bytes"] = var_to_bytes(world).size()
	Log.info("meta", "saved '%s' — day %d, %d alive, tick %d" % [
		slot, int(header.get("day", 0)), int(header.get("population", 0)),
		int(header.get("tick", 0))])
	return header


## Facts about the live world for a save header. Reads metrics, never state.
static func describe_world() -> Dictionary:
	var day: int = 1
	var phase: String = "dawn"
	var pop: int = 0
	var hope: float = 0.0
	var climate: SimSystem = Sim.get_system(&"climate")
	if climate != null:
		var m: Dictionary = climate.metrics()
		day = int(m.get("day", 1))
		phase = String(m.get("phase", "dawn"))
	var citizens: SimSystem = Sim.get_system(&"citizens")
	if citizens != null:
		pop = int(citizens.metrics().get("population", 0))
	var society: SimSystem = Sim.get_system(&"society")
	if society != null:
		hope = float(society.metrics().get("hope", 0.0))
	return {
		"day": day,
		"phase": phase,
		"population": pop,
		"hope": snappedf(hope, 0.001),
		"tick": SimClock.tick,
		"seed": str(Rng.seed_value),
		"playtime_s": snappedf(float(SimClock.tick) * SimClock.DT, 0.1),
		"city": "Caldera Nine",
	}


## A PNG of what the player is looking at, scaled down. Empty with no renderer,
## which is the headless case and is not an error.
static func capture_thumbnail() -> PackedByteArray:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return PackedByteArray()
	if DisplayServer.get_name() == "headless":
		return PackedByteArray()
	var tex: ViewportTexture = tree.root.get_texture()
	if tex == null:
		return PackedByteArray()
	var img: Image = tex.get_image()
	if img == null or img.get_width() <= 0 or img.get_height() <= 0:
		return PackedByteArray()
	# Crop to the thumbnail's aspect before scaling, so a 16:10 window does not
	# save a squashed city.
	var want: float = float(THUMB_WIDTH) / float(THUMB_HEIGHT)
	var have: float = float(img.get_width()) / float(img.get_height())
	if absf(have - want) > 0.01:
		var w: int = img.get_width()
		var h: int = img.get_height()
		if have > want:
			w = int(round(float(h) * want))
		else:
			h = int(round(float(w) / want))
		img = img.get_region(Rect2i(
			(img.get_width() - w) / 2, (img.get_height() - h) / 2, w, h))
	img.resize(THUMB_WIDTH, THUMB_HEIGHT, Image.INTERPOLATE_BILINEAR)
	img.convert(Image.FORMAT_RGB8)
	return img.save_png_to_buffer()


## An ImageTexture for a header's thumbnail bytes, or null.
static func thumbnail_texture(bytes: PackedByteArray) -> ImageTexture:
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(img)


# ==================================================================== load ===

## Loads a slot into the live simulation. Returns false and changes NOTHING when
## the file is missing, corrupt, or not a world this build can rebuild.
static func load_slot(slot_id: String) -> bool:
	var slot: String = sanitise_slot(slot_id)
	var world: Dictionary = LcnSaveFile.read_world(slot)
	if world.is_empty():
		return false
	return apply_world(world)


## Rebuilds the live world from a `Sim.serialize()` payload. See the class
## comment for why the four steps are in this order.
static func apply_world(world: Dictionary) -> bool:
	var systems: Variant = world.get("systems", {})
	if typeof(systems) != TYPE_DICTIONARY:
		Log.error("meta", "load: the payload has no systems block")
		return false
	var seed_value: int = int(world.get("seed", 7))
	Sim.create_world(seed_value)
	SimClock.tick = int(world.get("tick", 0))
	var by_name: Dictionary = systems
	var names: Array = by_name.keys()
	names.sort()
	var restored: PackedStringArray = PackedStringArray()
	var absent: PackedStringArray = PackedStringArray()
	for n: String in names:
		var sys: SimSystem = Sim.get_system(StringName(n))
		if sys == null:
			absent.append(n)
			continue
		var payload: Variant = by_name[n]
		if typeof(payload) != TYPE_DICTIONARY:
			continue
		sys.deserialize(payload)
		restored.append(n)
	var rng: Variant = world.get("rng", {})
	if typeof(rng) == TYPE_DICTIONARY:
		Rng.restore(rng)
	if not absent.is_empty():
		# Not a warning. A save naming a pillar this build does not have means
		# the player is loading a city that cannot come back the way it went in.
		Log.error("meta", "load: this build has no %s system(s) — that state is LOST" % [
			", ".join(absent)])
	Log.info("meta", "loaded tick %d, seed %d, %d system(s): %s" % [
		SimClock.tick, seed_value, restored.size(), " ".join(restored)])
	Bus.world_ready.emit()
	return true


# ================================================================== delete ===

## Removes a slot. Returns true when the file is gone afterwards.
static func delete(slot_id: String) -> bool:
	var slot: String = sanitise_slot(slot_id)
	var path: String = LcnSaveFile.path_for(slot)
	if not FileAccess.file_exists(path):
		return true
	var err: int = DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if err != OK:
		err = DirAccess.remove_absolute(path)
	if err != OK:
		Log.error("meta", "could not delete save '%s' (err %d)" % [slot, err])
		return false
	Log.info("meta", "deleted save '%s'" % slot)
	return true


# ================================================================ autosave ===

## Slot id for an autosave on `day`, rotating over AUTOSAVE_KEEP files so a bad
## morning never overwrites the only copy of a good one.
static func autosave_slot(day: int) -> String:
	var index: int = posmod(maxi(day, 1) - 1, AUTOSAVE_KEEP) + 1
	return "%s_%d" % [AUTOSAVE_PREFIX, index]


static func is_autosave(slot_id: String) -> bool:
	return slot_id.begins_with(AUTOSAVE_PREFIX)


## The next free `save_N` id, for "New save" in the browser.
static func next_free_slot() -> String:
	var n: int = 1
	while exists("save_%d" % n) and n < 999:
		n += 1
	return "save_%d" % n


## Filename-safe slot id. Everything outside [a-z0-9_-] becomes '_', so a player
## naming a save "Day 12 / last one" cannot write outside the saves directory.
static func sanitise_slot(raw: String) -> String:
	var out: PackedStringArray = PackedStringArray()
	for i: int in raw.length():
		var c: String = raw[i].to_lower()
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-":
			out.append(c)
		elif c == " ":
			out.append("_")
	var joined: String = "".join(out).lstrip("_-")
	return joined.substr(0, 64)


static func _pretty(slot: String) -> String:
	return slot.replace("_", " ").capitalize()
