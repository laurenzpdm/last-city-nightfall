extends TestCase
## [P24] Does any of this survive closing the game?
##
## Writing a setting and reading it back in the same process proves that a
## dictionary can hold a value. The only honest version of this test starts a
## SECOND GODOT PROCESS, cold, lets `Settings._ready()` load the config file the
## way a player's launch does, and reads what that process prints:
##
##   godot --headless --path . res://game/ui/meta/restart_probe.tscn
##
## What would make it go red: `Keybinds.persist()` not being called after a
## rebind; the override being stored in memory only; `Settings.save_to_disk()`
## dropping a section; a save written somewhere the next launch does not look.
## Deleting the `Keybinds.persist(_settings())` line from
## `game/ui/meta/controls_settings.gd` fails this suite and nothing else in the
## build.
##
## The suite restores the player's real settings file afterwards, byte for byte.

const PROBE: String = "res://game/ui/meta/restart_probe.tscn"
const SLOT: String = "restart_slot"

var _backup: PackedByteArray = PackedByteArray()
var _had_backup: bool = false


func requires_files() -> PackedStringArray:
	return PackedStringArray([PROBE])


func before_all() -> void:
	_had_backup = FileAccess.file_exists(Settings.PATH)
	if _had_backup:
		_backup = FileAccess.get_file_as_bytes(Settings.PATH)


func after_all() -> void:
	Keybinds.reset_all()
	if _had_backup:
		var f: FileAccess = FileAccess.open(Settings.PATH, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_backup)
			f.close()
	else:
		var _e: int = DirAccess.remove_absolute(ProjectSettings.globalize_path(Settings.PATH))
	Settings.load_from_disk()
	Keybinds.restore(Settings)
	LcnSaveManager.delete(SLOT)


func test_a_rebound_key_is_still_rebound_in_a_new_process() -> void:
	Keybinds.install()
	Keybinds.reset_all()
	var before: String = Keybinds.binding_label(&"rotate")
	assert_eq(before, "R", "rotate starts on R")

	var j := InputEventKey.new()
	j.physical_keycode = KEY_J
	assert_true(Keybinds.rebind(&"rotate", j, 0), "rotate can be moved to J")
	Keybinds.persist(Settings)

	var out: PackedStringArray = _run_probe(["--probe=rotate"])
	assert_true(_contains(out, "PROBE rotate=J"),
		"a cold process reads rotate as J — %s" % _first_probe_line(out))


func test_a_key_put_back_is_put_back_in_a_new_process_too() -> void:
	Keybinds.install()
	Keybinds.reset_all()
	Keybinds.persist(Settings)
	var out: PackedStringArray = _run_probe(["--probe=rotate"])
	assert_true(_contains(out, "PROBE rotate=R"),
		"a cold process reads rotate back on its default — %s" % _first_probe_line(out))


func test_an_accessibility_choice_survives_a_restart() -> void:
	Settings.set_value("accessibility", "font_scale", 1.35)
	Settings.set_value("graphics", "window_mode", LcnDisplaySettings.MODE_BORDERLESS)
	Settings.save_to_disk()
	var out: PackedStringArray = _run_probe([])
	assert_true(_contains(out, "PROBE font_scale=1.35"),
		"the text size came back — %s" % _joined(out, "font_scale"))
	assert_true(_contains(out, "PROBE window_mode=borderless"),
		"the window mode came back — %s" % _joined(out, "window_mode"))
	Settings.set_value("accessibility", "font_scale", 1.0)
	Settings.set_value("graphics", "window_mode", LcnDisplaySettings.MODE_WINDOWED)
	Settings.save_to_disk()


func test_a_save_written_now_is_on_disk_for_the_next_launch() -> void:
	var world := SimFixture.new(7).start()
	world.run(60)
	var before: int = LcnSaveManager.slots().size()
	assert_true(not LcnSaveManager.save(SLOT, "Cold start").is_empty(), "a save was written")
	var out: PackedStringArray = _run_probe([])
	assert_true(_contains(out, "PROBE saves=%d" % (before + 1)),
		"a cold process finds %d save(s) — %s" % [before + 1, _joined(out, "saves")])
	world.stop()


# ================================================================= helpers ===

## Runs the probe scene in its own Godot process and returns its output lines.
func _run_probe(args: PackedStringArray) -> PackedStringArray:
	var exe: String = OS.get_executable_path()
	var argv: PackedStringArray = PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"), PROBE])
	if not args.is_empty():
		argv.append("--")
		argv.append_array(args)
	var out: Array = []
	var code: int = OS.execute(exe, argv, out, true)
	var lines := PackedStringArray()
	for chunk: Variant in out:
		for line: String in String(chunk).split("\n"):
			lines.append(line.strip_edges())
	assert_eq(code, 0, "the probe process exited 0 (got %d)" % code)
	return lines


func _contains(lines: PackedStringArray, want: String) -> bool:
	for line: String in lines:
		if line == want:
			return true
	return false


func _first_probe_line(lines: PackedStringArray) -> String:
	for line: String in lines:
		if line.begins_with("PROBE "):
			return line
	return "the probe printed nothing"


func _joined(lines: PackedStringArray, key: String) -> String:
	for line: String in lines:
		if line.begins_with("PROBE " + key):
			return line
	return "no PROBE %s line" % key
