extends Node
## `--ui-tour`: opens every screen the build has, with the key a player would
## press, against the real window, and photographs each one.
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" \
##     $GODOT --path . --resolution 1920x1080 --ui-tour --out=artifacts/c1_ui
##
## The events are real `InputEventKey`s pushed through the real `Viewport`, so
## they travel the same path a keyboard does: the router first, then the panels,
## then the camera. If a panel is an orphan, nothing opens and the PNG shows it.
##
## Every step writes `<out>/shots/<name>.png` plus a `tour.json` recording what
## was pressed and whether the thing it should have opened reported itself open.
##
## ── THE TOUR WAS BLIND, AND EVERY STEP OF ITS REPORT WAS A LIE ────────────────
##
## Before this pass the tour reported 11 failures of 17 steps, and all eleven of
## its photographs were [P24]'s MAIN MENU. `artifacts/G4_tour_before/shots/`:
## ten 49 KB PNGs of a list of buttons, of which 45 of the 55 possible pairs are
## the same picture to within 0.00005 of a luma stop.
##
## The cause is one line in a part nobody suspected, and it is worth writing
## down because it is the same shape as the two before it. `LcnMetaRoot` stands
## its title screen down for `--ui-tour` — it says so in its own header — by
## asking `OS.get_cmdline_user_args()`. That array is EMPTY unless the command
## line contains a bare `--`, and every invocation in the briefs and in this
## repository's own docs is written WITHOUT one:
##
##     godot --path . --ui-tour --out=artifacts/x      <- no `--`
##
## So `game/boot.gd` (which unions both argument lists, on purpose, for exactly
## this reason) saw the flag and started the tour, while [P24] did not see it and
## opened the menu. The menu is opaque, sits on MODAL (80) over everything, and
## takes the keyboard on open — so it ate every hotkey the tour pressed AND stood
## in front of every photograph it took. Eleven "this screen is unreachable"
## failures about screens that are perfectly reachable, and eleven photographs of
## the wrong thing, from one disagreement about how to read a command line.
##
## TWO THINGS CHANGED, and only the second one is worth anything:
##
##   1. the tour now CLOSES the meta stack itself before it starts, rather than
##      hoping a flag was seen. That is the fix, and it is the half that rots:
##      the next part to install a full-screen layer re-blinds this tour in
##      silence.
##   2. every capture goes through `LcnShutter`, which asserts CHROME (nothing
##      above the subject when the shutter opens) and DIFF (photographs of
##      different screens must actually differ). Both would have gone red on the
##      old build, and `--keep-chrome` skips step 1 so they can be watched doing
##      it.
##
## Loaded BY PATH from `game/boot.gd`, not by class name, in the same spirit as
## every other seam there: a tool that fails to load costs one logged line, not
## a build that will not compile.

const SETTLE_FRAMES: int = 6
## [P18]'s "everything" pseudo-tab. Held as a literal so this compiles with the
## build menu absent.
const TAB_ALL: StringName = &"__all"
## The top of the picture. A tour photographs the interface, so everything up to
## and including [P20]'s statistics screens is the subject; MODAL (80) is not,
## because a surface that stops the world is never an answer to a hotkey.
const CEILING: int = LcnLayers.STATS

var out_dir: String = "res://artifacts/ui_tour"
var build_menu: Node = null
var overlays: Node = null
var router: Node = null

var _steps: Array[Dictionary] = []
var _done: bool = false
var _shutter: LcnShutter = null
## Skips the "shut the menu" step, so CHROME and DIFF can be shown going red
## against the exact defect they were written for.
var _keep_chrome: bool = false


func _ready() -> void:
	name = "UiTour"
	for a: String in OS.get_cmdline_args():
		if a == "--keep-chrome":
			_keep_chrome = true
	_shutter = LcnShutter.new(CEILING, "the interface", LcnLayers.MODAL)
	# A tour that hangs is worse than one that fails: it holds a window open
	# forever and every other agent's gate queues behind it.
	var watchdog := Timer.new()
	watchdog.wait_time = 180.0
	watchdog.one_shot = true
	watchdog.timeout.connect(_on_watchdog)
	add_child(watchdog)
	watchdog.start()
	call_deferred("_run")


func _on_watchdog() -> void:
	Log.error("ui-tour", "timed out after 180 s at step %d — writing what it got" % _steps.size())
	_write_report()
	get_tree().quit(1)


func _run() -> void:
	if _done:
		return
	_done = true
	var base: String = ProjectSettings.globalize_path(out_dir)
	DirAccess.make_dir_recursive_absolute(base + "/shots")

	await _settle(30)
	_shut_the_menu()
	await _settle(SETTLE_FRAMES)
	await _shoot("00_opening", "the session as it opens")
	# [P18] restores whatever the player left open last session, so a tour that
	# assumed a clean desk would photograph a CLOSE and call it an open.
	await _close_everything()

	# --- the five [P18] screens, each on its own hotkey -----------------------
	var index: int = 1
	for screen: Dictionary in LcnLayers.SCREENS:
		var id: StringName = screen["id"]
		var key: int = int(screen["key"])
		await _press(key)
		var open: bool = _panel_open(id)
		await _shoot("%02d_%s" % [index, String(id)], String(screen["label"]))
		_record(String(screen["label"]), OS.get_keycode_string(key), open,
			"%s reported open=%s" % [String(id), str(open)])
		await _press(KEY_ESCAPE)
		var closed: bool = not _panel_open(id)
		_record("%s closes on Escape" % String(screen["label"]), "Escape", closed, "")
		index += 1

	# --- screens outside [P18]'s panel set, same contract --------------------
	for extra: Dictionary in LcnLayers.EXTRA_SCREENS:
		var node: Node = get_tree().get_first_node_in_group(extra["group"])
		if node == null:
			_record("%s [%s]" % [String(extra["label"]), String(extra["owner"])],
				OS.get_keycode_string(int(extra["key"])), false, "not in this build yet")
			continue
		await _press(int(extra["key"]))
		var open2: bool = bool(node.get(extra["flag"]))
		await _shoot("%02d_%s" % [index, String(extra["group"])], String(extra["label"]))
		_record(String(extra["label"]), OS.get_keycode_string(int(extra["key"])), open2, "")
		await _press(KEY_ESCAPE)
		index += 1

	# --- the lenses, on the keys the router reserved for them ----------------
	for key: int in LcnLayers.RESERVED_LENS:
		await _press(key)
		var mode: int = _lens_mode()
		await _shoot("%02d_lens_%s" % [index, OS.get_keycode_string(key)],
			"readability lens on %s" % OS.get_keycode_string(key))
		_record("lens %s" % OS.get_keycode_string(key), OS.get_keycode_string(key),
			mode > 0, "overlay mode=%d" % mode)
		await _press(key)
		index += 1

	# --- time control, the keys [P18]'s quickbar used to eat -----------------
	await _press(KEY_2)
	_record("sim speed", "2", is_equal_approx(SimClock.speed, 2.0),
		"SimClock.speed=%.1f" % SimClock.speed)
	await _press(KEY_1)
	await _press(KEY_SPACE)
	_record("pause", "Space", not SimClock.running, "SimClock.running=%s" % str(SimClock.running))
	await _press(KEY_SPACE)

	# --- build mode: the palette arms a kind and the ghost appears -----------
	await _press(KEY_B)
	var armed: bool = _arm_first_building()
	await _settle(SETTLE_FRAMES)
	await _shoot("%02d_build_ghost" % index, "build mode with a live ghost")
	_record("build mode + ghost", "B then a palette entry", armed,
		"armed_kind=%s" % str(build_menu.get(&"armed_kind") if build_menu != null else ""))

	_write_report()
	get_tree().quit(0 if _failures() == 0 else 1)


# ------------------------------------------------------------------ driving --

## THE FIX FOR THE DEFECT ABOVE, AND IT IS DELIBERATELY NOT A FLAG.
##
## [P24] already tries to stand down for `--ui-tour` and cannot be relied on to
## have seen the flag (see the header). Rather than argue about argument parsing
## in a part this file does not own, the tour shuts the stack itself and RECORDS
## whether it succeeded — so "the main menu was in the way" is a named step in
## `tour.json` instead of eleven mysterious failures.
func _shut_the_menu() -> void:
	var meta: Node = get_tree().get_first_node_in_group(&"lcn_meta")
	if meta == null:
		_record("the main menu is not in the way", "-", true, "no meta layer in this build")
		return
	var was_open: bool = meta.has_method(&"is_open") and bool(meta.call(&"is_open"))
	if _keep_chrome:
		Log.info("ui-tour", "KEEPING the meta stack open (--keep-chrome) — "
			+ "the CHROME and DIFF guards should now go red")
		_record("the main menu is not in the way", "-", not was_open,
			"--keep-chrome: left open on purpose")
		return
	if was_open and meta.has_method(&"close_all"):
		meta.call(&"close_all")
	var still: bool = meta.has_method(&"is_open") and bool(meta.call(&"is_open"))
	_record("the main menu is not in the way", "-", not still,
		"opened itself over the tour (it reads --ui-tour off get_cmdline_user_args(), "
		+ "which is empty without a bare `--`); closed by the tour" if was_open
		else "already shut")


func _press(code: int) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	get_viewport().push_input(ev, true)
	var up := InputEventKey.new()
	up.physical_keycode = code
	up.keycode = code
	up.pressed = false
	get_viewport().push_input(up, true)
	await _settle(SETTLE_FRAMES)


func _settle(frames: int) -> void:
	for _i: int in frames:
		await get_tree().process_frame


func _shoot(shot_name: String, caption: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = _shutter.shoot(get_tree(), shot_name)
	# Put the build back before the next key is pressed: the shutter hides
	# whatever was above the subject, and a tour that kept driving a dismantled
	# interface would be photographing its own damage from here on.
	_shutter.restore()
	if img == null:
		Log.info("ui-tour", "UNCHECKED %s — the viewport handed back no image" % shot_name)
		return
	var path: String = ProjectSettings.globalize_path("%s/shots/%s.png" % [out_dir, shot_name])
	var _e: int = img.save_png(path)
	Log.info("ui-tour", "%s — %s" % [shot_name, caption])


# ------------------------------------------------------------------ reading --

func _close_everything() -> void:
	if build_menu == null or not build_menu.has_method(&"open_panels"):
		return
	for _i: int in 8:
		if (build_menu.call(&"open_panels") as Array).is_empty():
			return
		await _press(KEY_ESCAPE)


func _panel_open(id: StringName) -> bool:
	if build_menu == null or not build_menu.has_method(&"panel"):
		return false
	var p: Object = build_menu.call(&"panel", id)
	return p != null and p.has_method(&"is_open") and bool(p.call(&"is_open"))


func _lens_mode() -> int:
	return int(overlays.get(&"mode")) if overlays != null else -1


## Arms whatever the palette lists first, down the same path a click on the tile
## takes — the panel's `picked` handler, not a private shortcut into the shell.
func _arm_first_building() -> bool:
	if build_menu == null:
		return false
	var catalog: Object = build_menu.get(&"catalog")
	if catalog == null or not catalog.has_method(&"view"):
		return false
	var entries: Array = catalog.call(&"view", TAB_ALL, "")
	if entries.is_empty():
		return false
	var first: Object = entries[0]
	build_menu.call(&"_on_palette_picked", first.get(&"id"))
	return String(build_menu.get(&"armed_kind")) != ""


# ------------------------------------------------------------------ report ---

func _record(what: String, key: String, ok: bool, detail: String) -> void:
	_steps.append({"what": what, "key": key, "ok": ok, "detail": detail})
	if ok:
		Log.info("ui-tour", "OK   %-34s %-8s %s" % [what, key, detail])
	else:
		Log.error("ui-tour", "FAIL %-34s %-8s %s" % [what, key, detail])


func _failures() -> int:
	var n: int = 0
	for s: Dictionary in _steps:
		if not bool(s["ok"]):
			n += 1
	return n + _shutter.failures().size()


## THE GUARDS ARE PART OF THE REPORT, not a side note in the log. A tour that
## opened every screen correctly and photographed a menu eleven times is a FAILED
## tour, and `tour.json` has to say so where the next reader will look.
func _write_report() -> void:
	var guards: PackedStringArray = _shutter.failures()
	for g: String in guards:
		Log.error("ui-tour", "GUARD %s" % g)
	var base: String = ProjectSettings.globalize_path(out_dir)
	var f := FileAccess.open(base + "/tour.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"steps": _steps,
			"step_failures": _failures() - guards.size(),
			"guards": guards,
			"unchecked": _shutter.unchecked(),
			"shutter": _shutter.summary(),
			"failures": _failures(),
		}, "  "))
	Log.info("ui-tour", "%d step(s), %d failure(s) — %s" % [
		_steps.size(), _failures(), _shutter.summary()])
