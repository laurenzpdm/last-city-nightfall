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
	clock.call("advance", WARMUP)

	# Every tick here is ≡ 1 mod 100, so it triggers neither cadence; ≡ 20 mod
	# 100 recomputes the rate only; ≡ 0 mod 100 does both. Stepping by 100 keeps
	# each regime pure instead of averaging them together.
	var plain: float = _time(res, RUNS, 1000001)
	var rate: float = _time(res, RUNS / 10, 1000020)
	var pace: float = _time(res, RUNS / 100, 1000000)

	print("")
	print("research.step() cost, %d nodes in the tree" % (res.call("graph") as ResearchGraph).size())
	print("  ordinary tick        %8.3f us" % plain)
	print("  rate tick   (1 in 20)%8.3f us" % rate)
	print("  pacing tick (1 in 100)%7.3f us" % pace)
	var blended: float = (plain * 94.0 + rate * 5.0 + pace * 1.0) / 100.0
	print("  blended per tick     %8.3f us   (%.4f %% of the 50 ms budget)"
		% [blended, blended / 500.0])
	print("")
	var m: Dictionary = res.call("metrics")
	print("after %d ticks: %d researched, active '%s', %d available, %.2f insight/s" % [
		WARMUP, int(m["researched_count"]), String(m["active"]),
		int(m["unlocks_pending"]), float(m["rate"])])


## Average microseconds per step() call, always 100 ticks apart so every call in
## one measurement lands in the same cadence class.
func _time(res: SimSystem, runs: int, first_tick: int) -> float:
	var n: int = maxi(1, runs)
	var t0: int = Time.get_ticks_usec()
	for i: int in n:
		res.call("step", first_tick + i * 100)
	return float(Time.get_ticks_usec() - t0) / float(n)
