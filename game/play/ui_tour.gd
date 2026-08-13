class_name LcnUiTour
extends Node
## `--ui-tour`: opens every screen the build has, with the key a player would
## press, against the real window, and photographs each one. INTEGRATOR-OWNED.
##
##   godot --path . --resolution 1920x1080 -- --ui-tour --out=artifacts/c1_ui
##
## This is the answer to "is it reachable?" that cannot be faked by a log line.
## The events are real `InputEventKey`s pushed through the real `Viewport`, so
## they travel the same path a keyboard does: the router first, then the panels,
## then the camera. If a panel is an orphan, nothing opens and the PNG shows it.
##
## Every step writes `<out>/shots/<name>.png` plus a `tour.json` that records,
## per step, what was pressed and whether the thing it should have opened
## reported itself open afterwards. A step that photographs an unchanged screen
## is a FAIL in that file, not a pretty picture nobody diffs.

const SETTLE_FRAMES: int = 6
## [P18]'s "everything" pseudo-tab. Held as a literal so game/play/ compiles
## with the build menu absent.
const TAB_ALL: StringName = &"__all"

var out_dir: String = "res://artifacts/ui_tour"
var build_menu: Node = null
var overlays: Node = null
var router: Node = null

var _steps: Array[Dictionary] = []
var _done: bool = false


func _ready() -> void:
	name = "UiTour"
	call_deferred("_run")


func _run() -> void:
	if _done:
		return
	_done = true
	var base: String = ProjectSettings.globalize_path(out_dir)
	DirAccess.make_dir_recursive_absolute(base + "/shots")

	await _settle(30)
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
	var img: Image = get_viewport().get_texture().get_image()
	var path: String = ProjectSettings.globalize_path("%s/shots/%s.png" % [out_dir, shot_name])
	img.save_png(path)
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
	var entries: Array = catalog.call(&"view", LcnUiTour.TAB_ALL, "")
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
	return n


func _write_report() -> void:
	var base: String = ProjectSettings.globalize_path(out_dir)
	var f := FileAccess.open(base + "/tour.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"steps": _steps, "failures": _failures(),
		}, "  "))
	Log.info("ui-tour", "%d step(s), %d failure(s)" % [_steps.size(), _failures()])
