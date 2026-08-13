extends Node
## One-off profiler: replays a scenario, then times each sim system's step().
func _ready() -> void:
	var name: String = "stress_1000"
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--scenario="):
			name = a.substr(11)
	Log.min_level = Log.Level.ERROR
	SimClock.set_manual(true)
	var sc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/scenarios/%s.json" % name))
	var by_tick: Dictionary = {}
	for e: Dictionary in sc.get("script", []):
		var t: int = int(e.get("tick", 0))
		var arr: Array = by_tick.get(t, [])
		arr.append(e.get("cmd", {}))
		by_tick[t] = arr
	Sim.create_world(int(sc.get("seed", 7)))
	var warm: int = 1200
	for t: int in range(1, warm + 1):
		for c: Dictionary in by_tick.get(t, []):
			Sim.submit_command(c)
		SimClock.advance(1)
	var costs: Dictionary = {}
	var n: int = 300
	for i: int in n:
		SimClock.tick += 1
		for s: SimSystem in Sim.systems:
			var t0: int = Time.get_ticks_usec()
			s.step(SimClock.tick)
			var k: String = String(s.system_name())
			costs[k] = float(costs.get(k, 0.0)) + float(Time.get_ticks_usec() - t0)
	var keys: Array = costs.keys()
	keys.sort()
	var total: float = 0.0
	for k2: String in keys:
		total += costs[k2]
	for k3: String in keys:
		print("PERF %-10s %8.3f ms/tick" % [k3, float(costs[k3]) / float(n) / 1000.0])
	print("PERF %-10s %8.3f ms/tick  -> %.0f ticks/s" % ["TOTAL", total / float(n) / 1000.0, 1000.0 / (total / float(n) / 1000.0)])
	var pk: Array = HeatSystem.PROF.keys()
	pk.sort()
	for k4: String in pk:
		print("HEAT %-10s %8.3f ms/tick" % [k4, float(HeatSystem.PROF[k4]) / float(n + 1200) / 1000.0])
	var fk: Array = HeatFlow.PROF.keys()
	fk.sort()
	for k5: String in fk:
		print("FLOW %-10s %8.3f ms/tick" % [k5, float(HeatFlow.PROF[k5]) / float(n + 1200) / 1000.0])
	get_tree().quit(0)
