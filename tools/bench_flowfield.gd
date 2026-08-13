extends SceneTree
## Micro-benchmark for [P01]'s flow field, the one thing in this build with a
## 60+ ms worst case.
##
##   Godot --headless --path . --script tools/bench_flowfield.gd -- [--seed=4242] [--reps=20]
##
## Two numbers matter and they are different numbers:
##   FULL     a from-scratch Dijkstra over every reachable cell. What a goal
##            change costs.
##   REPAIR   the raise/lower path after n cells changed cost. What placing a
##            building — or an enemy chewing through a wall — costs, and the
##            case that produced a 68.8 ms spike on ONE changed cell, because
##            re-opening a hole near the core improves the integration of half
##            the map and the whole shadow has to be re-flooded.
##
## Reported as ms per operation and as cells per millisecond, because "it got
## faster" is only meaningful next to how much work it did.
##
## NOTE, and it is a sharp one: nothing in this file may name a `class_name`
## type. A --script SceneTree is compiled BEFORE the autoloads are registered,
## so naming FlowField here forces flow_field.gd to compile early, it dies on
## `Identifier not found: Log`, and the broken GDScript stays cached for the
## whole process — GridSystem then silently comes up with NO core field and the
## bench measures nothing at all. Everything below goes through Object.

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	quit(_execute())
	return true


func _execute() -> int:
	var world_seed: int = 4242
	var reps: int = 20
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			world_seed = int(arg.substr(7))
		elif arg.begins_with("--reps="):
			reps = maxi(1, int(arg.substr(7)))

	var sim: Node = root.get_node_or_null(^"Sim")
	var clock: Node = root.get_node_or_null(^"SimClock")
	var log_node: Node = root.get_node_or_null(^"Log")
	if sim == null or clock == null:
		print("bench: autoloads are missing")
		return 2
	if log_node != null:
		log_node.set("min_level", 2)
	clock.call("set_manual", true)
	sim.call("create_world", world_seed)

	var grid_sys: Object = sim.call("get_system", &"grid")
	if grid_sys == null:
		print("bench: no grid system in this build")
		return 2
	var grid: Object = grid_sys.get("grid")
	var field: Object = grid_sys.call("get_field", &"core")
	if field == null:
		print("bench: no core flow field — see the note at the top of this file")
		return 2
	var cost: PackedByteArray = grid.get("cost")

	# --- full rebuild ---
	var t0: int = Time.get_ticks_usec()
	var visited: int = 0
	for _i: int in reps:
		field.call("rebuild", cost)
		visited += int(field.get("last_visited"))
	var full_us: float = float(Time.get_ticks_usec() - t0) / float(reps)
	var full_cells: float = float(visited) / float(reps)

	# --- repair after one cell re-opened next to the core ---
	# The pathological case: a cell adjacent to the goal changing cost lifts the
	# integration of everything behind it, so the shadow is most of the map.
	var field_goals: PackedInt32Array = field.get("goals")
	var core_idx: int = int(field_goals[0]) if field_goals.size() > 0 else 0
	var probe: int = core_idx + 3
	var changed: PackedInt32Array = PackedInt32Array([probe])
	field.call("rebuild", cost)
	var saved: int = cost[probe]
	var t1: int = Time.get_ticks_usec()
	var rvisited: int = 0
	for i: int in reps:
		cost[probe] = 255 if (i % 2) == 0 else saved
		field.call("update", cost, changed)
		rvisited += int(field.get("last_visited"))
	var rep_us: float = float(Time.get_ticks_usec() - t1) / float(reps)
	var rep_cells: float = float(rvisited) / float(reps)
	cost[probe] = saved

	print("")
	print("── flow field bench (seed %d, %d reps) ──" % [world_seed, reps])
	print(" %-24s %10s %12s %14s" % ["operation", "ms", "cells", "cells/ms"])
	print(" %-24s %10.3f %12.0f %14.0f" % ["full rebuild", full_us / 1000.0,
		full_cells, full_cells / maxf(full_us / 1000.0, 0.001)])
	print(" %-24s %10.3f %12.0f %14.0f" % ["repair, 1 cell at core", rep_us / 1000.0,
		rep_cells, rep_cells / maxf(rep_us / 1000.0, 0.001)])
	print("")
	return 0
