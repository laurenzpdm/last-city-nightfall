extends SceneTree
## [P03] Bench and diagnostic rig. NOT part of the gate: the file name is
## outside the runner's discovery patterns (test_*, run_*, *.tscn) on purpose,
## so tools/check.sh never runs it.
##
##   godot --headless --path . --script tests/logistics/perf_probe.gd
##
## It answers the two questions a critic will ask:
##   1. does a belt carry what its tooltip says?
##   2. what does LogisticsSystem.step() cost at a real factory scale?
##
## The body is loaded BY PATH inside _process, never at compile time: under
## --script a file is compiled before the autoloads are registered, and any
## mention of Log or Sim at that point fails to compile.

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var scr: GDScript = load("res://tests/logistics/perf_body.gd")
	if scr == null:
		print("PROBE FAILED — could not load tests/logistics/perf_body.gd")
		quit(1)
		return true
	scr.new().call("run")
	quit(0)
	return true
