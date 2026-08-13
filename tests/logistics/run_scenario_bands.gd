extends SceneTree
## [P03] Runs the logistics scenarios and holds them to the bands they declare.
##
## Discovered by tools/check.sh through the `run_*.gd` naming contract, so it is
## part of the gate. It prints TESTS PASSED / TESTS FAILED, which the gate reads.
##
## WHY IT EXISTS. A scenario with no expectations is a run that cannot fail. The
## reference run reported `logistics.belt_lines = 0` and `items_moved = 0` for
## twenty-four thousand ticks and the gate stayed green, because nothing asserted
## that those numbers should be anything else. Every scenario in tests/logistics/
## now carries `expects.metrics: {key: [low, high]}` and this suite enforces them
## against the metrics the simulation actually produced.
##
## The body is loaded BY PATH inside _process: under --script a file compiles
## before the autoloads are registered, and any mention of Sim at that point
## fails to compile.

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var scr: GDScript = load("res://tests/logistics/scenario_bands_body.gd")
	if scr == null:
		print("TESTS FAILED — could not load tests/logistics/scenario_bands_body.gd")
		quit(1)
		return true
	quit(0 if bool(scr.new().call("run")) else 1)
	return true
