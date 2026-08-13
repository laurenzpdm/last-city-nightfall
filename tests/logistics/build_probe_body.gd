extends RefCounted
## [P03] Probe body: the whole automation pillar exercised through the SAME
## command path a player's click produces. Loaded by path once autoloads exist.

const ARROW: Array[String] = ["→", "↓", "←", "↑"]


func run() -> void:
	Log.min_level = Log.Level.WARN
	_catalogue()
	_drag()
	_splitters()
	_throughput()
	_fuel()


func _fresh() -> LogisticsSystem:
	SimClock.set_manual(true)
	Sim.create_world(7)
	Sim.submit_command({"system": &"build", "op": "add_stock", "items": {
		"iron_plate": 900, "gear": 400, "timber": 300, "scrap": 400,
		"steel_plate": 300, "stone": 400, "circuit": 100}})
	Sim.submit_command({"system": &"build", "op": "grant_unlock", "unlock": "belt_gearing"})
	Sim.submit_command({"system": &"build", "op": "grant_unlock", "unlock": "driven_rollers"})
	SimClock.advance(2)
	return Sim.get_system(&"logistics") as LogisticsSystem


func _catalogue() -> void:
	var logi: LogisticsSystem = _fresh()
	var build: SimSystem = Sim.get_system(&"build")
	print("")
	print("-- the build catalogue --")
	var available: Dictionary[StringName, bool] = {}
	for d: BuildingDef in build.call("available_defs"):
		available[d.id] = true
	for def: LogiDef in logi.all_defs():
		var bd: BuildingDef = build.call("def_of", def.id)
		print(" %-18s buildable=%-5s in-palette-now=%-5s cost=%s" % [
			String(def.id), str(bd != null), str(available.has(def.id)),
			"" if bd == null else str(bd.cost)])


func _drag() -> void:
	var logi: LogisticsSystem = _fresh()
	print("")
	print("-- one drag: (40,40) east to (50,40), then south to (50,46) --")
	Sim.submit_command({"system": &"build", "op": "place_line", "kind": "belt_mk1",
		"from": [40, 40], "to": [50, 46], "rot": 0})
	SimClock.advance(120)
	var row: String = ""
	for i: int in 11:
		row += _facing(logi, Vector2i(40 + i, 40))
	for j: int in range(1, 7):
		row += _facing(logi, Vector2i(50, 40 + j))
	print(" facings along the drag: %s" % row)
	print(" transport lines: %d, pieces adopted: %d" % [
		logi.world.segment_ids.size(), int(logi.metrics()["placed_by_player"])])
	# And it carries something.
	Sim.submit_command({"system": &"build", "op": "place", "kind": "crate",
		"cell": [50, 47], "free": true, "instant": true})
	SimClock.advance(30)
	for _i: int in 40:
		logi.world.push_onto_belt(Vector2i(40, 40), 0, &"coal")
		logi.world.push_onto_belt(Vector2i(40, 40), 1, &"coal")
		SimClock.advance(1)
	SimClock.advance(400)
	var store: LogiStore = logi.store_of(_id_at(logi, Vector2i(50, 47)))
	print(" coal that made it round the corner into the crate: %d" % (
		0 if store == null else store.count(&"coal")))


func _facing(logi: LogisticsSystem, cell: Vector2i) -> String:
	var e: LogiEntity = logi.entity_at(cell)
	return "·" if e == null else ARROW[posmod(e.rot, 4)]


func _id_at(logi: LogisticsSystem, cell: Vector2i) -> int:
	var e: LogiEntity = logi.entity_at(cell)
	return -1 if e == null else e.id


func _splitters() -> void:
	var logi: LogisticsSystem = _fresh()
	var build: SimSystem = Sim.get_system(&"build")
	print("")
	print("-- splitter footprint, both sides agreeing --")
	for rot: int in 4:
		var origin: Vector2i = Vector2i(60 + rot * 4, 60)
		Sim.submit_command({"system": &"build", "op": "place", "kind": "splitter_mk1",
			"cell": [origin.x, origin.y], "rot": rot, "free": true, "instant": true})
	SimClock.advance(40)
	for rot2: int in 4:
		var origin2: Vector2i = Vector2i(60 + rot2 * 4, 60)
		var b: Object = build.call("building_at", origin2)
		var sp: LogiSplitter = logi.entity_at(origin2) as LogiSplitter
		print(" rot %d %s  build %s  splitter anchor %s  inputs %s  outputs %s" % [
			rot2, ARROW[rot2],
			str(b.get("cells")) if b != null else "?",
			str(sp.cell) if sp != null else "?",
			str(sp.input_cells()) if sp != null else "?",
			str(sp.output_cells()) if sp != null else "?"])


func _fuel() -> void:
	var logi: LogisticsSystem = _fresh()
	var heat: SimSystem = Sim.get_system(&"heat")
	print("")
	print("-- coal down a belt into a generator, then the belt is cut --")
	var g: Vector2i = _find_site()
	if g == Vector2i.MAX:
		print("  no buildable site found — nothing to say")
		return
	print("  site: crate %s  arm %s  belt %s..%s  arm %s  generator %s" % [
		str(g - Vector2i(10, 0)), str(g - Vector2i(9, 0)), str(g - Vector2i(8, 0)),
		str(g - Vector2i(2, 0)), str(g - Vector2i(1, 0)), str(g)])
	Sim.submit_command({"system": &"build", "op": "set_stock", "items": {"coal": 0}})
	Sim.submit_command({"system": &"build", "op": "place", "kind": "coal_generator",
		"cell": [g.x, g.y], "free": true, "instant": true})
	Sim.submit_command({"system": &"build", "op": "place", "kind": "heat_pipe",
		"cell": [g.x + 3, g.y], "free": true, "instant": true})
	Sim.submit_command({"system": &"build", "op": "place", "kind": "warmth_radiator",
		"cell": [g.x + 4, g.y], "free": true, "instant": true})
	Sim.submit_command({"system": &"build", "op": "place", "kind": "crate",
		"cell": [g.x - 10, g.y], "free": true, "instant": true})
	Sim.submit_command({"system": &"build", "op": "place", "kind": "inserter_mk1",
		"cell": [g.x - 9, g.y], "rot": 0, "free": true, "instant": true})
	Sim.submit_command({"system": &"build", "op": "place_line", "kind": "belt_mk1",
		"from": [g.x - 8, g.y], "to": [g.x - 2, g.y], "rot": 0})
	Sim.submit_command({"system": &"build", "op": "place", "kind": "inserter_mk1",
		"cell": [g.x - 1, g.y], "rot": 0, "free": true, "instant": true})
	SimClock.advance(60)
	Sim.submit_command({"system": &"logistics", "op": "insert",
		"cell": [g.x - 10, g.y], "item": "coal", "count": 400})
	SimClock.advance(1)
	var gen: int = _building_id_at(g)
	var cut: Vector2i = g - Vector2i(5, 0)
	for t: int in 6:
		SimClock.advance(200)
		print("  t%5d  bunker %6.1f  supply %6.2f  fuel_by_machine %d  line_fed %d" % [
			SimClock.tick, float(heat.call("fuel_stock_of", gen)),
			float((heat.call("totals") as Dictionary)["supply"]),
			int(logi.metrics()["fuel_by_machine"]), int(logi.metrics()["line_fed_burners"])])
	print("  ✂ cutting the belt at %s" % str(cut))
	Sim.submit_command({"system": &"build", "op": "remove",
		"cell": [cut.x, cut.y], "instant": true})
	for t2: int in 14:
		SimClock.advance(400)
		print("  t%5d  bunker %6.1f  supply %6.2f  dry lines %d  hauled %d" % [
			SimClock.tick, float(heat.call("fuel_stock_of", gen)),
			float((heat.call("totals") as Dictionary)["supply"]),
			int(logi.metrics()["lines_dry"]), int(logi.metrics()["hauled_total"])])


## A generator origin with ten clear tiles of ground running west out of it.
## Searched rather than hard-coded so the probe survives a different world seed.
func _find_site() -> Vector2i:
	var build: SimSystem = Sim.get_system(&"build")
	for y: int in range(30, 220, 3):
		for x: int in range(30, 220, 3):
			var g := Vector2i(x, y)
			if not bool((build.call("can_place", &"coal_generator", g, 0, false, -1) as Dictionary)["ok"]):
				continue
			var clear: bool = true
			for i: int in range(1, 11):
				if not bool((build.call("can_place", &"belt_mk1", g - Vector2i(i, 0), 0, false, -1) as Dictionary)["ok"]):
					clear = false
					break
			# Room east of it for a pipe and a radiator, so the generator has
			# somewhere to send its heat. A burner nobody draws from never burns
			# a lump of coal and a cut belt would cost nothing. Tested with a
			# pipe on every cell: the radiator itself must_connect to heat, which
			# nothing offers until the generator is standing there.
			for c: Vector2i in [Vector2i(3, 0), Vector2i(4, 0), Vector2i(4, 1),
					Vector2i(5, 0), Vector2i(5, 1)]:
				if not clear:
					break
				if not bool((build.call("can_place", &"heat_pipe", g + c, 0, false, -1) as Dictionary)["ok"]):
					clear = false
			if clear:
				return g
	return Vector2i.MAX


func _building_id_at(cell: Vector2i) -> int:
	var build: SimSystem = Sim.get_system(&"build")
	var b: Object = build.call("building_at", cell)
	return -1 if b == null else int(b.get("id"))
