extends TestCase
## [P18] The blueprint library, over [P11]'s real book.
##
## Everything here goes through the same commands a player's click sends, so a
## green run means the library actually drives the simulation rather than a copy
## of it.

var world: SimFixture = null
var model: LcnBlueprintModel = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["build"])


func setup() -> void:
	world = SimFixture.new(7).start()
	model = LcnBlueprintModel.new()
	_seed_a_block()


func teardown() -> void:
	world.stop()


func _core() -> Vector2i:
	var grid: SimSystem = world.system(&"grid")
	return grid.call(&"core_cell") if grid != null else Vector2i(128, 128)


## A hearth with a short main hanging off it, then a capture over the lot.
func _seed_a_block() -> void:
	var c: Vector2i = _core()
	world.cmd_now({"system": &"build", "op": "place", "kind": "the_hearth",
		"cell": [c.x - 2, c.y - 2], "free": true, "instant": true})
	world.cmd_now({"system": &"build", "op": "place_line", "kind": "heat_pipe",
		"from": [c.x + 3, c.y], "to": [c.x + 8, c.y], "free": true, "instant": true})
	world.cmd_now(LcnBlueprintModel.capture_command(
		c + Vector2i(-3, -3), c + Vector2i(9, 3), "Hearth and mains"))
	model.rebuild(world.system(&"build"))


func test_the_book_becomes_cards() -> void:
	assert_eq(model.size(), 1, "the capture reached the library")
	var card: LcnBlueprintModel.Card = model.cards[0]
	assert_eq(card.title, "Hearth and mains", "with its title")
	assert_gt(float(card.entry_count), 0.0, "and its contents")
	assert_has(card.subtitle(), "building", "the subtitle counts them")
	assert_ne(card.contents_label(), "", "and names the kinds")


func test_the_thumbnail_is_the_actual_layout() -> void:
	var card: LcnBlueprintModel.Card = model.cards[0]
	assert_eq(card.thumb.size(), card.entry_count,
		"one drawn rectangle per building — two different stamps cannot look alike")
	for piece: Dictionary in card.thumb:
		var r: Rect2i = piece["rect"]
		assert_gt(float(r.size.x), 0.0, "every piece has a footprint")
		assert_true(r.position.x >= 0 and r.position.y >= 0, "inside the stamp's own box")


func test_cost_is_measured_against_the_warehouse() -> void:
	world.cmd_now({"system": &"build", "op": "set_stock", "items": {
		"iron_plate": 0, "steel_plate": 0, "stone": 0, "scrap": 0}})
	model.rebuild(world.system(&"build"))
	var card: LcnBlueprintModel.Card = model.cards[0]
	assert_false(card.affordable, "an empty warehouse cannot pay for a hearth")
	assert_not_empty(card.missing, "and the shortfall is itemised")

	world.cmd_now({"system": &"build", "op": "add_stock", "items": {
		"iron_plate": 999, "steel_plate": 999, "stone": 999, "scrap": 999}})
	model.rebuild(world.system(&"build"))
	assert_true(model.cards[0].affordable, "a full one can")


func test_renaming_is_a_ui_label_not_a_sim_write() -> void:
	var id: StringName = model.cards[0].id
	var before: String = String((world.system(&"build").get(&"book") as Object)
		.call(&"get_bp", id).get(&"title"))
	model.rebuild(world.system(&"build"), {String(id): "Cold Start Kit"})
	assert_eq(model.cards[0].title, "Cold Start Kit", "the card shows the player's name")
	assert_true(model.cards[0].renamed, "and marks it as an override")
	var after: String = String((world.system(&"build").get(&"book") as Object)
		.call(&"get_bp", id).get(&"title"))
	assert_eq(after, before, "while the stamp inside the simulation is untouched")


func test_place_actually_stamps_the_world() -> void:
	var build: SimSystem = world.system(&"build")
	var before: int = int(build.call(&"building_count"))
	var target: Vector2i = _core() + Vector2i(30, 30)
	world.cmd_now({"system": &"build", "op": "add_stock", "items": {
		"iron_plate": 999, "steel_plate": 999, "stone": 999, "scrap": 999, "timber": 999}})
	world.cmd_now(LcnBlueprintModel.place_command(model.cards[0].id, target))
	world.run(2)
	assert_gt(float(int(build.call(&"building_count"))), float(before),
		"the library's Place button puts buildings on the map")


func test_delete_removes_it_from_the_book() -> void:
	var id: StringName = model.cards[0].id
	world.cmd_now(LcnBlueprintModel.delete_command(id))
	model.rebuild(world.system(&"build"))
	assert_eq(model.size(), 0, "a deleted stamp leaves the library")


func test_turning_a_stamp_transposes_its_box() -> void:
	var id: StringName = model.cards[0].id
	var before: Vector2i = model.cards[0].size
	world.cmd_now(LcnBlueprintModel.transform_command(id, 1, false, false))
	model.rebuild(world.system(&"build"))
	var after: Vector2i = model.cards[0].size
	assert_eq(after, Vector2i(before.y, before.x), "a quarter turn swaps width and height")


func test_commands_are_addressed_to_the_build_system() -> void:
	for cmd: Dictionary in [
		LcnBlueprintModel.place_command(&"bp_1", Vector2i(3, 4)),
		LcnBlueprintModel.delete_command(&"bp_1"),
		LcnBlueprintModel.export_command(&"bp_1"),
		LcnBlueprintModel.import_command(),
		LcnBlueprintModel.capture_command(Vector2i.ZERO, Vector2i.ONE, "x"),
		LcnBlueprintModel.transform_command(&"bp_1", 1, false, false),
	]:
		assert_eq(String(cmd["system"]), "build", "every mutation goes through [P11]")


func test_it_survives_a_missing_build_system() -> void:
	var orphan := LcnBlueprintModel.new()
	orphan.rebuild(null)
	assert_eq(orphan.size(), 0, "no build system, no cards, no crash")
