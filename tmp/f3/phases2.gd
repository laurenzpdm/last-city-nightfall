extends Node
func _ready() -> void:
	var clock: Node = get_node("/root/SimClock")
	var sim: Node = get_node("/root/Sim")
	clock.call("set_manual", true)
	sim.call("create_world", 7)
	var cl: Object = sim.call("get_system", &"climate")
	var want: Array = [
		["opening", 30], ["build", 900], ["midday", 2200], ["dusk", 3800],
		["assault", 5200], ["deep_night", 6900], ["dawn", 8060],
		["second_day_factory", 11800], ["second_dusk", 13400],
		["second_night", 14800], ["third_day_city", 21400],
	]
	var at: int = 0
	for s: Array in want:
		clock.call("advance", maxi(0, int(s[1]) - at))
		at = maxi(at, int(s[1]))
		print("PROPOSED %-22s sim t=%-6d day %d  phase=%-12s progress=%.2f" % [
			str(s[0]), int(s[1]), int(cl.call("day")), str(cl.call("phase_of_day")), float(cl.call("phase_progress"))])
	get_tree().quit()
