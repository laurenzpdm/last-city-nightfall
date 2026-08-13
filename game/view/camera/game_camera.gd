class_name GameCamera
extends Camera2D
## The player's hands. Pan, zoom, drag, focus, shake, selection and the whole action map.
##
## Everything that decides *feel* lives in CameraRig (motion) and CameraShake (impact);
## this node collects input, hands it to them once per frame, and copies the result onto
## the Camera2D. It reads the simulation but never writes it — anything that changes the
## world goes out through Sim.submit_command().
##
## Contract for the rest of the game:
##   GameCamera.current()                     the active camera, no node paths needed
##   zoom_level() / detail_level()            how close the player is, for [P19] overlays
##   readability_changed(level, zoom)         emitted when a readability threshold is crossed
##   focus_on(pos, immediate)                 also wired to Bus.camera_focus_requested
##   shake(strength, duration, frequency)     for [P15]; honours screen_shake + reduce_motion
##   hovered_cell() / selected_entities()     for [P17] / [P18]
##   visible_world_rect()                     for culling and minimaps

## Zoom bands the rest of the game can key its readability off. CLOSE is "read one belt",
## STRATEGIC is "read the whole city as blocks".
enum DetailLevel { CLOSE, NORMAL, FAR, STRATEGIC }

const DETAIL_NAMES: Array[StringName] = [&"close", &"normal", &"far", &"strategic"]
const SPEED_STEPS: Array[float] = [1.0, 2.0, 3.0]
const SETTINGS_REFRESH: float = 0.5
const MOVE_EPSILON: float = 0.5

signal zoom_changed(zoom_value: float)
signal readability_changed(level: int, zoom_value: float)
signal hover_cell_changed(cell: Vector2i, inside: bool)
signal selection_changed(ids: PackedInt32Array, cell_rect: Rect2i)
signal box_select_changed(rect: Rect2, active: bool)
signal overlay_requested(index: int)
signal action_pressed(action: StringName)
signal sim_speed_changed(speed: float, running: bool)
signal camera_moved(centre: Vector2, zoom_value: float)

static var _current: GameCamera = null

@export var edge_scroll_allowed: bool = true
@export var handle_time_controls: bool = true
@export var handle_overlay_hotkeys: bool = true
@export var draw_selection_visuals: bool = true
@export var shake_roll_enabled: bool = true
## macOS trackpads emit both wheel and pan-gesture events for a two-finger scroll, so
## pan gestures stay off by default and [P24] can expose the toggle.
@export var trackpad_pan_enabled: bool = false
@export var trackpad_pan_scale: float = 26.0
@export var start_zoom: float = 1.0

var tuning: CameraTuning = CameraTuning.new()
var rig: CameraRig = null
var shake_model: CameraShake = null
var selection: SelectionController = null

var home_position: Vector2 = Vector2.ZERO

var _overlay: SelectionOverlay = null
var _detail_level: int = DetailLevel.NORMAL
var _overlay_index: int = 0
var _overlay_modes: PackedStringArray = PackedStringArray()
var _last_reported_centre: Vector2 = Vector2.ZERO
var _last_reported_zoom: float = -1.0
var _settings_timer: float = 0.0
var _edge_scroll: bool = true
var _reduce_motion: bool = false
var _shake_scale: float = 1.0
var _sim_speed: float = 1.0


## The camera the player is looking through, or null before one exists.
static func current() -> GameCamera:
	return _current if is_instance_valid(_current) else null


func _enter_tree() -> void:
	Keybinds.install()
	Keybinds.restore(CameraServices.settings_node())


func _ready() -> void:
	rig = CameraRig.new(tuning)
	shake_model = CameraShake.new(tuning)
	selection = SelectionController.new()
	selection.tile_size = CameraTuning.TILE_SIZE
	selection.drag_threshold_px = tuning.drag_threshold_px
	selection.provider = SimEntityProvider.new()
	selection.hover_changed.connect(_on_hover_changed)
	selection.selection_changed.connect(_on_selection_changed)
	selection.box_changed.connect(_on_box_changed)

	_overlay = SelectionOverlay.new()
	_overlay.name = "SelectionOverlay"
	_overlay.enabled = draw_selection_visuals
	add_child(_overlay)

	# Roll shake needs the camera to stop ignoring its own rotation.
	if has_method(&"set_ignore_rotation"):
		set(&"ignore_rotation", not shake_roll_enabled)
	position_smoothing_enabled = false
	rotation_smoothing_enabled = false

	_refresh_settings()
	rig.set_viewport_size(_viewport_size())
	rig.position = global_position
	rig.set_zoom_immediate(start_zoom)
	_detail_level = _raw_detail_level(rig.zoom)

	CameraServices.connect_bus(&"camera_focus_requested", _on_bus_focus_requested)
	CameraServices.connect_bus(&"world_ready", _on_world_ready)

	make_current()
	_current = self
	_apply_to_node()
	CameraServices.log_info("camera", "ready at zoom %.2f, detail=%s" % [rig.zoom, DETAIL_NAMES[_detail_level]])


func _exit_tree() -> void:
	CameraServices.disconnect_bus(&"camera_focus_requested", _on_bus_focus_requested)
	CameraServices.disconnect_bus(&"world_ready", _on_world_ready)
	if _current == self:
		_current = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		# Alt-tabbing must not leave the camera sliding or a box half-drawn.
		if rig != null:
			rig.set_pan_input(Vector2.ZERO)
			if rig.is_dragging():
				rig.end_drag()
			rig.stop_motion()
		if selection != null:
			selection.cancel()


# --- frame ---------------------------------------------------------------------

func _process(delta: float) -> void:
	if rig == null:
		return
	_settings_timer -= delta
	if _settings_timer <= 0.0:
		_refresh_settings()

	rig.set_viewport_size(_viewport_size())
	rig.set_pan_input(_gather_pan_input())
	rig.advance(delta)
	shake_model.advance(delta)
	_apply_to_node()
	_update_hover()
	_update_detail_level()
	_sync_overlay()
	_report_movement()


func _apply_to_node() -> void:
	global_position = rig.position
	var z: float = rig.zoom
	zoom = Vector2(z, z)
	if _reduce_motion or _shake_scale <= 0.0:
		offset = Vector2.ZERO
		rotation = 0.0
		return
	# Camera2D.offset is world space, so divide by zoom to keep shake constant on screen.
	offset = shake_model.offset() / z
	rotation = shake_model.roll() if shake_roll_enabled else 0.0


func _gather_pan_input() -> Vector2:
	var dir: Vector2 = Vector2.ZERO
	# Ctrl/Cmd chords are commands, not movement — Cmd+S must not nudge the view.
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META):
		return dir
	if Keybinds.pressed(&"cam_pan_right"):
		dir.x += 1.0
	if Keybinds.pressed(&"cam_pan_left"):
		dir.x -= 1.0
	if Keybinds.pressed(&"cam_pan_down"):
		dir.y += 1.0
	if Keybinds.pressed(&"cam_pan_up"):
		dir.y -= 1.0
	if dir != Vector2.ZERO:
		return dir
	if not (_edge_scroll and edge_scroll_allowed) or rig.is_dragging():
		return dir
	if not _window_focused():
		return dir
	var edge: Vector2 = CameraRig.edge_scroll_dir(
		_mouse_position(), _viewport_size(), tuning.edge_margin)
	return edge * tuning.edge_speed_scale


func _update_hover() -> void:
	var mouse: Vector2 = _mouse_position()
	var size: Vector2 = _viewport_size()
	var inside: bool = Rect2(Vector2.ZERO, size).has_point(mouse)
	selection.set_hover(rig.screen_to_world(mouse), inside)


func _sync_overlay() -> void:
	if _overlay == null:
		return
	_overlay.enabled = draw_selection_visuals
	_overlay.reduce_motion = _reduce_motion
	_overlay.sync(
		rig.zoom, selection.hovered_cell, selection.hovering,
		selection.box_rect(), selection.box_active,
		selection.selected_cells, selection.has_selection)


func _report_movement() -> void:
	if rig.position.distance_to(_last_reported_centre) < MOVE_EPSILON and is_equal_approx(rig.zoom, _last_reported_zoom):
		return
	if not is_equal_approx(rig.zoom, _last_reported_zoom):
		zoom_changed.emit(rig.zoom)
	_last_reported_centre = rig.position
	_last_reported_zoom = rig.zoom
	camera_moved.emit(rig.position, rig.zoom)


# --- input ---------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if rig == null:
		return
	if _handle_pointer_motion(event) or _handle_gesture(event):
		get_viewport().set_input_as_handled()
		return
	var pressed_action: StringName = Keybinds.match_pressed(event)
	if pressed_action != &"" and _on_action_pressed(pressed_action, event):
		get_viewport().set_input_as_handled()
		return
	var released_action: StringName = Keybinds.match_released(event)
	if released_action != &"" and _on_action_released(released_action, event):
		get_viewport().set_input_as_handled()


func _handle_pointer_motion(event: InputEvent) -> bool:
	var motion := event as InputEventMouseMotion
	if motion == null:
		return false
	if rig.is_dragging():
		rig.update_drag(motion.position)
		return true
	if selection.is_pressed():
		selection.motion(rig.screen_to_world(motion.position), motion.position)
		return true
	return false


func _handle_gesture(event: InputEvent) -> bool:
	if event is InputEventMagnifyGesture:
		var g := event as InputEventMagnifyGesture
		if g.factor > 0.0:
			rig.zoom_by(log(g.factor) / tuning.zoom_step, g.position)
		return true
	if trackpad_pan_enabled and event is InputEventPanGesture:
		var p := event as InputEventPanGesture
		rig.stop_motion()
		rig.position += p.delta * trackpad_pan_scale / rig.zoom
		return true
	return false


func _on_action_pressed(action: StringName, event: InputEvent) -> bool:
	match action:
		&"cam_zoom_in":
			rig.zoom_by(1.0, _event_anchor(event))
			return true
		&"cam_zoom_out":
			rig.zoom_by(-1.0, _event_anchor(event))
			return true
		&"cam_zoom_reset":
			rig.set_target_zoom(tuning.zoom_default, _viewport_size() * 0.5)
			return true
		&"cam_focus_home":
			focus_on(home_position, false)
			return true
		&"cam_drag":
			rig.begin_drag(_event_position(event))
			return true
		&"select":
			var screen: Vector2 = _event_position(event)
			rig.interrupt_focus()
			selection.press(rig.screen_to_world(screen), screen, _shift_held(event))
			return true
		&"cancel":
			if selection.is_pressed() or selection.box_active:
				selection.cancel()
			elif selection.has_selection:
				selection.clear()
			action_pressed.emit(action)
			return true
		&"pause":
			if not handle_time_controls:
				action_pressed.emit(action)
				return true
			toggle_pause()
			action_pressed.emit(action)
			return true
	var name: String = String(action)
	if name.begins_with("speed_"):
		var step: int = int(name.substr(6)) - 1
		if handle_time_controls and step >= 0 and step < SPEED_STEPS.size():
			set_sim_speed(SPEED_STEPS[step])
		action_pressed.emit(action)
		return true
	if name.begins_with("overlay_"):
		var index: int = int(name.substr(8))
		if handle_overlay_hotkeys and index >= 1 and index <= 5:
			request_overlay(index)
		action_pressed.emit(action)
		return true
	if action in [&"build", &"rotate", &"copy", &"paste", &"blueprint", &"quick_save", &"quick_load"]:
		action_pressed.emit(action)
		return true
	return false


func _on_action_released(action: StringName, event: InputEvent) -> bool:
	match action:
		&"cam_drag":
			rig.end_drag()
			return true
		&"select":
			var screen: Vector2 = _event_position(event)
			selection.release(rig.screen_to_world(screen), screen)
			return true
	return false


func _shift_held(event: InputEvent) -> bool:
	var mods := event as InputEventWithModifiers
	return mods != null and mods.shift_pressed


func _event_position(event: InputEvent) -> Vector2:
	var mouse := event as InputEventMouse
	return mouse.position if mouse != null else _mouse_position()


func _event_anchor(event: InputEvent) -> Vector2:
	# Wheel zooms at the cursor. Keyboard zooms at the centre, because there is no cursor
	# intent behind a key press and yanking the view to the pointer would feel possessed.
	var button := event as InputEventMouseButton
	return button.position if button != null else _viewport_size() * 0.5


# --- public API ----------------------------------------------------------------

## Current zoom, screen px per world px. > 1 is zoomed in.
func zoom_level() -> float:
	return rig.zoom if rig != null else 1.0


## Where the zoom is heading, before smoothing. Use for UI that must not lag the input.
func target_zoom_level() -> float:
	return rig.target_zoom_level() if rig != null else 1.0


func detail_level() -> int:
	return _detail_level


func detail_level_name() -> StringName:
	return DETAIL_NAMES[_detail_level]


## Absolute zoom, smoothed. Anchored on the screen centre.
func set_zoom_level(z: float, animate: bool = true) -> void:
	if rig == null:
		return
	if animate:
		rig.set_target_zoom(z, _viewport_size() * 0.5)
	else:
		rig.set_zoom_immediate(z)


## Move to a world point. `immediate` teleports; otherwise it eases over a
## distance-scaled duration and any player input cancels it.
func focus_on(pos: Vector2, immediate: bool = false) -> void:
	if rig == null:
		return
	rig.focus_on(pos, immediate)


## Frame a whole area — a district, a wave's spawn cluster, a blueprint.
func focus_on_rect(rect: Rect2, padding: float = 96.0, immediate: bool = false) -> void:
	if rig == null:
		return
	rig.focus_on_rect(rect, padding, immediate)


## Impact shake. `strength` 0..1, `duration` seconds, `frequency` shakes/second.
## Scaled by Settings.graphics.screen_shake and silenced by accessibility.reduce_motion.
func shake(strength: float, duration: float = 0.35, frequency: float = -1.0) -> void:
	if shake_model == null or _reduce_motion or _shake_scale <= 0.0:
		return
	shake_model.add(strength * _shake_scale, duration, frequency)


func shake_trauma() -> float:
	return shake_model.trauma if shake_model != null else 0.0


## Roaming limits for the camera centre, in world px. Called by whoever knows the map.
func set_world_bounds(bounds: Rect2) -> void:
	if rig == null:
		return
	rig.set_world_bounds(bounds)


func world_bounds() -> Rect2:
	return rig.world_bounds if rig != null else Rect2()


## Where "H" sends the player. [P11] should point this at the generator once it exists.
func set_home(pos: Vector2) -> void:
	home_position = pos


func hovered_cell() -> Vector2i:
	return selection.hovered_cell if selection != null else Vector2i.ZERO


func hovered_world() -> Vector2:
	return selection.hovered_world if selection != null else Vector2.ZERO


func is_hovering() -> bool:
	return selection != null and selection.hovering


func selected_entities() -> PackedInt32Array:
	return selection.selected if selection != null else PackedInt32Array()


func selection_cell_rect() -> Rect2i:
	return selection.selected_cells if selection != null else Rect2i()


func clear_selection() -> void:
	if selection != null:
		selection.clear()


## Replace the default sim-backed entity lookup ([P18] may want its own).
func set_entity_provider(p: Object) -> void:
	if selection != null:
		selection.provider = p


## [P19] registers the five overlay ids so hotkeys can announce them on the Bus.
## Without this the camera only emits overlay_requested(index).
func set_overlay_modes(modes: PackedStringArray) -> void:
	_overlay_modes = modes


func active_overlay() -> int:
	return _overlay_index


## Pressing the active overlay again turns it off; 0 means "no overlay".
func request_overlay(index: int) -> void:
	var next: int = 0 if index == _overlay_index else index
	_overlay_index = next
	overlay_requested.emit(next)
	if _overlay_modes.is_empty():
		return
	var mode: StringName = &"none"
	if next >= 1 and next <= _overlay_modes.size():
		mode = StringName(_overlay_modes[next - 1])
	CameraServices.emit_bus(&"overlay_mode_changed", [mode])


func toggle_pause() -> void:
	var running: bool = CameraServices.sim_running()
	CameraServices.set_sim_running(not running)
	sim_speed_changed.emit(_sim_speed, not running)


func set_sim_speed(speed: float) -> void:
	_sim_speed = speed
	CameraServices.set_sim_speed(speed)
	sim_speed_changed.emit(speed, speed > 0.0)


## The only legal way for camera-driven UI to change the world.
func submit_command(cmd: Dictionary) -> void:
	CameraServices.submit_command(cmd)


func screen_to_world(screen: Vector2) -> Vector2:
	return rig.screen_to_world(screen) if rig != null else screen


func world_to_screen(world_pos: Vector2) -> Vector2:
	return rig.world_to_screen(world_pos) if rig != null else world_pos


## What the player can currently see, in world px. For culling, minimaps and overlays.
func visible_world_rect() -> Rect2:
	return rig.visible_world_rect() if rig != null else Rect2()


func serialize() -> Dictionary:
	var d: Dictionary = rig.serialize() if rig != null else {}
	d["overlay"] = _overlay_index
	return d


func deserialize(data: Dictionary) -> void:
	if rig == null:
		return
	rig.deserialize(data)
	_overlay_index = int(data.get("overlay", 0))
	_detail_level = _raw_detail_level(rig.zoom)
	_apply_to_node()


# --- internals -----------------------------------------------------------------

func _refresh_settings() -> void:
	_settings_timer = SETTINGS_REFRESH
	_edge_scroll = CameraServices.setting_bool("gameplay", "edge_scroll", true)
	_reduce_motion = CameraServices.setting_bool("accessibility", "reduce_motion", false)
	_shake_scale = CameraServices.setting_float("graphics", "screen_shake", 1.0)


func _viewport_size() -> Vector2:
	var vp: Viewport = get_viewport()
	if vp == null:
		return rig.viewport_size if rig != null else Vector2(1920.0, 1080.0)
	return vp.get_visible_rect().size


func _mouse_position() -> Vector2:
	var vp: Viewport = get_viewport()
	return vp.get_mouse_position() if vp != null else Vector2.ZERO


func _window_focused() -> bool:
	var w: Window = get_window()
	return w == null or w.has_focus()


func _raw_detail_level(z: float) -> int:
	return tuning.detail_level_for(z)


## Hysteresis around each threshold: a zoom parked on the boundary must not strobe the
## overlays on and off, which is exactly what a naive comparison does.
func _update_detail_level() -> void:
	var z: float = rig.zoom
	var level: int = tuning.detail_level_step(z, _detail_level)
	if level == _detail_level:
		return
	_detail_level = level
	readability_changed.emit(level, z)
	CameraServices.log_debug("camera", "readability -> %s at zoom %.3f" % [DETAIL_NAMES[level], z])


func _on_hover_changed(cell: Vector2i, _world_pos: Vector2, inside: bool) -> void:
	hover_cell_changed.emit(cell, inside)


func _on_selection_changed(ids: PackedInt32Array, cell_rect: Rect2i) -> void:
	selection_changed.emit(ids, cell_rect)


func _on_box_changed(rect: Rect2, active: bool) -> void:
	box_select_changed.emit(rect, active)


func _on_bus_focus_requested(pos: Vector2) -> void:
	focus_on(pos, false)
	if _overlay != null:
		_overlay.ping(pos)


func _on_world_ready() -> void:
	_adopt_world_bounds()


## The grid system owns the map extent; ask it in whatever shape it offers. Until [P01]
## exposes one of these, the generous default bounds apply and nothing breaks.
func _adopt_world_bounds() -> void:
	var grid: Object = CameraServices.sim_system(&"grid")
	if grid == null:
		return
	if grid.has_method(&"world_bounds_px"):
		var r: Variant = grid.call(&"world_bounds_px")
		if r is Rect2:
			set_world_bounds(r)
			return
	if grid.has_method(&"world_rect_tiles"):
		var t: Variant = grid.call(&"world_rect_tiles")
		if t is Rect2i:
			var rect: Rect2i = t
			set_world_bounds(Rect2(
				Vector2(rect.position) * float(CameraTuning.TILE_SIZE),
				Vector2(rect.size) * float(CameraTuning.TILE_SIZE)))
			return
	if grid.has_method(&"size_tiles"):
		var s: Variant = grid.call(&"size_tiles")
		if s is Vector2i:
			var size: Vector2i = s
			var px: Vector2 = Vector2(size) * float(CameraTuning.TILE_SIZE)
			set_world_bounds(Rect2(-px * 0.5, px))
			return
	CameraServices.log_debug("camera", "grid system exposes no world extent; keeping default bounds")
