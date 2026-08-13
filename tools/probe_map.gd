extends Node
func _ready() -> void:
	SimClock.set_manual(true)
	Sim.create_world(7)
	var g: SimSystem = Sim.get_system(&"grid")
	var core: Vector2i = g.call("core_cell")
	print("PROBE core=", core, " size=", g.call("map_size"))
	var wg: Variant = g.get("grid")
	for r: int in [0, 5, 10, 15, 20, 25, 30]:
		var line: String = ""
		for dx: int in [-r, 0, r]:
			var c: Vector2i = core + Vector2i(dx, 0)
			line += "%s:t%d free=%s  " % [str(c), wg.call("terrain_at", c), str(wg.call("is_free", c, Vector2i(1, 1)))]
		print("PROBE r", r, " ", line)
	for kind: int in [1, 2, 3, 6]:
		var c2: Vector2i = wg.call("find_nearest_resource", core, kind, 90)
		print("PROBE res kind ", kind, " nearest ", c2, " dist ", (Vector2(c2 - core)).length() if c2.x >= 0 else -1.0, " amount ", wg.call("resource_amount_at", c2) if c2.x >= 0 else 0)
	var rows: Array[String] = []
	for dy: int in range(-40, 41, 2):
		var s: String = ""
		for dx: int in range(-40, 41):
			var c3: Vector2i = core + Vector2i(dx, dy)
			s += "#" if not bool(wg.call("is_free", c3, Vector2i(1, 1))) else "."
		rows.append(s)
	for r2: String in rows:
		print("PROBE MAP ", r2)
	get_tree().quit(0)
