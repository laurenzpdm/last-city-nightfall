extends Node
## Does a seeded ore drill on the nearest coal seam actually feed the burners?

func _ready() -> void:
	var clock: Node = get_node("/root/SimClock")
	var sim: Node = get_node("/root/Sim")
	clock.call("set_manual", true)
	sim.call("create_world", 7)
	var build: Object = sim.call("get_system", &"build")
	var grid: Object = sim.call("get_system", &"grid")
	var c: Vector2i = grid.call("core_cell")
	for cmd: Dictionary in load("res://game/boot.gd").call("opening_commands", c):
		build.call("execute", cmd)
	var seam: Vector2i = grid.call("nearest_resource", c, 2, 90)
	print("SEAM ", seam)
	# Dogleg pipe from the north stub of the hearth to a tile beside the seam.
	var start: Vector2i = c + Vector2i(0, -3)
	var stop: Vector2i = seam + Vector2i(0, 2)
	var r1: Dictionary = build.call("execute", {"op": "place_line", "kind": "heat_pipe",
		"from": [start.x, start.y], "to": [stop.x, stop.y], "free": true, "instant": true})
	print("PIPE ", JSON.stringify(r1))
	var r2: Dictionary = build.call("execute", {"op": "place", "kind": "ore_drill",
		"cell": [seam.x - 1, seam.y - 1], "rot": 0, "free": true, "instant": true})
	print("DRILL ", JSON.stringify(r2))
	var heat: Object = sim.call("get_system", &"heat")
	var at: int = 0
	for m: int in [20, 600, 2000, 4000, 6000]:
		clock.call("advance", m - at)
		at = m
		var stock: Variant = build.call("stock_count", &"coal")
		var nets: int = int((heat.call("totals") as Dictionary).get("networks", -1))
		var fuel: Array = []
		for b: BuildingInstance in build.call("all_buildings"):
			if b.kind == &"the_hearth" or b.kind == &"coal_generator" or b.kind == &"ore_drill":
				fuel.append("%s=%.0f(net %d,pf %.2f,w %d)" % [b.kind, heat.call("fuel_stock_of", b.id), heat.call("network_of", b.id), heat.call("power_factor", b.id), b.workers])
		print("T%-6d coal_stock=%s nets=%d %s" % [m, str(stock), nets, " ".join(fuel)])
	get_tree().quit()
