extends Node
## Which climate phase each of the reference run's shot ticks actually lands in.
func _ready() -> void:
	var clock: Node = get_node("/root/SimClock")
	var sim: Node = get_node("/root/Sim")
	clock.call("set_manual", true)
	sim.call("create_world", 7)
	var cl: Object = sim.call("get_system", &"climate")
	var shots: Array = JSON.parse_string(FileAccess.get_file_as_string("res://tests/scenarios/first_night.json")).get("shots", [])
	var at: int = 0
	for s: Dictionary in shots:
		var t: int = int(s.get("tick", 0))
		clock.call("advance", maxi(0, t - at))
		at = maxi(at, t)
		print("SHOT %-22s sim t=%-6d climate t=%-6d day %d  phase=%-12s progress=%.2f" % [
			str(s.get("name","")), t, int(cl.call("clock_tick")), int(cl.call("day")),
			str(cl.call("phase_of_day")), float(cl.call("phase_progress"))])
	get_tree().quit()
