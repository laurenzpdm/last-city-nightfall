extends Node
func _ready() -> void:
	var clock: Node = get_node("/root/SimClock")
	var sim: Node = get_node("/root/Sim")
	clock.call("set_manual", true)
	var boot: Script = load("res://game/boot.gd")
	for seed: int in [7, 3]:
		sim.call("create_world", seed)
		clock.call("advance", 1)
		var gs: Object = sim.call("get_system", &"grid")
		var g: Object = gs.get("grid")
		var c: Vector2i = gs.call("core_cell")
		var seam: Vector2i = boot.call("coal_seam", c)
		var road: Array = boot.call("road_to_core", seam)
		var s: PackedStringArray = PackedStringArray()
		var prev := Vector2i(9999, 9999)
		for cell: Vector2i in road:
			var fl: int = int(g.call("flags_at", cell))
			var mark: String = ""
			if (fl & 2) == 0: mark += "!UNBUILDABLE"
			if prev.x != 9999 and (absi(cell.x-prev.x) + absi(cell.y-prev.y)) != 1: mark += "!JUMP(from %s)" % str(prev)
			prev = cell
			if mark != "": s.append("%s%s" % [str(cell), mark])
		print("SEED %d seam %s core %s road len %d  end %s  problems: %s" % [
			seed, str(seam), str(c), road.size(), str(road[-1]) if road.size() > 0 else "-", str(Array(s)).substr(0,400)])
	get_tree().quit()
