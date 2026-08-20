extends SceneTree
## Authoring source for game/content/recipes/*.tres and for [P04]'s own three
## machines in game/content/buildings/ — the same pattern [P11] uses for its
## buildings, so the .tres syntax can never rot and the numbers stay readable.
##
##   Godot --headless --path . --script tests/production/author_content.gd
##
## Only files whose names this script owns are written. It never touches another
## part's .tres.
##
## The balance argument for every number is in the header of
## game/sim/production/production_system.gd. The short version:
##
##   * one craft time unit is 50 ticks (2.5 s); everything is a multiple of it,
##     so the ratios between recipes come out as small whole numbers
##   * every clean chain ratio in the game is 1:1, except the top of the tree,
##     which is deliberately 2:1 so the last component is never free
##   * iron smelting cannot be done without producing slag, and slag has exactly
##     one use at exactly the rate one smelter makes it
##   * heat_cost is set so the flagship recipe of each machine wants EXACTLY the
##     machine's rated heat draw: a brownout slows the deep recipes 1:1 and
##     leaves the shallow ones alone

const RECIPE_DIR: String = "res://game/content/recipes"
const BUILDING_DIR: String = "res://game/content/buildings"


func _initialize() -> void:
	var failed: int = 0
	failed += _write_recipes()
	failed += _write_buildings()
	print("authored production content (%d failures)" % failed)
	quit(1 if failed > 0 else 0)


# =========================================================================
# recipes
# =========================================================================

func _write_recipes() -> int:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RECIPE_DIR))
	var failed: int = 0
	var written: int = 0
	for r: RecipeDef in _recipes():
		var issues: PackedStringArray = r.validate()
		if issues.size() > 0:
			print("INVALID recipe %s: %s" % [String(r.id), ", ".join(issues)])
			failed += 1
			continue
		r.resource_name = r.display_name
		var path: String = "%s/%s.tres" % [RECIPE_DIR, String(r.id)]
		var err: int = ResourceSaver.save(r, path)
		if err != OK:
			print("SAVE FAILED %s -> %d" % [path, err])
			failed += 1
			continue
		written += 1
	print("authored %d recipes" % written)
	return failed


func _recipe(id: String, display: String, desc: String, category: StringName, tier: int) -> RecipeDef:
	var r := RecipeDef.new()
	r.id = StringName(id)
	r.display_name = display
	r.description = desc
	r.category = category
	r.tier = tier
	return r


func _recipes() -> Array[RecipeDef]:
	var out: Array[RecipeDef] = []

	# ---------------------------------------------------------- smelting ----
	# 2 ore -> 1 plate + 1 slag every 2.5 s = 0.40 plate/s.
	# One ore drill runs at 0.80 ore/s, so ONE DRILL FEEDS ONE SMELTER exactly.
	# heat_cost 30 over 2.5 s = 12 u/s against the smelter's 14 u/s rating:
	# comfortable, so the bread-and-butter recipe survives a mild brownout.
	var iron := _recipe("iron_plate", "Iron Plate",
		"Ore in, plate out, and a slag heap that will not stop growing. The bar every other thing in the city is cut from.",
		&"smelting", 1)
	iron.inputs = {&"iron_ore": 2} as Dictionary[StringName, int]
	iron.outputs = {&"iron_plate": 1} as Dictionary[StringName, int]
	iron.byproducts = {&"slag": 1} as Dictionary[StringName, int]
	iron.time_ticks = 50
	iron.machines = [&"smelter"] as Array[StringName]
	iron.machine_tags = [&"smelter"] as Array[StringName]
	iron.heat_cost = 30.0
	iron.waste_heat = 6.0
	iron.min_temperature_c = -30.0
	iron.sort_order = 10
	iron.tint = Color(0.78, 0.80, 0.84)
	out.append(iron)

	# 1 ore -> 2 coil every 1.25 s = 1.60 coil/s, drawing 0.80 ore/s.
	# Again exactly one drill. Coil is cheap on purpose: it is the input three
	# different tier-2 recipes compete for.
	var coil := _recipe("copper_coil", "Copper Coil",
		"Drawn hot and wound while it is still soft. Every radiator and every circuit in the city is mostly this.",
		&"smelting", 1)
	coil.inputs = {&"copper_ore": 1} as Dictionary[StringName, int]
	coil.outputs = {&"copper_coil": 2} as Dictionary[StringName, int]
	coil.time_ticks = 25
	coil.machines = [&"smelter"] as Array[StringName]
	coil.machine_tags = [&"smelter"] as Array[StringName]
	coil.heat_cost = 12.0
	coil.waste_heat = 2.5
	coil.min_temperature_c = -30.0
	coil.sort_order = 20
	coil.tint = Color(0.85, 0.55, 0.32)
	out.append(coil)

	# 2 plate + 1 coal -> 1 steel every 5 s = 0.20 steel/s, drawing 0.40 plate/s.
	# ONE IRON SMELTER FEEDS ONE STEEL SMELTER. heat_cost 70 over 5 s = 14 u/s,
	# exactly the smelter's rating: steel is the recipe that dies first in a
	# brownout, which is the whole point of putting the good stuff behind it.
	var steel := _recipe("steel_plate", "Steel Plate",
		"Iron, coal and a great deal of patience held at temperature. Twice the plate for four times the heat.",
		&"smelting", 2)
	steel.inputs = {&"iron_plate": 2, &"coal": 1} as Dictionary[StringName, int]
	steel.outputs = {&"steel_plate": 1} as Dictionary[StringName, int]
	steel.time_ticks = 100
	steel.machines = [&"smelter"] as Array[StringName]
	steel.machine_tags = [&"smelter"] as Array[StringName]
	steel.heat_cost = 70.0
	steel.waste_heat = 18.0
	steel.min_temperature_c = -12.0
	steel.sort_order = 30
	steel.tint = Color(0.62, 0.68, 0.76)
	out.append(steel)

	# ----------------------------------------------------------- salvage ----
	# The city cannot mine stone or fell timber on a dead plain: both come back
	# out of its own ruins. 4 scrap -> 2 stone + 1 timber + 1 iron_ore in 5 s.
	var rubble := _recipe("sorted_rubble", "Sorted Rubble",
		"Trommels and picking belts. What the old city left behind, sorted back into things that can be built with.",
		&"salvage", 1)
	rubble.inputs = {&"scrap": 4} as Dictionary[StringName, int]
	rubble.outputs = {&"stone": 2, &"timber": 1} as Dictionary[StringName, int]
	rubble.byproducts = {&"iron_ore": 1} as Dictionary[StringName, int]
	rubble.time_ticks = 100
	rubble.machines = [&"rubble_sorter"] as Array[StringName]
	rubble.machine_tags = [&"sorter"] as Array[StringName]
	rubble.heat_cost = 20.0
	rubble.waste_heat = 3.0
	rubble.min_temperature_c = -30.0
	rubble.sort_order = 10
	rubble.tint = Color(0.66, 0.64, 0.6)
	out.append(rubble)

	# The Frostpunk choice, expressed as two recipes on one machine: the same
	# crew can bring back building material OR sealed food, never both.
	var stores := _recipe("salvaged_stores", "Salvaged Stores",
		"Sealed crates pulled out of collapsed cellars. Grain that has been frozen for a decade still counts as grain.",
		&"salvage", 1)
	stores.inputs = {&"scrap": 6} as Dictionary[StringName, int]
	stores.outputs = {&"grain": 2} as Dictionary[StringName, int]
	stores.byproducts = {&"timber": 1} as Dictionary[StringName, int]
	stores.time_ticks = 200
	stores.machines = [&"rubble_sorter"] as Array[StringName]
	stores.machine_tags = [&"sorter"] as Array[StringName]
	stores.heat_cost = 30.0
	stores.waste_heat = 2.0
	stores.min_temperature_c = -30.0
	stores.sort_order = 20
	stores.tint = Color(0.8, 0.74, 0.5)
	out.append(stores)

	# THE THIRD THING THE SAME CREW CAN BRING BACK, AND THE ONE THAT UNLOCKS THE
	# TOP HALF OF THE TREE. `pipe_segment` and `circuit` both want copper_coil,
	# heat_core wants both of them, and a warmth_radiator costs 20 coil to place
	# — so before this recipe existed, copper was a RAW material with no source
	# inside the walls and the graph above depth 3 could not be entered at all
	# without a mine. The nearest copper field on the reference map is 37 tiles
	# south-east, past the wall, past the lanes [P08] uses.
	#
	# THE RATIO IS THE DESIGN AND IT IS DELIBERATELY BAD: 2 copper_ore per 12.5 s
	# is 0.16/s, against the 0.80 ore/s ONE drill lifts. Five sorters to feed one
	# copper smelter. Salvage is how a city that cannot yet afford an expedition
	# gets its first coil; mining is how it stops being poor. A player who reads
	# that ratio off the tooltip has been told, in numbers, to go take the field.
	var wire := _recipe("salvaged_wire", "Salvaged Wire",
		"Armoured cable cut out of the buried streets and burned back to metal. Eight crates of rubble for two of copper: a fifth of what one drill lifts, which is exactly why the copper field is worth thirty tiles of pipe.",
		&"salvage", 2)
	wire.inputs = {&"scrap": 8} as Dictionary[StringName, int]
	wire.outputs = {&"copper_ore": 2} as Dictionary[StringName, int]
	wire.time_ticks = 250
	wire.machines = [&"rubble_sorter"] as Array[StringName]
	wire.machine_tags = [&"sorter"] as Array[StringName]
	# 45 over 12.5 s = 3.6 u/s against the sorter's 6 u/s rating. Burning cable
	# clean costs more heat per second than picking rubble (2.0 u/s) and less
	# than the machine can draw, so it is the salvage recipe a brownout slows
	# first and stops last.
	wire.heat_cost = 45.0
	wire.waste_heat = 4.0
	wire.min_temperature_c = -25.0
	wire.sort_order = 30
	wire.tint = Color(0.84, 0.52, 0.36)
	out.append(wire)

	# ------------------------------------------------------------- parts ----
	# 2 plate -> 1 gear every 5 s = 0.20 gear/s, drawing 0.40 plate/s.
	# ONE IRON SMELTER FEEDS ONE GEAR SHOP.
	var gear := _recipe("gear", "Gear",
		"Cut, hardened and stacked in crates of twelve. Nothing in the city turns without them.",
		&"parts", 2)
	gear.inputs = {&"iron_plate": 2} as Dictionary[StringName, int]
	gear.outputs = {&"gear": 1} as Dictionary[StringName, int]
	gear.time_ticks = 100
	gear.machines = [&"workshop", &"assembly_hall"] as Array[StringName]
	gear.machine_tags = [&"crafter"] as Array[StringName]
	gear.heat_cost = 40.0
	gear.waste_heat = 5.0
	gear.min_temperature_c = -25.0
	gear.sort_order = 10
	gear.tint = Color(0.72, 0.74, 0.78)
	out.append(gear)

	# The byproduct loop that makes the whole design close: 2 slag + 1 timber ->
	# 2 insulation every 5 s, drawing 0.40 slag/s — EXACTLY what one iron smelter
	# throws off. Run iron without insulation and the slag is dead weight; run
	# them together and the block consumes nothing it does not use.
	var insul := _recipe("insulation", "Insulation",
		"Slag wool pressed into batts between timber laths. Ugly, itchy, and the difference between a warm district and a dead one.",
		&"parts", 2)
	insul.inputs = {&"slag": 2, &"timber": 1} as Dictionary[StringName, int]
	insul.outputs = {&"insulation": 2} as Dictionary[StringName, int]
	insul.time_ticks = 100
	insul.machines = [&"workshop", &"assembly_hall"] as Array[StringName]
	insul.machine_tags = [&"crafter"] as Array[StringName]
	insul.heat_cost = 30.0
	insul.waste_heat = 4.0
	insul.min_temperature_c = -25.0
	insul.sort_order = 20
	insul.tint = Color(0.78, 0.72, 0.55)
	out.append(insul)

	# 1 steel + 1 coil -> 2 pipe every 5 s = 0.40 pipe/s, drawing 0.20 steel/s.
	# ONE STEEL SMELTER FEEDS ONE PIPE SHOP.
	var pipe := _recipe("pipe_segment", "Pipe Segment",
		"Rolled steel with a copper liner, flanged at both ends. The heat grid is made of nothing else.",
		&"parts", 3)
	pipe.inputs = {&"steel_plate": 1, &"copper_coil": 1} as Dictionary[StringName, int]
	pipe.outputs = {&"pipe_segment": 2} as Dictionary[StringName, int]
	pipe.time_ticks = 100
	pipe.machines = [&"workshop", &"assembly_hall"] as Array[StringName]
	pipe.machine_tags = [&"crafter"] as Array[StringName]
	pipe.heat_cost = 50.0
	pipe.waste_heat = 6.0
	pipe.min_temperature_c = -18.0
	pipe.sort_order = 30
	pipe.tint = Color(0.66, 0.72, 0.8)
	out.append(pipe)

	# Delicate work: the coldest floor in the game, and the first recipe [P10]
	# gates. 3 coil + 1 plate -> 2 circuit every 10 s.
	var circuit := _recipe("circuit", "Circuit",
		"Etched board, hand-wound coils, and a soldering iron that will not stay hot below minus eight. Precision hates the cold.",
		&"parts", 3)
	circuit.inputs = {&"copper_coil": 3, &"iron_plate": 1} as Dictionary[StringName, int]
	circuit.outputs = {&"circuit": 2} as Dictionary[StringName, int]
	circuit.time_ticks = 200
	circuit.machines = [&"workshop", &"assembly_hall"] as Array[StringName]
	circuit.machine_tags = [&"crafter"] as Array[StringName]
	circuit.heat_cost = 60.0
	circuit.waste_heat = 4.0
	circuit.min_temperature_c = -8.0
	circuit.unlock_id = &"electrotechnics"
	circuit.sort_order = 40
	circuit.tint = Color(0.55, 0.78, 0.66)
	out.append(circuit)

	# --------------------------------------------------------- munitions ----
	# 1 steel + 1 gear + 2 sulfur -> 4 shells every 10 s = 0.40 shell/s.
	# Half a steel smelter, half a gear shop and a quarter of a sulfur drill.
	var ammo := _recipe("ammo_shell", "Ammunition Shell",
		"Steel case, sulfur charge, and a gear-cut fuse. Four to a crate, and the crates go out to the wall before dusk.",
		&"munitions", 3)
	ammo.inputs = {&"steel_plate": 1, &"gear": 1, &"sulfur": 2} as Dictionary[StringName, int]
	ammo.outputs = {&"ammo_shell": 4} as Dictionary[StringName, int]
	ammo.time_ticks = 200
	ammo.machines = [&"workshop", &"assembly_hall"] as Array[StringName]
	ammo.machine_tags = [&"crafter"] as Array[StringName]
	ammo.heat_cost = 80.0
	ammo.waste_heat = 10.0
	ammo.min_temperature_c = -20.0
	ammo.sort_order = 50
	ammo.tint = Color(0.86, 0.62, 0.3)
	out.append(ammo)

	# -------------------------------------------------------- components ----
	# The top of the tree, and the only deliberate 2:1 in the game: one pipe,
	# one circuit and one insulation shop between them feed TWO assembly halls.
	var core := _recipe("heat_core", "Heat Core",
		"A sealed exchanger block. Drop one into a pipe run and the far end of the district stops freezing.",
		&"components", 4)
	core.inputs = {&"pipe_segment": 2, &"circuit": 1, &"insulation": 2} as Dictionary[StringName, int]
	core.outputs = {&"heat_core": 1} as Dictionary[StringName, int]
	core.time_ticks = 200
	core.machines = [&"assembly_hall"] as Array[StringName]
	core.machine_tags = [&"assembler"] as Array[StringName]
	core.heat_cost = 180.0
	core.waste_heat = 12.0
	core.min_temperature_c = -5.0
	core.unlock_id = &"thermal_assembly"
	core.sort_order = 10
	core.tint = Color(1.0, 0.66, 0.34)
	out.append(core)

	# -------------------------------------------------------------- food ----
	# [P05] citizens owns hunger; production only owns the pot. Grain comes out
	# of the ruins today; when [P05] lands a real farm, this recipe does not move.
	var ration := _recipe("ration", "Ration",
		"Grain, meltwater and whatever fat the kitchen has left, boiled until it is hot enough to eat standing up.",
		&"food", 2)
	ration.inputs = {&"grain": 2} as Dictionary[StringName, int]
	ration.outputs = {&"ration": 3} as Dictionary[StringName, int]
	ration.time_ticks = 100
	ration.machines = [&"field_kitchen"] as Array[StringName]
	ration.machine_tags = [&"kitchen"] as Array[StringName]
	ration.heat_cost = 20.0
	ration.waste_heat = 2.0
	ration.min_temperature_c = -20.0
	ration.sort_order = 10
	ration.tint = Color(0.9, 0.78, 0.5)
	out.append(ration)

	return out


# =========================================================================
# [P04]'s own machines — three files, all named after the machine.
# =========================================================================

func _write_buildings() -> int:
	var failed: int = 0
	for d: BuildingDef in _buildings():
		var issues: PackedStringArray = d.validate()
		if issues.size() > 0:
			print("INVALID building %s: %s" % [String(d.id), ", ".join(issues)])
			failed += 1
			continue
		d.resource_name = d.display_name
		var path: String = "%s/%s.tres" % [BUILDING_DIR, String(d.id)]
		var err: int = ResourceSaver.save(d, path)
		if err != OK:
			print("SAVE FAILED %s -> %d" % [path, err])
			failed += 1
			continue
	print("authored %d production buildings" % (_buildings().size() - failed))
	return failed


func _building(id: String, display: String, desc: String, category: StringName, tier: int) -> BuildingDef:
	var d := BuildingDef.new()
	d.id = StringName(id)
	d.display_name = display
	d.description = desc
	d.category = category
	d.tier = tier
	return d


func _buildings() -> Array[BuildingDef]:
	var out: Array[BuildingDef] = []

	# --------------------------------------------------------- recuperator --
	# The heat-recovery machine, and the reason a tight industrial block beats a
	# sprawling one. It is an ordinary [P02] burner whose fuel item is the
	# pseudo-item "waste_heat"; production pushes captured waste into its bunker
	# and heat burns it without knowing where it came from.
	#   fuel_per_unit = 3.0 / 15.0 = 0.2, so at full output it eats 3.0 waste/s.
	#   One smelter on iron_plate throws off 6 units per 2.5 s craft = 2.4/s,
	#   so ~1.25 smelters keep one recuperator lit: 15 heat/s for no coal at all,
	#   against the coal generator's 30 heat/s for 0.35 coal/s.
	var rec := _building("recuperator", "Recuperator",
		"A flue stack wrapped in an exchanger coil. Stands among the smelters and drinks the heat they would otherwise throw at the sky.",
		&"power", 2)
	rec.size = Vector2i(2, 2)
	rec.sort_order = 20
	rec.tags = [&"heat_source", &"machine", &"powered", &"recovery"] as Array[StringName]
	rec.cost = {&"copper_coil": 20, &"iron_plate": 25, &"steel_plate": 10} as Dictionary[StringName, int]
	rec.build_time_ticks = 700
	rec.demolish_time_ticks = 90
	rec.refund_ratio = 0.6
	rec.build_priority = 55
	rec.workers_required = 1
	rec.heat_produced = 15.0
	rec.fuel_items = [&"waste_heat"] as Array[StringName]
	rec.fuel_burn_rate = 3.0
	# A recuperator that only ever gives has a cold-start problem: with no waste
	# to burn it produces nothing, cools, and freezes solid before the first
	# smelter beside it has finished a craft. So it also DRAWS a trickle. While
	# it is producing it covers that itself; while it is starved it is not a live
	# source, so the grid can reach it and keep it above freezing. The buffer is
	# the flywheel between the two, and heavy insulation is what a stack of
	# exchanger coil actually is.
	rec.heat_consumed = 2.0
	rec.heat_buffer = 90.0
	rec.heat_insulation = 0.8
	rec.hp = 420.0
	rec.connects_as = [&"heat", &"power"] as Array[StringName]
	rec.tint = Color(0.84, 0.58, 0.36)
	rec.light_energy = 0.8
	rec.light_color = Color(1.0, 0.66, 0.34)
	out.append(rec)

	# ------------------------------------------------------- rubble sorter --
	# Without this the material economy dead-ends: nothing on a frozen plain
	# produces stone or timber, so the city would spend its starting pile and
	# stop. The sorter turns its own ruins back into buildings, or into food.
	var sorter := _building("rubble_sorter", "Rubble Sorter",
		"Trommels and picking belts under a canvas roof. Everything the old city left behind comes back through here as something usable.",
		&"production", 1)
	sorter.size = Vector2i(3, 2)
	sorter.sort_order = 85
	sorter.tags = [&"crafter", &"machine", &"sorter", &"salvage"] as Array[StringName]
	sorter.cost = {&"iron_plate": 10, &"scrap": 25, &"timber": 30} as Dictionary[StringName, int]
	sorter.build_time_ticks = 700
	sorter.demolish_time_ticks = 90
	sorter.build_priority = 60
	sorter.workers_required = 2
	sorter.staff_capacity = 4
	sorter.heat_consumed = 6.0
	sorter.hp = 420.0
	sorter.recipes = [&"sorted_rubble", &"salvaged_stores"] as Array[StringName]
	sorter.storage_capacity = 180
	sorter.tint = Color(0.68, 0.66, 0.6)
	out.append(sorter)

	# -------------------------------------------------------- assembly hall --
	# Tier three. The only machine that can build a heat core, and the machine a
	# brownout hurts most: heat_core wants 18 u/s against a 22 u/s rating.
	var hall := _building("assembly_hall", "Assembly Hall",
		"Overhead cranes, a heated floor and benches long enough to build something that will outlast the winter.",
		&"production", 3)
	hall.size = Vector2i(4, 4)
	hall.sort_order = 95
	hall.tags = [&"crafter", &"machine", &"assembler", &"powered"] as Array[StringName]
	hall.cost = {&"steel_plate": 40, &"gear": 30, &"iron_plate": 50, &"stone": 60} as Dictionary[StringName, int]
	hall.build_time_ticks = 2200
	hall.demolish_time_ticks = 260
	hall.build_priority = 50
	hall.workers_required = 6
	hall.staff_capacity = 12
	hall.heat_consumed = 22.0
	hall.heat_insulation = 0.6
	hall.hp = 950.0
	hall.recipes = [&"heat_core", &"ammo_shell", &"circuit", &"pipe_segment",
		&"insulation", &"gear"] as Array[StringName]
	hall.craft_speed = 1.0
	hall.storage_capacity = 320
	hall.tint = Color(0.6, 0.68, 0.78)
	hall.light_energy = 0.9
	out.append(hall)

	return out
