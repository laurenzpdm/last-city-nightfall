class_name LcnSteamSeam
extends RefCounted
## [P24] The Steamworks seam. **There is deliberately no Steam binary in this
## repository**, and adding one is a decision for the person who owns the
## Steamworks account, not for a build agent.
##
## What a GDExtension dependency would cost right now, measured rather than
## asserted: `godotsteam` ships a per-platform `.so`/`.dll`/`.dylib` plus a
## `.gdextension`, the editor loads it at startup, and every headless run in
## `tools/check.sh` would then need `steam_api` present or would print a load
## error per invocation. The gate counts engine errors. So the dependency lands
## when someone can attach it to a real app id, and until then this file is the
## shape it will land in.
##
## THE SEAM. Everything the game wants from Steam goes through the six calls
## below. They are no-ops that log at debug level. To turn Steam on:
##
##   1. add the GDExtension under `addons/` and its binaries;
##   2. set `LcnSteamSeam.APP_ID` to the real app id (480 is Valve's test id);
##   3. replace the bodies below with the four Steam calls they name —
##      `Steam.steamInit`, `Steam.setAchievement`, `Steam.storeStats`,
##      `Steam.runCallbacks` from `_process` on one node;
##   4. add `steam_appid.txt` next to the binary for local testing only. It must
##      NOT be shipped: with it present the client trusts whatever app id the
##      file says, which is exactly the hole Valve tells you not to ship.
##
## Nothing else in the build calls Steam directly, so step 3 is the whole
## integration and it is testable: `tests/meta/test_steam_seam.gd` asserts the
## calls are safe with no Steam present, which is also the state every CI run is
## in.

## Valve's public test app id. Replace with the real one at store-page time.
const APP_ID: int = 480

## Achievements the build already has the facts to raise, with the condition
## each one is waiting for. They are declared here so the Steamworks partner
## page and the code cannot drift apart — this array IS the list to enter there.
const ACHIEVEMENTS: Array[Dictionary] = [
	{"id": &"first_night", "name": "The First Night",
		"how": "Survive the first night with the Hearth still lit.",
		"fact": "climate.day >= 2 and heat.hearth_alive"},
	{"id": &"the_belts_run", "name": "The Belts Run",
		"how": "Move a thousand items on belts in one city.",
		"fact": "logistics.items_moved >= 1000"},
	{"id": &"nobody_froze", "name": "Nobody Froze",
		"how": "Reach day five with no death from cold.",
		"fact": "climate.day >= 5 and citizens.deaths.cold == 0"},
	{"id": &"the_long_winter", "name": "The Long Winter",
		"how": "Reach day twenty.", "fact": "climate.day >= 20"},
	{"id": &"held_the_line", "name": "Held the Line",
		"how": "Clear ten waves without losing a building.",
		"fact": "threat.waves_cleared >= 10 and combat.structures_lost == 0"},
]

static var _initialised: bool = false
static var _unlocked: Dictionary[StringName, bool] = {}


## True when a real Steam client is attached. Always false until the seam is
## filled in, and everything below is written to be correct in that state.
static func available() -> bool:
	return Engine.has_singleton("Steam")


## Called once at startup. Safe, and quiet, with no Steam present.
static func init_if_present() -> bool:
	if _initialised:
		return available()
	_initialised = true
	if not available():
		Log.debug("meta", "no Steam client attached — the seam is inert (see LcnSteamSeam)")
		return false
	Log.info("meta", "Steam seam: a Steam singleton is present; wire steamInit here")
	return true


## Raise an achievement. Idempotent per session.
static func unlock(id: StringName) -> void:
	if _unlocked.get(id, false):
		return
	if not _is_declared(id):
		Log.warn("meta", "achievement '%s' is not in LcnSteamSeam.ACHIEVEMENTS" % id)
		return
	_unlocked[id] = true
	Log.info("meta", "achievement: %s" % id)
	if available():
		Log.info("meta", "Steam seam: setAchievement + storeStats go here for '%s'" % id)


static func unlocked_this_session() -> Array[StringName]:
	var keys: Array = _unlocked.keys()
	keys.sort()
	var out: Array[StringName] = []
	for k: StringName in keys:
		out.append(k)
	return out


static func _is_declared(id: StringName) -> bool:
	for row: Dictionary in ACHIEVEMENTS:
		if StringName(row["id"]) == id:
			return true
	return false


## What the title screen prints in the corner: which build, on what.
static func platform_line() -> String:
	var os_name: String = OS.get_name()
	var arch: String = Engine.get_architecture_name()
	return "%s %s%s" % [os_name, arch, "  ·  steam" if available() else ""]


## The Steam Cloud path, for whenever the seam is filled in. Steam's auto-cloud
## syncs a directory pattern rather than calling into the game, so the whole
## integration on this side is: point auto-cloud at the same folder the saves
## already live in.
static func save_directory_for_cloud() -> String:
	return ProjectSettings.globalize_path(LcnSaveFile.DIR)
