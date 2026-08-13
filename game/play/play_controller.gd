class_name PlayController
extends Node2D
## The session shell: the thing that makes this a game you can play rather than
## a simulation you can screenshot. INTEGRATOR-OWNED (see ARCHITECTURE.md §1).
##
## It owns exactly three responsibilities and hands everything else to the parts:
##
##   1. BUILD MODE — a palette of the definitions [P11] says are available, a
##      live ghost validated every frame by BuildSystem.can_place(), and a click
##      that turns into Sim.submit_command(). No placement rule lives here.
##   2. SELECTION READ-OUT — what the player clicked, answered out of [P11] and
##      [P02] rather than guessed.
##   3. HANDING THE CAMERA ITS WORLD — bounds and home, so H means something.
##
## It is deliberately thin. [P18] replaces the palette with a real build menu and
## [P17] replaces the read-out with a real HUD; when they land, this becomes the
## fallback nobody sees. Until then it is the difference between a tech demo and
## a game.

const TILE: int = 32
## Kinds a fresh session offers, in the order the palette cycles them. Anything
## not on this list is still buildable once [P18] ships a real menu; this is a
## curated opening hand, not a whitelist.
const PALETTE_ORDER: Array[StringName] = [
	&"heat_pipe", &"warmth_radiator", &"coal_generator", &"housing_block",
	&"workshop", &"storage_yard", &"ore_drill", &"wall", &"watchtower",
	&"turret_mount", &"the_hearth", &"geothermal_tap", &"heat_booster_pump",
	&"heat_accumulator", &"rubble_road",
]

signal palette_changed(kind: StringName, index: int, total: int)
signal build_mode_changed(active: bool)

var camera: GameCamera = null
var hud: PlayHud = null

var build_mode: bool = false
var kind: StringName = &"heat_pipe"
var rot: int = 0

var _palette: Array[StringName] = []
var _index: int = 0
var _cell: Vector2i = Vector2i.ZERO
var _valid: bool = false
var _reason: String = ""
var _cells: Array[Vector2i] = []
var _drag_from: Vector2i = Vector2i.ZERO
var _dragging: bool = false
var _selected: int = -1
var _build: SimSystem = null
var _grid: SimSystem = null
var _heat: SimSystem = null


func _ready() -> void:
	name = "Play"
	z_index = 60
	z_as_relative = false
	Bus.world_ready.connect(_on_world_ready)
	if Sim.alive:
		_on_world_ready()


func attach(cam: GameCamera, overlay: PlayHud) -> void:
	camera = cam
	hud = overlay
	camera.action_pressed.connect(_on_action)
	camera.hover_cell_changed.connect(_on_hover)


func _on_world_ready() -> void:
	_build = Sim.get_system(&"build")
	_grid = Sim.get_system(&"grid")
	_heat = Sim.get_system(&"heat")
	_refresh_palette()
	if camera != null:
		var core: Vector2 = Vector2(_core_cell()) * float(TILE)
		camera.set_home(core)
		camera.focus_on(core, true)
		if _grid != null and _grid.has_method("map_size"):
			var size: Vector2i = _grid.call("map_size")
			camera.set_world_bounds(Rect2(Vector2.ZERO, Vector2(size) * float(TILE)))


func _core_cell() -> Vector2i:
	if _grid != null and _grid.has_method("core_cell"):
		return _grid.call("core_cell")
	return Vector2i(128, 128)


## Only the definitions [P11] says are placeable right now, in palette order,
## with anything it offers that the curated list forgot appended at the end.
func _refresh_palette() -> void:
	_palette = []
	if _build == null:
		return
	var available: Dictionary[StringName, bool] = {}
	for d: BuildingDef in _build.call("available_defs"):
		available[d.id] = true
	for k: StringName in PALETTE_ORDER:
		if available.has(k):
			_palette.append(k)
			available.erase(k)
	var rest: Array = available.keys()
	rest.sort()
	for k2: StringName in rest:
		_palette.append(k2)
	if _palette.is_empty():
		return
	_index = clampi(_index, 0, _palette.size() - 1)
	kind = _palette[_index]
	palette_changed.emit(kind, _index, _palette.size())


func _select_index(i: int) -> void:
	if _palette.is_empty():
		return
	_index = posmod(i, _palette.size())
	kind = _palette[_index]
	rot = 0
	palette_changed.emit(kind, _index, _palette.size())
	_revalidate()


func set_build_mode(on: bool) -> void:
	if build_mode == on:
		return
	build_mode = on
	_dragging = false
	build_mode_changed.emit(on)
	queue_redraw()


# ------------------------------------------------------------------- input ---

## `_input` rather than `_unhandled_input` on purpose: while build mode is on, a
## click is a placement and must not also open a selection box in the camera.
func _input(event: InputEvent) -> void:
	if camera == null or _build == null:
		return
	if event is InputEventMouseMotion:
		_update_cell(camera.screen_to_world((event as InputEventMouseMotion).position))
		if _dragging:
			queue_redraw()
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		match key.physical_keycode:
			KEY_Q:
				if build_mode:
					_select_index(_index - 1)
					get_viewport().set_input_as_handled()
				return
			KEY_E:
				if build_mode:
					_select_index(_index + 1)
					get_viewport().set_input_as_handled()
				return
			KEY_X:
				_demolish_under_cursor()
				get_viewport().set_input_as_handled()
				return
	if not build_mode:
		return
	var button := event as InputEventMouseButton
	if button == null:
		return
	if button.button_index == MOUSE_BUTTON_LEFT:
		_update_cell(camera.screen_to_world(button.position))
		if button.pressed:
			_dragging = true
			_drag_from = _cell
		elif _dragging:
			_dragging = false
			_commit(_drag_from, _cell)
		get_viewport().set_input_as_handled()
	elif button.button_index == MOUSE_BUTTON_RIGHT and button.pressed:
		if _dragging:
			_dragging = false
		else:
			set_build_mode(false)
		get_viewport().set_input_as_handled()


func _on_action(action: StringName) -> void:
	match action:
		&"build":
			set_build_mode(not build_mode)
			_refresh_palette()
		&"rotate":
			if build_mode:
				rot = (rot + 1) & 3
				_revalidate()
		&"cancel":
			set_build_mode(false)


func _on_hover(cell: Vector2i, _inside: bool) -> void:
	if cell == _cell:
		return
	_cell = cell
	_revalidate()


func _update_cell(world_pos: Vector2) -> void:
	var c := Vector2i(int(floor(world_pos.x / float(TILE))), int(floor(world_pos.y / float(TILE))))
	if c == _cell:
		return
	_cell = c
	_revalidate()


func _revalidate() -> void:
	if _build == null or not build_mode:
		_valid = false
		queue_redraw()
		return
	var check: Dictionary = _build.call("can_place", kind, _cell, rot, true, -1)
	_valid = bool(check.get("ok", false))
	_reason = String(check.get("reason", ""))
	_cells = _build.call("preview_cells", kind, _cell, int(check.get("rot", rot)))
	queue_redraw()


## A drag places a line of 1x1 pieces (pipes, walls, road); anything larger is a
## single placement at the release cell. Both go out as commands, never as direct
## calls, so a click and a scripted scenario take exactly the same path.
func _commit(from: Vector2i, to: Vector2i) -> void:
	var def: BuildingDef = _build.call("def_of", kind)
	if def == null:
		return
	if from != to and def.size == Vector2i.ONE:
		Sim.submit_command({
			"system": &"build", "op": "place_line", "kind": String(kind),
			"from": [from.x, from.y], "to": [to.x, to.y], "rot": rot,
		})
	else:
		Sim.submit_command({
			"system": &"build", "op": "place", "kind": String(kind),
			"cell": [to.x, to.y], "rot": rot,
		})
	_revalidate()


func _demolish_under_cursor() -> void:
	if _build == null:
		return
	var b: Object = _build.call("building_at", _cell)
	if b == null:
		return
	Sim.submit_command({"system": &"build", "op": "remove", "id": int(b.get("id"))})


# -------------------------------------------------------------------- draw ---

func _process(_delta: float) -> void:
	if hud != null:
		hud.refresh(self)
	if Harness.active and Harness.visual:
		_drive_harness_tour()
	if build_mode:
		queue_redraw()


## Screenshot runs should show the art from several distances, not the same frame
## six times. Only ever runs under --harness --visual; a player's camera is the
## player's. Keyframes are in world tiles from the city core.
const TOUR: Array[Dictionary] = [
	{"t": 0.0, "off": Vector2(0.0, -2.0), "zoom": 1.05},
	{"t": 1500.0, "off": Vector2(-11.0, -6.0), "zoom": 1.55},
	{"t": 3400.0, "off": Vector2(8.0, 5.0), "zoom": 1.30},
	{"t": 5500.0, "off": Vector2(0.0, 1.0), "zoom": 0.85},
	{"t": 7200.0, "off": Vector2(-2.0, -20.0), "zoom": 1.15},
	{"t": 8800.0, "off": Vector2(0.0, 0.0), "zoom": 0.60},
	{"t": 11000.0, "off": Vector2(0.0, -4.0), "zoom": 0.95},
]


func _drive_harness_tour() -> void:
	if camera == null:
		return
	var centre: Vector2 = Vector2(_core_cell()) * float(TILE)
	var t: float = float(SimClock.tick)
	var i: int = 0
	for k: int in range(TOUR.size() - 1):
		if t >= float(TOUR[k]["t"]) and t <= float(TOUR[k + 1]["t"]):
			i = k
			break
	if t >= float(TOUR[TOUR.size() - 1]["t"]):
		i = TOUR.size() - 2
	var a: Dictionary = TOUR[i]
	var b: Dictionary = TOUR[i + 1]
	var span: float = maxf(1.0, float(b["t"]) - float(a["t"]))
	var f: float = smoothstep(0.0, 1.0, clampf((t - float(a["t"])) / span, 0.0, 1.0))
	camera.focus_on(centre + (a["off"] as Vector2).lerp(b["off"] as Vector2, f) * float(TILE), true)
	camera.set_zoom_level(lerpf(float(a["zoom"]), float(b["zoom"]), f), false)


func _draw() -> void:
	if not build_mode or _build == null:
		return
	var ok := Color(0.42, 0.86, 0.58, 1.0)
	var bad := Color(0.95, 0.35, 0.30, 1.0)
	var tint: Color = ok if _valid else bad
	var cells: Array[Vector2i] = _cells
	if _dragging:
		cells = _line_cells(_drag_from, _cell)
	for c: Vector2i in cells:
		var r := Rect2(Vector2(c) * float(TILE), Vector2(float(TILE), float(TILE)))
		draw_rect(r, Color(tint.r, tint.g, tint.b, 0.18), true)
		draw_rect(r, Color(tint.r, tint.g, tint.b, 0.85), false, 1.5)
	# A crosshair on the anchor cell, so the player can see where a drag started.
	var a := Rect2(Vector2(_cell) * float(TILE), Vector2(float(TILE), float(TILE)))
	draw_rect(a, Color(1.0, 1.0, 1.0, 0.35), false, 1.0)


func _line_cells(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var cur: Vector2i = from
	var guard: int = 0
	while guard < 512:
		guard += 1
		out.append(cur)
		if cur == to:
			break
		if cur.x != to.x:
			cur.x += signi(to.x - cur.x)
		elif cur.y != to.y:
			cur.y += signi(to.y - cur.y)
		else:
			break
	return out


# ---------------------------------------------------------------- read-out ---

func hovered_cell() -> Vector2i:
	return _cell


func ghost_reason() -> String:
	return "" if _valid else _reason


func palette_label() -> String:
	if _palette.is_empty():
		return "—"
	var def: BuildingDef = _build.call("def_of", kind) if _build != null else null
	var title: String = def.display_name if def != null and def.display_name != "" else String(kind)
	return "%s  (%d/%d)" % [title, _index + 1, _palette.size()]


## What the player is pointing at, answered out of the simulation.
func inspect() -> String:
	if _build == null:
		return ""
	var b: Object = _build.call("building_at", _cell)
	if b == null:
		return ""
	var id: int = int(b.get("id"))
	var text: String = "%s #%d" % [String(b.get("kind")), id]
	if _heat != null and bool(_heat.call("has_building", id)):
		text += "   heat %.0f%%  %.0f C" % [
			float(_heat.call("served_of", id)) * 100.0,
			float(_heat.call("temperature_of", id)),
		]
		var why: Dictionary = _heat.call("bottleneck_of", id)
		if not why.is_empty():
			text += "   limited by %s" % String(why.get("kind", "?"))
	return text
