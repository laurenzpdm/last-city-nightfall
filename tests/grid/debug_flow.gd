extends SceneTree
## Temporary diagnostic: shrinks an incremental-repair mismatch to its smallest
## reproducing case and prints the neighbourhood of the first cell that differs.

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var w: int = 24
	var h: int = 24
	var g := WorldGrid.new(w, h)
	g.rebuild_all_costs()
	var goals := PackedInt32Array([g.index_of(Vector2i(12, 12))])
	var live := FlowField.new()
	live.setup(w, h, &"live")
	live.set_goals(goals)
	live.rebuild(g.cost)
	g.take_dirty(1 << 30)

	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for step: int in range(40):
		var id: int = 100 + step
		var cell := Vector2i(rng.randi_range(2, w - 4), rng.randi_range(2, h - 4))
		var sz := Vector2i(rng.randi_range(1, 3), rng.randi_range(1, 3))
		var did: bool = g.occupy(cell, sz, id)
		var dirty: PackedInt32Array = g.take_dirty(1 << 30)
		live.update(g.cost, dirty)
		var fresh := FlowField.new()
		fresh.setup(w, h, &"fresh")
		fresh.set_goals(goals)
		fresh.rebuild(g.cost)
		if live.integration != fresh.integration:
			print("MISMATCH at step %d after %s %s (%s)" % [step, cell, sz, "placed" if did else "refused"])
			_report(g, live, fresh)
			quit(0)
			return true
	print("no mismatch in 40 placements")
	quit(0)
	return true


func _report(g: WorldGrid, live: FlowField, fresh: FlowField) -> void:
	var n: int = 0
	for i: int in range(live.integration.size()):
		if live.integration[i] == fresh.integration[i]:
			continue
		n += 1
		if n > 3:
			continue
		var c: Vector2i = g.cell_of(i)
		print("  cell %s cost=%d live=%d fresh=%d livedir=%d freshdir=%d" % [
			c, g.cost[i], live.integration[i], fresh.integration[i], live.direction[i], fresh.direction[i]])
		for d: int in range(8):
			var nb: Vector2i = c + Grid.DIRS8[d]
			var ni: int = g.index_of(nb)
			print("     nb %s d=%d cost=%d live=%d fresh=%d livedir=%d" % [
				nb, d, g.cost[ni], live.integration[ni], fresh.integration[ni], live.direction[ni]])
	print("  total differing cells: %d" % n)
