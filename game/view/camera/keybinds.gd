class_name Keybinds
extends RefCounted
## The whole input action map, defined in code at runtime.
##
## project.godot is integrator-owned, so nothing here touches it: the actions are
## registered into InputMap at boot, rebinds are stored as plain data, and the data
## rides along in Settings.gameplay["keybinds"] so it survives a restart.
##
## Matching rule: every binding is compared with **exact modifiers**. Without that,
## Ctrl+B (blueprint) would also fire B (build), because Godot's default action
## matching ignores modifiers. Consumers should poll through Keybinds.pressed() /
## Keybinds.just_pressed(), or simply listen to GameCamera.action_pressed.

## Which screen an action belongs to. Used for conflict checks and for grouping in a
## settings UI, so rebinding "rotate" cannot silently collide with a camera key.
enum Ctx { CAMERA, SELECTION, BUILD, TIME, OVERLAY, SYSTEM }

const SETTINGS_SECTION: String = "gameplay"
const SETTINGS_KEY: String = "keybinds"
const DEADZONE: float = 0.2

const CTX_NAMES: Array[String] = ["camera", "selection", "build", "time", "overlay", "system"]

static var _defaults: Dictionary[StringName, Array] = {}
static var _labels: Dictionary[StringName, String] = {}
static var _contexts: Dictionary[StringName, int] = {}
static var _order: Array[StringName] = []
## action -> Array of serialized event dictionaries. Only actions the player changed.
static var _overrides: Dictionary[StringName, Array] = {}
static var _installed: bool = false


# --- installation --------------------------------------------------------------

## Registers every action in InputMap and applies stored rebinds. Idempotent.
static func install(force: bool = false) -> void:
	if _installed and not force:
		return
	_build_defaults()
	for action: StringName in _order:
		if not InputMap.has_action(action):
			InputMap.add_action(action, DEADZONE)
		_apply(action)
	_installed = true
	CameraServices.log_info("input", "action map installed: %d actions" % _order.size())


static func is_installed() -> bool:
	return _installed


## Removes every action this class owns. Tests use it to prove a clean re-install.
static func uninstall() -> void:
	for action: StringName in _order:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
	_installed = false


static func actions() -> Array[StringName]:
	_build_defaults()
	return _order.duplicate()


static func actions_in(context: int) -> Array[StringName]:
	_build_defaults()
	var out: Array[StringName] = []
	for action: StringName in _order:
		if _contexts.get(action, Ctx.SYSTEM) == context:
			out.append(action)
	return out


static func has(action: StringName) -> bool:
	_build_defaults()
	return _defaults.has(action)


## Human-readable name for a settings screen, e.g. "Rotate building".
static func label(action: StringName) -> String:
	_build_defaults()
	return _labels.get(action, String(action))


static func context_of(action: StringName) -> int:
	_build_defaults()
	return _contexts.get(action, Ctx.SYSTEM)


static func context_name(context: int) -> String:
	return CTX_NAMES[context] if context >= 0 and context < CTX_NAMES.size() else "system"


# --- polling -------------------------------------------------------------------

## Held-key polling (pan keys). Modifier-insensitive on purpose: holding Shift while
## panning must keep panning.
static func pressed(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


static func just_pressed(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_just_pressed(action)


static func just_released(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_just_released(action)


static func event_is(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action_pressed(action, false, true)


static func event_is_release(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action_released(action, true)


## The action an event should trigger, or &"" for none.
##
## Exact modifier match first, then a modifier-insensitive fallback. Both passes are
## needed: without the exact pass Ctrl+B fires "blueprint" *and* "build"; without the
## loose fallback Shift+click stops counting as "select". Ties are impossible in the
## exact pass because rebind() refuses colliding bindings.
static func match_pressed(event: InputEvent) -> StringName:
	_build_defaults()
	var loose: StringName = &""
	for action: StringName in _order:
		if not InputMap.has_action(action):
			continue
		if event.is_action_pressed(action, false, true):
			return action
		if loose == &"" and event.is_action_pressed(action, false, false):
			loose = action
	return loose


static func match_released(event: InputEvent) -> StringName:
	_build_defaults()
	var loose: StringName = &""
	for action: StringName in _order:
		if not InputMap.has_action(action):
			continue
		if event.is_action_released(action, true):
			return action
		if loose == &"" and event.is_action_released(action, false):
			loose = action
	return loose


# --- rebinding -----------------------------------------------------------------

## Effective events for an action: the player's override if any, else the default.
static func events_for(action: StringName) -> Array[InputEvent]:
	_build_defaults()
	var out: Array[InputEvent] = []
	if _overrides.has(action):
		for d: Dictionary in _overrides[action]:
			var e: InputEvent = event_from_dict(d)
			if e != null:
				out.append(e)
		return out
	for e: InputEvent in _defaults.get(action, []):
		out.append(e.duplicate() as InputEvent)
	return out


## Actions already using an equivalent event. Empty means the binding is free.
static func conflicts(action: StringName, event: InputEvent) -> Array[StringName]:
	_build_defaults()
	var wanted: String = event_signature(event)
	var out: Array[StringName] = []
	if wanted == "":
		return out
	for other: StringName in _order:
		if other == action:
			continue
		for e: InputEvent in events_for(other):
			if event_signature(e) == wanted:
				out.append(other)
				break
	return out


## Replaces one binding slot. Returns false when the action is unknown, the event type
## is unsupported, or it would collide with another action and allow_conflict is false.
static func rebind(action: StringName, event: InputEvent, slot: int = 0, allow_conflict: bool = false) -> bool:
	_build_defaults()
	if not _defaults.has(action):
		CameraServices.log_warn("input", "rebind of unknown action '%s'" % action)
		return false
	var d: Dictionary = event_to_dict(event)
	if d.is_empty():
		CameraServices.log_warn("input", "rebind of '%s' with unsupported event" % action)
		return false
	if not allow_conflict:
		var clash: Array[StringName] = conflicts(action, event)
		if not clash.is_empty():
			CameraServices.log_warn("input", "rebind of '%s' collides with %s" % [action, str(clash)])
			return false
	var current: Array = _serialize_events(events_for(action))
	var index: int = clampi(slot, 0, current.size())
	if index < current.size():
		current[index] = d
	else:
		current.append(d)
	_overrides[action] = current
	_apply(action)
	return true


## Adds a second (or third) binding without dropping the existing ones.
static func add_binding(action: StringName, event: InputEvent, allow_conflict: bool = false) -> bool:
	return rebind(action, event, 1 << 30, allow_conflict)


static func clear_bindings(action: StringName) -> void:
	_build_defaults()
	if not _defaults.has(action):
		return
	_overrides[action] = []
	_apply(action)


static func reset(action: StringName) -> void:
	if _overrides.erase(action):
		_apply(action)


static func reset_all() -> void:
	var changed: Array = _overrides.keys()
	_overrides.clear()
	for a: StringName in changed:
		_apply(a)


static func is_overridden(action: StringName) -> bool:
	return _overrides.has(action)


# --- persistence ---------------------------------------------------------------

## Only overrides are stored; defaults stay in code so they can be improved later
## without a stale copy in every player's config file.
static func to_dict() -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = _overrides.keys()
	keys.sort()
	for a: StringName in keys:
		out[String(a)] = (_overrides[a] as Array).duplicate(true)
	return out


static func from_dict(data: Dictionary) -> void:
	_build_defaults()
	_overrides.clear()
	var keys: Array = data.keys()
	keys.sort()
	for k: Variant in keys:
		var action := StringName(str(k))
		if not _defaults.has(action):
			continue
		var raw: Variant = data[k]
		if typeof(raw) != TYPE_ARRAY:
			continue
		var events: Array = []
		for entry: Variant in raw:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			if event_from_dict(entry) == null:
				continue
			events.append(entry)
		_overrides[action] = events
	if _installed:
		for action: StringName in _order:
			_apply(action)


## `settings` is the Settings autoload (passed in so this file never names an autoload).
static func persist(settings: Object) -> void:
	if settings == null:
		return
	settings.call(&"set_value", SETTINGS_SECTION, SETTINGS_KEY, to_dict())
	settings.call(&"save_to_disk")


static func restore(settings: Object) -> void:
	if settings == null:
		return
	var raw: Variant = settings.call(&"get_value", SETTINGS_SECTION, SETTINGS_KEY, {})
	if typeof(raw) == TYPE_DICTIONARY:
		from_dict(raw)


# --- event <-> data -------------------------------------------------------------

## Plain-data form of an event. No objects, so it round-trips through ConfigFile.
static func event_to_dict(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		var k := event as InputEventKey
		var physical: int = int(k.physical_keycode)
		var code: int = int(k.keycode)
		if physical == 0 and code == 0:
			return {}
		return {
			"type": "key", "physical": physical, "keycode": code,
			"cmd_ctrl": k.command_or_control_autoremap,
			"ctrl": k.ctrl_pressed, "alt": k.alt_pressed,
			"shift": k.shift_pressed, "meta": k.meta_pressed,
		}
	if event is InputEventMouseButton:
		var m := event as InputEventMouseButton
		return {
			"type": "mouse", "button": int(m.button_index),
			"cmd_ctrl": m.command_or_control_autoremap,
			"ctrl": m.ctrl_pressed, "alt": m.alt_pressed,
			"shift": m.shift_pressed, "meta": m.meta_pressed,
		}
	if event is InputEventJoypadButton:
		return {"type": "joy_button", "button": int((event as InputEventJoypadButton).button_index)}
	if event is InputEventJoypadMotion:
		var j := event as InputEventJoypadMotion
		return {"type": "joy_axis", "axis": int(j.axis), "value": j.axis_value}
	return {}


static func event_from_dict(data: Dictionary) -> InputEvent:
	var kind: String = str(data.get("type", ""))
	match kind:
		"key":
			var k := InputEventKey.new()
			k.physical_keycode = int(data.get("physical", 0))
			k.keycode = int(data.get("keycode", 0))
			if k.physical_keycode == KEY_NONE and k.keycode == KEY_NONE:
				return null
			_apply_modifiers(k, data)
			return k
		"mouse":
			var m := InputEventMouseButton.new()
			m.button_index = int(data.get("button", 0))
			if m.button_index == MOUSE_BUTTON_NONE:
				return null
			_apply_modifiers(m, data)
			return m
		"joy_button":
			var b := InputEventJoypadButton.new()
			b.button_index = int(data.get("button", 0))
			return b
		"joy_axis":
			var j := InputEventJoypadMotion.new()
			j.axis = int(data.get("axis", 0))
			j.axis_value = float(data.get("value", 1.0))
			return j
	return null


## Canonical string for equality checks between two events.
static func event_signature(event: InputEvent) -> String:
	var d: Dictionary = event_to_dict(event)
	if d.is_empty():
		return ""
	var keys: Array = d.keys()
	keys.sort()
	var parts: PackedStringArray = PackedStringArray()
	for k: String in keys:
		parts.append("%s=%s" % [k, str(d[k])])
	return "|".join(parts)


# --- display -------------------------------------------------------------------

## What a settings screen shows for one binding, e.g. "Ctrl+S" or "Middle Mouse".
static func event_label(event: InputEvent) -> String:
	if event is InputEventKey:
		var k := event as InputEventKey
		var code: int = int(k.keycode)
		if code == 0:
			code = int(DisplayServer.keyboard_get_keycode_from_physical(k.physical_keycode))
			if code == 0:
				code = int(k.physical_keycode)
		return _modifier_prefix(k) + OS.get_keycode_string(code)
	if event is InputEventMouseButton:
		var m := event as InputEventMouseButton
		return _modifier_prefix(m) + _mouse_name(m.button_index)
	if event is InputEventJoypadButton:
		return "Pad %d" % int((event as InputEventJoypadButton).button_index)
	if event is InputEventJoypadMotion:
		var j := event as InputEventJoypadMotion
		return "Pad axis %d%s" % [int(j.axis), "+" if j.axis_value > 0.0 else "-"]
	return "—"


static func binding_label(action: StringName) -> String:
	var events: Array[InputEvent] = events_for(action)
	if events.is_empty():
		return "—"
	return event_label(events[0])


static func _modifier_prefix(event: InputEventWithModifiers) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if event.command_or_control_autoremap:
		parts.append("Cmd" if OS.has_feature("macos") else "Ctrl")
	else:
		if event.ctrl_pressed:
			parts.append("Ctrl")
		if event.meta_pressed:
			parts.append("Meta")
	if event.alt_pressed:
		parts.append("Alt")
	if event.shift_pressed:
		parts.append("Shift")
	if parts.is_empty():
		return ""
	return "+".join(parts) + "+"


static func _mouse_name(button: int) -> String:
	match button:
		MOUSE_BUTTON_LEFT: return "Left Mouse"
		MOUSE_BUTTON_RIGHT: return "Right Mouse"
		MOUSE_BUTTON_MIDDLE: return "Middle Mouse"
		MOUSE_BUTTON_WHEEL_UP: return "Wheel Up"
		MOUSE_BUTTON_WHEEL_DOWN: return "Wheel Down"
		MOUSE_BUTTON_WHEEL_LEFT: return "Wheel Left"
		MOUSE_BUTTON_WHEEL_RIGHT: return "Wheel Right"
	return "Mouse %d" % int(button)


# --- internals -----------------------------------------------------------------

static func _apply(action: StringName) -> void:
	if not InputMap.has_action(action):
		return
	InputMap.action_erase_events(action)
	for e: InputEvent in events_for(action):
		InputMap.action_add_event(action, e)


static func _serialize_events(events: Array[InputEvent]) -> Array:
	var out: Array = []
	for e: InputEvent in events:
		var d: Dictionary = event_to_dict(e)
		if not d.is_empty():
			out.append(d)
	return out


static func _apply_modifiers(event: InputEventWithModifiers, data: Dictionary) -> void:
	event.alt_pressed = bool(data.get("alt", false))
	event.shift_pressed = bool(data.get("shift", false))
	# Order matters: Godot refuses ctrl/meta writes once autoremap is on.
	if bool(data.get("cmd_ctrl", false)):
		event.command_or_control_autoremap = true
		return
	event.ctrl_pressed = bool(data.get("ctrl", false))
	event.meta_pressed = bool(data.get("meta", false))


static func _register(action: StringName, context: int, text: String, events: Array) -> void:
	_defaults[action] = events
	_labels[action] = text
	_contexts[action] = context
	_order.append(action)


static func _key(code: int, alt: bool = false, shift: bool = false, cmd_ctrl: bool = false) -> InputEventKey:
	var e := InputEventKey.new()
	# Physical, so WASD stays where it is on AZERTY and QWERTZ keyboards.
	e.physical_keycode = code
	e.alt_pressed = alt
	e.shift_pressed = shift
	if cmd_ctrl:
		e.command_or_control_autoremap = true
	return e


static func _mouse(button: int) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	return e


static func _build_defaults() -> void:
	if not _defaults.is_empty():
		return

	_register(&"cam_pan_up", Ctx.CAMERA, "Pan up", [_key(KEY_W), _key(KEY_UP)])
	_register(&"cam_pan_down", Ctx.CAMERA, "Pan down", [_key(KEY_S), _key(KEY_DOWN)])
	_register(&"cam_pan_left", Ctx.CAMERA, "Pan left", [_key(KEY_A), _key(KEY_LEFT)])
	_register(&"cam_pan_right", Ctx.CAMERA, "Pan right", [_key(KEY_D), _key(KEY_RIGHT)])
	_register(&"cam_zoom_in", Ctx.CAMERA, "Zoom in", [
		_mouse(MOUSE_BUTTON_WHEEL_UP), _key(KEY_EQUAL), _key(KEY_KP_ADD)])
	_register(&"cam_zoom_out", Ctx.CAMERA, "Zoom out", [
		_mouse(MOUSE_BUTTON_WHEEL_DOWN), _key(KEY_MINUS), _key(KEY_KP_SUBTRACT)])
	_register(&"cam_zoom_reset", Ctx.CAMERA, "Reset zoom", [_key(KEY_0)])
	_register(&"cam_drag", Ctx.CAMERA, "Drag map", [_mouse(MOUSE_BUTTON_MIDDLE)])
	_register(&"cam_focus_home", Ctx.CAMERA, "Centre on the generator", [_key(KEY_H)])

	_register(&"select", Ctx.SELECTION, "Select", [_mouse(MOUSE_BUTTON_LEFT)])
	_register(&"cancel", Ctx.SELECTION, "Cancel", [_key(KEY_ESCAPE), _mouse(MOUSE_BUTTON_RIGHT)])

	_register(&"build", Ctx.BUILD, "Build menu", [_key(KEY_B)])
	_register(&"rotate", Ctx.BUILD, "Rotate", [_key(KEY_R)])
	_register(&"copy", Ctx.BUILD, "Copy", [_key(KEY_C, false, false, true)])
	_register(&"paste", Ctx.BUILD, "Paste", [_key(KEY_V, false, false, true)])
	_register(&"blueprint", Ctx.BUILD, "Blueprint", [_key(KEY_B, false, false, true)])

	_register(&"pause", Ctx.TIME, "Pause", [_key(KEY_SPACE)])
	_register(&"speed_1", Ctx.TIME, "Normal speed", [_key(KEY_1)])
	_register(&"speed_2", Ctx.TIME, "Fast forward", [_key(KEY_2)])
	_register(&"speed_3", Ctx.TIME, "Very fast forward", [_key(KEY_3)])

	_register(&"overlay_1", Ctx.OVERLAY, "Heat overlay", [_key(KEY_F1)])
	_register(&"overlay_2", Ctx.OVERLAY, "Logistics overlay", [_key(KEY_F2)])
	_register(&"overlay_3", Ctx.OVERLAY, "Defence overlay", [_key(KEY_F3)])
	_register(&"overlay_4", Ctx.OVERLAY, "Citizens overlay", [_key(KEY_F4)])
	_register(&"overlay_5", Ctx.OVERLAY, "Alerts overlay", [_key(KEY_F5)])

	_register(&"quick_save", Ctx.SYSTEM, "Quick save", [_key(KEY_S, false, false, true)])
	_register(&"quick_load", Ctx.SYSTEM, "Quick load", [_key(KEY_L, false, false, true)])
