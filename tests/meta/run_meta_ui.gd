extends Node
## [P24] THE MENU REACHABILITY SUITE — can a human get at any of this, with a
## keyboard, with a mouse, in the real scene tree?
##
##   godot --path . tests/meta/run_meta_ui.tscn -- --force-ui
##
## Run as a SCENE, never with --script: the autoloads do not exist until the
## SceneTree has installed them (ARCHITECTURE.md §6.1).
##
## Every check here pushes a real InputEvent into the real viewport and then
## asks the running objects what happened. Nothing calls a method directly to
## prove a key works — the whole point is the path from the key to the screen.
##
## What would make it go red: a screen that draws but cannot be focused; an
## entry the keyboard cannot reach because the focus skips it; Esc not popping
## the stack; a save that writes but does not appear in the browser; a rebind
## the reservation table should have refused; a modal that lets the game keep
## running underneath. Each of those was tried against this suite by hand.
##
## It also photographs every screen into artifacts/meta/shots/ when there is a
## display, because "a human can open it" is best answered with a picture.
##
## REQUIRES: --force-ui

const TAG: String = "meta-ui"
const BOOT_SCENE: String = "res://game/boot.tscn"
const SETTLE: int = 3
## The slot this suite writes, carrying this process's id. `user://saves/` and
## `game/core/settings.cfg` are one path per MACHINE, not one per process: this
## suite runs in its own Godot process, and so does everybody else's copy of the
## gate. Filled in by _boot_a_real_session, which also takes the machine-wide
## test lock for the whole run — see tests/save/save_slots.gd.
var _slot: String = "suite_slot"

var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _unchecked: PackedStringArray = PackedStringArray()
var _out_dir: String = "res://artifacts/meta"

var _boot: Node = null
var _meta: LcnMetaRoot = null
var _shots: int = 0
## The player's real config, restored in _finish(). This suite rebinds keys and
## moves sliders for real; leaving a developer's machine reconfigured because a
## test ran is not acceptable.
var _settings_backup: PackedByteArray = PackedByteArray()
var _had_settings: bool = false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.substr(6)
	var watchdog := Timer.new()
	watchdog.wait_time = 150.0
	watchdog.one_shot = true
	watchdog.timeout.connect(_on_watchdog)
	add_child(watchdog)
	watchdog.start()
	call_deferred("_run")


func _on_watchdog() -> void:
	print("TESTS FAILED — the meta UI suite timed out after 150 s")
	get_tree().quit(125)


func _run() -> void:
	await _boot_a_real_session()
	if _meta == null:
		_finish()
		return
	await _suite_the_layer_is_where_the_table_says()
	await _suite_escape_opens_and_closes_the_pause_menu()
	await _suite_every_entry_is_reachable_by_keyboard()
	await _suite_the_mouse_and_the_keyboard_agree()
	await _suite_settings_are_reachable_and_bite()
	await _suite_rebinding_goes_through_the_reservation_table()
	await _suite_saving_and_loading_from_the_menu()
	await _suite_destroying_a_save_asks_first()
	await _suite_text_scaling_does_not_break_the_layout()
	await _suite_the_title_screen()
	_finish()


# ==================================================================== boot ===

func _boot_a_real_session() -> void:
	if not OS.get_cmdline_user_args().has("--force-ui") and DisplayServer.get_name() == "headless":
		_ok(false, "run with --force-ui or a display: without either the meta "
			+ "bootstrap declines and every check below cannot fail")
		return
	LcnSaveSlots.hold("tests/meta run_meta_ui")
	_slot = LcnSaveSlots.scratch("suite_slot")
	_had_settings = FileAccess.file_exists(Settings.PATH)
	if _had_settings:
		_settings_backup = FileAccess.get_file_as_bytes(Settings.PATH)
	# START FROM THE DEFAULTS. Without this the suite reads whatever the LAST run
	# of it left in user://settings.cfg — and a rebinding left behind by a
	# previous run makes every "the rebinding stuck" check pass no matter what
	# the code does. That is the shape of a test that cannot fail, and it was
	# live in this file until removing Keybinds.persist() from the production
	# path did not turn it red.
	Keybinds.install()
	Keybinds.reset_all()
	Keybinds.persist(Settings)
	LcnLayers.force_install = true
	var packed: PackedScene = load(BOOT_SCENE) as PackedScene
	if packed == null:
		_ok(false, "%s loads" % BOOT_SCENE)
		return
	_boot = packed.instantiate()
	add_child(_boot)
	await _settle(8)
	var node: Node = get_tree().get_first_node_in_group(LcnMetaRoot.GROUP)
	_ok(node != null, "the meta layer installed itself from game/content/meta/")
	_meta = node as LcnMetaRoot
	if _meta != null:
		_ok(_meta.is_inside_tree(), "the meta root is a live node in the scene tree")
		_ok(not _meta.is_open(), "nothing is open on top of the game at launch under --force-ui")


func _settle(frames: int) -> void:
	for _i: int in frames:
		await get_tree().process_frame


# ================================================================= layers ====

func _suite_the_layer_is_where_the_table_says() -> void:
	_ok(_meta.layer == LcnLayers.MODAL,
		"the meta layer sits on %d, the layer the table reserves for it (found %d)" % [
			LcnLayers.MODAL, _meta.layer])
	_ok(LcnLayers.violations(get_tree()).is_empty(),
		"adding the meta layer broke nothing in the allocation table")


# ================================================================== escape ===

func _suite_escape_opens_and_closes_the_pause_menu() -> void:
	SimClock.start()
	await _press(KEY_ESCAPE)
	_ok(_meta.is_open(), "Escape opens the pause menu")
	_ok(_meta.current_screen() == &"pause", "…and it is the pause menu (%s)" % _meta.current_screen())
	_ok(not SimClock.running, "the simulation is paused while the menu is up")
	await _shoot("pause")
	await _press(KEY_ESCAPE)
	_ok(not _meta.is_open(), "Escape closes it again")
	_ok(SimClock.running, "the simulation runs again when the menu closes")


# ================================================================ keyboard ===

func _suite_every_entry_is_reachable_by_keyboard() -> void:
	await _press(KEY_ESCAPE)
	var screen: LcnMetaScreen = _meta._stack[_meta._stack.size() - 1]
	var want: Array[StringName] = []
	for row: Dictionary in screen.list.rows:
		if screen.list.is_selectable(screen.list.rows.find(row)):
			want.append(StringName(row.get("id", &"")))
	_ok(want.size() >= 5, "the pause menu offers %d entries" % want.size())
	# Walk down with the arrow key only and collect what the focus lands on.
	var seen: Dictionary[StringName, bool] = {}
	for _i: int in want.size() + 2:
		seen[_meta.focused_row_id()] = true
		await _press(KEY_DOWN)
	for id: StringName in want:
		_ok(seen.has(id), "'%s' can be reached with the down arrow alone" % id)
	# And the focus wraps, so a player never has to press up eleven times.
	_ok(seen.size() == want.size(), "the focus visits every entry and only those")
	await _press(KEY_ESCAPE)


# =================================================================== mouse ===

func _suite_the_mouse_and_the_keyboard_agree() -> void:
	if DisplayServer.get_name() == "headless":
		_skip("the mouse moves the focus", "no display: GUI hit-testing is not real")
		return
	await _press(KEY_ESCAPE)
	var screen: LcnMetaScreen = _meta._stack[_meta._stack.size() - 1]
	var last: int = screen.list.rows.size() - 1
	while last > 0 and not screen.list.is_selectable(last):
		last -= 1
	var target: Rect2 = screen.list.row_rect(last)
	var at: Vector2 = screen.list.global_position + target.get_center()
	await _move_mouse(at)
	_ok(screen.list.focus_index == last,
		"hovering the last entry moves the keyboard focus to it (%d)" % screen.list.focus_index)
	# Click it: "Leave the game" opens a confirm rather than quitting, which is
	# also the check that a destructive entry never fires on one click.
	await _click(at)
	_ok(_meta.current_screen() == &"confirm", "clicking a destructive entry opens the confirm")
	await _press(KEY_ESCAPE)
	await _press(KEY_ESCAPE)


# ================================================================ settings ===

func _suite_settings_are_reachable_and_bite() -> void:
	await _press(KEY_ESCAPE)
	_ok(_open(&"settings"), "the settings index opens from the pause menu")
	await _shoot("settings")
	for id: StringName in [&"display", &"audio", &"controls", &"access"]:
		_ok(_open(id), "the %s page opens" % id)
		await _shoot(String(id))
		await _press(KEY_ESCAPE)
		_ok(_meta.current_screen() == &"settings", "Escape goes back one step, to settings")

	# A setting that does not reach the game is a setting that does not exist.
	_ok(_open(&"audio"), "the sound page is open")
	var screen: LcnMetaScreen = _meta._stack[_meta._stack.size() - 1]
	_ok(screen.list.focus_id(&"music"), "the music slider can be focused")
	var before: float = float(Settings.get_value("audio", "music", 0.7))
	await _press(KEY_LEFT)
	var after: float = float(Settings.get_value("audio", "music", 0.7))
	_ok(after < before, "the left arrow lowered the music gain (%.2f → %.2f)" % [before, after])
	_ok(_settings_file_has("audio", "music", after),
		"…and it was written to user://settings.cfg in the same breath")
	await _press(KEY_RIGHT)

	_ok(_open(&"access"), "the accessibility page is open")
	screen = _meta._stack[_meta._stack.size() - 1]
	_ok(screen.list.focus_id(&"colorblind_mode"), "colour vision can be focused")
	await _press(KEY_RIGHT)
	var mode: String = String(Settings.get_value("accessibility", "colorblind_mode", "off"))
	_ok(mode != "off", "the right arrow chose a colour vision mode (%s)" % mode)
	_ok(LcnAccessSettings.CB_VALUES.has(mode), "…and it is a token both [P17] and [P19] read")
	# [P19] must agree with what we wrote, or the lenses ignore the setting.
	var vision: int = LcnOverlayPalette.vision_from_setting(mode)
	_ok(vision != LcnOverlayPalette.Vision.NORMAL,
		"[P19]'s palette resolves '%s' to a deficiency (%d), not to normal vision" % [mode, vision])
	await _shoot("access_colourblind")
	Settings.set_value("accessibility", "colorblind_mode", "off")
	Settings.save_to_disk()
	await _press(KEY_ESCAPE)
	await _press(KEY_ESCAPE)
	await _press(KEY_ESCAPE)


func _settings_file_has(section: String, key: String, value: float) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(Settings.PATH) != OK:
		return false
	return is_equal_approx(float(cfg.get_value(section, key, -999.0)), value)


# ================================================================= rebind ====

func _suite_rebinding_goes_through_the_reservation_table() -> void:
	await _press(KEY_ESCAPE)
	_ok(_open(&"settings"), "settings open")
	_ok(_open(&"controls"), "the controls page opens")
	var screen := _meta._stack[_meta._stack.size() - 1] as LcnControlsSettings
	_ok(screen != null, "it is the controls page")
	if screen == null:
		return
	_ok(screen.list.focus_id(&"rotate"), "the 'rotate' binding can be focused")

	# 1. A reserved key must be REFUSED, whatever the InputMap thinks.
	var before: String = Keybinds.binding_label(&"rotate")
	_ok(before == "R", "rotate starts on its default, R (found %s)" % before)
	await _press(KEY_ENTER)
	_ok(screen._capturing == &"rotate", "Enter starts capturing a new key")
	await _press(KEY_4)
	_ok(Keybinds.binding_label(&"rotate") == before,
		"4 is refused — it is reserved for a lens and the router eats it (still %s)" % before)
	_ok(screen._capturing == &"", "the capture ended")

	# 2. A key another action already holds must be refused, with a name.
	await _press(KEY_ENTER)
	await _press(KEY_B)
	_ok(Keybinds.binding_label(&"rotate") == before,
		"B is refused — the build menu already has it")

	# 3. A free key must be accepted, applied and written to disk.
	await _press(KEY_ENTER)
	await _press(KEY_J)
	var now: String = Keybinds.binding_label(&"rotate")
	_ok(now == "J", "J is accepted (binding is now %s)" % now)
	var live: Array[InputEvent] = Keybinds.events_for(&"rotate")
	var in_map: bool = false
	for e: InputEvent in live:
		var k := e as InputEventKey
		if k != null and (k.physical_keycode == KEY_J or k.keycode == KEY_J):
			in_map = true
	_ok(in_map, "the action map itself carries the new binding")
	var stored: Dictionary = Settings.get_value("gameplay", "keybinds", {})
	_ok(stored.has("rotate"), "the override was written into Settings.gameplay.keybinds")
	var cfg := ConfigFile.new()
	var _e: int = cfg.load(Settings.PATH)
	var on_disk: Dictionary = cfg.get_value("gameplay", "keybinds", {})
	_ok(on_disk.has("rotate"),
		"…and it reached user://settings.cfg, which is what makes it survive a restart")
	await _shoot("controls_rebound")

	# 4. And it is still bound after the game is closed and opened again. This is
	# a SECOND GODOT PROCESS, started cold, printing what its own Settings
	# autoload loaded off disk — not this process reading back what it wrote.
	var probe: PackedStringArray = _run_restart_probe()
	var says_j: bool = false
	for line: String in probe:
		if line.strip_edges() == "PROBE rotate=J":
			says_j = true
	_ok(says_j, "a cold process reads rotate as J — the rebinding survives a restart")

	await _press(KEY_ESCAPE)
	await _press(KEY_ESCAPE)
	await _press(KEY_ESCAPE)


# ============================================================== save / load ==

func _suite_saving_and_loading_from_the_menu() -> void:
	LcnSaveManager.delete(_slot)
	SimClock.start()
	await _settle(6)
	await _press(KEY_ESCAPE)
	_ok(_open(&"saves", {"mode": "save"}), "the save browser opens")
	var screen := _meta._stack[_meta._stack.size() - 1] as LcnSaveBrowser
	_ok(screen != null and screen.mode == "save", "in save mode")
	await _shoot("saves")

	# Write a new slot the way the browser does, then prove the browser sees it.
	var head: Dictionary = LcnSaveManager.save(_slot, "Suite city")
	_ok(not head.is_empty(), "a save was written")
	var thumb: PackedByteArray = LcnSaveFile.read_header_and_thumb(_slot).get("thumbnail", PackedByteArray())
	if DisplayServer.get_name() == "headless":
		_skip("the save carries a thumbnail", "no renderer: there is no frame to photograph")
	else:
		_ok(thumb.size() > 0, "the save carries a thumbnail of the city (%d bytes)" % thumb.size())
		_ok(LcnSaveManager.thumbnail_texture(thumb) != null, "…and it decodes to a texture")
	screen.refresh()
	var found: bool = false
	for row: Dictionary in screen.list.rows:
		if String(row.get("label", "")) == "Suite city":
			found = true
			_ok(String(row.get("sub", "")).contains("day "),
				"the row says which day it reached: '%s'" % String(row.get("sub", "")))
	_ok(found, "the new save appears in the browser")
	await _shoot("saves_with_a_city")

	# Load it back through the menu path and prove the world came with it.
	var tick_at_save: int = int(head.get("tick", -1))
	SimClock.start()
	await _settle(20)
	var moved_on: int = SimClock.tick
	_ok(moved_on > tick_at_save, "the city ran on after the save (%d → %d)" % [tick_at_save, moved_on])
	_meta._load_and_close(_slot)
	# Read the clock BEFORE settling: the load resumes the world, so a frame of
	# waiting here would be measuring how fast this machine is, not the load.
	var at_load: int = SimClock.tick
	var citizens: SimSystem = Sim.get_system(&"citizens")
	var pop_after: int = int(citizens.metrics().get("population", -1)) if citizens != null else -1
	_ok(pop_after == int(head.get("population", -2)),
		"the people came back with the city (%d saved, %d loaded)" % [
			int(head.get("population", -2)), pop_after])
	_ok(at_load == tick_at_save,
		"loading it put the clock back to the saved tick (%d, saved at %d)" % [
			at_load, tick_at_save])
	await _settle(4)
	_ok(SimClock.tick > at_load, "…and the city runs on from there (%d)" % SimClock.tick)
	# A city that loads and then empties out over the next few seconds has not
	# loaded. This is the check that looks at the city a minute later, not at the
	# instant of the load.
	await _settle(90)
	var still: int = int(citizens.metrics().get("population", -1)) if citizens != null else -1
	_ok(still == pop_after,
		"the people are still there %d ticks later (%d, was %d)" % [
			SimClock.tick - at_load, still, pop_after])
	_ok(not _meta.is_open(), "the menus closed when the city loaded")


# ================================================================= confirm ===

func _suite_destroying_a_save_asks_first() -> void:
	await _press(KEY_ESCAPE)
	_ok(_open(&"saves", {"mode": "load"}), "the load browser opens")
	var screen := _meta._stack[_meta._stack.size() - 1] as LcnSaveBrowser
	var id := StringName("slot_" + _slot)
	_ok(screen.list.focus_id(id), "the suite's save can be focused")
	await _press(KEY_DELETE)
	_ok(_meta.current_screen() == &"confirm", "Delete asks first")
	_ok(LcnSaveManager.exists(_slot), "nothing has been deleted yet")
	await _shoot("confirm_delete")

	var dialog := _meta._stack[_meta._stack.size() - 1] as LcnConfirmDialog
	_ok(dialog.list.focused_id() == &"cancel",
		"the SAFE entry is focused, so Enter on a dialog you did not read keeps the city")
	await _press(KEY_ENTER)
	_ok(LcnSaveManager.exists(_slot), "cancelling kept the save")
	_ok(_meta.current_screen() == &"saves", "…and went back to the browser")

	# Now actually delete it.
	_ok(screen.list.focus_id(id), "focus the save again")
	await _press(KEY_DELETE)
	var dialog2 := _meta._stack[_meta._stack.size() - 1] as LcnConfirmDialog
	_ok(dialog2 != null and dialog2.list.focus_id(&"confirm"), "the destructive entry can be chosen")
	await _press(KEY_ENTER)
	_ok(not LcnSaveManager.exists(_slot), "confirming deleted it")
	await _press(KEY_ESCAPE)
	await _press(KEY_ESCAPE)


# ============================================================ text scaling ===

func _suite_text_scaling_does_not_break_the_layout() -> void:
	await _press(KEY_ESCAPE)
	var screen: LcnMetaScreen = _meta._stack[_meta._stack.size() - 1]
	var small: float = screen.list.content_height()
	Settings.set_value("accessibility", "font_scale", 1.6)
	_meta.style.refresh_from_settings()
	screen.refresh()
	await _settle(2)
	var large: float = screen.list.content_height()
	_ok(large > small * 1.3,
		"160%% text makes the rows taller rather than clipping (%d → %d px)" % [
			int(small), int(large)])
	var panel: Rect2 = screen.panel_rect()
	_ok(panel.size.y <= screen.size.y and panel.position.y >= 0.0,
		"the panel still fits on the screen at 160%% text")
	_ok(screen.list.position.y + screen.list.content_height() <= panel.end.y + 1.0,
		"the rows still fit inside the panel")
	await _shoot("pause_large_text")
	Settings.set_value("accessibility", "font_scale", 1.0)
	_meta.style.refresh_from_settings()
	screen.refresh()
	await _press(KEY_ESCAPE)


# ================================================================== title ====

func _suite_the_title_screen() -> void:
	var screen: LcnMetaScreen = _meta.open_screen(&"main", {})
	await _settle(SETTLE)
	_ok(screen != null and _meta.current_screen() == &"main", "the title screen opens")
	var cit: SimSystem = Sim.get_system(&"citizens")
	var sim_pop: int = int(cit.metrics().get("population", -1)) if cit != null else -1
	# [P17] names itself rather than joining a group — boot's install report is
	# the reliable handle.
	var hud: Node = _boot.get(&"hud")
	var hud_probe: Object = hud.get(&"probe") if hud != null else null
	var hud_pop: int = int(hud_probe.get(&"population")) if hud_probe != null else -1
	print("      [probe] sim population %d, HUD population %d, tick %d" % [
		sim_pop, hud_pop, SimClock.tick])
	_ok(hud_pop == sim_pop,
		"the HUD is showing the city that is actually loaded (HUD %d, sim %d)" % [
			hud_pop, sim_pop])
	_ok(not SimClock.running, "the world is not running behind the title screen")
	# Esc must NOT dismiss the title screen — there is nothing behind it.
	await _press(KEY_ESCAPE)
	_ok(_meta.current_screen() == &"main", "Escape does not drop the player out of the title screen")
	await _shoot("title")
	var ids: PackedStringArray = PackedStringArray()
	for row: Dictionary in screen.list.rows:
		ids.append(String(row.get("id", "")))
	for want: String in ["new", "load", "settings", "quit"]:
		_ok(ids.has(want), "the title screen offers '%s'" % want)
	_meta.close_all()
	await _settle(SETTLE)


# ================================================================= helpers ===

func _open(id: StringName, args: Dictionary = {}) -> bool:
	var screen: LcnMetaScreen = _meta.open_screen(id, args)
	return screen != null and _meta.current_screen() == id


func _press(code: int) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = code
	down.keycode = code
	down.pressed = true
	get_viewport().push_input(down, true)
	var up := InputEventKey.new()
	up.physical_keycode = code
	up.keycode = code
	up.pressed = false
	get_viewport().push_input(up, true)
	await _settle(SETTLE)


func _move_mouse(at: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = at
	ev.global_position = at
	get_viewport().push_input(ev, true)
	await _settle(SETTLE)


func _click(at: Vector2) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		get_viewport().push_input(ev, true)
		await _settle(2)
	await _settle(SETTLE)


## A real frame of a real screen. Silently skipped with no renderer.
func _shoot(shot_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var dir: String = ProjectSettings.globalize_path(_out_dir + "/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	var _e: int = img.save_png("%s/%s.png" % [dir, shot_name])
	_shots += 1


## Boots the engine again, headless, and reads what it says about the config on
## disk. The probe scene lives in game/ui/meta/ rather than tests/ so the gate
## does not discover it as a suite that owes a verdict.
func _run_restart_probe() -> PackedStringArray:
	var out: Array = []
	var code: int = OS.execute(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://game/ui/meta/restart_probe.tscn", "--", "--probe=rotate"]), out, true)
	_ok(code == 0, "the restart probe process ran (exit %d)" % code)
	var lines := PackedStringArray()
	for chunk: Variant in out:
		for line: String in String(chunk).split("\n"):
			lines.append(line)
	return lines


func _ok(condition: bool, what: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL %s" % what)


func _skip(what: String, why: String) -> void:
	_unchecked.append("UNCHECKED %s — %s" % [what, why])


func _finish() -> void:
	_restore_settings()
	var verdict: String = "TESTS FAILED"
	if _failures.is_empty():
		verdict = "TESTS PASSED, PARTIAL" if not _unchecked.is_empty() else "TESTS PASSED"
	for f: String in _failures:
		print("  %s" % f)
	for u: String in _unchecked:
		print("  %s" % u)
	print("%s — %d checks, %d failures, %d unchecked, %d shot(s)" % [
		verdict, _checks, _failures.size(), _unchecked.size(), _shots])
	var base: String = ProjectSettings.globalize_path(_out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var f := FileAccess.open(base + "/meta_ui.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"part": "P24", "verdict": verdict, "checks": _checks,
			"failed": _failures.size(), "unchecked": _unchecked.size(),
			"failures": _failures, "skipped": _unchecked,
			"display": DisplayServer.get_name(), "shots": _shots,
		}, "  "))
	if not _failures.is_empty():
		get_tree().quit(mini(_failures.size(), 125))
		return
	get_tree().quit(0 if _unchecked.is_empty() else 126)


## Puts the player's config back exactly as it was found.
func _restore_settings() -> void:
	Keybinds.reset_all()
	if _had_settings:
		var f: FileAccess = FileAccess.open(Settings.PATH, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_settings_backup)
			f.close()
	else:
		var _e: int = DirAccess.remove_absolute(ProjectSettings.globalize_path(Settings.PATH))
	Settings.load_from_disk()
	Keybinds.restore(Settings)
	LcnSaveManager.delete(_slot)
	LcnSaveSlots.purge()
	LcnSaveSlots.drop()
