class_name LcnSaveSlots
extends RefCounted
## Test isolation for everything that lives in `user://` — and the reason nine
## save/settings tests were failing the gate on a build where nothing was wrong
## with saving.
##
## THE DEFECT THIS FIXES IS IN THE TESTS, NOT IN THE GAME. `user://saves/` and
## `user://settings.cfg` are ONE directory per machine, not one per process. Four
## agents on four cores each run `tools/check.sh`, each spawns Godot, and every
## one of them writes `user://saves/test_roundtrip.lcn`, rotates
## `autosave_1..3`, and rewrites the player's `settings.cfg`. So:
##
##   * `test_a_saved_city_comes_back_identical` saved a world on seed 7, another
##     process wrote its own seed-999 world over the same file, and the first
##     process loaded that. The suite then reported 44 fields differing —
##     including `$.seed`, all six RNG streams, `$.systems.grid.hash` and
##     society's hope — and every one of those fields round-trips perfectly. The
##     measurement was of two different cities.
##   * `test_the_rotation_comes_back_round_rather_than_growing_forever` counts
##     every autosave file on the machine.
##   * `test_a_save_written_now_is_on_disk_for_the_next_launch` counts the slots
##     before and demands exactly one more afterwards.
##   * the restart probe boots a second process that reads the same
##     `settings.cfg` a concurrent suite is in the middle of rewriting.
##
## Reproduced deliberately: two `--part=meta` runs started together, one passes
## 38 of 38, the other fails 5. That is the whole of it.
##
## TWO TOOLS, and which one to reach for:
##
##   [method scratch] — a slot id nobody else can be using, because it carries
##   this process's id. Use it for every save a test writes. No waiting, no
##   shared state, and it is what tests/save uses throughout.
##
##   [method hold] — an exclusive, cross-process lock, for the tests that
##   genuinely cannot be namespaced: the autosave rotation writes fixed slot ids
##   (`autosave_1`), and `settings.cfg` is a fixed path in `game/core/`. Those
##   suites take the lock for their whole run so two machines' worth of agents
##   take turns instead of overwriting each other.
##
## The lock is a directory, because `make_dir` is the one filesystem operation
## that is atomic and fails cleanly when the thing already exists. It carries the
## holder's pid and the time it was taken, and a lock older than [constant
## STALE_SECONDS] is broken rather than waited on — a Godot process killed by
## `timeout -k 5` mid-suite must not wedge the gate for everyone afterwards.

const LOCK_DIR: String = "user://.lcn_test_lock"
const OWNER_FILE: String = LOCK_DIR + "/owner.txt"
const STALE_SECONDS: int = 300
const WAIT_STEP_MS: int = 120
const MAX_WAIT_MS: int = 240000

static var _depth: int = 0
static var _tag: String = ""


## A save slot id no other process on this machine will pick. Sanitised the same
## way `LcnSaveManager` sanitises a player's name, so it is still a legal slot.
static func scratch(base: String) -> String:
	return LcnSaveManager.sanitise_slot("%s_p%d" % [base, OS.get_process_id()])


## True when `slot` was minted by [method scratch] in THIS process. Suites that
## count files on disk use it to ignore everybody else's.
static func is_ours(slot: String) -> bool:
	return slot.ends_with("_p%d" % OS.get_process_id())


## How many of the slots on disk belong to this process.
static func ours_on_disk() -> int:
	var n: int = 0
	for head: Dictionary in LcnSaveManager.slots():
		if is_ours(String(head.get("slot", ""))):
			n += 1
	return n


## Deletes every scratch slot this process wrote. Cheap insurance in after_all:
## a suite that fails half way through must not leave litter for the next run to
## count.
static func purge() -> void:
	for head: Dictionary in LcnSaveManager.slots():
		var slot: String = String(head.get("slot", ""))
		if is_ours(slot):
			var _d: bool = LcnSaveManager.delete(slot)


# ------------------------------------------------------------------- lock ---

## Takes the machine-wide test lock. Re-entrant within a process. Returns true
## when the lock is held — it always ends up held, because a wait that has run
## out of patience breaks the lock rather than failing the suite; a stuck gate
## teaches nobody anything.
static func hold(tag: String) -> bool:
	_depth += 1
	if _depth > 1:
		return true
	_tag = tag
	var waited: int = 0
	while true:
		if DirAccess.make_dir_absolute(LOCK_DIR) == OK:
			_stamp(tag)
			return true
		if _age_seconds() > STALE_SECONDS or waited >= MAX_WAIT_MS:
			_force_release()
			continue
		OS.delay_msec(WAIT_STEP_MS)
		waited += WAIT_STEP_MS
	return true


## Releases the lock taken by [method hold]. Safe to call unbalanced.
static func drop() -> void:
	_depth = maxi(0, _depth - 1)
	if _depth > 0:
		return
	if _mine():
		_force_release()


static func _mine() -> bool:
	return _read_owner().get("pid", -1) == OS.get_process_id()


static func _stamp(tag: String) -> void:
	var f: FileAccess = FileAccess.open(OWNER_FILE, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"pid": OS.get_process_id(),
		"unix": int(Time.get_unix_time_from_system()),
		"tag": tag,
	}))
	f.close()


static func _read_owner() -> Dictionary:
	if not FileAccess.file_exists(OWNER_FILE):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(OWNER_FILE))
	return parsed if parsed is Dictionary else {}


## Seconds since the lock was taken. A lock directory with no readable owner file
## is treated as ancient: it is either a half-written stamp or somebody else's
## crash, and both want breaking.
static func _age_seconds() -> int:
	var owner: Dictionary = _read_owner()
	if owner.is_empty():
		return STALE_SECONDS + 1
	return int(Time.get_unix_time_from_system()) - int(owner.get("unix", 0))


static func _force_release() -> void:
	if FileAccess.file_exists(OWNER_FILE):
		var _f: int = DirAccess.remove_absolute(OWNER_FILE)
	var _d: int = DirAccess.remove_absolute(LOCK_DIR)
