extends Node

func _ready() -> void:
	var clock: Node = get_node("/root/SimClock")
	var sim: Node = get_node("/root/Sim")
	clock.call("set_manual", true)
	for s: int in [7, 1, 12345]:
		sim.call("create_world", s)
		var grid: Object = sim.call("get_system", &"grid")
		var c: Vector2i = grid.call("core_cell")
		var line: PackedStringArray = PackedStringArray()
		for kind: int in [1, 2, 3, 4, 5, 6]:
			var n: Vector2i = grid.call("nearest_resource", c, kind, 90)
			var d: int = -1 if n == Vector2i(-1, -1) else int(maxi(absi(n.x - c.x), absi(n.y - c.y)))
			line.append("kind%d=%s d=%d amt=%d" % [kind, str(n), d, grid.call("resource_amount_at", n) if d >= 0 else 0])
		print("SEED ", s, " core ", c, " :: ", " | ".join(line))
		sim.call("teardown")
	get_tree().quit()
