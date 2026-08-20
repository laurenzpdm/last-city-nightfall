extends Node
func _ready() -> void:
	var clock: Node = get_node("/root/SimClock")
	var sim: Node = get_node("/root/Sim")
	clock.call("set_manual", true)
	var boot: Script = load("res://game/boot.gd")
	for seed: int in [1, 2, 3, 7, 11, 23, 99, 1234]:
		sim.call("create_world", seed)
		clock.call("advance", 1)
		var build: Object = sim.call("get_system", &"build")
		var grid: Object = sim.call("get_system", &"grid")
		var c: Vector2i = grid.call("core_cell")
		var refusals: PackedStringArray = PackedStringArray()
		for cmd: Dictionary in boot.call("opening_commands", c):
			var r: Dictionary = build.call("execute", cmd)
			if not bool(r.get("ok", false)):
				refusals.append("%s %s %s: %s" % [str(cmd.get("op","?")), str(cmd.get("kind","?")),
					str(cmd.get("cell", cmd.get("from",""))), str(r.get("reason",""))])
		clock.call("advance", 1)
		var heat: Object = sim.call("get_system", &"heat")
		var drills: int = 0
		for b: BuildingInstance in build.call("all_buildings"):
			if b.kind == &"ore_drill":
				drills += 1
		print("SEED %-5d coal_seam=%s cheb=%d drills=%d nets=%d refusals=%d %s" % [
			seed, str(boot.call("coal_seam", c)),
			maxi(absi(int(boot.call("coal_seam", c).x) - c.x), absi(int(boot.call("coal_seam", c).y) - c.y)),
			drills, int(heat.call("network_ids").size()), refusals.size(),
			str(Array(refusals)).substr(0, 400)])
		print("   DEFECTS: ", boot.call("opening_defects"))
	get_tree().quit()
