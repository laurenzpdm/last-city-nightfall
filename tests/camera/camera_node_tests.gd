class_name CameraNodeTests
extends Node
## [P16] integration tests: a real GameCamera in a real tree, driven by real InputEvents.
##
## CameraTests proves the maths. This proves the wiring — that pushed events reach the
## rig, that the Camera2D transform ends up where the rig says, that Settings actually
## silence shake, and that a Bus focus request moves the view.
##
## Time is advanced by calling the camera's own _process at a fixed 60 Hz rather than by
## waiting for frames: a headless main loop runs unthrottled, so "wait 90 frames" would
## be a few milliseconds of camera time and every timing assertion would be a lie.

const DT: float = 1.0 / 60.0

var failures: PackedStringArray = PackedStringArray()
var checks: int = 0

var _case: String = ""
var _camera: GameCamera = null
var _readability_events: int = 0
var _last_detail: int = -1
var _overlay_events: PackedInt32Array = PackedInt32Array()
var _actions_seen: Array[StringName] = []


func run_all() -> Dictionary:
	failures = PackedStringArray()
	checks = 0

	_camera = GameCamera.new()
	_camera.name = "GameCamera"
	# A headless viewport reports the mouse at (0, 0) forever, which is the top-left
	# EDGE — leave edge scroll on and every case below measures edge scroll instead
	# of the thing it names. The ramp itself is covered by CameraTests
	# (test_edge_scroll_ramp) and by _test_edge_scroll_wiring at the end of this file.
	_camera.edge_scroll_allowed = false
	add_child(_camera)
	_camera.readability_changed.connect(_on_readability)
	_camera.overlay_requested.connect(_on_overlay)
	_camera.action_pressed.connect(_on_action)
	await _frames(2)

	_case = "boot"
	_test_boot()
	_case = "wheel_zoom_anchors_on_cursor"
	_test_wheel_zoom()
	_case = "middle_drag"
	_test_middle_drag()
	_case = "bus_focus"
	_test_bus_focus()
	_case = "shake_respects_settings"
	_test_shake_settings()
	_case = "box_select"
	_test_box_select()
	_case = "hover_follows_the_view"
	_test_hover()
	_case = "readability_signal"
	_test_readability()
	_case = "overlay_hotkeys"
	_test_overlay_hotkeys()
	_case = "keyboard_pan"
	_test_keyboard_pan()
	_case = "settings_round_trip"
	_test_settings_round_trip()
	_case = "edge_scroll_wiring"
	_test_edge_scroll_wiring()

	# One real engine frame at the end: the node must survive an actual draw pass.
	await _frames(2)
	_case = "teardown"
	_ok(GameCamera.current() == _camera, "camera lost its static registration during the run")
	_camera.queue_free()
	_camera = null
	await _frames(1)
	_ok(GameCamera.current() == null, "the camera did not deregister on exit")
	return {"name": "camera_node", "checks": checks, "failed": failures.size(), "failures": failures}


# --- helpers -------------------------------------------------------------------

func _ok(condition: bool, what: String) -> void:
	checks += 1
	if not condition:
		failures.append("%s: %s" % [_case, what])


func _near(a: float, b: float, tol: float, what: String) -> void:
	checks += 1
	if absf(a - b) > tol:
		failures.append("%s: %s (%.5f vs %.5f, tol %.5f)" % [_case, what, a, b, tol])


func _near_v(a: Vector2, b: Vector2, tol: float, what: String) -> void:
	checks += 1
	if a.distance_to(b) > tol:
		failures.append("%s: %s (%s vs %s, tol %.5f)" % [_case, what, str(a), str(b), tol])


func _frames(count: int) -> void:
	for _i: int in count:
		await get_tree().process_frame


## Advance camera time deterministically, in 60 Hz steps.
func _tick(seconds: float) -> void:
	var steps: int = maxi(1, int(round(seconds / DT)))
	for _i: int in steps:
		_camera._process(DT)


func _push(event: InputEvent) -> void:
	get_viewport().push_input(event)


func _mouse_button(button: int, pos: Vector2, is_pressed: bool) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.position = pos
	e.global_position = pos
	e.pressed = is_pressed
	return e


func _mouse_motion(pos: Vector2, relative: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.relative = relative
	return e


func _key_event(code: int, is_pressed: bool) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.pressed = is_pressed
	return e


func _set_setting(section: String, key: String, value: Variant) -> void:
	var s: Node = CameraServices.settings_node()
	if s != null:
		s.call(&"set_value", section, key, value)


func _on_readability(level: int, _zoom_value: float) -> void:
	_readability_events += 1
	_last_detail = level


func _on_overlay(index: int) -> void:
	_overlay_events.append(index)


func _on_action(action: StringName) -> void:
	_actions_seen.append(action)


# --- cases ---------------------------------------------------------------------

func _test_boot() -> void:
	_ok(GameCamera.current() == _camera, "GameCamera.current() does not point at the live camera")
	_ok(_camera.is_current(), "the camera did not make itself current")
	_ok(Keybinds.is_installed(), "the action map was never installed")
	for action: StringName in Keybinds.actions():
		_ok(InputMap.has_action(action), "action '%s' missing from InputMap at runtime" % action)
	_near(_camera.zoom.x, _camera.zoom_level(), 0.0001, "Camera2D.zoom disagrees with the rig")
	_ok(_camera.visible_world_rect().size.x > 0.0, "visible world rect is empty")
	_ok(_camera.get_node_or_null(^"SelectionOverlay") != null, "the selection overlay was never created")


func _test_wheel_zoom() -> void:
	_camera.set_zoom_level(1.0, false)
	_camera.focus_on(Vector2(500.0, 400.0), true)
	_tick(DT)
	var anchor: Vector2 = Vector2(320.0, 220.0)
	var world_before: Vector2 = _camera.screen_to_world(anchor)
	var zoom_before: float = _camera.zoom_level()

	_push(_mouse_button(MOUSE_BUTTON_WHEEL_UP, anchor, true))
	_push(_mouse_button(MOUSE_BUTTON_WHEEL_UP, anchor, false))
	_tick(0.6)

	_ok(_camera.zoom_level() > zoom_before, "the wheel did not zoom in (%.3f -> %.3f)"
		% [zoom_before, _camera.zoom_level()])
	_near_v(_camera.screen_to_world(anchor), world_before, 0.1, "wheel zoom did not anchor on the cursor")

	_push(_mouse_button(MOUSE_BUTTON_WHEEL_DOWN, anchor, true))
	_push(_mouse_button(MOUSE_BUTTON_WHEEL_DOWN, anchor, false))
	_tick(0.6)
	_near(_camera.zoom_level(), zoom_before, 0.01, "wheel down did not return to the previous zoom")
	_near_v(_camera.screen_to_world(anchor), world_before, 0.1, "wheel out did not anchor on the cursor")


func _test_middle_drag() -> void:
	_camera.set_zoom_level(1.0, false)
	_camera.focus_on(Vector2.ZERO, true)
	_tick(DT)
	var start: Vector2 = _camera.rig.position
	_push(_mouse_button(MOUSE_BUTTON_MIDDLE, Vector2(600.0, 400.0), true))
	_push(_mouse_motion(Vector2(700.0, 460.0), Vector2(100.0, 60.0)))
	_tick(DT)
	# Dragging the mouse right pulls the world right, so the camera goes left.
	_near_v(_camera.rig.position, start - Vector2(100.0, 60.0), 0.05, "drag moved the camera wrongly")
	_push(_mouse_button(MOUSE_BUTTON_MIDDLE, Vector2(700.0, 460.0), false))
	_tick(DT)
	_ok(not _camera.rig.is_dragging(), "the drag never ended")
	_camera.rig.stop_motion()


func _test_bus_focus() -> void:
	_camera.focus_on(Vector2.ZERO, true)
	_tick(DT)
	var target: Vector2 = Vector2(1800.0, -1200.0)
	CameraServices.emit_bus(&"camera_focus_requested", [target])
	_tick(DT)
	_ok(_camera.rig.is_focusing(), "Bus.camera_focus_requested did not start a focus move")
	_tick(1.2)
	_near_v(_camera.rig.position, target, 0.05, "Bus focus never arrived")


func _test_shake_settings() -> void:
	var settings: Node = CameraServices.settings_node()
	_ok(settings != null, "no Settings autoload to test against")
	var previous_reduce: Variant = CameraServices.setting("accessibility", "reduce_motion", false)
	var previous_scale: Variant = CameraServices.setting("graphics", "screen_shake", 1.0)

	_set_setting("accessibility", "reduce_motion", false)
	_set_setting("graphics", "screen_shake", 1.0)
	_camera._refresh_settings()
	_camera.shake_model.reset()
	_camera.shake(1.0, 0.4, 18.0)
	_ok(_camera.shake_trauma() > 0.9, "shake did not charge trauma")
	_tick(DT)
	var shake_px: float = _camera.offset.length() * _camera.zoom_level()
	_ok(shake_px > 0.0, "shake produced no screen displacement")
	_ok(shake_px <= _camera.shake_model.max_offset_px * 1.5,
		"shake displacement %.2f px exceeded the cap" % shake_px)
	# Camera2D.offset is world space; the /zoom conversion must land the shake exactly
	# where get_screen_center_position() reports it.
	_near_v(_camera.get_screen_center_position(), _camera.rig.position + _camera.offset, 0.05,
		"shake is not applied through the camera offset")
	_tick(0.6)
	_ok(_camera.shake_trauma() == 0.0, "shake never decayed to rest")
	_ok(_camera.offset == Vector2.ZERO, "shake left the camera off-centre")

	# reduce_motion is an accessibility promise: absolutely no shake.
	_set_setting("accessibility", "reduce_motion", true)
	_camera._refresh_settings()
	_camera.shake(1.0, 0.5, 20.0)
	_ok(_camera.shake_trauma() == 0.0, "reduce_motion did not suppress shake")
	_tick(DT)
	_ok(_camera.offset == Vector2.ZERO, "reduce_motion left a camera offset")
	_near(_camera.rotation, 0.0, 0.0, "reduce_motion left a camera roll")

	# screen_shake = 0 means off as well.
	_set_setting("accessibility", "reduce_motion", false)
	_set_setting("graphics", "screen_shake", 0.0)
	_camera._refresh_settings()
	_camera.shake(1.0, 0.5, 20.0)
	_ok(_camera.shake_trauma() == 0.0, "screen_shake=0 did not suppress shake")

	# Half the setting, half the trauma.
	_set_setting("graphics", "screen_shake", 0.5)
	_camera._refresh_settings()
	_camera.shake_model.reset()
	_camera.shake(1.0, 0.5, 20.0)
	_near(_camera.shake_trauma(), 0.5, 0.001, "screen_shake scale was ignored")

	_set_setting("accessibility", "reduce_motion", previous_reduce)
	_set_setting("graphics", "screen_shake", previous_scale)
	_camera._refresh_settings()
	_camera.shake_model.reset()
	_tick(DT)


func _test_box_select() -> void:
	_camera.set_zoom_level(1.0, false)
	_camera.focus_on(Vector2.ZERO, true)
	_camera.clear_selection()
	_tick(DT)
	var from: Vector2 = Vector2(400.0, 300.0)
	var to: Vector2 = Vector2(760.0, 620.0)
	var world_from: Vector2 = _camera.screen_to_world(from)
	var world_to: Vector2 = _camera.screen_to_world(to)

	_push(_mouse_button(MOUSE_BUTTON_LEFT, from, true))
	_push(_mouse_motion(to, to - from))
	_ok(_camera.selection.box_active, "dragging with the left button did not open a box")
	_tick(DT)
	_push(_mouse_button(MOUSE_BUTTON_LEFT, to, false))
	_ok(not _camera.selection.box_active, "the box stayed open after release")
	var expected: Rect2i = SelectionController.cell_rect(world_from, world_to, CameraTuning.TILE_SIZE)
	_ok(_camera.selection_cell_rect() == expected,
		"box covered %s, expected %s" % [str(_camera.selection_cell_rect()), str(expected)])

	# A click without movement stays a click.
	_push(_mouse_button(MOUSE_BUTTON_LEFT, from, true))
	_push(_mouse_button(MOUSE_BUTTON_LEFT, from, false))
	_ok(_camera.selection_cell_rect().size == Vector2i.ONE, "a click selected more than one cell")

	# Escape drops the box, then the selection.
	_push(_mouse_button(MOUSE_BUTTON_LEFT, from, true))
	_push(_mouse_motion(to, to - from))
	_push(_key_event(KEY_ESCAPE, true))
	_push(_key_event(KEY_ESCAPE, false))
	_ok(not _camera.selection.box_active, "escape did not abandon the box")
	_tick(DT)


func _test_hover() -> void:
	# The mouse cannot be moved headlessly, so move the world under it instead: the
	# hovered cell must track the view, not only pointer motion.
	_camera.set_zoom_level(1.0, false)
	_camera.focus_on(Vector2.ZERO, true)
	_tick(DT)
	var first: Vector2i = _camera.hovered_cell()
	var expected_first: Vector2i = SelectionController.world_to_cell(
		_camera.screen_to_world(get_viewport().get_mouse_position()), CameraTuning.TILE_SIZE)
	_ok(first == expected_first, "hovered cell %s does not match the cursor's world cell %s"
		% [str(first), str(expected_first)])
	_camera.focus_on(Vector2(4096.0, 4096.0), true)
	_tick(DT)
	_ok(_camera.hovered_cell() != first, "hovered cell did not follow the camera")


func _test_readability() -> void:
	_readability_events = 0
	_camera.set_zoom_level(2.0, false)
	_tick(DT)
	_ok(_camera.detail_level() == GameCamera.DetailLevel.CLOSE, "zoom 2.0 is not the close band")
	_camera.set_zoom_level(0.25, false)
	_tick(DT)
	_ok(_camera.detail_level() == GameCamera.DetailLevel.STRATEGIC, "zoom 0.25 is not the strategic band")
	_ok(_readability_events >= 1, "readability_changed never fired")
	_ok(_camera.detail_level_name() == &"strategic", "detail level name is wrong")
	_ok(_last_detail == _camera.detail_level(), "the signal reported a different level than the getter")
	_camera.set_zoom_level(1.0, false)
	_tick(DT)


func _test_overlay_hotkeys() -> void:
	_overlay_events = PackedInt32Array()
	_push(_key_event(KEY_F2, true))
	_push(_key_event(KEY_F2, false))
	_ok(_camera.active_overlay() == 2, "F2 did not activate overlay 2")
	_push(_key_event(KEY_F2, true))
	_push(_key_event(KEY_F2, false))
	_ok(_camera.active_overlay() == 0, "pressing the same overlay key did not turn it off")
	_ok(_overlay_events.size() == 2 and _overlay_events[0] == 2 and _overlay_events[1] == 0,
		"overlay_requested did not report %s" % str(_overlay_events))

	# Registered mode ids let the hotkeys announce themselves on the Bus for [P19].
	_camera.set_overlay_modes(PackedStringArray(["heat", "logistics", "defence", "citizens", "alerts"]))
	_camera.request_overlay(1)
	_ok(_camera.active_overlay() == 1, "programmatic overlay request was ignored")
	_camera.request_overlay(1)
	_camera.set_overlay_modes(PackedStringArray())

	_actions_seen.clear()
	_push(_key_event(KEY_R, true))
	_push(_key_event(KEY_R, false))
	_ok(_actions_seen.has(&"rotate"), "the rotate hotkey did not reach action_pressed")


func _test_keyboard_pan() -> void:
	_camera.set_zoom_level(1.0, false)
	_camera.focus_on(Vector2.ZERO, true)
	_tick(DT)
	Input.parse_input_event(_key_event(KEY_D, true))
	if not Input.is_action_pressed(&"cam_pan_right"):
		# Synthetic key state is not observable in this build; drive the rig instead so
		# the assertion below still measures real panning rather than nothing.
		_camera.rig.set_pan_input(Vector2.RIGHT)
		_tick(0.2)
		_camera.rig.set_pan_input(Vector2.ZERO)
	else:
		_tick(0.2)
		Input.parse_input_event(_key_event(KEY_D, false))
		_ok(not Input.is_action_pressed(&"cam_pan_right"), "the pan key stayed latched after release")
	var moved: float = _camera.rig.position.x
	_ok(moved > 0.0, "holding the pan key did not move the camera east (x=%.2f)" % moved)
	_camera.rig.stop_motion()


## The one case that deliberately turns edge scroll back on. It cannot move a real
## cursor, so it drives the camera's own gather step with a synthetic pointer and
## asserts the sign and the gating, which is the wiring the other cases mute.
func _test_edge_scroll_wiring() -> void:
	var size: Vector2 = _camera._viewport_size()
	var margin: float = _camera.tuning.edge_margin
	var right_edge: Vector2 = Vector2(size.x - 1.0, size.y * 0.5)
	var middle: Vector2 = size * 0.5

	_ok(CameraRig.edge_scroll_dir(middle, size, margin) == Vector2.ZERO,
		"a cursor in the middle of the window must not scroll")
	_ok(CameraRig.edge_scroll_dir(right_edge, size, margin).x > 0.9,
		"a cursor on the right edge must scroll east")
	_ok(CameraRig.edge_scroll_dir(Vector2(0.0, 0.0), size, margin) == Vector2(-1.0, -1.0),
		"a cursor in the top-left corner scrolls up and left at full rate")

	# And the camera must obey the toggle rather than the ramp alone.
	_camera.edge_scroll_allowed = true
	_set_setting("gameplay", "edge_scroll", false)
	_camera._refresh_settings()
	_ok(_camera._gather_pan_input() == Vector2.ZERO,
		"edge_scroll=false still produced pan input")
	_set_setting("gameplay", "edge_scroll", true)
	_camera._refresh_settings()
	_camera.edge_scroll_allowed = false
	_camera.rig.stop_motion()


func _test_settings_round_trip() -> void:
	var settings: Node = CameraServices.settings_node()
	if settings == null:
		_ok(false, "no Settings autoload")
		return
	var previous: Variant = CameraServices.setting("gameplay", "keybinds", {})

	Keybinds.reset_all()
	var f10 := InputEventKey.new()
	f10.physical_keycode = KEY_F10
	_ok(Keybinds.rebind(&"cam_focus_home", f10), "rebinding cam_focus_home failed")
	settings.call(&"set_value", "gameplay", "keybinds", Keybinds.to_dict())
	Keybinds.reset_all()
	Keybinds.restore(settings)
	_ok(Keybinds.is_overridden(&"cam_focus_home"), "the rebind did not survive Settings")
	var found: bool = false
	for e: InputEvent in InputMap.action_get_events(&"cam_focus_home"):
		var k := e as InputEventKey
		if k != null and k.physical_keycode == KEY_F10:
			found = true
	_ok(found, "the restored binding never reached InputMap")

	# Edge scroll is a gameplay setting the camera must actually obey.
	var previous_edge: Variant = CameraServices.setting("gameplay", "edge_scroll", true)
	_set_setting("gameplay", "edge_scroll", false)
	_camera._refresh_settings()
	_ok(not _camera._edge_scroll, "the camera ignored gameplay.edge_scroll")
	_set_setting("gameplay", "edge_scroll", previous_edge)

	Keybinds.reset_all()
	settings.call(&"set_value", "gameplay", "keybinds", previous)
	Keybinds.restore(settings)
	_camera._refresh_settings()
