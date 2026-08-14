class_name LcnHudWidget
extends Control
## Base class for every panel in the HUD. [P17]
##
## A widget is one Control that paints itself. It does not build node trees for
## rows and labels, because a panel that rebuilds forty Labels whenever a number
## moves is how a HUD ends up costing more than the simulation it describes.
## Instead each widget:
##
##   * draws in `_draw`, which Godot caches until something calls `queue_redraw()`,
##   * declares HOT REGIONS — rectangles that carry a tooltip and, optionally, an
##     action — so hover, keyboard focus and clicking all work without a node per
##     number,
##   * redraws only when `signature()` changes, so a calm city costs nothing.
##
## Keyboard: Tab moves between widgets (Godot's own focus chain), the arrow keys
## move between hot regions inside the focused widget, Enter triggers the region.
## Enter and not Space, because Space is the pause key and stealing it from the
## player would be a bug, not a feature.

const S := preload("res://game/ui/hud/hud_style.gd")

var style: LcnHudStyle = null
var probe: LcnHudProbe = null
var hud: Node = null

## Painted rectangles that can be hovered, focused and activated.
## {rect: Rect2, title: String, body: String, action: StringName, arg: Variant}
var hot: Array[Dictionary] = []

## How loud this panel is meant to be in the composition the screen is currently
## in, 0..1. Set by `LcnHud._place_panels` from `LcnHudLayout.EMPHASIS`; a panel
## never decides its own prominence, because prominence is a comparison and a
## panel cannot see its neighbours.
##
## It moves two things and deliberately no more: the lamplight on the plate, and
## the panel's overall alpha. The floor is 0.62 rather than 0 — a HUD that fades
## a panel to the point of illegibility has stopped composing and started hiding.
var emphasis: float = 1.0:
	set(value):
		var v: float = clampf(value, 0.0, 1.0)
		if is_equal_approx(v, emphasis):
			return
		emphasis = v
		modulate.a = 0.62 + 0.38 * v
		queue_redraw()

var hover_index: int = -1
var key_index: int = -1
var _signature: String = ""
var _dirty: bool = true
var _panel_seed: int = 1


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL


func setup(hud_root: Node, hud_style: LcnHudStyle, hud_probe: LcnHudProbe) -> void:
	hud = hud_root
	style = hud_style
	probe = hud_probe
	_panel_seed = int(abs(hash(name))) % 100000 + 1
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(_on_focus_exited)
	mouse_exited.connect(_on_mouse_exited)


# ====================================================================  refresh =

## Called by LcnHud after every probe refresh. Widgets override `signature()`
## and `layout()`; this decides whether any pixels actually need to move.
func refresh() -> void:
	var vis: bool = should_show()
	if vis != visible:
		visible = vis
		_dirty = true
	if not vis:
		return
	var sig: String = signature()
	if sig == _signature and not _dirty:
		return
	_signature = sig
	_dirty = false
	layout()
	queue_redraw()


## Override: false hides the panel entirely. A panel showing dashes because the
## system behind it does not exist is worse than no panel.
func should_show() -> bool:
	return true


## Override: everything that, when it changes, changes the picture. Cheap string
## concatenation beats a redraw by an order of magnitude.
func signature() -> String:
	return ""


## Override: recompute geometry and hot regions. Called only when the signature
## moved, never per frame.
func layout() -> void:
	pass


## Forces the next refresh to redraw even if nothing changed (scale, palette).
func invalidate() -> void:
	_dirty = true


## THE BACKSTOP. `LcnHud` calls this with the height the composition actually had
## room for, after the solve. Panels that can shed content gracefully — the
## attention stack, the selection panel — do that first through their own
## `max_height`; this is what catches everything else.
##
## It exists because a panel that REPORTS one height and DRAWS another makes
## every rectangle placed beneath it wrong, and the failure is silent: the solver
## believes there is no overlap and the screen has one. Measured at ui 1.6 with
## large type, the unclamped right column put the heat panel 40 px through the
## attention stack under it. `clip_contents` is what makes the pixels and the
## rectangle agree.
func clamp_height(h: float) -> void:
	if h <= 0.0 or size.y <= h + 0.5:
		return
	clip_contents = true
	custom_minimum_size = Vector2(custom_minimum_size.x, h)
	size = Vector2(size.x, h)


# =======================================================================  hot =

func clear_hot() -> void:
	hot.clear()
	if key_index >= 0:
		key_index = -1


func add_hot(rect: Rect2, title: String, body: String, action: StringName = &"",
		arg: Variant = null) -> void:
	hot.append({"rect": rect, "title": title, "body": body, "action": action, "arg": arg})


func hot_at(pos: Vector2) -> int:
	for i: int in range(hot.size() - 1, -1, -1):
		if (hot[i]["rect"] as Rect2).has_point(pos):
			return i
	return -1


# =====================================================================  input =

func _gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null:
		var idx: int = hot_at(motion.position)
		if idx != hover_index:
			hover_index = idx
			_publish_tooltip(idx)
			queue_redraw()
		return
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
		var idx2: int = hot_at(button.position)
		if idx2 >= 0:
			grab_focus()
			key_index = idx2
			if activate(idx2):
				accept_event()
			queue_redraw()
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		_key_nav(key)


func _key_nav(key: InputEventKey) -> void:
	var actionable: int = hot.size()
	if actionable == 0:
		return
	match key.physical_keycode:
		KEY_DOWN, KEY_RIGHT:
			key_index = posmod(key_index + 1, actionable)
			_publish_tooltip(key_index)
			accept_event()
			queue_redraw()
		KEY_UP, KEY_LEFT:
			key_index = posmod(key_index - 1, actionable)
			_publish_tooltip(key_index)
			accept_event()
			queue_redraw()
		KEY_ENTER, KEY_KP_ENTER:
			if key_index >= 0 and activate(key_index):
				accept_event()
			queue_redraw()


## Override for panels with real actions. Return true when the event was used.
func activate(index: int) -> bool:
	var entry: Dictionary = hot[index] if index >= 0 and index < hot.size() else {}
	var action: StringName = StringName(String(entry.get("action", "")))
	if action == &"focus" and entry.get("arg") != null:
		focus_camera(entry["arg"] as Vector2)
		return true
	return false


## Puts the camera on a world position. The only way this HUD ever moves the
## player's view, and it goes through the Bus exactly like everything else.
func focus_camera(world_pos: Vector2) -> void:
	if world_pos == Vector2.ZERO:
		return
	var bus: Node = _bus()
	if bus != null:
		bus.emit_signal(&"camera_focus_requested", world_pos)


func _publish_tooltip(index: int) -> void:
	if hud == null or not hud.has_method("show_tooltip"):
		return
	if index < 0 or index >= hot.size():
		hud.call("hide_tooltip")
		return
	var e: Dictionary = hot[index]
	var r: Rect2 = e["rect"]
	hud.call("show_tooltip", Rect2(global_position + r.position, r.size),
		Rect2(global_position, size), String(e.get("title", "")), String(e.get("body", "")))


func _on_mouse_exited() -> void:
	if hover_index != -1:
		hover_index = -1
		_publish_tooltip(-1)
		queue_redraw()


func _on_focus_entered() -> void:
	if key_index < 0 and not hot.is_empty():
		key_index = 0
		_publish_tooltip(key_index)
	queue_redraw()


func _on_focus_exited() -> void:
	key_index = -1
	_publish_tooltip(-1)
	queue_redraw()


# ======================================================================  draw =

## y of the stencilled title's baseline. Font-relative, so raising the
## accessibility font scale moves the whole panel down instead of overprinting it.
func title_baseline() -> float:
	return 15.0 + float(style.fs(10))


## y where a panel's first row of content may sit. Every widget lays out from
## here, and `layout()` — never `_draw()` — decides the rest, so a hot region and
## the pixels under it cannot drift apart.
func content_top() -> float:
	return title_baseline() + 12.0


## Standard chrome: plate, title in stencilled caps, the rule under it.
## Returns `content_top()` so a `_draw` can start where `layout` did.
func draw_frame(title: String, sev: int = S.Sev.CALM, lit: float = 0.35) -> float:
	var rect := Rect2(Vector2.ZERO, size)
	# Emphasis rides ON TOP of whatever light the panel asked for, so a panel that
	# lights itself for a reason of its own still gets to; it just does it louder
	# when the composition wants it read first.
	style.draw_plate(self, rect, clampf(lit * (0.55 + 0.75 * emphasis), 0.0, 1.0),
		sev, _panel_seed)
	if title == "":
		return content_top()
	var y: float = title_baseline()
	style.draw_caps(self, Vector2(15.0, y), title, style.fs(10), style.ink_dim(), 2.2)
	var line_y: float = y + 7.0
	var edge: Color = LcnHudStyle.P.COLD_RIM
	draw_line(Vector2(15.0, line_y), Vector2(size.x - 15.0, line_y),
		Color(edge.r, edge.g, edge.b, 0.45), 1.0)
	return content_top()


## Draws hover and keyboard marks over the hot regions. Call last in `_draw`.
func draw_marks() -> void:
	if hover_index >= 0 and hover_index < hot.size():
		style.draw_hover(self, (hot[hover_index]["rect"] as Rect2).grow(2.0))
	if has_focus() and key_index >= 0 and key_index < hot.size():
		style.draw_focus(self, hot[key_index]["rect"] as Rect2)


func _bus() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath("Bus"))
