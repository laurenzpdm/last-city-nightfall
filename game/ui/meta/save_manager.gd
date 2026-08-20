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
##
## Those four steps now live in exactly one place, `Sim.deserialize()`, and
## `apply_world()` below calls it. See the comment there for what the second
## copy cost while it existed.

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
	# NEWEST FIRST, COMPARED AS WHOLE SECONDS, AND THAT IS A FIX.
	#
	# This used to read `if not is_equal_approx(ta, tb): return ta > tb`, on two
	# floats holding a Unix time. `is_equal_approx` is RELATIVE: its tolerance is
	# CMP_EPSILON (1e-5) x the magnitude of the operand, and a Unix time in 2026
	# is 1.79e9 — so anything written within about FIVE HOURS of anything else
	# counted as the same instant and the list fell through to sorting by slot
	# NAME. Every autosave this game writes is inside that window, so
	# `autosave_1` was permanently "the most recent save" and the title screen
	# offered whichever morning happened to land in slot 1. Continue is a claim
	# about recency; it has to be sorted by the thing it claims.
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ta: int = int(a.get("saved_unix", 0))
		var tb: int = int(b.get("saved_unix", 0))
		if ta != tb:
			return ta > tb
		return String(a.get("slot", "")) < String(b.get("slot", "")))
	return out


static func exists(slot_id: String) -> bool:
	return FileAccess.file_exists(LcnSaveFile.path_for(slot_id))


## True when at least one save exists — what "Continue" on the main menu asks.
static func has_any() -> bool:
	return not slots().is_empty()


## When a save was written, in the language the rest of this game uses.
##
## Every other time in this build is written rather than stamped — "Caldera
## Nine, the morning of the first day", "food runs out in 1.5 days", "0:42 to
## nightfall". The save list and the Continue row printed
## "2026-08-15 02:52:46": a machine timestamp, to the second, on the first
## screen a player sees, next to a line of prose about a lamp on Kettle Row.
static func when_words(saved_unix: int, now_unix: int = 0) -> String:
	if saved_unix <= 0:
		return "date unknown"
	var now: int = now_unix if now_unix > 0 else int(Time.get_unix_time_from_system())
	var ago: int = now - saved_unix
	if ago < 0:
		return "just now"
	if ago < 90:
		return "just now"
	if ago < 3600:
		var m: int = int(roundf(float(ago) / 60.0))
		return "%d minute%s ago" % [m, "" if m == 1 else "s"]
	if ago < 86400:
		var h: int = int(roundf(float(ago) / 3600.0))
		return "%d hour%s ago" % [h, "" if h == 1 else "s"]
	if ago < 172800:
		return "yesterday"
	var d: int = ago / 86400
	if d < 30:
		return "%d days ago" % d
	return Time.get_date_string_from_unix_time(saved_unix)


## How many souls a header is talking about, or -1 when it does not carry the
## figure at all.
##
## THE DIFFERENCE BETWEEN "NOBODY" AND "I DO NOT KNOW" IS THE WHOLE POINT. A
## header written by a build with no [P05] in it has no `population` key, and
## `int({}.get("population", 0))` turned that into a confident zero — which is
## how the title screen came to offer "Continue — Dawn of day 4 · 0 alive". The
## default is -1 so the two cases can never collapse into each other again.
static func souls_of(header: Dictionary) -> int:
	if not header.has("population"):
		return -1
	return maxi(-1, int(header.get("population", -1)))


## The souls clause for a header. Three cases and three different sentences:
##
##   no figure   ""              say nothing — the HUD's rule, applied here
##   zero        "no one left"   a fact, in the words the rest of the game uses
##   otherwise   "18 alive"
##
## Never "0 alive". A count of zero people is not a count, it is an ending, and
## printing it as a tally next to a Continue button says the city is still there.
static func souls_words(header: Dictionary) -> String:
	var pop: int = souls_of(header)
	if pop < 0:
		return ""
	if pop == 0:
		return "no one left"
	return "%d alive" % pop


## Whether a save is a city a player can go back TO.
##
## A recorded population of zero is not: that run ended, and offering it under
## "Continue" is the menu claiming a city exists that does not. A header with NO
## population figure is still resumable — this build cannot prove it is dead, so
## it does not get to say so.
static func is_resumable(header: Dictionary) -> bool:
	if header.is_empty():
		return false
	return souls_of(header) != 0


## The one-line description of a save, used by the browser and by Continue so
## the two cannot drift. The DAY is omitted when the save's own name already
## carries it — "Dawn of day 4 / day 4 · 0 alive" said day 4 twice.
static func describe_slot(header: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var day: int = int(header.get("day", 1))
	var name: String = String(header.get("name", ""))
	if not name.to_lower().contains("day %d" % day):
		parts.append("day %d" % day)
	var souls: String = souls_words(header)
	if souls != "":
		parts.append(souls)
	parts.append(when_words(int(header.get("saved_unix", 0))))
	return "  ·  ".join(parts)


## The most recently written slot, whatever state its city is in.
static func most_recent() -> Dictionary:
	var all: Array[Dictionary] = slots()
	return all[0] if not all.is_empty() else {}


## The slot "Continue" resumes: the most recent one that still has a city in it.
## Ended runs stay in the browser, where they are labelled honestly and can still
## be loaded on purpose — they are simply not offered as somewhere to carry on.
static func most_recent_playable() -> Dictionary:
	for head: Dictionary in slots():
		if is_resumable(head):
			return head
	return {}


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
	var souls: String = souls_words(header)
	Log.info("meta", "saved '%s' — day %d, %s, tick %d" % [
		slot, int(header.get("day", 0)),
		souls if souls != "" else "population not recorded",
		int(header.get("tick", 0))])
	return header


## Facts about the live world for a save header. Reads metrics, never state.
##
## **A FIGURE THIS BUILD CANNOT COMPUTE IS LEFT OUT, NOT SET TO ZERO.** The
## previous version seeded `pop = 0` and `hope = 0.0` and wrote them whether or
## not [P05] and [P06] were in the world, so every header taken without them
## claimed a city of nobody with no hope — and the title screen read those back
## and offered "Continue — Dawn of day 4 · 0 alive". Absent keys are what the
## readers above are written against: `souls_of()` answers -1 and the menu says
## nothing rather than something false.
static func describe_world() -> Dictionary:
	var out: Dictionary = {
		"tick": SimClock.tick,
		"seed": str(Rng.seed_value),
		"playtime_s": snappedf(float(SimClock.tick) * SimClock.DT, 0.1),
		"city": "Caldera Nine",
	}
	var climate: SimSystem = Sim.get_system(&"climate")
	if climate != null:
		var m: Dictionary = climate.metrics()
		out["day"] = int(m.get("day", 1))
		out["phase"] = String(m.get("phase", "dawn"))
	var citizens: SimSystem = Sim.get_system(&"citizens")
	if citizens != null:
		out["population"] = int(citizens.metrics().get("population", 0))
	var society: SimSystem = Sim.get_system(&"society")
	if society != null:
		out["hope"] = snappedf(float(society.metrics().get("hope", 0.0)), 0.001)
	return out


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


## Rebuilds the live world from a `Sim.serialize()` payload.
##
## ── THERE WERE TWO DOORS INTO A LOAD AND ONLY ONE OF THEM WAS MAINTAINED ─────
##
## The class comment above says "nothing here re-implements any of that", and
## until this wave that sentence was false about the function directly under it.
## This body WAS the four steps, hand-written a second time — create_world, set
## the tick, deserialize in sorted name order, restore the RNG — and it was
## correct on the day it was written. Then `Sim.deserialize()` grew a second
## restore pass and `LcnStateReconciler`, and this copy did not, because nothing
## made the two move together.
##
## The price, measured by `tests/meta/test_save_roundtrip.gd` on a live world:
## `Sim.deserialize` loses 8 fields, this door lost 40. The 32-field difference
## was entirely on the door a PLAYER uses — the simulation's own loader was the
## repaired one and the menu's was not.
##
## So it delegates now, and the delegation is the point: there is one loader, the
## suite that grades it grades both doors at once, and the next pass that teaches
## `Sim.deserialize()` something new cannot leave the player behind. Everything
## this body used to do itself — the absent-pillar ERROR, the loaded line in the
## log, `Bus.world_ready` — `Sim.deserialize()` already does, in the same order.
## Changed by the INTEGRATOR: [P24] owns this file and the save layer measured
## the gap, and neither of them may write in the other's folder.
static func apply_world(world: Dictionary) -> bool:
	return bool(Sim.deserialize(world)["ok"])


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
