extends SceneTree
## Standalone runner for the [P01] grid suite.
##   godot --headless --path . --script tests/grid/run_grid_tests.gd
## Exit code is 0 when green, 1 when anything failed.
##
## The suite is loaded inside _process, not _initialize, and by path rather than
## by class name: under --script the autoload singletons (Log, Rng, Registry) are
## only registered after the first frame, and compiling the tests any earlier
## would fail on identifiers that do not exist yet.

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var scr: GDScript = load("res://tests/grid/grid_tests.gd")
	if scr == null:
		print("TESTS FAILED — could not load tests/grid/grid_tests.gd")
		quit(1)
		return true
	var suite: Object = scr.new()
	var t0: int = Time.get_ticks_msec()
	var r: Dictionary = suite.call("run_all")
	var ms: int = Time.get_ticks_msec() - t0

	print("")
	for n: String in r["notes"] as PackedStringArray:
		print("  · %s" % n)
	print("")
	for f: String in r["failures"] as PackedStringArray:
		print("  FAIL  %s" % f)
	var failed: int = int(r["failed"])
	print("")
	print("grid: %d passed, %d failed in %d ms" % [int(r["passed"]), failed, ms])
	print("TESTS PASSED" if failed == 0 else "TESTS FAILED")
	quit(1 if failed > 0 else 0)
	return true
