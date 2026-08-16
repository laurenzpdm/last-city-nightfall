extends Node
func _ready() -> void:
	var sim: Node = get_node("/root/Sim")
	get_node("/root/SimClock").call("set_manual", true)
	sim.call("create_world", 7)
	var grid: Object = sim.call("get_system", &"grid")
	var c: Vector2i = grid.call("core_cell")
	print("core ", c)
	for kind: int in [1, 2, 3, 4, 5, 6]:
		var name: String = ["none","scrap","coal","iron","copper","sulfur","vent"][kind]
		var best: Vector2i = grid.call("nearest_resource", c, kind, 120)
		if best.x < 0:
			print("%-8s none within 120" % name); continue
		var amt: int = grid.call("resource_amount_at", best)
		# count the patch
		var n: int = 0
		var tot: int = 0
		for dy: int in range(-8, 9):
			for dx: int in range(-8, 9):
				var q := best + Vector2i(dx, dy)
				if int(grid.call("resource_kind_at", q)) == kind:
					n += 1
					tot += int(grid.call("resource_amount_at", q))
		print("%-8s at %s  cheb %d  amt %d  patch %d tiles / %d units" % [name, str(best), maxi(absi(best.x-c.x), absi(best.y-c.y)), amt, n, tot])
	get_tree().quit()
