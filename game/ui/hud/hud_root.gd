class_name LcnHud
extends CanvasLayer
## The heads-up display. [P17]
##
## One CanvasLayer, one probe, one alert model, seven panels that paint
## themselves. The contract with the rest of the build is deliberately tiny:
##
## [codeblock]
##   var hud := LcnHud.new()
##   add_child(hud)                      # that is the whole installation
##   hud.refresh(play_controller)        # optional: build-mode read-out
##   hud.select(building_id)             # optional: drive the selection panel
## [/codeblock]
##
## It reads the simulation through LcnHudProbe and never writes to it. The only
## thing it ever asks the rest of the game for is a camera move, and that goes
## out on `Bus.camera_focus_requested` like everything else.
##
## THE RULE THIS HUD IS BUILT AROUND: **calm when the city is healthy, urgent
## when it is not.** One stress value drives plate brightness, panel rims, the
## edge vignette and whether the alert stack exists at all, so a base that is
## running well shows a clock, a grid readout and a shelf of stocks — and a base
## that is dying is impossible to misread.
##
## Cost: the sim is polled ten times a second, not per frame, and each panel
## redraws only when its own signature string changes. A steady city costs a
## handful of microseconds a frame; see `last_refresh_us` and tests/hud/.

const DESIGN_MARGIN: float = 16.0
const GAP: float = 10.0
const LAYER: int = 10

var style: LcnHudStyle = null
var probe: LcnHudProbe = null
var alerts: LcnHudAlerts = null

var clock_panel: LcnHudClock = null
var heat_panel: LcnHudHeat = null
var vitals_panel: LcnHudVitals = null
var wave_panel: LcnHudWave = null
var resource_panel: LcnHudResources = null
var alert_panel: LcnHudAlertStack = null
var selection_panel: LcnHudSelection = null
var tooltip: LcnHudTooltip = null

## Microseconds the last data refresh took. Read by the perf test.
var last_refresh_us: int = 0
var selected_id: int = -1

var _root: Control = null
var _vignette: Control = null
var _footer: Control = null
var _widgets: Array[LcnHudWidget] = []
var _context: Object = null
var _camera: Node = null
var _camera_poll: float = 0.0
var _urgency: float = 0.0
var _urgency_target: float = 0.0
var _last_layout: Vector2 = Vector2.ZERO
var _footer_signature: String = ""


func _ready() -> void:
	name = "LcnHud"
	layer = LAYER
	style = LcnHudStyle.new()
	probe = LcnHudProbe.new()
	alerts = LcnHudAlerts.new()

	_root = Control.new()
	_root.name = "HudRoot"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_vignette = Control.new()
	_vignette.name = "Vignette"
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.draw.connect(_draw_vignette)
	_root.add_child(_vignette)

	clock_panel = LcnHudClock.new()
	heat_panel = LcnHudHeat.new()
	alert_panel = LcnHudAlertStack.new()
	vitals_panel = LcnHudVitals.new()
	wave_panel = LcnHudWave.new()
	resource_panel = LcnHudResources.new()
	selection_panel = LcnHudSelection.new()
	alert_panel.bind_alerts(alerts)
	# Tree order is the keyboard's Tab order, so it runs worst-news-first.
	_install(alert_panel, "Alerts")
	_install(clock_panel, "Clock")
	_install(heat_panel, "Heat")
	_install(vitals_panel, "Vitals")
	_install(wave_panel, "Wave")
	_install(selection_panel, "Selection")
	_install(resource_panel, "Resources")

	_footer = Control.new()
	_footer.name = "Footer"
	_footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_footer.draw.connect(_draw_footer)
	_root.add_child(_footer)

	tooltip = LcnHudTooltip.new()
	tooltip.name = "Tooltip"
	tooltip.setup(style)
	_root.add_child(tooltip)

	probe.bind()
	Bus.world_ready.connect(_on_world_ready)
	Bus.ui_scale_changed.connect(_on_ui_scale_changed)
	Bus.alert_raised.connect(_on_alert_raised)
	get_viewport().size_changed.connect(_relayout)
	_relayout()
	Log.info("hud", "installed (%d panels)" % _widgets.size())


func _install(w: LcnHudWidget, node_name: String) -> void:
	w.name = node_name
	_root.add_child(w)
	w.setup(self, style, probe)
	w.visible = false
	_widgets.append(w)


func _exit_tree() -> void:
	if Bus.world_ready.is_connected(_on_world_ready):
		Bus.world_ready.disconnect(_on_world_ready)
	if Bus.ui_scale_changed.is_connected(_on_ui_scale_changed):
		Bus.ui_scale_changed.disconnect(_on_ui_scale_changed)
	if Bus.alert_raised.is_connected(_on_alert_raised):
		Bus.alert_raised.disconnect(_on_alert_raised)


# ======================================================================  api ==

## Integrator hook, signature-compatible with the placeholder PlayHud: pass the
## play shell and the footer shows build mode, the ghost's refusal reason and
## what is under the cursor. Optional — the HUD is complete without it.
func refresh(context: Object = null) -> void:
	_context = context


## Drives the selection panel. -1 clears it.
func select(id: int) -> void:
	if id == selected_id:
		return
	selected_id = id
	if id < 0:
		selection_panel.clear_entity()
		return
	var info: Dictionary = probe.describe_building(id)
	if info.is_empty():
		var citizen: Dictionary = probe.describe_citizen(id)
		if citizen.is_empty():
			selection_panel.clear_entity()
			selected_id = -1
			return
		selection_panel.show_entity(_citizen_view(citizen), true)
		return
	selection_panel.show_entity(info, false)


## Selects whatever stands on a map cell. Returns the id, or -1.
func select_cell(cell: Vector2i) -> int:
	var id: int = probe.entity_at_cell(cell)
	select(id)
	return id


## Tooltip plumbing, called by the widgets.
func show_tooltip(anchor: Rect2, title: String, body: String) -> void:
	if tooltip != null:
		tooltip.show_for(anchor, title, body)


func hide_tooltip() -> void:
	if tooltip != null:
		tooltip.hide_tip()


## 0..1 city stress, smoothed. The renderer or the audio mixer may read it.
func urgency() -> float:
	return _urgency


# ==================================================================  lifecycle =

func _on_world_ready() -> void:
	probe.bind()
	alerts.clear()
	select(-1)
	for w: LcnHudWidget in _widgets:
		w.invalidate()


func _on_ui_scale_changed(_value: float) -> void:
	style.refresh_from_settings()
	_relayout()


## An alert is the one thing that must not wait for the next poll.
func _on_alert_raised(severity: int, _key: StringName, _text: String, _pos: Vector2) -> void:
	if severity >= 1:
		_force_refresh()


func _process(delta: float) -> void:
	style.beat += delta
	var t0: int = Time.get_ticks_usec()
	if probe.refresh():
		_after_probe()
	last_refresh_us = Time.get_ticks_usec() - t0

	var speed: float = 2.4 if not style.reduce_motion else 100.0
	var next: float = move_toward(_urgency, _urgency_target, delta * speed)
	if not is_equal_approx(next, _urgency):
		_urgency = next
		style.urgency = _urgency
		_vignette.queue_redraw()
	# Only the panels that actually breathe get a per-frame redraw, and only
	# while something is wrong.
	if _urgency > 0.05 and not style.reduce_motion:
		if alert_panel.visible:
			alert_panel.queue_redraw()
		if clock_panel.visible and _urgency > 0.4:
			clock_panel.queue_redraw()
		if wave_panel.visible:
			wave_panel.queue_redraw()
	_refresh_footer()
	_camera_poll -= delta
	if _camera == null and _camera_poll <= 0.0:
		_camera_poll = 0.5
		_bind_camera()


func _force_refresh() -> void:
	if probe.refresh(true):
		_after_probe()


func _after_probe() -> void:
	alerts.refresh(probe, SimClock.seconds())
	_urgency_target = maxf(probe.stress(), _alert_pressure())
	style.urgency = _urgency
	if selected_id >= 0:
		var info: Dictionary = probe.describe_building(selected_id)
		if not info.is_empty():
			selection_panel.show_entity(info, false)
	for w: LcnHudWidget in _widgets:
		w.refresh()
	_place_panels()


func _alert_pressure() -> float:
	match alerts.worst_severity():
		LcnHudStyle.Sev.CRITICAL:
			return 1.0
		LcnHudStyle.Sev.DANGER:
			return 0.72
		LcnHudStyle.Sev.WARN:
			return 0.35
	return 0.0


# =====================================================================  layout =

## The HUD is authored in design pixels and scaled once, here, so a widget never
## has to think about ui_scale. Font scale is applied separately inside the
## style, which is what lets a player enlarge the text without inflating the
## panels around it.
func _relayout() -> void:
	style.refresh_from_settings()
	var vp: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	scale = Vector2(style.ui_scale, style.ui_scale)
	var logical: Vector2 = vp / maxf(0.01, style.ui_scale)
	_root.size = logical
	_root.position = Vector2.ZERO
	_vignette.size = logical
	_footer.size = logical
	tooltip.size = logical
	_last_layout = logical
	for w: LcnHudWidget in _widgets:
		w.invalidate()
		w.refresh()
	_place_panels()
	_vignette.queue_redraw()
	_footer.queue_redraw()


func _place_panels() -> void:
	var w: float = _last_layout.x
	var h: float = _last_layout.y
	if w <= 0.0:
		return
	if clock_panel.visible:
		clock_panel.position = Vector2(roundf((w - clock_panel.size.x) * 0.5), 10.0)

	var left_y: float = DESIGN_MARGIN
	if heat_panel.visible:
		heat_panel.position = Vector2(DESIGN_MARGIN, left_y)
		left_y += heat_panel.size.y + GAP
	if alert_panel.visible:
		alert_panel.position = Vector2(DESIGN_MARGIN, left_y)

	var right_y: float = DESIGN_MARGIN
	if vitals_panel.visible:
		vitals_panel.position = Vector2(w - vitals_panel.size.x - DESIGN_MARGIN, right_y)
		right_y += vitals_panel.size.y + GAP
	if wave_panel.visible:
		wave_panel.position = Vector2(w - wave_panel.size.x - DESIGN_MARGIN, right_y)

	if resource_panel.visible:
		resource_panel.position = Vector2(DESIGN_MARGIN,
			h - resource_panel.size.y - DESIGN_MARGIN)
	if selection_panel.visible:
		selection_panel.position = Vector2(w - selection_panel.size.x - DESIGN_MARGIN,
			h - selection_panel.size.y - DESIGN_MARGIN)


# ==================================================================  vignette =

## The room goes dark at the edges when the city is in trouble. It is the only
## full-screen effect the HUD owns, it is never animated when the player asked
## for reduced motion, and at urgency 0 it draws nothing at all.
func _draw_vignette() -> void:
	if _urgency <= 0.02 and (probe == null or not probe.is_night):
		return
	var w: float = _vignette.size.x
	var h: float = _vignette.size.y
	var band: float = minf(h * 0.30, 220.0)
	var danger: Color = style.sev_colour(LcnHudStyle.Sev.DANGER)
	var pulse: float = 1.0
	if _urgency > 0.6:
		pulse = 0.82 + 0.18 * style.pulse(2.0)
	var strength: float = _urgency * 0.30 * pulse
	if strength > 0.004:
		_band(Rect2(0.0, 0.0, w, band), Vector2(0.0, 1.0), danger, strength)
		_band(Rect2(0.0, h - band, w, band), Vector2(0.0, -1.0), danger, strength * 0.9)
		_band(Rect2(0.0, 0.0, band * 0.8, h), Vector2(1.0, 0.0), danger, strength * 0.7)
		_band(Rect2(w - band * 0.8, 0.0, band * 0.8, h), Vector2(-1.0, 0.0), danger,
			strength * 0.7)
	if probe != null and probe.is_night:
		var cold: Color = LcnHudStyle.P.COLD_DEEP
		var night: float = 0.18 * clampf(1.0 - probe.light_level * 2.0, 0.0, 1.0)
		_band(Rect2(0.0, 0.0, w, band * 0.7), Vector2(0.0, 1.0), cold, night)
		_band(Rect2(0.0, h - band * 0.7, w, band * 0.7), Vector2(0.0, -1.0), cold, night)


## One edge gradient, drawn as a four-point polygon with per-vertex alpha.
func _band(rect: Rect2, fade_dir: Vector2, colour: Color, alpha: float) -> void:
	var p0: Vector2 = rect.position
	var p1: Vector2 = rect.position + Vector2(rect.size.x, 0.0)
	var p2: Vector2 = rect.position + rect.size
	var p3: Vector2 = rect.position + Vector2(0.0, rect.size.y)
	var strong := Color(colour.r, colour.g, colour.b, alpha)
	var weak := Color(colour.r, colour.g, colour.b, 0.0)
	var cols: PackedColorArray
	if fade_dir.y > 0.0:
		cols = PackedColorArray([strong, strong, weak, weak])
	elif fade_dir.y < 0.0:
		cols = PackedColorArray([weak, weak, strong, strong])
	elif fade_dir.x > 0.0:
		cols = PackedColorArray([strong, weak, weak, strong])
	else:
		cols = PackedColorArray([weak, strong, strong, weak])
	_vignette.draw_polygon(PackedVector2Array([p0, p1, p2, p3]), cols)


# ====================================================================  footer =

## Toasts and the build-mode read-out. Kept in one small Control at the bottom
## so the big panels never redraw for a passing message.
func _refresh_footer() -> void:
	var sig: String = _footer_sig()
	if sig == _footer_signature:
		return
	_footer_signature = sig
	_footer.queue_redraw()


func _footer_sig() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for t: Dictionary in alerts.toasts():
		parts.append("%s%d" % [t.get("text", ""), int(t.get("count", 1))])
	if _context != null:
		parts.append(_context_line())
	return "|".join(parts)


func _context_line() -> String:
	if _context == null:
		return ""
	var line: String = ""
	if bool(_context.get("build_mode")) and _context.has_method("palette_label"):
		line = "BUILD  ·  %s" % String(_context.call("palette_label"))
		if _context.has_method("ghost_reason"):
			var why: String = String(_context.call("ghost_reason"))
			if why != "":
				line += "  ·  cannot place here: %s" % why
	elif _context.has_method("hovered_cell"):
		line = LcnHudFormat.cell(_context.call("hovered_cell") as Vector2i)
	return line


func _draw_footer() -> void:
	if style == null:
		return
	var w: float = _footer.size.x
	var h: float = _footer.size.y
	var line: String = _context_line()
	if line != "":
		var size_px: int = style.fs(12)
		var text_w: float = style.text_width(line, size_px)
		var rect := Rect2((w - text_w) * 0.5 - 14.0, h - 34.0, text_w + 28.0, 24.0)
		style.draw_plate(_footer, rect, 0.25, LcnHudStyle.Sev.CALM, 7717)
		style.draw_text(_footer, Vector2(rect.position.x + 14.0, rect.position.y + 16.0),
			line, size_px, style.ink_dim())

	var y: float = h - 52.0
	var toast_list: Array[Dictionary] = alerts.toasts()
	for i: int in range(toast_list.size() - 1, -1, -1):
		var t: Dictionary = toast_list[i]
		var text: String = String(t.get("text", ""))
		var n: int = int(t.get("count", 1))
		if n > 1:
			text += "  ×%d" % n
		var fs: int = style.fs(12)
		var tw: float = style.text_width(text, fs)
		var r := Rect2((w - tw) * 0.5 - 12.0, y - 20.0, tw + 24.0, 24.0)
		style.draw_plate(_footer, r, 0.3, int(t.get("sev", 1)), 5150 + i)
		style.draw_text(_footer, Vector2(r.position.x + 12.0, r.position.y + 16.0), text, fs,
			style.ink())
		y -= 28.0


# =====================================================================  input =

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var focus: Control = _root.get_viewport().gui_get_focus_owner()
	var inside: bool = focus != null and _root.is_ancestor_of(focus)
	if key.physical_keycode == KEY_TAB and not inside:
		# Tab from the world puts the keyboard on the most urgent thing there is.
		var target: LcnHudWidget = _first_focusable()
		if target != null:
			target.grab_focus()
			get_viewport().set_input_as_handled()
	elif key.physical_keycode == KEY_ESCAPE and inside:
		focus.release_focus()
		hide_tooltip()
		get_viewport().set_input_as_handled()


func _first_focusable() -> LcnHudWidget:
	for w: LcnHudWidget in [alert_panel, selection_panel, heat_panel, clock_panel,
			wave_panel, vitals_panel, resource_panel]:
		if w != null and w.visible and not w.hot.is_empty():
			return w
	return null


## Binds to [P16]'s camera when it exists so clicking the world drives the
## selection panel. Absent camera, absent selection — the panel simply never
## opens, and everything else still works.
func _bind_camera() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var cam: Node = get_viewport().get_camera_2d()
	if cam == null or not cam.has_signal(&"selection_changed"):
		cam = _find_camera(tree.root, 0)
	if cam == null or not cam.has_signal(&"selection_changed"):
		return
	_camera = cam
	if not cam.is_connected(&"selection_changed", _on_camera_selection):
		cam.connect(&"selection_changed", _on_camera_selection)


func _find_camera(node: Node, depth: int) -> Node:
	if depth > 4:
		return null
	for child: Node in node.get_children():
		if child is Camera2D and child.has_signal(&"selection_changed"):
			return child
		var found: Node = _find_camera(child, depth + 1)
		if found != null:
			return found
	return null


func _on_camera_selection(ids: PackedInt32Array, cell_rect: Rect2i) -> void:
	if ids.is_empty():
		if cell_rect.size == Vector2i.ZERO:
			select(-1)
			return
		select_cell(cell_rect.position)
		return
	select(ids[0])


func _citizen_view(info: Dictionary) -> Dictionary:
	var lines: Array[Dictionary] = []
	var problems: Array[String] = []
	for key: String in ["job", "home", "warmth", "health", "mood", "task"]:
		if not info.has(key):
			continue
		var raw: Variant = info[key]
		var value: String = ""
		if typeof(raw) == TYPE_FLOAT:
			value = LcnHudFormat.percent(float(raw)) if float(raw) <= 1.0 \
				else LcnHudFormat.rate(float(raw))
		else:
			value = LcnHudFormat.titleize(str(raw))
		lines.append({
			"label": key, "value": value, "good": 1.0,
			"tip": "What this citizen's %s is right now." % key,
		})
	for key2: String in ["problem", "why", "complaint"]:
		if info.has(key2):
			problems.append(String(info[key2]))
	return {
		"id": int(info.get("id", -1)),
		"kind": &"citizen",
		"title": String(info.get("name", "Citizen")),
		"cell": info.get("cell", Vector2i.ZERO),
		"state": 2,
		"lines": lines,
		"problems": problems,
		"task": String(info.get("task", info.get("activity", ""))),
		"progress": 1.0,
		"hp": 1.0,
		"max_hp": 1.0,
	}
