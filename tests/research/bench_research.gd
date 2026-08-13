extends SceneTree
## Profiler for [P10]. Not a test — the gate ignores it (a suite entry point is
## `test_*.gd`, `run_*.gd` or a `.tscn`), because a wall-clock number is a
## measurement, not an assertion. test_research.gd carries the assertion.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##       --script tests/research/bench_research.gd
##
## It reports the per-tick cost of ResearchSystem.step() in three regimes:
## an ordinary tick, a tick that recomputes the insight rate (every 20), and a
## tick that resamples the pacing engine (every 100). The third is the only
## expensive one and it is the one that runs least often.

const WARMUP: int = 200
const RUNS: int = 20000

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	quit(0)
	return true


func _run() -> void:
	var sim: Node = root.get_node_or_null(NodePath("/root/Sim"))
	var clock: Node = root.get_node_or_null(NodePath("/root/SimClock"))
	if sim == null or clock == null:
		printerr("no autoloads; run through Godot with the project's project.godot")
		return
	clock.call("set_manual", true)
	sim.call("create_world", 7)
	var res: SimSystem = sim.call("get_system", &"research") as SimSystem
	if res == null:
		printerr("research system is not in this build")
		return
	res.call("execute", {"op": "set_auto", "on": true})
	var build: SimSystem = sim.call("get_system", &"build") as SimSystem
	if build != null:
		build.call("execute", {"op": &"set_stock", "items": {
			"iron_plate": 9000, "steel_plate": 9000, "stone": 9000, "timber": 9000,
			"scrap": 9000, "gear": 9000, "copper_coil": 9000, "coal": 9000,
			"pipe_segment": 9000, "insulation_wool": 9000,
		}})
	clock.call("advance", WARMUP)

	# Consecutive ticks on purpose: the 1-in-20 rate recompute and the 1-in-100
	# pacing sample then occur at exactly the frequency they occur in play, so
	# the average IS the per-tick cost rather than a weighted guess.
	var early: float = _time(res, RUNS, 1000000)
	var m1: Dictionary = res.call("metrics")

	# Empty the yard and measure again: every tick is now a project that cannot
	# buy its next instalment, which is the pathological case for this system.
	if build != null:
		build.call("execute", {"op": &"set_stock", "items": {
			"iron_plate": 0, "steel_plate": 0, "stone": 0, "timber": 0, "scrap": 0,
			"gear": 0, "copper_coil": 0, "coal": 0, "pipe_segment": 0,
		}})
	var starved: float = _time(res, RUNS, 3000000)
	var m2: Dictionary = res.call("metrics")

	print("")
	print("research.step() cost, %d nodes in the tree, %d consecutive ticks per sample"
		% [(res.call("graph") as ResearchGraph).size(), RUNS])
	print("  mid-campaign %8.3f us/tick   (%.4f %% of the 50 ms budget)"
		% [early, early / 500.0])
	print("  empty yard   %8.3f us/tick   (%.4f %% of the 50 ms budget)"
		% [starved, starved / 500.0])
	print("")
	print("  mid-campaign: %d researched, active '%s', %d available, %.2f insight/s" % [
		int(m1["researched_count"]), String(m1["active"]),
		int(m1["unlocks_pending"]), float(m1["rate"])])
	print("  empty yard:   %d researched, stalled=%d" % [
		int(m2["researched_count"]), int(m2["stalled"])])


## Average microseconds per step() call over consecutive ticks.
func _time(res: SimSystem, runs: int, first_tick: int) -> float:
	var n: int = maxi(1, runs)
	var t0: int = Time.get_ticks_usec()
	for i: int in n:
		res.call("step", first_tick + i)
	return float(Time.get_ticks_usec() - t0) / float(n)
