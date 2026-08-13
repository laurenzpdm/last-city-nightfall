class_name CameraRig
extends RefCounted
## The camera's motion model. Pure math, no nodes, no autoloads, no engine input.
##
## GameCamera is a thin shell around this: it collects input, calls advance(dt), and
## copies the result onto a Camera2D. Keeping the maths here is what makes camera feel
## testable — every claim about zoom-to-cursor, momentum or clamping in tests/camera/
## is checked against this class directly, at a fixed dt, headlessly.
##
## Conventions:
##   position  logical camera centre, world px (shake is NOT part of it)
##   zoom      screen px per world px; > 1 is zoomed in
##   screen    viewport pixels, origin top-left

enum PanState { IDLE, DRIVEN, GLIDE, DRAG, FOCUS }

## Largest frame step the rig will integrate. A stalled frame must not teleport the map.
const MAX_DT: float = 0.1

var tuning: CameraTuning = CameraTuning.new()

var position: Vector2 = Vector2.ZERO
var zoom: float = 1.0
var viewport_size: Vector2 = Vector2(1920.0, 1080.0)
var world_bounds: Rect2 = Rect2(-8192.0, -8192.0, 16384.0, 16384.0)
var clamp_enabled: bool = true

var _log_zoom: float = 0.0
var _target_log_zoom: float = 0.0
var _zoom_anchor: Vector2 = Vector2.ZERO
var _zoom_anchor_active: bool = false

var _pan_input: Vector2 = Vector2.ZERO
var _velocity: Vector2 = Vector2.ZERO      ## screen px/s
var _glide_halflife: float = 0.075
var _state: int = PanState.IDLE

var _dragging: bool = false
var _drag_anchor_world: Vector2 = Vector2.ZERO
var _drag_screen: Vector2 = Vector2.ZERO
var _drag_step: Vector2 = Vector2.ZERO     ## screen movement accumulated since last advance

var _focus_active: bool = false
var _focus_from: Vector2 = Vector2.ZERO
var _focus_to: Vector2 = Vector2.ZERO
var _focus_t: float = 0.0
var _focus_duration: float = 0.0

var _clamped_x: bool = false
var _clamped_y: bool = false


func _init(t: CameraTuning = null) -> void:
	if t != null:
		tuning = t
	world_bounds = tuning.default_bounds
	zoom = tuning.zoom_default
	_log_zoom = log(zoom)
	_target_log_zoom = _log_zoom
	_glide_halflife = tuning.pan_release_halflife


# --- configuration ------------------------------------------------------------

func set_viewport_size(s: Vector2) -> void:
	if s.x <= 0.0 or s.y <= 0.0:
		return
	viewport_size = s


## The rectangle the camera centre may roam, in world px. Passed in by whoever knows
## the map size (grid system, or a scenario). Clamping keeps the *view* inside it.
func set_world_bounds(r: Rect2) -> void:
	world_bounds = r.abs()
	_clamp_position()


# --- input surface ------------------------------------------------------------

## Keyboard/edge-scroll direction, any magnitude; lengths above 1 are normalised.
func set_pan_input(dir: Vector2) -> void:
	var d: Vector2 = dir
	if d.length_squared() > 1.0:
		d = d.normalized()
	if d != Vector2.ZERO:
		_focus_active = false
	_pan_input = d


## `steps` is in wheel notches (fractional allowed, e.g. trackpad pinch).
## `anchor_screen` is the point that must keep showing the same world tile.
func zoom_by(steps: float, anchor_screen: Vector2) -> void:
	if is_zero_approx(steps):
		return
	set_target_zoom(exp(_target_log_zoom + steps * tuning.zoom_step), anchor_screen)


## Smoothly drive the zoom to an absolute level, anchored on a screen point.
func set_target_zoom(z: float, anchor_screen: Vector2 = Vector2.INF) -> void:
	_target_log_zoom = log(clampf(z, tuning.zoom_min, tuning.zoom_max))
	_zoom_anchor = _resolve_anchor(anchor_screen)
	_zoom_anchor_active = true


## No interpolation. Used for save restore and for tests that want an exact state.
func set_zoom_immediate(z: float, anchor_screen: Vector2 = Vector2.INF) -> void:
	var anchor: Vector2 = _resolve_anchor(anchor_screen)
	var new_zoom: float = clampf(z, tuning.zoom_min, tuning.zoom_max)
	_apply_zoom_anchored(new_zoom, anchor)
	_log_zoom = log(zoom)
	_target_log_zoom = _log_zoom
	_zoom_anchor_active = false
	_clamp_position()


func begin_drag(screen: Vector2) -> void:
	_dragging = true
	_state = PanState.DRAG
	_focus_active = false
	_velocity = Vector2.ZERO
	_drag_anchor_world = screen_to_world(screen)
	_drag_screen = screen
	_drag_step = Vector2.ZERO


func update_drag(screen: Vector2) -> void:
	if not _dragging:
		return
	_drag_step += screen - _drag_screen
	_drag_screen = screen
	# Exact: the world point grabbed at drag start stays under the cursor, no drift.
	position = _drag_anchor_world - (screen - viewport_size * 0.5) / zoom
	_clamp_position()


func end_drag() -> void:
	if not _dragging:
		return
	_dragging = false
	if _velocity.length() > tuning.max_throw_speed:
		_velocity = _velocity.normalized() * tuning.max_throw_speed
	_glide_halflife = tuning.drag_release_halflife
	_state = PanState.GLIDE if _velocity.length() > tuning.glide_stop_speed else PanState.IDLE


func is_dragging() -> bool:
	return _dragging


## Move the camera to a world point. `immediate` teleports (alerts that must not be missed),
## otherwise it eases in over a distance-scaled duration.
func focus_on(world_pos: Vector2, immediate: bool = false) -> void:
	_velocity = Vector2.ZERO
	if immediate:
		_focus_active = false
		position = world_pos
		_clamp_position()
		_state = PanState.IDLE
		return
	_focus_from = position
	_focus_to = world_pos
	_focus_t = 0.0
	var screen_distance: float = (world_pos - position).length() * zoom
	_focus_duration = clampf(
		sqrt(screen_distance) / tuning.focus_distance_divisor,
		tuning.focus_min_duration,
		tuning.focus_max_duration
	)
	_focus_active = true
	_state = PanState.FOCUS


## Frame a rectangle: picks the zoom that fits it with padding, then focuses its centre.
func focus_on_rect(rect: Rect2, padding: float = 64.0, immediate: bool = false) -> void:
	var r: Rect2 = rect.abs().grow(padding)
	var fit: float = 1.0
	if r.size.x > 0.0 and r.size.y > 0.0:
		fit = minf(viewport_size.x / r.size.x, viewport_size.y / r.size.y)
	var target: float = clampf(fit, tuning.zoom_min, tuning.zoom_max)
	if immediate:
		set_zoom_immediate(target)
	else:
		set_target_zoom(target, viewport_size * 0.5)
	focus_on(r.get_center(), immediate)


func is_focusing() -> bool:
	return _focus_active


## Kill momentum and any running focus. Called the instant the player touches anything.
func stop_motion() -> void:
	_velocity = Vector2.ZERO
	_focus_active = false
	_state = PanState.IDLE


## Cancel an automated move but keep whatever momentum the player built up.
func interrupt_focus() -> void:
	_focus_active = false
	if _state == PanState.FOCUS:
		_state = PanState.IDLE


# --- integration --------------------------------------------------------------

func advance(dt: float) -> void:
	var step: float = clampf(dt, 0.0, MAX_DT)
	if step <= 0.0:
		return
	_advance_zoom(step)
	_advance_pan(step)
	_clamp_position()


func _advance_zoom(dt: float) -> void:
	if absf(_target_log_zoom - _log_zoom) <= tuning.zoom_snap_epsilon:
		if _zoom_anchor_active:
			_apply_zoom_anchored(exp(_target_log_zoom), _zoom_anchor)
			_log_zoom = _target_log_zoom
			_zoom_anchor_active = false
		return
	_log_zoom = CameraTuning.approach(_log_zoom, _target_log_zoom, dt, tuning.zoom_smooth_halflife)
	_apply_zoom_anchored(exp(_log_zoom), _zoom_anchor if _zoom_anchor_active else viewport_size * 0.5)


func _advance_pan(dt: float) -> void:
	if _dragging:
		# Position already moved in update_drag; here we only measure how fast, so the
		# throw on release matches what the hand was doing.
		var instant: Vector2 = -_drag_step / dt
		_velocity = CameraTuning.approach_vec(_velocity, instant, dt, tuning.drag_velocity_halflife)
		_drag_step = Vector2.ZERO
		return

	if _focus_active:
		_focus_t += dt
		var t: float = 1.0 if _focus_duration <= 0.0 else clampf(_focus_t / _focus_duration, 0.0, 1.0)
		position = _focus_from.lerp(_focus_to, CameraTuning.smootherstep(t))
		if t >= 1.0:
			position = _focus_to
			_focus_active = false
			_state = PanState.IDLE
		return

	if _pan_input != Vector2.ZERO:
		_state = PanState.DRIVEN
		_glide_halflife = tuning.pan_release_halflife
		var desired: Vector2 = _pan_input * tuning.pan_speed
		_velocity = _velocity.move_toward(desired, tuning.pan_accel * dt)
	elif _velocity != Vector2.ZERO:
		_state = PanState.GLIDE
		_velocity = CameraTuning.approach_vec(_velocity, Vector2.ZERO, dt, _glide_halflife)
		if _velocity.length() < tuning.glide_stop_speed:
			_velocity = Vector2.ZERO
			_state = PanState.IDLE
	else:
		_state = PanState.IDLE

	if _velocity != Vector2.ZERO:
		position += _velocity * dt / zoom


func _apply_zoom_anchored(new_zoom: float, anchor_screen: Vector2) -> void:
	var z: float = clampf(new_zoom, tuning.zoom_min, tuning.zoom_max)
	if is_equal_approx(z, zoom):
		zoom = z
		return
	# Keep the world point under `anchor_screen` exactly where it is:
	#   p1 = p0 + (a - c) * (1/z0 - 1/z1)
	var offset: Vector2 = anchor_screen - viewport_size * 0.5
	position += offset * (1.0 / zoom - 1.0 / z)
	zoom = z


func _resolve_anchor(anchor_screen: Vector2) -> Vector2:
	if is_inf(anchor_screen.x) or is_inf(anchor_screen.y):
		return viewport_size * 0.5
	return anchor_screen


func _clamp_position() -> void:
	_clamped_x = false
	_clamped_y = false
	if not clamp_enabled:
		return
	var half: Vector2 = viewport_size * 0.5 / zoom
	var lo: Vector2 = world_bounds.position + half
	var hi: Vector2 = world_bounds.end - half
	var centre: Vector2 = world_bounds.get_center()

	if lo.x > hi.x:
		# View is wider than the world: pin to the middle, there is nothing to scroll to.
		if not is_equal_approx(position.x, centre.x):
			_clamped_x = true
		position.x = centre.x
	elif position.x < lo.x or position.x > hi.x:
		position.x = clampf(position.x, lo.x, hi.x)
		_clamped_x = true

	if lo.y > hi.y:
		if not is_equal_approx(position.y, centre.y):
			_clamped_y = true
		position.y = centre.y
	elif position.y < lo.y or position.y > hi.y:
		position.y = clampf(position.y, lo.y, hi.y)
		_clamped_y = true

	# Momentum into a wall dies at the wall instead of pressing against it.
	if _clamped_x:
		_velocity.x = 0.0
	if _clamped_y:
		_velocity.y = 0.0


# --- queries ------------------------------------------------------------------

func zoom_level() -> float:
	return zoom


func target_zoom_level() -> float:
	return exp(_target_log_zoom)


func velocity_screen() -> Vector2:
	return _velocity


func pan_state() -> int:
	return _state


func is_clamped() -> bool:
	return _clamped_x or _clamped_y


func screen_to_world(screen: Vector2) -> Vector2:
	return position + (screen - viewport_size * 0.5) / zoom


func world_to_screen(world_pos: Vector2) -> Vector2:
	return (world_pos - position) * zoom + viewport_size * 0.5


func visible_world_rect() -> Rect2:
	var size: Vector2 = viewport_size / zoom
	return Rect2(position - size * 0.5, size)


## Direction contribution from the mouse sitting near a window edge, 0..1 per axis.
## Static and pure so the ramp can be tested without a window.
static func edge_scroll_dir(mouse: Vector2, size: Vector2, margin: float) -> Vector2:
	if margin <= 0.0 or size.x <= 0.0 or size.y <= 0.0:
		return Vector2.ZERO
	if mouse.x < -margin or mouse.y < -margin or mouse.x > size.x + margin or mouse.y > size.y + margin:
		return Vector2.ZERO
	var dir: Vector2 = Vector2.ZERO
	if mouse.x < margin:
		dir.x = -_edge_ramp((margin - mouse.x) / margin)
	elif mouse.x > size.x - margin:
		dir.x = _edge_ramp((mouse.x - (size.x - margin)) / margin)
	if mouse.y < margin:
		dir.y = -_edge_ramp((margin - mouse.y) / margin)
	elif mouse.y > size.y - margin:
		dir.y = _edge_ramp((mouse.y - (size.y - margin)) / margin)
	return dir


static func _edge_ramp(t: float) -> float:
	var x: float = clampf(t, 0.0, 1.0)
	# Eased so brushing the edge nudges and slamming into it sprints.
	return x * x * (3.0 - 2.0 * x)


# --- persistence ---------------------------------------------------------------

func serialize() -> Dictionary:
	return {
		"x": position.x, "y": position.y, "zoom": zoom,
		"bounds": [world_bounds.position.x, world_bounds.position.y, world_bounds.size.x, world_bounds.size.y],
	}


func deserialize(d: Dictionary) -> void:
	if d.has("bounds"):
		var b: Array = d["bounds"]
		if b.size() == 4:
			set_world_bounds(Rect2(float(b[0]), float(b[1]), float(b[2]), float(b[3])))
	set_zoom_immediate(float(d.get("zoom", tuning.zoom_default)))
	position = Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	stop_motion()
	_clamp_position()
