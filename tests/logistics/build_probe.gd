extends SceneTree
## [P03] The player-path probe. NOT part of the gate: the file name is outside
## the runner's discovery patterns (test_*, run_*, *.tscn) on purpose.
##
##   godot --headless --path . --script tests/logistics/build_probe.gd
##
## It answers the question a critic asks first: can a human actually put a belt
## down, and does dragging one behave the way the genre has taught them?
##
## The body is loaded BY PATH inside _process, never at compile time: under
## --script a file is compiled before the autoloads are registered, and any
## mention of Log or Sim at that point fails to compile.

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var scr: GDScript = load("res://tests/logistics/build_probe_body.gd")
	if scr == null:
		print("PROBE FAILED — could not load tests/logistics/build_probe_body.gd")
		quit(1)
		return true
	scr.new().call("run")
	quit(0)
	return true
