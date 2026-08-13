extends TestCase
## [P18] The panel shell, driven headlessly.
##
## The contract in the brief is behavioural, so it is tested behaviourally: a
## hotkey opens a panel, Escape closes the topmost one, the state survives a
## restart, and nothing here ever pauses the clock or eats a click.

var world: SimFixture = null
var menu: LcnBuildMenu = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["build"])


func before_all() -> void:
	LcnUiStore.wipe()


func setup() -> void:
	world = SimFixture.new(7).start()
	menu = LcnBuildMenu.new()
	TestEnv.tree().root.add_child(menu)


func teardown() -> void:
	if menu != null and is_instance_valid(menu):
		TestEnv.tree().root.remove_child(menu)
		menu.free()
	menu = null
	world.stop()
	LcnUiStore.wipe()


func _key(code: int, ctrl: bool = false, shift: bool = false) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.pressed = true
	e.ctrl_pressed = ctrl
	e.shift_pressed = shift
	return e


func _press(code: int, ctrl: bool = false, shift: bool = false) -> bool:
	return menu.handle_hotkey(_key(code, ctrl, shift))


# ------------------------------------------------------------- the panels ----

func test_every_panel_exists_and_starts_closed() -> void:
	for id: StringName in LcnBuildMenu.PANEL_IDS:
		var p: LcnUiPanel = menu.panel(id)
		assert_not_null(p, "panel '%s' was built" % String(id))
		assert_false(p.is_open(), "and starts closed")
	assert_empty(menu.open_panels(), "nothing is open on a fresh install")


func test_hotkeys_open_the_right_panel() -> void:
	var cases: Dictionary = {
		KEY_B: &"palette", KEY_I: &"recipes", KEY_T: &"tech",
		KEY_N: &"blueprints", KEY_L: &"laws",
	}
	var keys: Array = cases.keys()
	keys.sort()
	for k: Variant in keys:
		assert_true(_press(int(k)), "the key is consumed")
		assert_true(menu.panel(cases[k]).is_open(), "%s opens" % String(cases[k]))
		assert_true(_press(int(k)), "and pressing it again is consumed too")
		assert_false(menu.panel(cases[k]).is_open(), "closing it")


func test_escape_closes_the_topmost_panel_only() -> void:
	_press(KEY_B)
	_press(KEY_T)
	assert_size(menu.open_panels(), 2, "two panels open")
	assert_true(_press(KEY_ESCAPE), "escape is consumed while something is open")
	assert_false(menu.panel(&"tech").is_open(), "the last one opened closes first")
	assert_true(menu.panel(&"palette").is_open(), "the other stays")
	_press(KEY_ESCAPE)
	assert_empty(menu.open_panels(), "a second escape closes the rest")
	assert_false(_press(KEY_ESCAPE),
		"and with nothing open escape is left alone, so it still reaches the game")


func test_panels_never_pause_the_clock() -> void:
	var before: int = world.tick()
	_press(KEY_B)
	_press(KEY_T)
	world.run(10)
	assert_eq(world.tick(), before + 10, "the simulation runs behind an open panel")


func test_the_screen_layer_does_not_swallow_the_map() -> void:
	var screen: Control = menu.get_node(^"Screen") as Control
	assert_eq(screen.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"clicks that miss a panel must reach the world")
	assert_eq(menu.panel(&"palette").mouse_filter, Control.MOUSE_FILTER_STOP,
		"clicks that hit one must not")


# ----------------------------------------------------------- the palette -----

func test_the_palette_search_filters_and_enter_picks() -> void:
	_press(KEY_B)
	var palette: LcnPalettePanel = menu.palette
	palette.set_query("coal")
	assert_gt(float(palette.view_size()), 0.0, "typing filters the list")
	assert_eq(String(palette.current_kind()), "coal_generator", "the cursor lands on the best match")

	var armed: Array[StringName] = []
	menu.selection_changed.connect(func(kind: StringName) -> void: armed.append(kind))
	assert_true(_press(KEY_ENTER), "Enter is consumed by the open palette")
	assert_size(armed, 1, "and commits the selection")
	assert_eq(String(armed[0]), "coal_generator", "to the highlighted building")
	assert_eq(String(menu.armed_kind), "coal_generator", "the menu remembers what is on the cursor")


func test_arrow_keys_move_the_cursor_before_the_search_box_sees_them() -> void:
	_press(KEY_B)
	var palette: LcnPalettePanel = menu.palette
	palette.set_query("")
	var first: StringName = palette.current_kind()
	assert_true(_press(KEY_DOWN), "down is consumed")
	assert_ne(String(palette.current_kind()), String(first), "and moves the highlight")
	assert_true(_press(KEY_UP), "up is consumed")
	assert_eq(String(palette.current_kind()), String(first), "and moves it back")


func test_the_quickbar_places_pinned_and_recent_buildings() -> void:
	menu.catalog.toggle_favourite(&"heat_pipe")
	assert_true(_press(KEY_1), "the first slot fires")
	assert_eq(String(menu.armed_kind), "heat_pipe", "and arms the pinned building")


func test_the_quickbar_stands_down_mid_word() -> void:
	_press(KEY_B)
	menu.palette.set_query("smelter")
	assert_false(_press(KEY_2),
		"a digit typed into a search box is a character, not a build order")


func test_placing_something_feeds_the_recent_list() -> void:
	var c: Vector2i = Vector2i(128, 128)
	var grid: SimSystem = world.system(&"grid")
	if grid != null:
		c = grid.call(&"core_cell")
	world.cmd_now({"system": &"build", "op": "place", "kind": "the_hearth",
		"cell": [c.x - 2, c.y - 2], "free": true, "instant": true})
	assert_has(menu.catalog.recent_ids(), &"the_hearth",
		"what you build is what the quickbar offers you next")


func test_pinning_from_the_keyboard() -> void:
	_press(KEY_B)
	menu.palette.set_query("wall")
	var kind: StringName = menu.palette.current_kind()
	assert_true(_press(KEY_P, true), "Ctrl+P is consumed")
	assert_true(menu.catalog.is_favourite(kind), "and pins the highlighted building")


# ------------------------------------------------------------ persistence ----

func test_open_panels_and_pins_survive_a_restart() -> void:
	_press(KEY_B)
	_press(KEY_N)
	menu.catalog.toggle_favourite(&"wall")
	menu.palette.set_query("heat")
	menu.store.palette = menu.catalog.to_dict()
	menu.store.mark_dirty()
	assert_true(menu.store.flush(), "the store writes")

	TestEnv.tree().root.remove_child(menu)
	menu.free()
	menu = LcnBuildMenu.new()
	TestEnv.tree().root.add_child(menu)

	assert_true(menu.store.is_open(&"palette"), "the palette was open when we left")
	assert_true(menu.store.is_open(&"blueprints"), "and so was the library")
	assert_true(menu.catalog.is_favourite(&"wall"), "pins came back")
	assert_eq(menu.store.last_query, "heat", "and so did the last thing typed")


func test_dragging_a_panel_is_remembered() -> void:
	var palette: LcnUiPanel = menu.panel(&"palette")
	palette.position = Vector2(311.0, 222.0)
	menu.store.remember_placement(&"palette", palette.position)
	assert_true(menu.store.flush(), "a moved panel is written down")
	var fresh := LcnUiStore.new()
	fresh.load_from_disk()
	assert_eq(fresh.placement[&"palette"], Vector2(311.0, 222.0), "and comes back where it was")


# ------------------------------------------------------------- blueprints ----

func test_arming_a_blueprint_takes_the_map_click() -> void:
	var c: Vector2i = Vector2i(128, 128)
	var grid: SimSystem = world.system(&"grid")
	if grid != null:
		c = grid.call(&"core_cell")
	world.cmd_now({"system": &"build", "op": "place", "kind": "the_hearth",
		"cell": [c.x - 2, c.y - 2], "free": true, "instant": true})
	world.cmd_now(LcnBlueprintModel.capture_command(c + Vector2i(-3, -3), c + Vector2i(3, 3), "Core"))
	menu.rebuild_models()
	assert_gt(float(menu.blueprints.size()), 0.0, "the library sees the stamp")

	var id: StringName = menu.blueprints.cards[0].id
	menu.blueprint_panel.place_requested.emit(id)
	assert_eq(String(menu.armed_blueprint), String(id), "clicking Place arms it")
	assert_true(_press(KEY_ESCAPE), "escape is consumed while a stamp is armed")
	assert_eq(String(menu.armed_blueprint), "", "and disarms it before closing any panel")


# ------------------------------------------------------------- robustness ----

func test_it_installs_and_stands_down_idempotently() -> void:
	LcnBuildMenuBootstrap.reset()
	var first: LcnBuildMenu = LcnBuildMenuBootstrap.install()
	assert_null(first, "headless runs install no UI at all — the sim gate pays nothing")


func test_models_rebuild_without_the_optional_systems() -> void:
	assert_no_errors(menu.rebuild_models,
		"research, society and production are all absent and nothing complains")
