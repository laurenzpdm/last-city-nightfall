class_name LcnTutorialMemory
extends RefCounted
## [P21] What the player has already been taught, across sessions.
##
## Its own file, not `Settings`: game/core/settings.gd is [P24]'s and its header
## says other parts read it and never write it. A tutorial that stored its
## progress in someone else's autoload would be a merge conflict with a
## save-game system that has not landed yet.
##
## WHAT RESUMABLE MEANS HERE, precisely, because the honest answer is not the
## obvious one. There is no save-game in this build: quitting throws the city
## away. So this file cannot restore a step — it records which LESSONS the
## player has already been shown to the end. On the next launch the course skips
## those and opens at the first one the player has not yet been taught, in a
## fresh city where its pressure is real again. A player who got as far as the
## first night is never made to re-learn pipes.
##
## `skipped` is terminal and deliberate: a player who dismissed the guide gets
## it back by deleting this file or by pressing Show guide, and never by
## surprise on the next launch.

const PATH: String = "user://tutorial.cfg"
const SECTION: String = "tutorial"
## Bumped when the lesson set changes enough that old progress is meaningless.
const COURSE_VERSION: int = 1

var taught: Dictionary[StringName, bool] = {}
var skipped: bool = false
var version: int = COURSE_VERSION

var _path: String = PATH


## `override_path` exists so the suite can prove save/load round-trips without
## trampling the player's own file.
func _init(override_path: String = PATH) -> void:
	_path = override_path


func load_from_disk() -> void:
	taught.clear()
	skipped = false
	version = COURSE_VERSION
	var cfg := ConfigFile.new()
	if cfg.load(_path) != OK:
		return
	version = int(cfg.get_value(SECTION, "version", COURSE_VERSION))
	if version != COURSE_VERSION:
		# A lesson set that has changed shape teaches a different course. Start
		# it over rather than silently skipping four lessons nobody has seen.
		return
	skipped = bool(cfg.get_value(SECTION, "skipped", false))
	for raw: Variant in (cfg.get_value(SECTION, "taught", []) as Array):
		taught[StringName(String(raw))] = true


func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "version", COURSE_VERSION)
	cfg.set_value(SECTION, "skipped", skipped)
	var ids: Array = taught.keys()
	ids.sort()
	var out: Array[String] = []
	for id: StringName in ids:
		out.append(String(id))
	cfg.set_value(SECTION, "taught", out)
	cfg.save(_path)


func was_taught(id: StringName) -> bool:
	return bool(taught.get(id, false))


func remember(id: StringName) -> void:
	if taught.has(id):
		return
	taught[id] = true
	save_to_disk()


func set_skipped(on: bool) -> void:
	if skipped == on:
		return
	skipped = on
	save_to_disk()


## Wipes the record. The Show guide button and the suite both use it.
func forget_everything() -> void:
	taught.clear()
	skipped = false
	save_to_disk()
