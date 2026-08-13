extends RefCounted
func run() -> void:
	Log.min_level = Log.Level.ERROR
	SimClock.set_manual(true)
	Sim.create_world(7)
	var build: SimSystem = Sim.get_system(&"build")
	var head: String = "    "
	for x: int in range(14, 60):
		head += str(x % 10)
	print(head)
	for y: int in range(20, 50):
		var row: String = "%3d " % y
		for x: int in range(14, 60):
			row += "." if bool((build.call("can_place", &"belt_mk1", Vector2i(x, y), 0, false, -1) as Dictionary)["ok"]) else "#"
		print(row)
