extends SceneTree
## Authoring source for game/content/buildings/*.tres — [P11].
##
## The numbers of the opening twenty minutes live here in readable form; the
## .tres files next to Registry are generated from it so the syntax can never rot.
## Re-run after changing a number:
##
##   Godot --headless --path . --script tests/build/author_buildings.gd
##
## Balance sketch for the first twenty minutes, against the starting stock
## (320 scrap, 140 iron plate, 220 stone, 180 timber, 40 copper, 36 gear, 200 coal):
##   the hearth is free and warms the centre; two coal generators, a dozen pipes
##   and three radiators reach the first housing; a scrap collector and an ore
##   drill feed a smelter, which is the only way to make the iron the second ring
##   of radiators needs. Iron runs out ~15 minutes in on purpose — that shortage
##   is the tutorial for automation.

const OUT_DIR: String = "res://game/content/buildings"


func _initialize() -> void:
	var defs: Array[BuildingDef] = _author()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var written: int = 0
	var failed: int = 0
	for d: BuildingDef in defs:
		var issues: PackedStringArray = d.validate()
		if issues.size() > 0:
			print("INVALID %s: %s" % [String(d.id), ", ".join(issues)])
			failed += 1
			continue
		d.resource_name = d.display_name
		var path: String = "%s/%s.tres" % [OUT_DIR, String(d.id)]
		var err: int = ResourceSaver.save(d, path)
		if err != OK:
			print("SAVE FAILED %s -> %d" % [path, err])
			failed += 1
			continue
		written += 1
	print("authored %d building definitions (%d failed)" % [written, failed])
	quit(1 if failed > 0 else 0)


func _new(id: String, display: String, desc: String, category: StringName, tier: int) -> BuildingDef:
	var d := BuildingDef.new()
	d.id = StringName(id)
	d.display_name = display
	d.description = desc
	d.category = category
	d.tier = tier
	return d


func _author() -> Array[BuildingDef]:
	var out: Array[BuildingDef] = []

	# ------------------------------------------------------------ the hearth --
	var hearth := _new("the_hearth", "The Hearth",
		"The generator the first survivors built around. It burns anything and it never stops. If it goes out, the city does.",
		&"power", 1)
	hearth.size = Vector2i(5, 5)
	hearth.sort_order = 0
	hearth.tags = [&"heat_source", &"unique", &"landmark", &"powered"] as Array[StringName]
	hearth.cost = {&"steel_plate": 40, &"stone": 140, &"iron_plate": 60} as Dictionary[StringName, int]
	hearth.build_time_ticks = 2400
	hearth.demolish_time_ticks = 400
	hearth.refund_ratio = 0.25
	hearth.workers_required = 4
	hearth.staff_capacity = 8
	hearth.heat_produced = 120.0
	hearth.heat_buffer = 600.0
	hearth.heat_radius = 14.0
	hearth.heat_insulation = 0.7
	hearth.fuel_items = [&"coal", &"timber"] as Array[StringName]
	hearth.fuel_burn_rate = 0.8
	hearth.connects_as = [&"heat", &"power"] as Array[StringName]
	hearth.hp = 3000.0
	hearth.armor = 6.0
	hearth.max_count = 1
	hearth.build_priority = 100
	hearth.vision_radius = 18.0
	hearth.light_energy = 2.2
	hearth.light_color = Color(1.0, 0.56, 0.22)
	hearth.tint = Color(1.0, 0.62, 0.28)
	out.append(hearth)

	# ------------------------------------------------------- coal generator ---
	var coal := _new("coal_generator", "Coal Generator",
		"A riveted furnace that turns coal into heat and soot. Cheap, loud, and the reason the first night is survivable.",
		&"power", 1)
	coal.size = Vector2i(3, 2)
	coal.sort_order = 10
	coal.tags = [&"heat_source", &"powered", &"burner"] as Array[StringName]
	coal.cost = {&"scrap": 45, &"iron_plate": 20} as Dictionary[StringName, int]
	coal.build_time_ticks = 900
	coal.demolish_time_ticks = 120
	coal.refund_ratio = 0.6
	coal.workers_required = 1
	coal.heat_produced = 30.0
	coal.heat_buffer = 120.0
	coal.heat_radius = 3.0
	coal.fuel_items = [&"coal"] as Array[StringName]
	coal.fuel_burn_rate = 0.35
	coal.connects_as = [&"heat"] as Array[StringName]
	coal.hp = 600.0
	coal.rotatable = true
	coal.rotation_symmetry = 4
	coal.build_priority = 60
	coal.light_energy = 1.1
	coal.tint = Color(0.86, 0.47, 0.24)
	out.append(coal)

	# ------------------------------------------------------ geothermal tap ----
	var geo := _new("geothermal_tap", "Geothermal Tap",
		"Drives a column into a vent and takes the heat straight from the ground. No fuel, no smoke, and it only works where the earth is already angry.",
		&"power", 2)
	geo.size = Vector2i(3, 3)
	geo.sort_order = 20
	geo.tags = [&"heat_source", &"powered", &"clean"] as Array[StringName]
	geo.cost = {&"iron_plate": 45, &"stone": 60, &"pipe_segment": 10} as Dictionary[StringName, int]
	geo.build_time_ticks = 1800
	geo.demolish_time_ticks = 240
	geo.refund_ratio = 0.5
	geo.workers_required = 2
	geo.heat_produced = 55.0
	geo.heat_buffer = 200.0
	geo.heat_radius = 4.0
	geo.needs_ore = &"vent"          # Grid.Res name table
	geo.ore_coverage = 1
	geo.needs_flat = true
	geo.connects_as = [&"heat"] as Array[StringName]
	geo.hp = 1100.0
	geo.armor = 2.0
	geo.unlock_id = &"geothermal_tapping"
	geo.build_priority = 70
	geo.light_energy = 0.8
	geo.light_color = Color(0.98, 0.72, 0.38)
	geo.tint = Color(0.94, 0.68, 0.36)
	out.append(geo)

	# ------------------------------------------------------------ heat pipe ---
	var pipe := _new("heat_pipe", "Heat Pipe",
		"Insulated conduit. Heat only reaches what you connect, so the shape of your pipe run is the shape of your city.",
		&"heat", 1)
	pipe.size = Vector2i.ONE
	pipe.sort_order = 30
	pipe.tags = [&"conduit", &"network"] as Array[StringName]
	pipe.cost = {&"iron_plate": 2} as Dictionary[StringName, int]
	pipe.build_time_ticks = 20
	pipe.demolish_time_ticks = 6
	pipe.refund_ratio = 0.8
	pipe.is_heat_conduit = true
	pipe.conduit_throughput = 60.0
	pipe.heat_buffer = 6.0
	pipe.heat_insulation = 0.8
	pipe.connects_as = [&"heat"] as Array[StringName]
	pipe.blocks_movement = false
	pipe.walkable = true
	pipe.drag_mode = 1
	pipe.hp = 120.0
	pipe.build_priority = 80
	pipe.tint = Color(0.78, 0.55, 0.35)
	out.append(pipe)

	# ------------------------------------------------------ heat accumulator --
	var accum := _new("heat_accumulator", "Heat Accumulator",
		"A pressure tank of superheated brine. Charges while the generators are ahead, and carries the grid through the worst hour of the night.",
		&"heat", 2)
	accum.size = Vector2i(2, 2)
	accum.sort_order = 40
	accum.tags = [&"buffer", &"network"] as Array[StringName]
	accum.cost = {&"iron_plate": 30, &"copper_coil": 12} as Dictionary[StringName, int]
	accum.build_time_ticks = 800
	accum.demolish_time_ticks = 90
	accum.is_heat_conduit = true
	accum.conduit_throughput = 40.0
	accum.heat_buffer = 900.0
	accum.heat_insulation = 0.9
	accum.connects_as = [&"heat"] as Array[StringName]
	accum.must_connect = [&"heat"] as Array[StringName]
	accum.hp = 400.0
	accum.unlock_id = &"thermal_storage"
	accum.build_priority = 50
	accum.tint = Color(0.72, 0.62, 0.52)
	out.append(accum)

	# ------------------------------------------------------ warmth radiator ---
	var rad := _new("warmth_radiator", "Warmth Radiator",
		"Sheds the grid's heat into the streets around it. Citizens only live where these reach.",
		&"heat", 1)
	rad.size = Vector2i(2, 2)
	rad.sort_order = 50
	rad.tags = [&"radiator", &"comfort"] as Array[StringName]
	rad.cost = {&"scrap": 20, &"iron_plate": 12, &"copper_coil": 4} as Dictionary[StringName, int]
	rad.build_time_ticks = 400
	rad.demolish_time_ticks = 60
	rad.refund_ratio = 0.7
	rad.heat_consumed = 12.0
	rad.heat_buffer = 40.0
	rad.heat_radius = 6.5
	rad.must_connect = [&"heat"] as Array[StringName]
	rad.hp = 350.0
	rad.build_priority = 75
	rad.light_energy = 0.9
	rad.light_color = Color(1.0, 0.68, 0.36)
	rad.tint = Color(0.95, 0.6, 0.3)
	out.append(rad)

	# ------------------------------------------------------ scrap collector ---
	var scrapper := _new("scrap_collector", "Scrap Collector",
		"A crew shed and a winch. Pulls usable metal out of the frozen rubble field around the city.",
		&"extraction", 1)
	scrapper.size = Vector2i(2, 2)
	scrapper.sort_order = 60
	scrapper.tags = [&"extractor", &"salvage"] as Array[StringName]
	scrapper.cost = {&"timber": 25, &"iron_plate": 8} as Dictionary[StringName, int]
	scrapper.build_time_ticks = 500
	scrapper.demolish_time_ticks = 60
	scrapper.workers_required = 2
	scrapper.staff_capacity = 4
	scrapper.extracts = &"scrap"
	scrapper.extract_rate = 0.55
	scrapper.heat_consumed = 2.0
	scrapper.storage_capacity = 100
	scrapper.storage_filter = [&"scrap"] as Array[StringName]
	scrapper.hp = 300.0
	scrapper.build_priority = 65
	scrapper.tint = Color(0.66, 0.64, 0.6)
	out.append(scrapper)

	# ------------------------------------------------------------ ore drill ---
	var drill := _new("ore_drill", "Ore Drill",
		"Chews through permafrost into the seam below. It must sit directly on a vein, and it is loud enough to be heard from the dark.",
		&"extraction", 1)
	drill.size = Vector2i(3, 3)
	drill.sort_order = 70
	drill.tags = [&"extractor", &"machine"] as Array[StringName]
	drill.cost = {&"scrap": 55, &"iron_plate": 25, &"gear": 8} as Dictionary[StringName, int]
	drill.build_time_ticks = 1100
	drill.demolish_time_ticks = 150
	drill.workers_required = 3
	drill.staff_capacity = 6
	drill.extracts = BuildTypes.ANY_ORE
	drill.extract_rate = 0.8
	drill.needs_ore = BuildTypes.ANY_ORE
	drill.ore_coverage = 2            # the head must really be over the seam
	drill.heat_consumed = 8.0
	drill.storage_capacity = 120
	drill.hp = 700.0
	drill.rotatable = true
	drill.rotation_symmetry = 4
	drill.build_priority = 65
	drill.tint = Color(0.7, 0.66, 0.58)
	out.append(drill)

	# -------------------------------------------------------------- smelter ---
	var smelter := _new("smelter", "Smelter",
		"Ore in, plate out, and a great deal of heat lost to the sky. The whole metal economy hangs off this building.",
		&"production", 1)
	smelter.size = Vector2i(3, 3)
	smelter.sort_order = 80
	smelter.tags = [&"crafter", &"machine", &"hot"] as Array[StringName]
	smelter.cost = {&"stone": 80, &"iron_plate": 20, &"scrap": 30} as Dictionary[StringName, int]
	smelter.build_time_ticks = 1400
	smelter.demolish_time_ticks = 180
	smelter.workers_required = 3
	smelter.staff_capacity = 6
	smelter.recipes = [&"iron_plate", &"steel_plate", &"copper_coil"] as Array[StringName]
	smelter.craft_speed = 1.0
	smelter.heat_consumed = 14.0
	smelter.heat_produced = 4.0
	smelter.heat_radius = 2.5
	smelter.fuel_items = [&"coal"] as Array[StringName]
	smelter.fuel_burn_rate = 0.2
	smelter.storage_capacity = 200
	smelter.hp = 800.0
	smelter.build_priority = 60
	smelter.light_energy = 1.4
	smelter.tint = Color(0.88, 0.5, 0.28)
	out.append(smelter)

	# ------------------------------------------------------------- workshop ---
	var shop := _new("workshop", "Workshop",
		"Benches, presses and a foreman who never sleeps. Turns plate into the parts everything else is made of.",
		&"production", 1)
	shop.size = Vector2i(4, 3)
	shop.sort_order = 90
	shop.tags = [&"crafter", &"machine"] as Array[StringName]
	shop.cost = {&"timber": 60, &"iron_plate": 35, &"scrap": 40} as Dictionary[StringName, int]
	shop.build_time_ticks = 1800
	shop.demolish_time_ticks = 200
	shop.workers_required = 4
	shop.staff_capacity = 8
	shop.recipes = [&"gear", &"pipe_segment", &"circuit", &"ammo_shell", &"insulation"] as Array[StringName]
	shop.craft_speed = 1.0
	shop.heat_consumed = 10.0
	shop.storage_capacity = 240
	shop.hp = 750.0
	shop.build_priority = 55
	shop.light_energy = 0.7
	shop.tint = Color(0.62, 0.66, 0.74)
	out.append(shop)

	# -------------------------------------------------------- field kitchen ---
	var kitchen := _new("field_kitchen", "Field Kitchen",
		"Boils grain into something a shift crew can eat standing up. Hungry citizens do not build.",
		&"production", 1)
	kitchen.size = Vector2i(3, 2)
	kitchen.sort_order = 100
	kitchen.tags = [&"crafter", &"food", &"comfort"] as Array[StringName]
	kitchen.cost = {&"timber": 35, &"iron_plate": 12} as Dictionary[StringName, int]
	kitchen.build_time_ticks = 800
	kitchen.demolish_time_ticks = 90
	kitchen.workers_required = 2
	kitchen.staff_capacity = 4
	kitchen.recipes = [&"ration"] as Array[StringName]
	kitchen.heat_consumed = 5.0
	kitchen.heat_radius = 2.0
	kitchen.storage_capacity = 150
	kitchen.storage_filter = [&"grain", &"ration"] as Array[StringName]
	kitchen.hp = 400.0
	kitchen.build_priority = 70
	kitchen.light_energy = 0.6
	kitchen.tint = Color(0.85, 0.72, 0.5)
	out.append(kitchen)

	# --------------------------------------------------------- housing block --
	var house := _new("housing_block", "Housing Block",
		"Bunks, a stove pipe and a door that shuts. Twelve people live here, and they will tell you exactly how cold it is.",
		&"housing", 1)
	house.size = Vector2i(4, 4)
	house.sort_order = 110
	house.tags = [&"housing", &"comfort"] as Array[StringName]
	house.cost = {&"timber": 80, &"stone": 60, &"scrap": 30} as Dictionary[StringName, int]
	house.build_time_ticks = 1600
	house.demolish_time_ticks = 200
	house.refund_ratio = 0.55
	house.residents = 12
	house.heat_consumed = 9.0
	house.heat_buffer = 60.0
	house.heat_insulation = 0.6
	house.hp = 900.0
	house.build_priority = 70
	house.light_energy = 0.5
	house.tint = Color(0.58, 0.62, 0.72)
	out.append(house)

	# --------------------------------------------------------------- granary --
	var granary := _new("granary", "Granary",
		"Sealed bins on stilts, above the drift line. Keeps grain from freezing and rats from voting.",
		&"storage", 1)
	granary.size = Vector2i(3, 3)
	granary.sort_order = 120
	granary.tags = [&"storage", &"food"] as Array[StringName]
	granary.cost = {&"timber": 55, &"stone": 30} as Dictionary[StringName, int]
	granary.build_time_ticks = 1000
	granary.demolish_time_ticks = 120
	granary.workers_required = 1
	granary.storage_capacity = 500
	granary.storage_filter = [&"grain", &"ration"] as Array[StringName]
	granary.heat_consumed = 3.0
	granary.heat_insulation = 0.75
	granary.hp = 600.0
	granary.build_priority = 45
	granary.tint = Color(0.72, 0.68, 0.5)
	out.append(granary)

	# ---------------------------------------------------------- storage yard --
	var yard := _new("storage_yard", "Storage Yard",
		"Racks, tarpaulins and a gate. Everything the city is not using yet ends up here.",
		&"storage", 1)
	yard.size = Vector2i(3, 3)
	yard.sort_order = 130
	yard.tags = [&"storage", &"logistics"] as Array[StringName]
	yard.cost = {&"timber": 30, &"scrap": 20} as Dictionary[StringName, int]
	yard.build_time_ticks = 700
	yard.demolish_time_ticks = 90
	yard.refund_ratio = 0.7
	yard.storage_capacity = 1200
	yard.hp = 500.0
	yard.build_priority = 40
	yard.tint = Color(0.6, 0.6, 0.62)
	out.append(yard)

	# ------------------------------------------------------------ rubble road -
	var road := _new("rubble_road", "Rubble Road",
		"Crushed masonry rolled flat. Nothing moves quickly through a metre of snow, and this is the cheapest answer to that.",
		&"infrastructure", 1)
	road.size = Vector2i.ONE
	road.sort_order = 140
	road.tags = [&"road", &"surface"] as Array[StringName]
	road.cost = {&"stone": 2} as Dictionary[StringName, int]
	road.build_time_ticks = 15
	road.demolish_time_ticks = 4
	road.refund_ratio = 0.5
	road.blocks_movement = false
	road.walkable = true
	road.drag_mode = 2
	road.hp = 120.0
	road.build_priority = 30
	road.tint = Color(0.48, 0.5, 0.54)
	out.append(road)

	# ------------------------------------------------------------------ wall --
	var wall := _new("wall", "Wall",
		"Stacked stone and frozen mortar. It does not shoot back; it only decides where the shooting happens.",
		&"defense", 1)
	wall.size = Vector2i.ONE
	wall.sort_order = 150
	wall.tags = [&"wall", &"defense"] as Array[StringName]
	wall.cost = {&"stone": 6} as Dictionary[StringName, int]
	wall.build_time_ticks = 60
	wall.demolish_time_ticks = 20
	wall.refund_ratio = 0.5
	wall.drag_mode = 1
	wall.hp = 500.0
	wall.armor = 4.0
	wall.build_priority = 85
	wall.tint = Color(0.55, 0.58, 0.62)
	out.append(wall)

	# ---------------------------------------------------------- turret mount --
	var turret := _new("turret_mount", "Turret Mount",
		"A burner cannon on a swivel. It draws from the heat grid to fire, so every shot is warmth taken from someone's home.",
		&"defense", 1)
	turret.size = Vector2i(2, 2)
	turret.sort_order = 160
	turret.tags = [&"turret", &"defense", &"powered"] as Array[StringName]
	turret.cost = {&"iron_plate": 30, &"gear": 10, &"scrap": 20} as Dictionary[StringName, int]
	turret.build_time_ticks = 900
	turret.demolish_time_ticks = 120
	turret.refund_ratio = 0.6
	turret.workers_required = 1
	turret.weapon_id = &"burner_cannon"
	turret.heat_consumed = 6.0
	turret.heat_buffer = 40.0
	turret.storage_capacity = 60
	turret.storage_filter = [&"ammo_shell"] as Array[StringName]
	turret.vision_radius = 9.0
	turret.hp = 450.0
	turret.armor = 2.0
	turret.rotatable = true
	turret.rotation_symmetry = 4
	turret.build_priority = 90
	turret.light_energy = 0.4
	turret.tint = Color(0.8, 0.42, 0.36)
	out.append(turret)

	# ------------------------------------------------------------ watchtower --
	var tower := _new("watchtower", "Watchtower",
		"Timber frame, a brazier and someone with good eyes. You cannot shoot what you cannot see coming.",
		&"defense", 1)
	tower.size = Vector2i(2, 2)
	tower.sort_order = 170
	tower.tags = [&"vision", &"defense"] as Array[StringName]
	tower.cost = {&"timber": 30, &"iron_plate": 10} as Dictionary[StringName, int]
	tower.build_time_ticks = 600
	tower.demolish_time_ticks = 60
	tower.refund_ratio = 0.7
	tower.workers_required = 1
	tower.vision_radius = 16.0
	tower.heat_consumed = 1.0
	tower.hp = 300.0
	tower.build_priority = 80
	tower.light_energy = 0.5
	tower.tint = Color(0.7, 0.6, 0.45)
	out.append(tower)

	return out
