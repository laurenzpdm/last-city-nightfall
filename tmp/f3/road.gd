extends Node
func _ready() -> void:
	var clock: Node = get_node("/root/SimClock")
	var sim: Node = get_node("/root/Sim")
	clock.call("set_manual", true)
	var boot: Script = load("res://game/boot.gd")
	for seed: int in [3, 11]:
		sim.call("create_world", seed)
		clock.call("advance", 1)
		var grid: Object = sim.call("get_system", &"grid")
		var g: Object = grid.get("grid")
		var c: Vector2i = grid.call("core_cell")
		var seam: Vector2i = boot.call("coal_seam", c)
		var drill: Vector2i = seam - Vector2i(1, 1)
		var elbow := Vector2i(c.x, drill.y + 1)
		print("SEED %d core %s seam %s drill %s elbow %s" % [seed, str(c), str(seam), str(drill), str(elbow)])
		var bad: PackedStringArray = PackedStringArray()
		var walk := func(a: Vector2i, b: Vector2i) -> void:
			var d: Vector2i = (b - a).sign()
			var p: Vector2i = a
			while true:
				var fl: int = int(g.call("flags_at", p))
				if (fl & 2) == 0:
					bad.append("%s terrain=%s" % [str(p), Grid.TERRAIN_NAMES[int(g.call("terrain_at", p))]])
				if p == b: break
				p += d
		walk.call(c + Vector2i(0, -3), elbow)
		if elbow.x < drill.x:
			walk.call(elbow, Vector2i(drill.x - 1, elbow.y))
		elif elbow.x > drill.x + 2:
			walk.call(elbow, Vector2i(drill.x + 3, elbow.y))
		print("   unbuildable tiles on the road: %d  %s" % [bad.size(), str(Array(bad)).substr(0, 500)])
	get_tree().quit()
