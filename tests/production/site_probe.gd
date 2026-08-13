extends SceneTree
## Scratch: prints a buildable factory site for seed 7 so the demo scenario can
## be written against real ground instead of guessed coordinates.

var _done: bool = false


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true


func _run() -> void:
	var sim: Node = root.get_node_or_null("/root/Sim")
	var clock: Node = root.get_node_or_null("/root/SimClock")
	clock.call("set_manual", true)
	sim.call("create_world", 7)
	var build: Object = sim.call("get_system", &"build")
	var grid: Object = sim.call("get_system", &"grid")
	var core: Vector2i = grid.call("core_cell")
	print("core ", core)

	for ring: int in 40:
		for sign: int in [1, -1]:
			var y: int = core.y + ring * sign
			for dx: int in range(4, 40):
				for sx: int in [1, -1]:
					var x0: int = core.x + dx * sx
					if _plan(build, x0, y):
						print("SITE x0=%d y=%d" % [x0, y])
						_mine(build, grid, core)
						quit(0)
						return
			if ring == 0:
				break
	print("NO SITE")
	quit(1)


## A drill on the nearest seam of each kind, with a generator and a pipe between
## them, since two machines standing side by side are not connected.
func _mine(build: Object, grid: Object, core: Vector2i) -> void:
	for kind: int in [3, 4, 2, 5, 1]:
		var seam: Vector2i = grid.call("nearest_resource", core, kind, 80)
		if seam.x < 0:
			continue
		var drill: Vector2i = seam - Vector2i(1, 1)
		var pipe: Vector2i = Vector2i(seam.x + 2, seam.y)
		var gen: Vector2i = Vector2i(seam.x + 3, seam.y - 1)
		var ok: bool = _fits(build, "ore_drill", drill) and _fits(build, "heat_pipe", pipe) \
			and _fits(build, "coal_generator", gen)
		print("  MINE kind=%d seam=%s amount=%s drill=%s pipe=%s gen=%s fits=%s" % [
			kind, str(seam), str(grid.call("resource_amount_at", seam)),
			str(drill), str(pipe), str(gen), str(ok)])


func _plan(build: Object, x0: int, y: int) -> bool:
	for i: int in 22:
		if not _fits(build, "heat_pipe", Vector2i(x0 + i, y)):
			return false
	# hearth, two 4x3 shops and a 4x4 hall above; smelters, recuperator,
	# sorter and two housing blocks below.
	var plan: Array = [
		["the_hearth", Vector2i(x0 - 5, y - 2)],
		["workshop", Vector2i(x0, y - 3)],
		["workshop", Vector2i(x0 + 5, y - 3)],
		["assembly_hall", Vector2i(x0 + 10, y - 4)],
		["rubble_sorter", Vector2i(x0 + 15, y - 2)],
		["smelter", Vector2i(x0, y + 1)],
		["smelter", Vector2i(x0 + 4, y + 1)],
		["recuperator", Vector2i(x0 + 8, y + 1)],
		["smelter", Vector2i(x0 + 11, y + 1)],
		["housing_block", Vector2i(x0 + 15, y + 1)],
		["housing_block", Vector2i(x0 + 19, y + 1)],
	]
	for e: Variant in plan:
		var entry: Array = e
		if not _fits(build, String(entry[0]), entry[1]):
			return false
	return true


func _fits(build: Object, kind: String, cell: Vector2i) -> bool:
	var r: Dictionary = build.call("can_place", StringName(kind), cell, 0, false)
	return bool(r.get("ok", false))
