extends TestCase
## The scene a player actually lands in.
##
## game/boot.gd seeds an opening settlement so launching the game shows a city
## instead of an empty plain. It goes out as ordinary build commands, so it can —
## and did — quietly refuse half of itself and still look like it worked. This
## test is the reason that cannot happen again.

var world: SimFixture = null


func requires_systems() -> PackedStringArray:
	return PackedStringArray(["build", "grid", "heat"])


func setup() -> void:
	world = SimFixture.new(7).start()


func teardown() -> void:
	if world != null:
		world.stop()


func test_every_opening_command_is_accepted() -> void:
	var build: SimSystem = world.system(&"build")
	var grid: SimSystem = world.system(&"grid")
	var core: Vector2i = grid.call("core_cell")
	var refusals: PackedStringArray = PackedStringArray()
	for cmd: Dictionary in load("res://game/boot.gd").call("opening_commands", core):
		var r: Dictionary = build.call("execute", cmd)
		if not bool(r.get("ok", false)):
			refusals.append("%s %s: %s" % [
				String(cmd.get("op", "?")), String(cmd.get("kind", "?")),
				String(r.get("reason", ""))])
	assert_empty(refusals, "the opening settlement must land in full on the default seed")


func test_the_opening_settlement_is_one_lit_heat_network() -> void:
	var grid: SimSystem = world.system(&"grid")
	var core: Vector2i = grid.call("core_cell")
	for cmd: Dictionary in load("res://game/boot.gd").call("opening_commands", core):
		world.cmd(cmd)
	world.run(60)
	var heat: SimSystem = world.system(&"heat")
	var totals: Dictionary = heat.call("totals")
	assert_gt(float(totals.get("supply", 0.0)), 0.0, "the hearth is burning on launch")
	assert_gt(float(totals.get("delivered", 0.0)), 0.0, "and heat is reaching the city")
	assert_gt(float(totals.get("buildings", 0)), 10.0, "most of the settlement is on the grid")
	assert_not_empty(heat.call("heat_sources_for_view"),
		"and there is something warm for the renderer to light")
