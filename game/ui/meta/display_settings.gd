class_name LcnDisplaySettings
extends LcnMetaScreen
## [P24] Resolution, window mode, vsync, frame cap, interface scale.
##
## Every one of these is applied THE MOMENT it changes and written to Settings
## in the same breath, so there is no "Apply" button to forget and no way for
## the screen to disagree with the window. [method apply_all] is also called once
## at startup by [LcnMetaRoot], which is what makes the choice survive a restart.
##
## `graphics/ui_scale` is [P17]'s and [P18]'s as much as it is ours: writing it
## through `Settings.set_value` fires `Bus.ui_scale_changed`, which the HUD and
## the build menu already listen to. This screen does not re-implement any of
## that; it moves the number they read.

const MODE_WINDOWED: String = "windowed"
const MODE_BORDERLESS: String = "borderless"
const MODE_FULLSCREEN: String = "fullscreen"

const MODES: Array[String] = [MODE_WINDOWED, MODE_BORDERLESS, MODE_FULLSCREEN]
const MODE_TEXT: Dictionary[String, String] = {
	MODE_WINDOWED: "windowed",
	MODE_BORDERLESS: "borderless window",
	MODE_FULLSCREEN: "fullscreen",
}

## Offered in descending order; anything larger than the monitor is dropped.
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(3840, 2160), Vector2i(2560, 1440), Vector2i(1920, 1200),
	Vector2i(1920, 1080), Vector2i(1680, 1050), Vector2i(1600, 900),
	Vector2i(1366, 768), Vector2i(1280, 720),
]

const FPS_CAPS: Array[int] = [0, 30, 60, 120, 144, 240]


func _init() -> void:
	# GDScript does not call a base _init() when the subclass declares one, and
	# without this the list this screen draws is null.
	super()
	screen_id = &"display"
	title = "DISPLAY"
	panel_width = 0.46


func refresh() -> void:
	var s: Node = _settings()
	if s == null:
		return
	var rows: Array[Dictionary] = []
	var mode: String = String(s.call("get_value", "graphics", "window_mode", MODE_WINDOWED))
	rows.append({"kind": LcnMetaList.Kind.CHOICE, "id": &"window_mode", "label": "Window",
		"values": MODES, "value": mode, "value_text": MODE_TEXT.get(mode, mode)})
	var res: String = String(s.call("get_value", "graphics", "resolution", _current_res_text()))
	var offered: Array = _offered_resolutions()
	rows.append({"kind": LcnMetaList.Kind.CHOICE, "id": &"resolution", "label": "Resolution",
		"values": offered, "value": res if offered.has(res) else offered[0],
		"value_text": res, "enabled": mode == MODE_WINDOWED,
		"hint": "" if mode == MODE_WINDOWED else "the desktop decides this in %s" % MODE_TEXT.get(mode, mode)})
	rows.append({"kind": LcnMetaList.Kind.TOGGLE, "id": &"vsync", "label": "Vertical sync",
		"value": bool(s.call("get_value", "graphics", "vsync", true))})
	var cap: int = int(s.call("get_value", "graphics", "max_fps", 0))
	var cap_values: Array = []
	for c: int in FPS_CAPS:
		cap_values.append(c)
	rows.append({"kind": LcnMetaList.Kind.CHOICE, "id": &"max_fps", "label": "Frame cap",
		"values": cap_values, "value": cap,
		"value_text": "unlimited" if cap <= 0 else "%d fps" % cap})
	rows.append({"kind": LcnMetaList.Kind.SLIDER, "id": &"ui_scale", "label": "Interface scale",
		"min": 0.7, "max": 1.6, "step": 0.05,
		"value": float(s.call("get_value", "graphics", "ui_scale", 1.0)),
		"value_text": "%d%%" % int(round(float(s.call("get_value", "graphics", "ui_scale", 1.0)) * 100.0)),
		"hint": "scales the whole interface — text alone is under Accessibility"})
	rows.append({"kind": LcnMetaList.Kind.HEADER, "id": &"h_look", "label": "the look"})
	rows.append({"kind": LcnMetaList.Kind.TOGGLE, "id": &"bloom", "label": "Bloom",
		"value": bool(s.call("get_value", "graphics", "bloom", true))})
	rows.append({"kind": LcnMetaList.Kind.TOGGLE, "id": &"grain", "label": "Film grain",
		"value": bool(s.call("get_value", "graphics", "grain", true))})
	rows.append({"kind": LcnMetaList.Kind.SLIDER, "id": &"snow_density", "label": "Snowfall",
		"min": 0.0, "max": 1.5, "step": 0.1,
		"value": float(s.call("get_value", "graphics", "snow_density", 1.0)),
		"value_text": "%d%%" % int(round(float(s.call("get_value", "graphics", "snow_density", 1.0)) * 100.0))})
	list.set_rows(rows)
	relayout()


func _on_row_changed(id: StringName, value: Variant) -> void:
	var s: Node = _settings()
	if s == null:
		return
	s.call("set_value", "graphics", String(id), value)
	s.call("save_to_disk")
	apply_all()
	if style != null:
		style.refresh_from_settings()
	refresh()


# ================================================================== apply ====

## Puts every display setting into effect. Called on change and once at startup.
## A no-op with no display server, so the harness and the gate never touch a
## window that does not exist.
static func apply_all() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var s: Node = tree.root.get_node_or_null(NodePath("Settings"))
	if s == null:
		return
	var vsync: bool = bool(s.call("get_value", "graphics", "vsync", true))
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = maxi(0, int(s.call("get_value", "graphics", "max_fps", 0)))

	var mode: String = String(s.call("get_value", "graphics", "window_mode", MODE_WINDOWED))
	match mode:
		MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
		MODE_BORDERLESS:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			var res: Vector2i = parse_resolution(String(s.call("get_value", "graphics", "resolution", "")))
			if res.x > 0 and res.y > 0 and DisplayServer.window_get_size() != res:
				DisplayServer.window_set_size(res)
				# Re-centre, or a player who picks a bigger resolution loses the
				# title bar off the top of the screen and cannot get it back.
				var screen: Rect2i = DisplayServer.screen_get_usable_rect(
					DisplayServer.window_get_current_screen())
				DisplayServer.window_set_position(
					screen.position + (screen.size - res) / 2)


static func parse_resolution(text: String) -> Vector2i:
	var parts: PackedStringArray = text.split("×")
	if parts.size() != 2:
		parts = text.split("x")
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))


static func resolution_text(res: Vector2i) -> String:
	return "%d × %d" % [res.x, res.y]


func _offered_resolutions() -> Array:
	var out: Array = []
	var limit := Vector2i(9999, 9999)
	if DisplayServer.get_name() != "headless":
		limit = DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	for r: Vector2i in RESOLUTIONS:
		if r.x <= limit.x and r.y <= limit.y:
			out.append(resolution_text(r))
	if out.is_empty():
		out.append(_current_res_text())
	return out


func _current_res_text() -> String:
	if DisplayServer.get_name() == "headless":
		return resolution_text(Vector2i(1920, 1080))
	return resolution_text(DisplayServer.window_get_size())


func _settings() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null(NodePath("Settings"))
