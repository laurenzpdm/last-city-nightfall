class_name LcnBuildMenu
extends CanvasLayer
## [P18] The build UI: palette, tooltips, recipe browser, tech tree, blueprint
## library and the Book of Laws, wired to the live simulation.
##
## One node owns all of it because they share one contract:
##
##   * every panel opens on a hotkey and closes on Escape, topmost first
##   * no panel is modal, no panel pauses the clock, no panel eats a click that
##     did not land on it — the game keeps running behind an open screen
##   * every panel remembers whether it was open and where it was dragged to
##   * all of them read the sim through duck-typed calls, so a missing part
##     removes a line rather than a panel
##
## Hotkeys were chosen against `game/view/camera/keybinds.gd` so nothing here
## collides with the camera, the overlays or the speed controls:
##
##   B  build palette      I  recipes & items      T  research
##   N  blueprints         L  the Book of Laws     Esc close the top panel
##   1-0 quickbar          Ctrl+P pin the highlighted building
##
## Performance: panels refresh on a 6 Hz timer, not per frame, and each one
## short-circuits on a content signature, so an open palette in a settled city
## costs a handful of microseconds a frame. `last_refresh_usec()` reports the
## real number and the harness screenshot run prints it.

const GROUP: StringName = &"lcn_build_menu"
const LAYER: int = 20
const REFRESH_HZ: float = 6.0
const TOOLTIP_MARGIN: float = 18.0

## Panels in Escape order — last opened closes first, and this is the tie-break.
const PANEL_IDS: Array[StringName] = [&"palette", &"recipes", &"tech", &"blueprints", &"laws"]

signal panel_toggled(id: StringName, open: bool)
signal selection_changed(kind: StringName)

var store: LcnUiStore = LcnUiStore.new()
var catalog: LcnBuildCatalog = LcnBuildCatalog.new()
var graph: LcnItemGraph = LcnItemGraph.new()
var tech: LcnTechModel = LcnTechModel.new()
var laws: LcnLawModel = LcnLawModel.new()
var blueprints: LcnBlueprintModel = LcnBlueprintModel.new()

var palette: LcnPalettePanel = null
var recipes: LcnRecipePanel = null
var tech_panel: LcnTechPanel = null
var blueprint_panel: LcnBlueprintPanel = null
var law_panel: LcnLawPanel = null
var tooltip: LcnTooltipView = null

## The building the palette last committed to. Empty means "not building".
var armed_kind: StringName = &""
## The blueprint the library last armed. Empty means "not stamping".
var armed_blueprint: StringName = &""

var _screen: Control = null
var _hint_bar: Label = null
var _open_order: Array[StringName] = []
var _build: Object = null
var _heat: Object = null
var _grid: Object = null
var _research: Object = null
var _society: Object = null
var _camera: Object = null
var _play: Object = null
var _accum: float = 0.0
var _last_refresh_usec: int = 0
var _hover_cell: Vector2i = Vector2i.ZERO
var _tooltip_kind: StringName = &""
var _shot_dir: String = ""
var _shot_step: int = -1
var _shot_phase: int = 0
var _shot_wait: int = 0
var _shot_hover_lock: bool = false
var _sheet_cache_key: String = ""


func _init() -> void:
	name = "LcnBuildMenu"
	layer = LAYER


func _ready() -> void:
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS
	store.load_from_disk()
	catalog.from_dict(store.palette)

	_screen = Control.new()
	_screen.name = "Screen"
	_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	# PASS, never STOP: an open panel must not swallow a click meant for the map.
	_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_screen)

	_build_panels()
	_build_hint_bar()

	Bus.world_ready.connect(_on_world_ready)
	Bus.unlocked.connect(_on_unlocked)
	Bus.research_completed.connect(_on_unlocked)
	Bus.law_enacted.connect(_on_law_enacted)
	Bus.building_placed.connect(_on_building_placed)
	if Sim.alive:
		_on_world_ready()
	_apply_cli()
	Log.info("ui.build_menu", "installed: %d panels, hotkeys B I T N L" % PANEL_IDS.size())


func _exit_tree() -> void:
	if Harness.active:
		return
	store.palette = catalog.to_dict()
	store.mark_dirty()
	store.flush()


# ------------------------------------------------------------------ build ----

func _build_panels() -> void:
	palette = LcnPalettePanel.new()
	palette.store = store
	palette.catalog = catalog
	palette.picked.connect(_on_palette_picked)
	palette.hovered.connect(_on_palette_hovered)
	_screen.add_child(palette)
	palette.place(Vector2(24.0, 152.0), Vector2(LcnPalettePanel.PANEL_W, LcnPalettePanel.PANEL_H))

	recipes = LcnRecipePanel.new()
	recipes.store = store
	recipes.graph = graph
	recipes.building_requested.connect(_arm_kind)
	_screen.add_child(recipes)
	recipes.place(Vector2(340.0, 150.0), Vector2(LcnRecipePanel.PANEL_W, LcnRecipePanel.PANEL_H))

	tech_panel = LcnTechPanel.new()
	tech_panel.store = store
	tech_panel.model = tech
	tech_panel.research_requested.connect(_on_research_requested)
	tech_panel.building_requested.connect(_arm_kind)
	_screen.add_child(tech_panel)
	tech_panel.place(Vector2(300.0, 130.0), Vector2(LcnTechPanel.PANEL_W, LcnTechPanel.PANEL_H))

	blueprint_panel = LcnBlueprintPanel.new()
	blueprint_panel.store = store
	blueprint_panel.model = blueprints
	blueprint_panel.place_requested.connect(_arm_blueprint)
	blueprint_panel.command_requested.connect(_submit)
	_screen.add_child(blueprint_panel)
	blueprint_panel.place(Vector2(520.0, 150.0), Vector2(LcnBlueprintPanel.PANEL_W, LcnBlueprintPanel.PANEL_H))

	law_panel = LcnLawPanel.new()
	law_panel.store = store
	law_panel.model = laws
	law_panel.sign_requested.connect(_on_sign_requested)
	_screen.add_child(law_panel)
	law_panel.place(Vector2(400.0, 120.0), Vector2(LcnLawPanel.PANEL_W, LcnLawPanel.PANEL_H))

	tooltip = LcnTooltipView.new()
	tooltip.visible = false
	_screen.add_child(tooltip)


func _build_hint_bar() -> void:
	_hint_bar = LcnUiStyle.label(
		"B build    I recipes    T research    N blueprints    L laws",
		LcnUiStyle.FS_TINY, LcnUiStyle.TEXT_FAINT)
	_hint_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hint_bar.position = Vector2(18.0, -26.0)
	_hint_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_screen.add_child(_hint_bar)


func panel(id: StringName) -> LcnUiPanel:
	match id:
		&"palette": return palette
		&"recipes": return recipes
		&"tech": return tech_panel
		&"blueprints": return blueprint_panel
		&"laws": return law_panel
	return null


# ------------------------------------------------------------------ world ----

func _on_world_ready() -> void:
	_build = Sim.get_system(&"build")
	_heat = Sim.get_system(&"heat")
	_grid = Sim.get_system(&"grid")
	_research = Sim.get_system(&"research")
	_society = Sim.get_system(&"society")
	LcnBuildFacts.reset_caches()
	rebuild_models()
	_find_view_nodes()
	_restore_open_panels()


## Re-indexes everything that depends on content or on unlock state. Called on
## world creation and whenever something unlocks — never per frame.
func rebuild_models() -> void:
	catalog.rebuild(_build)
	catalog.from_dict(store.palette)
	graph.rebuild(_build, Registry)
	tech.rebuild(_research, _build, Registry)
	tech.refresh_relevance(_context(false))
	laws.rebuild(_society, Registry)
	blueprints.rebuild(_build, store.blueprint_overrides())

	if palette != null:
		palette.catalog = catalog
		palette.tab = store.last_tab
		palette.set_query(store.last_query)
	if recipes != null:
		recipes.graph = graph
		recipes.build_system = _build
		if String(store.browser_item) != "":
			recipes.focus("item", store.browser_item, false)
	if tech_panel != null:
		tech_panel.model = tech
		tech_panel.build_system = _build
		tech_panel.research_system = _research
		if String(store.tech_focus) != "":
			tech_panel.selected = store.tech_focus
	if blueprint_panel != null:
		blueprint_panel.model = blueprints
		blueprint_panel.bind_build(_build)
	if law_panel != null:
		law_panel.model = laws
		if String(store.law_chapter) != "":
			law_panel.chapter = store.law_chapter
	_refresh_open_panels(true)


## Only a real session restores what the player left open. A harness run must
## photograph the world it was asked to photograph, not whatever panels happened
## to be open when someone last played — eleven other parts screenshot against
## the same scenarios.
func _restore_open_panels() -> void:
	if Harness.active:
		return
	for id: StringName in PANEL_IDS:
		if store.is_open(id):
			var p: LcnUiPanel = panel(id)
			if p != null and not p.is_open():
				_open(id, true)


func _on_unlocked(_id: StringName) -> void:
	catalog.rebuild(_build)
	catalog.from_dict(store.palette)
	tech.refresh_state(_research, _build)
	tech.refresh_relevance(_context(false))
	_refresh_open_panels(true)


func _on_law_enacted(_id: StringName) -> void:
	laws.refresh_state(_society)
	_refresh_open_panels(true)


func _on_building_placed(_id: int, kind: StringName, _cell: Vector2i) -> void:
	catalog.note_used(kind)
	store.palette = catalog.to_dict()
	store.mark_dirty()


## Finds the camera and the play shell without naming either class, so this part
## keeps working when the integrator's placeholder shell is deleted.
func _find_view_nodes() -> void:
	_camera = null
	_play = null
	var root: Node = get_tree().root
	_scan_for_view(root, 0)


func _scan_for_view(node: Node, depth: int) -> void:
	if depth > 6 or (_camera != null and _play != null):
		return
	if _camera == null and node.has_method(&"screen_to_world") and node.has_method(&"hovered_cell"):
		_camera = node
	if _play == null and node.has_method(&"set_build_mode") and node.has_method(&"hovered_cell"):
		_play = node
	for child: Node in node.get_children():
		_scan_for_view(child, depth + 1)


# ------------------------------------------------------------------ input ----

## `_input`, not `_unhandled_input`: the palette's search box has keyboard focus
## while it is open, so the navigation keys have to be taken before the LineEdit
## sees them. Everything not consumed here falls through untouched.
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		if handle_hotkey(key):
			get_viewport().set_input_as_handled()
		return
	var button := event as InputEventMouseButton
	if button != null and button.pressed and String(armed_blueprint) != "":
		if button.button_index == MOUSE_BUTTON_LEFT:
			_stamp_blueprint()
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			_arm_blueprint(&"")
			get_viewport().set_input_as_handled()


## Routes one key press. Public so a headless test can drive the whole UI
## without a window or an input device.
func handle_hotkey(key: InputEventKey) -> bool:
	var top: LcnUiPanel = _top_panel()
	if key.physical_keycode == KEY_ESCAPE:
		if String(armed_blueprint) != "":
			_arm_blueprint(&"")
			return true
		if top != null:
			_close(top.panel_id)
			return true
		return false

	var cmd: bool = key.ctrl_pressed or key.meta_pressed
	if not cmd:
		match key.physical_keycode:
			KEY_B:
				_toggle(&"palette")
				return true
			KEY_I:
				_toggle(&"recipes")
				return true
			KEY_T:
				_toggle(&"tech")
				return true
			KEY_N:
				_toggle(&"blueprints")
				return true
			KEY_L:
				_toggle(&"laws")
				return true
	if _quickbar_key(key):
		return true
	if top != null and top.handle_key(key):
		return true
	return false


## Number keys place the quickbar. Only when no search box is mid-word, so a
## player typing "smelter 2" into the palette is not building something instead.
func _quickbar_key(key: InputEventKey) -> bool:
	if key.ctrl_pressed or key.meta_pressed or key.alt_pressed:
		return false
	if palette != null and palette.is_open() and palette.query() != "":
		return false
	var slot: int = -1
	if key.physical_keycode >= KEY_1 and key.physical_keycode <= KEY_9:
		slot = key.physical_keycode - KEY_1
	elif key.physical_keycode == KEY_0:
		slot = 9
	if slot < 0:
		return false
	var ids: Array[StringName] = catalog.quickbar_ids()
	if slot >= ids.size():
		return false
	_arm_kind(ids[slot])
	return true


# ----------------------------------------------------------------- panels ----

func _toggle(id: StringName) -> void:
	var p: LcnUiPanel = panel(id)
	if p != null and p.is_open():
		_close(id)
	else:
		_open(id)


func _open(id: StringName, restoring: bool = false) -> void:
	var p: LcnUiPanel = panel(id)
	if p == null:
		return
	_open_order.erase(id)
	_open_order.append(id)
	p.set_open(true)
	p.move_to_front()
	if not restoring:
		Log.debug("ui.build_menu", "opened %s" % String(id))
	panel_toggled.emit(id, true)


func _close(id: StringName) -> void:
	var p: LcnUiPanel = panel(id)
	if p == null:
		return
	_open_order.erase(id)
	p.set_open(false)
	panel_toggled.emit(id, false)


func _top_panel() -> LcnUiPanel:
	for i: int in range(_open_order.size() - 1, -1, -1):
		var p: LcnUiPanel = panel(_open_order[i])
		if p != null and p.is_open():
			return p
	return null


func open_panels() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in PANEL_IDS:
		var p: LcnUiPanel = panel(id)
		if p != null and p.is_open():
			out.append(id)
	return out


# -------------------------------------------------------------- selection ----

func _on_palette_picked(kind: StringName) -> void:
	_arm_kind(kind)


func _on_palette_hovered(kind: StringName) -> void:
	_tooltip_kind = kind
	_sheet_cache_key = ""


## Puts a building on the cursor. The play shell owns placement, so this only
## tells it what to place — it never places anything itself.
func _arm_kind(kind: StringName) -> void:
	armed_kind = kind
	armed_blueprint = &""
	_tooltip_kind = kind
	_sheet_cache_key = ""
	if _play != null:
		_play.set(&"kind", kind)
		_play.set(&"rot", 0)
		_play.call(&"set_build_mode", true)
	Bus.build_selection_changed.emit(kind)
	selection_changed.emit(kind)


func _arm_blueprint(id: StringName) -> void:
	armed_blueprint = id
	if blueprint_panel != null:
		blueprint_panel.armed = id
		blueprint_panel.refresh()
	if String(id) != "":
		armed_kind = &""
		if _play != null:
			_play.call(&"set_build_mode", false)
		Bus.toast.emit("Click the map to stamp this blueprint. Right-click or Escape to stop.")


func _stamp_blueprint() -> void:
	if String(armed_blueprint) == "":
		return
	_submit(LcnBlueprintModel.place_command(armed_blueprint, _hover_cell))
	# Stay armed: laying the same block four times is the whole point of a stamp.


func _on_research_requested(id: StringName) -> void:
	if _research == null:
		Bus.toast.emit("No research system in this build yet.")
		return
	_submit({"system": &"research", "op": "start", "id": String(id)})


func _on_sign_requested(id: StringName) -> void:
	if _society == null:
		Bus.toast.emit("No society system in this build yet.")
		return
	_submit(LcnLawModel.enact_command(id))


func _submit(cmd: Dictionary) -> void:
	Sim.submit_command(cmd)


# ------------------------------------------------------------------- tick ----

func _process(delta: float) -> void:
	_accum += delta
	if _shot_dir != "":
		_drive_shots()
	if _accum < 1.0 / REFRESH_HZ:
		return
	_accum = 0.0
	var t0: int = Time.get_ticks_usec()
	_read_hover()
	_refresh_open_panels(false)
	_refresh_tooltip()
	_last_refresh_usec = Time.get_ticks_usec() - t0
	if store.is_dirty() and not Harness.active:
		store.flush()


## Microseconds the last UI refresh took. Reported by the screenshot run so the
## cost of this part is a measured number rather than a claim.
func last_refresh_usec() -> int:
	return _last_refresh_usec


func _read_hover() -> void:
	if _shot_hover_lock:
		return
	if _camera != null:
		_hover_cell = _camera.call(&"hovered_cell")
	elif _play != null:
		_hover_cell = _play.call(&"hovered_cell")


func _refresh_open_panels(force: bool) -> void:
	if palette != null and palette.is_open():
		palette.stock = _build.get(&"stock") if _build != null else null
		palette.refresh()
	if recipes != null and recipes.is_open() and force:
		recipes.refresh()
	if tech_panel != null and tech_panel.is_open():
		# State every refresh (progress and the pacing recommendation move while
		# you watch); relevance only on a real change, since it walks the defs.
		tech.refresh_state(_research, _build)
		if force:
			tech.refresh_relevance(_context(false))
		tech_panel.refresh()
	if blueprint_panel != null and blueprint_panel.is_open():
		if force:
			blueprints.rebuild(_build, store.blueprint_overrides())
		blueprint_panel.refresh()
	if law_panel != null and law_panel.is_open():
		law_panel.refresh()


func _context(with_cell: bool) -> LcnBuildFacts.Ctx:
	return LcnBuildFacts.Ctx.from_sim(Sim, _hover_cell, _play_rot(), with_cell)


func _play_rot() -> int:
	if _play == null:
		return 0
	var r: Variant = _play.get(&"rot")
	return int(r) if r != null else 0


## The tooltip shows, in priority order: the building you are about to place,
## then the building under the cursor. Rebuilt at most six times a second and
## short-circuited on a cache key, because this is the only part of the UI that
## touches the simulation on a timer.
func _refresh_tooltip() -> void:
	if tooltip == null:
		return
	var subject: StringName = _tooltip_kind if String(_tooltip_kind) != "" else armed_kind
	var instance: Object = null
	if String(subject) == "" and _build != null and _build.has_method(&"building_at"):
		instance = _build.call(&"building_at", _hover_cell)

	if String(subject) == "" and instance == null:
		tooltip.visible = false
		return

	var key: String = "%s|%s|%d,%d|%d" % [
		String(subject), str(instance.get(&"id")) if instance != null else "-",
		_hover_cell.x, _hover_cell.y, SimClock.tick / 10]
	if key != _sheet_cache_key:
		_sheet_cache_key = key
		var ctx: LcnBuildFacts.Ctx = _context(true)
		if String(subject) != "":
			var def: Resource = catalog.def_of(subject)
			if def == null and _build != null and _build.has_method(&"def_of"):
				def = _build.call(&"def_of", subject) as Resource
			tooltip.set_sheet(LcnBuildFacts.sheet(def, ctx))
		else:
			tooltip.set_sheet(LcnBuildFacts.instance_sheet(instance, ctx))
	tooltip.visible = true
	_place_tooltip()


func _place_tooltip() -> void:
	if tooltip == null or _screen == null:
		return
	var screen: Vector2 = _screen.size
	var pos: Vector2
	if palette != null and palette.is_open() and String(_tooltip_kind) != "":
		# Docked beside the palette: a tooltip that hides the list it describes
		# is the reason nobody reads tooltips.
		pos = palette.position + Vector2(palette.size.x + 10.0, 0.0)
	elif _shot_hover_lock and _camera != null and _camera.has_method(&"world_to_screen"):
		pos = _camera.call(&"world_to_screen", Vector2(_hover_cell) * 32.0) \
			+ Vector2(TOOLTIP_MARGIN, TOOLTIP_MARGIN)
	else:
		var mouse: Vector2 = _screen.get_local_mouse_position()
		pos = mouse + Vector2(TOOLTIP_MARGIN, TOOLTIP_MARGIN)
	tooltip.position = Vector2(
		clampf(pos.x, 8.0, maxf(8.0, screen.x - tooltip.size.x - 8.0)),
		clampf(pos.y, 8.0, maxf(8.0, screen.y - tooltip.size.y - 8.0)))


# ----------------------------------------------------- command line / shots --

func _apply_cli() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--ui-open="):
			for name: String in arg.substr(10).split(",", false):
				_open(StringName(name.strip_edges()))
		elif arg.begins_with("--ui-shots="):
			_shot_dir = arg.substr(11)
			_shot_step = 0
			_shot_phase = 0
			_shot_wait = WARMUP_FRAMES
			# Run the world fast so the shots show a city that has been alive for
			# a while: heat flowing, buffers filling, a real warning or two.
			SimClock.speed = 4.0


## The screenshot rig for this part. Not the world harness: [P18] needs the REAL
## game running with the REAL UI on top of it, and the harness's tick loop never
## yields a frame between ticks, so a shot scheduled on a tick would photograph
## the frame before it.
##
##   godot --path . --resolution 1920x1080 -- --ui-shots=artifacts/p18/shots
const WARMUP_FRAMES: int = 150
const SETTLE_FRAMES: int = 20
const GAP_FRAMES: int = 20

const SHOT_SEQUENCE: Array[Dictionary] = [
	{"name": "01_palette", "panels": ["palette"], "tooltip": true},
	{"name": "02_palette_search", "panels": ["palette"], "query": "heat", "tooltip": true},
	{"name": "03_recipes", "panels": ["recipes"]},
	{"name": "04_tech", "panels": ["tech"]},
	{"name": "05_blueprints", "panels": ["blueprints"], "capture": true},
	{"name": "06_laws", "panels": ["laws"]},
	{"name": "07_world_tooltip", "panels": [], "hover": true},
]


func _drive_shots() -> void:
	if _shot_step < 0:
		return
	if _shot_wait > 0:
		_shot_wait -= 1
		return
	if _shot_step >= SHOT_SEQUENCE.size():
		Log.info("ui.build_menu", "screenshots done; last refresh cost %d us" % _last_refresh_usec)
		_shot_step = -1
		get_tree().quit(0)
		return
	var step: Dictionary = SHOT_SEQUENCE[_shot_step]
	if _shot_phase == 0:
		_stage_shot(step)
		_shot_phase = 1
		_shot_wait = SETTLE_FRAMES
		return
	_capture(String(step["name"]))
	_shot_step += 1
	_shot_phase = 0
	_shot_wait = GAP_FRAMES


func _stage_shot(step: Dictionary) -> void:
	for id: StringName in PANEL_IDS:
		_close(id)
	_shot_hover_lock = false
	_tooltip_kind = &""
	_sheet_cache_key = ""
	for raw: Variant in step.get("panels", []):
		_open(LcnUiFormat.as_name(raw))
	if step.has("query") and palette != null:
		palette.set_query(String(step["query"]))
	if bool(step.get("capture", false)):
		_capture_demo_blueprint()
	if bool(step.get("tooltip", false)) and palette != null:
		palette.set_cursor(palette.cursor)
		_tooltip_kind = palette.current_kind()
	if bool(step.get("hover", false)):
		_hover_over_something()
	_refresh_open_panels(true)
	_refresh_tooltip()


## Copies a corner of the opening settlement into the book, through the same
## command a player's Ctrl+C would send, so the library screenshot shows real
## content rather than a mock.
func _capture_demo_blueprint() -> void:
	if _grid == null or not _grid.has_method(&"core_cell"):
		return
	var c: Vector2i = _grid.call(&"core_cell")
	_submit(LcnBlueprintModel.capture_command(
		c + Vector2i(-4, -4), c + Vector2i(14, 4), "Hearth and mains"))
	_submit(LcnBlueprintModel.capture_command(
		c + Vector2i(3, 2), c + Vector2i(13, 6), "East housing spur"))
	SimClock.advance(1)
	blueprints.rebuild(_build, store.blueprint_overrides())


func _hover_over_something() -> void:
	if _build == null or not _build.has_method(&"all_buildings"):
		return
	var all: Array = _build.call(&"all_buildings")
	for raw: Variant in all:
		var b: Object = raw
		var def: Resource = b.get(&"def") as Resource
		if def != null and LcnUiFormat.as_number(def.get(&"heat_consumed")) + LcnUiFormat.as_number(def.get(&"heat_radius")) > 0.0:
			_hover_cell = b.get(&"cell")
			_shot_hover_lock = true
			_tooltip_kind = &""
			_sheet_cache_key = ""
			if _camera != null and _camera.has_method(&"focus_on"):
				_camera.call(&"focus_on", Vector2(_hover_cell) * 32.0, true)
			return


func _capture(name: String) -> void:
	var dir: String = ProjectSettings.globalize_path(_shot_dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = "%s/ui_%s.png" % [dir, name]
	var err: int = image.save_png(path)
	if err == OK:
		Log.info("ui.build_menu", "shot %s (refresh %d us)" % [name, _last_refresh_usec])
	else:
		Log.warn("ui.build_menu", "could not write %s (%d)" % [path, err])
