class_name GridTests
extends RefCounted
## [P01] test suite: geometry, chunk storage, occupancy, flow-field correctness,
## incremental repair, serialization, and world-generation sanity.
##
## The load-bearing test is [method _test_flow_incremental]: it places and
## removes buildings and asserts that the incrementally repaired field is
## byte-identical to a field rebuilt from scratch. That is the only way to trust
## a raise/lower repair, and it is where a subtle pathfinding bug would hide.
##
## Run: godot --headless --path . --script tests/grid/run_grid_tests.gd

var passed: int = 0
var failed: int = 0
var failures: PackedStringArray = PackedStringArray()
var notes: PackedStringArray = PackedStringArray()


static func run() -> Dictionary:
	return GridTests.new().run_all()


func run_all() -> Dictionary:
	_test_conversion()
	_test_iteration()
	_test_lines()
	_test_flood_fill()
	_test_chunk_storage()
	_test_occupancy()
	_test_occupancy_edges()
	_test_line_of_sight()
	_test_flow_basic()
	_test_flow_obstacle()
	_test_flow_corner_rule()
	_test_flow_incremental()
	_test_flow_sealed_room()
	_test_astar()
	_test_snow()
	_test_harvest()
	_test_serialization()
	_test_mapgen_determinism()
	_test_mapgen_sanity()
	_test_richness_gradient()
	_test_all_biomes()
	return {
		"passed": passed,
		"failed": failed,
		"failures": failures,
		"notes": notes,
	}


# ---------------------------------------------------------------- helpers

func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		failures.append(msg)


func eq_int(a: int, b: int, msg: String) -> void:
	check(a == b, "%s: got %d, expected %d" % [msg, a, b])


func note(msg: String) -> void:
	notes.append(msg)


## Flat, empty test world: all snow, impassable border, no buildings.
func _plain(w: int, h: int) -> WorldGrid:
	var g := WorldGrid.new(w, h)
	g.rebuild_all_costs()
	return g


func _wall(g: WorldGrid, x0: int, y0: int, x1: int, y1: int) -> void:
	for y: int in range(y0, y1 + 1):
		for x: int in range(x0, x1 + 1):
			g.set_terrain(Vector2i(x, y), Grid.Terrain.RIDGE)


func _field_for(g: WorldGrid, goals: PackedInt32Array) -> FlowField:
	var f := FlowField.new()
	f.setup(g.width, g.height, &"test")
	f.set_goals(goals)
	f.rebuild(g.cost)
	return f


## Every reachable cell must step to a neighbour whose integration is exactly its
## own minus the edge it crossed. Catches drift, stale directions and bad repairs.
func _validate(f: FlowField, g: WorldGrid, label: String) -> void:
	var bad: int = 0
	var orphan: int = 0
	for idx: int in range(g.width * g.height):
		if g.cost[idx] == Grid.IMPASSABLE:
			continue
		var v: int = f.integration[idx]
		if v == FlowField.UNREACHABLE:
			continue
		if v == 0:
			continue
		var d: int = f.direction[idx]
		if d >= 8:
			orphan += 1
			continue
		var step: Vector2i = Grid.DIRS8[d]
		var n: int = idx + step.y * g.width + step.x
		var w: int = FlowField.W_DIAG if (d & 1) == 1 else FlowField.W_ORTHO
		if f.integration[n] + g.cost[idx] * w != v:
			bad += 1
	eq_int(bad, 0, "%s: cells whose stored step does not match its cost" % label)
	eq_int(orphan, 0, "%s: reachable cells with no direction" % label)


# ---------------------------------------------------------------- geometry

func _test_conversion() -> void:
	check(Grid.cell_to_world(Vector2i(0, 0)) == Vector2(16, 16), "cell 0,0 centre is 16,16")
	check(Grid.cell_to_world(Vector2i(3, 2)) == Vector2(112, 80), "cell 3,2 centre")
	check(Grid.cell_origin(Vector2i(3, 2)) == Vector2(96, 64), "cell 3,2 origin")
	check(Grid.world_to_cell(Vector2(0, 0)) == Vector2i(0, 0), "world 0,0 -> cell 0,0")
	check(Grid.world_to_cell(Vector2(31.9, 31.9)) == Vector2i(0, 0), "world 31.9 stays in cell 0")
	check(Grid.world_to_cell(Vector2(32, 32)) == Vector2i(1, 1), "world 32 -> cell 1")
	check(Grid.world_to_cell(Vector2(-1, -1)) == Vector2i(-1, -1), "negative world floors down")
	check(Grid.world_to_cell(Vector2(-33, -33)) == Vector2i(-2, -2), "negative world floors again")
	for c: Vector2i in [Vector2i(0, 0), Vector2i(17, 3), Vector2i(-5, 9), Vector2i(255, 255)]:
		check(Grid.world_to_cell(Grid.cell_to_world(c)) == c, "round trip for %s" % c)
		check(Grid.unkey(Grid.key(c)) == c, "key round trip for %s" % c)
	check(Grid.footprint_center(Vector2i(4, 4), Vector2i(2, 2)) == Vector2(160, 160), "2x2 footprint centre")
	eq_int(Grid.footprint_cells(Vector2i(1, 1), Vector2i(3, 2)).size(), 6, "3x2 footprint cell count")
	eq_int(Grid.local_index(Vector2i(33, 34)), 2 * 32 + 1, "local index inside chunk")
	check(Grid.chunk_coord(Vector2i(33, 34)) == Vector2i(1, 1), "chunk coord")


func _test_iteration() -> void:
	eq_int(Grid.ring(Vector2i(5, 5), 0).size(), 1, "ring 0 is the centre")
	eq_int(Grid.ring(Vector2i(5, 5), 1).size(), 8, "ring 1 has 8 cells")
	eq_int(Grid.ring(Vector2i(5, 5), 3).size(), 24, "ring 3 has 24 cells")
	var seen: Dictionary[int, bool] = {}
	for c: Vector2i in Grid.ring(Vector2i(9, 9), 4):
		check(Grid.chebyshev(c, Vector2i(9, 9)) == 4, "ring cell at radius 4")
		check(not seen.has(Grid.key(c)), "ring has no duplicates")
		seen[Grid.key(c)] = true
	eq_int(Grid.spiral(Vector2i(0, 0), 2).size(), 1 + 8 + 16, "spiral 0..2 count")
	var sp: Array[Vector2i] = Grid.spiral(Vector2i(4, 4), 3)
	var prev: int = -1
	var monotone: bool = true
	for c: Vector2i in sp:
		var d: int = Grid.chebyshev(c, Vector2i(4, 4))
		if d < prev:
			monotone = false
		prev = d
	check(monotone, "spiral visits rings in order")
	eq_int(Grid.disc(Vector2i(0, 0), 1).size(), 5, "disc radius 1 is a plus shape")
	eq_int(Grid.rect_cells(Rect2i(2, 2, 3, 4)).size(), 12, "rect cells")
	eq_int(Grid.octile_cost(Vector2i(0, 0), Vector2i(3, 0)), 30, "octile straight")
	eq_int(Grid.octile_cost(Vector2i(0, 0), Vector2i(3, 3)), 42, "octile diagonal")
	eq_int(Grid.dir_index(Vector2i(0, -1)), 6, "north is index 6")
	eq_int(Grid.dir_opposite(1), 5, "opposite of SE is NW")


func _test_lines() -> void:
	var l: Array[Vector2i] = Grid.line(Vector2i(0, 0), Vector2i(5, 0))
	eq_int(l.size(), 6, "horizontal line length")
	check(l[0] == Vector2i(0, 0) and l[5] == Vector2i(5, 0), "line endpoints included")
	var d: Array[Vector2i] = Grid.line(Vector2i(0, 0), Vector2i(4, 4))
	eq_int(d.size(), 5, "exact diagonal line is 5 cells")
	var contiguous: bool = true
	var probe: Array[Vector2i] = Grid.line(Vector2i(2, 3), Vector2i(11, 7))
	for i: int in range(1, probe.size()):
		if Grid.chebyshev(probe[i], probe[i - 1]) != 1:
			contiguous = false
	check(contiguous, "line steps are contiguous")
	check(probe[probe.size() - 1] == Vector2i(11, 7), "line reaches its target")
	var sc: Array[Vector2i] = Grid.supercover(Vector2i(0, 0), Vector2i(3, 3))
	check(sc.size() > 4, "supercover includes clipped corners")
	var four_connected: bool = true
	for i: int in range(1, sc.size()):
		if Grid.manhattan(sc[i], sc[i - 1]) != 1:
			four_connected = false
	check(four_connected, "supercover never skips a shared edge")


func _test_flood_fill() -> void:
	var g: WorldGrid = _plain(24, 24)
	_wall(g, 10, 1, 10, 22)
	var mask: PackedByteArray = g.reachable_mask(Vector2i(5, 5))
	var left: int = 0
	var right: int = 0
	for idx: int in range(mask.size()):
		if mask[idx] == 0:
			continue
		if idx % 24 < 10:
			left += 1
		else:
			right += 1
	eq_int(right, 0, "wall splits the map: nothing on the far side is reachable")
	# Columns 1..9 inside the border ring, rows 1..22 (the wall spans y 1..22).
	eq_int(left, 9 * 22, "near side is fully reachable")
	var filled: Array[Vector2i] = Grid.flood_fill(Vector2i(2, 2), 500, func(c: Vector2i) -> bool:
		return c.x >= 0 and c.y >= 0 and c.x < 6 and c.y < 6)
	eq_int(filled.size(), 36, "callable flood fill respects its predicate")
	var capped: Array[Vector2i] = Grid.flood_fill(Vector2i(2, 2), 10, func(c: Vector2i) -> bool:
		return c.x >= 0 and c.y >= 0 and c.x < 60 and c.y < 60)
	eq_int(capped.size(), 10, "flood fill honours its cap")


# ---------------------------------------------------------------- storage

func _test_chunk_storage() -> void:
	var g: WorldGrid = _plain(70, 70)
	eq_int(g.chunks_x, 3, "70 tiles wide is 3 chunks")
	eq_int(g.chunk_count(), 9, "70x70 is 9 chunks")
	g.set_terrain(Vector2i(40, 50), Grid.Terrain.ROAD)
	eq_int(g.terrain_at(Vector2i(40, 50)), Grid.Terrain.ROAD, "terrain survives a chunk write")
	eq_int(g.terrain_at(Vector2i(41, 50)), Grid.Terrain.SNOW, "neighbour tile untouched")
	eq_int(g.cost_at(Vector2i(40, 50)), Grid.TERRAIN_COST[Grid.Terrain.ROAD], "road is cheap to walk")
	g.set_elevation(Vector2i(40, 50), 200)
	eq_int(g.elevation_at(Vector2i(40, 50)), 200, "elevation stored")
	eq_int(g.terrain_at(Vector2i(-1, 5)), Grid.Terrain.RIDGE, "out of bounds reads as wall")
	eq_int(g.cost_at(Vector2i(999, 999)), Grid.IMPASSABLE, "out of bounds is impassable")
	for x: int in range(g.width):
		check(not g.is_walkable(Vector2i(x, 0)), "top border row is impassable")
	check(not g.is_walkable(Vector2i(0, 35)), "left border column is impassable")
	check(g.is_walkable(Vector2i(1, 1)), "first inner tile is walkable")
	var chunk: GridChunk = g.chunk_at(Vector2i(40, 50))
	check(chunk.cx == 1 and chunk.cy == 1, "chunk lookup maps to the right block")
	var before: int = chunk.version
	g.set_terrain(Vector2i(40, 50), Grid.Terrain.ICE)
	check(chunk.version > before, "chunk version bumps so the renderer re-meshes")


# ---------------------------------------------------------------- occupancy

func _test_occupancy() -> void:
	var g: WorldGrid = _plain(40, 40)
	check(g.is_free(Vector2i(10, 10), Vector2i(3, 2)), "empty ground is free")
	check(g.occupy(Vector2i(10, 10), Vector2i(3, 2), 7), "occupy succeeds")
	check(not g.is_free(Vector2i(10, 10), Vector2i(1, 1)), "occupied tile is not free")
	check(not g.is_free(Vector2i(12, 11), Vector2i(1, 1)), "far corner of the footprint is claimed")
	check(g.is_free(Vector2i(13, 11), Vector2i(1, 1)), "one tile past the footprint is free")
	eq_int(g.building_at(Vector2i(11, 10)), 7, "building id reported at its tile")
	eq_int(g.building_at(Vector2i(20, 20)), 0, "empty tile reports no building")
	check(g.building_rect(7) == Rect2i(10, 10, 3, 2), "footprint rect remembered")
	eq_int(g.cost_at(Vector2i(11, 11)), Grid.IMPASSABLE, "a blocking building is a wall")
	check(not g.occupy(Vector2i(11, 10), Vector2i(2, 2), 8), "overlapping placement is refused")
	eq_int(g.building_at(Vector2i(12, 11)), 7, "refused placement changed nothing")
	check(g.release(7), "release succeeds")
	check(g.is_free(Vector2i(10, 10), Vector2i(3, 2)), "released ground is free again")
	check(g.cost_at(Vector2i(11, 11)) != Grid.IMPASSABLE, "released ground is walkable again")
	eq_int(g.building_count(), 0, "no buildings left")

	check(g.occupy(Vector2i(5, 5), Vector2i(2, 2), 11, false), "non-blocking occupy succeeds")
	check(g.cost_at(Vector2i(5, 5)) != Grid.IMPASSABLE, "a belt does not block movement")
	check(not g.is_free(Vector2i(5, 5), Vector2i(1, 1)), "but the tile is still claimed")


func _test_occupancy_edges() -> void:
	var g: WorldGrid = _plain(32, 32)
	check(not g.is_free(Vector2i(30, 30), Vector2i(4, 4)), "footprint over the map edge is refused")
	check(not g.is_free(Vector2i(-1, 5), Vector2i(2, 2)), "negative origin is refused")
	check(not g.is_free(Vector2i(0, 5), Vector2i(2, 2)), "footprint on the border ridge is refused")
	check(not g.occupy(Vector2i(4, 4), Vector2i(2, 2), 0), "id 0 is reserved for empty")
	check(g.occupy(Vector2i(4, 4), Vector2i(2, 2), 5), "first placement of id 5")
	check(not g.occupy(Vector2i(9, 9), Vector2i(2, 2), 5), "the same id cannot be placed twice")
	check(not g.release(999), "releasing an unknown id fails cleanly")
	eq_int(g.building_count(), 1, "only one building tracked")
	check(g.occupy(Vector2i(1, 1), Vector2i(1, 1), 6), "placement in the first inner corner")
	_wall(g, 20, 20, 20, 20)
	check(not g.is_free(Vector2i(20, 20), Vector2i(1, 1)), "ridge is not buildable")
	check(not g.occupy(Vector2i(20, 20), Vector2i(1, 1), 12), "cannot build on a ridge")
	var ids: PackedInt32Array = g.building_ids()
	eq_int(ids.size(), 2, "two ids tracked")
	check(ids[0] < ids[1], "building ids come back sorted, so iteration is deterministic")


func _test_line_of_sight() -> void:
	var g: WorldGrid = _plain(40, 40)
	check(g.line_of_sight(Vector2i(5, 5), Vector2i(5, 5)), "a tile sees itself")
	check(g.line_of_sight(Vector2i(5, 5), Vector2i(20, 7)), "open ground is clear")
	_wall(g, 12, 1, 12, 38)
	check(not g.line_of_sight(Vector2i(5, 5), Vector2i(20, 7)), "a ridge breaks sight")
	check(g.line_of_sight(Vector2i(5, 5), Vector2i(11, 5)), "sight up to the ridge is fine")
	g.set_terrain(Vector2i(12, 5), Grid.Terrain.SNOW)
	check(g.line_of_sight(Vector2i(5, 5), Vector2i(20, 5)), "a gap in the ridge restores sight")
	g.set_terrain(Vector2i(25, 25), Grid.Terrain.WRECK)
	check(not g.line_of_sight(Vector2i(23, 25), Vector2i(28, 25)), "a wreck is cover")


# ---------------------------------------------------------------- flow field

func _test_flow_basic() -> void:
	var g: WorldGrid = _plain(40, 40)
	var goal: Vector2i = Vector2i(20, 20)
	var f: FlowField = _field_for(g, PackedInt32Array([g.index_of(goal)]))
	eq_int(f.integration[g.index_of(goal)], 0, "goal costs nothing to reach")
	check(f.reachable(g.index_of(Vector2i(1, 1))), "far corner is reachable on open ground")
	eq_int(f.direction[g.index_of(goal)], FlowField.DIR_NONE, "goal has no direction")
	_validate(f, g, "open field")

	# Walking the flow must actually arrive, from everywhere, in finite steps.
	var worst: int = 0
	for start: Vector2i in [Vector2i(1, 1), Vector2i(38, 38), Vector2i(1, 38), Vector2i(30, 5)]:
		var c: Vector2i = start
		var steps: int = 0
		while c != goal and steps < 500:
			var s: Vector2i = f.step_at(g.index_of(c))
			check(s != Grid.ZERO, "flow never dead-ends at %s" % c)
			if s == Grid.ZERO:
				break
			c += s
			steps += 1
		check(c == goal, "flow from %s arrives at the goal" % start)
		worst = maxi(worst, steps)
	check(worst <= 40, "longest walk on a 40x40 map is at most 40 steps, got %d" % worst)

	var straight: int = f.integration[g.index_of(Vector2i(20, 10))]
	var diagonal: int = f.integration[g.index_of(Vector2i(10, 10))]
	# Edge weight is terrain cost x direction weight. Ten orthogonal steps over
	# plain snow is therefore 10 * 10 * 10.
	eq_int(straight, 10 * Grid.TERRAIN_COST[Grid.Terrain.SNOW] * FlowField.W_ORTHO, "10 tiles straight costs 10 moves")
	check(diagonal > straight, "the diagonal corner is further than the straight one")
	check(f.steer(Grid.cell_to_world(Vector2i(20, 10))).length() > 0.9, "steer returns a unit vector")


func _test_flow_obstacle() -> void:
	var g: WorldGrid = _plain(48, 32)
	# A wall across the map with one gap: everything behind it must route through.
	_wall(g, 24, 1, 24, 30)
	g.set_terrain(Vector2i(24, 16), Grid.Terrain.SNOW)
	var goal: Vector2i = Vector2i(4, 16)
	var f: FlowField = _field_for(g, PackedInt32Array([g.index_of(goal)]))
	_validate(f, g, "wall with one gap")
	check(f.reachable(g.index_of(Vector2i(44, 4))), "far side is still reachable through the gap")

	var c: Vector2i = Vector2i(44, 4)
	var through_gap: bool = false
	var steps: int = 0
	while c != goal and steps < 400:
		var s: Vector2i = f.step_at(g.index_of(c))
		if s == Grid.ZERO:
			break
		c += s
		if c == Vector2i(24, 16):
			through_gap = true
		steps += 1
	check(c == goal, "a unit behind the wall reaches the goal")
	check(through_gap, "and it goes through the one gap, because there is no other way")

	# Seal the gap: the far side must become unreachable, near side untouched.
	g.set_terrain(Vector2i(24, 16), Grid.Terrain.RIDGE)
	f.update(g.cost, g.take_dirty(1 << 30))
	_validate(f, g, "sealed wall")
	check(not f.reachable(g.index_of(Vector2i(44, 4))), "sealing the gap cuts the far side off")
	check(f.reachable(g.index_of(Vector2i(10, 4))), "the near side is unaffected")


func _test_flow_corner_rule() -> void:
	var g: WorldGrid = _plain(20, 20)
	# A hard corner: (10,9) and (9,10) blocked, so (9,9)->(10,10) must not squeeze.
	g.set_terrain(Vector2i(10, 9), Grid.Terrain.RIDGE)
	g.set_terrain(Vector2i(9, 10), Grid.Terrain.RIDGE)
	var f: FlowField = _field_for(g, PackedInt32Array([g.index_of(Vector2i(10, 10))]))
	_validate(f, g, "corner rule")
	var diag: int = f.integration[g.index_of(Vector2i(9, 9))]
	var direct: int = Grid.TERRAIN_COST[Grid.Terrain.SNOW] * FlowField.W_DIAG
	check(diag > direct, "a unit cannot cut the corner between two walls (%d vs %d)" % [diag, direct])


func _test_flow_incremental() -> void:
	var g: WorldGrid = _plain(64, 64)
	var goal: int = g.index_of(Vector2i(32, 32))
	var goals: PackedInt32Array = PackedInt32Array([goal])
	var live: FlowField = _field_for(g, goals)
	g.take_dirty(1 << 30)

	var rng: RandomNumberGenerator = Rng.stream("grid_test")
	var mismatches: int = 0
	var placed: Array[int] = []
	var repaired_cells: int = 0
	var full_cells: int = 0

	for step: int in range(60):
		# Half the time build something, half the time tear something down.
		if placed.is_empty() or rng.randf() < 0.62:
			var id: int = 100 + step
			var cell := Vector2i(rng.randi_range(2, 58), rng.randi_range(2, 58))
			var sz := Vector2i(rng.randi_range(1, 4), rng.randi_range(1, 4))
			if g.occupy(cell, sz, id):
				placed.append(id)
		else:
			var pick: int = rng.randi_range(0, placed.size() - 1)
			g.release(placed[pick])
			placed.remove_at(pick)

		var dirty: PackedInt32Array = g.take_dirty(1 << 30)
		live.update(g.cost, dirty)
		repaired_cells += live.last_visited

		var fresh: FlowField = _field_for(g, goals)
		full_cells += fresh.last_visited
		if live.integration != fresh.integration:
			mismatches += 1

	eq_int(mismatches, 0, "incremental repair matches a from-scratch rebuild after every change")
	_validate(live, g, "after 60 building changes")
	note("flow repair: %d cells for 60 changes vs %d for full rebuilds (%.1fx cheaper)" % [
		repaired_cells, full_cells, float(full_cells) / maxf(float(repaired_cells), 1.0),
	])
	check(repaired_cells < full_cells, "incremental repair is cheaper than rebuilding")


func _test_flow_sealed_room() -> void:
	var g: WorldGrid = _plain(32, 32)
	var goal: int = g.index_of(Vector2i(4, 4))
	var f: FlowField = _field_for(g, PackedInt32Array([goal]))
	g.take_dirty(1 << 30)
	# Wall a unit into a 3x3 room and let the field repair incrementally.
	for i: int in range(18, 25):
		g.set_terrain(Vector2i(i, 18), Grid.Terrain.RIDGE)
		g.set_terrain(Vector2i(i, 24), Grid.Terrain.RIDGE)
		g.set_terrain(Vector2i(18, i), Grid.Terrain.RIDGE)
		g.set_terrain(Vector2i(24, i), Grid.Terrain.RIDGE)
	f.update(g.cost, g.take_dirty(1 << 30))
	check(not f.reachable(g.index_of(Vector2i(21, 21))), "a sealed room has no path out")
	check(f.reachable(g.index_of(Vector2i(15, 21))), "the ground outside the room still routes home")
	_validate(f, g, "sealed room")

	# Knock one tile out of the wall: the room must reconnect, still incrementally.
	g.set_terrain(Vector2i(21, 18), Grid.Terrain.SNOW)
	f.update(g.cost, g.take_dirty(1 << 30))
	check(f.reachable(g.index_of(Vector2i(21, 21))), "opening a door reconnects the room")
	_validate(f, g, "opened room")
	var fresh: FlowField = _field_for(g, PackedInt32Array([goal]))
	check(f.integration == fresh.integration, "reopened field still matches a full rebuild")


func _test_astar() -> void:
	var sys := GridSystem.new()
	sys.grid = _plain(48, 48)
	_wall(sys.grid, 24, 1, 24, 40)
	var path: Array[Vector2i] = sys.find_path(Vector2i(4, 20), Vector2i(44, 20))
	check(path.size() > 0, "A* finds a way around a wall that stops short of the edge")
	check(path[0] == Vector2i(4, 20), "path starts where asked")
	check(path[path.size() - 1] == Vector2i(44, 20), "path ends where asked")
	var contiguous: bool = true
	var walkable: bool = true
	for i: int in range(path.size()):
		if not sys.grid.is_walkable(path[i]):
			walkable = false
		if i > 0 and Grid.chebyshev(path[i], path[i - 1]) != 1:
			contiguous = false
	check(contiguous, "A* path steps one tile at a time")
	check(walkable, "A* path never crosses a wall")
	check(path.size() > 40, "and it is longer than the straight line, because it detours")

	_wall(sys.grid, 24, 41, 24, 46)
	var blocked: Array[Vector2i] = sys.find_path(Vector2i(4, 20), Vector2i(44, 20))
	eq_int(blocked.size(), 0, "no path exists once the wall is complete")
	var same: Array[Vector2i] = sys.find_path(Vector2i(4, 20), Vector2i(4, 20))
	eq_int(same.size(), 1, "path to yourself is one cell")


# ---------------------------------------------------------------- world state

func _test_snow() -> void:
	var g: WorldGrid = _plain(40, 40)
	g.set_terrain(Vector2i(5, 5), Grid.Terrain.GEOTHERMAL)
	# Drain the queue that terrain change legitimately produced, so the assertion
	# below measures the snow model and nothing else.
	g.take_dirty(1 << 30)
	g.accumulate_snow(0, 40, 200)
	eq_int(g.snow_at(Vector2i(5, 5)), 0, "snow never settles on warm ground")
	eq_int(g.snow_at(Vector2i(6, 6)), 40, "snow settles everywhere else")
	g.accumulate_snow(0, 400, 200)
	eq_int(g.snow_at(Vector2i(6, 6)), 200, "snow depth is capped")
	var fast: float = g.speed_scale(Vector2i(20, 20))
	g.set_snow(Vector2i(20, 20), 220)
	var slow: float = g.speed_scale(Vector2i(20, 20))
	check(slow < fast, "deep snow slows a unit down (%.2f -> %.2f)" % [fast, slow])
	check(slow > 0.0, "but never stops it outright")
	eq_int(g.cost_at(Vector2i(20, 20)), Grid.TERRAIN_COST[Grid.Terrain.SNOW], "snow does not repath the world")
	eq_int(g.dirty_count(), 0, "a blizzard queues no pathfinding work at all")
	check(g.speed_scale(Vector2i(0, 0)) == 0.0, "a wall has no speed")


func _test_harvest() -> void:
	var g: WorldGrid = _plain(40, 40)
	g.set_terrain(Vector2i(10, 10), Grid.Terrain.WRECK)
	g.set_resource(Vector2i(10, 10), Grid.Res.SCRAP, 100)
	eq_int(g.harvest(Vector2i(10, 10), 30), 30, "harvest takes what was asked")
	eq_int(g.resource_amount_at(Vector2i(10, 10)), 70, "and leaves the rest")
	eq_int(g.harvest(Vector2i(10, 10), 500), 70, "harvest cannot take more than is there")
	eq_int(g.resource_amount_at(Vector2i(10, 10)), 0, "deposit is empty")
	eq_int(g.resource_kind_at(Vector2i(10, 10)), Grid.Res.NONE, "empty deposit has no kind")
	eq_int(g.terrain_at(Vector2i(10, 10)), Grid.Terrain.RUBBLE, "a stripped wreck leaves rubble")
	eq_int(g.harvest(Vector2i(10, 10), 10), 0, "harvesting nothing yields nothing")
	eq_int(g.harvest(Vector2i(99, 99), 10), 0, "harvesting off-map yields nothing")

	g.set_resource(Vector2i(12, 12), Grid.Res.COAL, 500)
	check(g.find_nearest_resource(Vector2i(20, 20), Grid.Res.COAL, 30) == Vector2i(12, 12), "nearest coal found")
	check(g.find_nearest_resource(Vector2i(20, 20), Grid.Res.IRON, 30) == Vector2i(-1, -1), "no iron on this map")
	eq_int(g.resource_totals()[Grid.Res.COAL], 500, "resource totals add up")


func _test_serialization() -> void:
	Rng.reset(4242)
	var profile: BiomeProfile = BiomeProfile.fallback()
	profile.width = 96
	profile.height = 96
	var gen := MapGenerator.new(profile)
	var g: WorldGrid = gen.generate()
	g.occupy(Vector2i(48, 48), Vector2i(2, 2), 77)
	g.occupy(Vector2i(52, 48), Vector2i(1, 1), 78, false)
	var before: int = g.content_hash()
	var payload: Dictionary = g.serialize()

	var restored := WorldGrid.new()
	check(restored.deserialize(payload), "deserialize accepts its own payload")
	eq_int(restored.content_hash(), before, "content hash survives a save/load round trip")
	eq_int(restored.width, g.width, "width restored")
	eq_int(restored.building_at(Vector2i(48, 48)), 77, "occupancy restored")
	eq_int(restored.cost_at(Vector2i(48, 48)), Grid.IMPASSABLE, "blocking building still blocks after load")
	check(restored.cost_at(Vector2i(52, 48)) != Grid.IMPASSABLE, "non-blocking building still does not block")
	check(restored.cost == g.cost, "every movement cost matches after load")
	eq_int(restored.walkable_cells, g.walkable_cells, "walkable count matches after load")
	check(restored.building_rect(77) == Rect2i(48, 48, 2, 2), "footprint restored")
	var empty := WorldGrid.new()
	check(not empty.deserialize({}), "an empty payload is rejected, not half-applied")


# ---------------------------------------------------------------- world gen

func _make_world(seed_value: int, w: int = 128, h: int = 128) -> MapGenerator:
	Rng.reset(seed_value)
	var profile: BiomeProfile = BiomeProfile.fallback()
	profile.width = w
	profile.height = h
	var gen := MapGenerator.new(profile)
	gen.generate()
	return gen


func _test_mapgen_determinism() -> void:
	var a: MapGenerator = _make_world(1234)
	var b: MapGenerator = _make_world(1234)
	var c: MapGenerator = _make_world(1235)
	eq_int(b.grid.content_hash(), a.grid.content_hash(), "same seed produces the same map, byte for byte")
	check(c.grid.content_hash() != a.grid.content_hash(), "a different seed produces a different map")
	eq_int(b.chokepoints.size(), a.chokepoints.size(), "same seed produces the same chokepoints")
	check(b.grid.cost == a.grid.cost, "same seed produces the same movement costs")
	eq_int(int(b.stats["reachable"]), int(a.stats["reachable"]), "same seed, same reachable ground")

	# And the map is stable across a save/load boundary, which is what a replay needs.
	var payload: Dictionary = a.grid.serialize()
	var restored := WorldGrid.new()
	restored.deserialize(payload)
	eq_int(restored.content_hash(), a.grid.content_hash(), "hash survives serialize on a generated map")


func _test_mapgen_sanity() -> void:
	var gen: MapGenerator = _make_world(99, 192, 192)
	var g: WorldGrid = gen.grid
	var total: int = g.width * g.height
	var walk_frac: float = float(g.walkable_cells) / float(total)
	check(walk_frac > 0.55 and walk_frac < 0.95, "the basin is open but not empty: %.0f%% walkable" % (walk_frac * 100.0))

	var mask: PackedByteArray = g.reachable_mask(gen.core)
	var reach: int = 0
	for v: int in mask:
		if v != 0:
			reach += 1
	var reach_frac: float = float(reach) / float(g.walkable_cells)
	check(reach_frac > 0.90, "almost all walkable ground connects to the city: %.1f%%" % (reach_frac * 100.0))

	check(g.terrain_at(gen.core) == Grid.Terrain.GEOTHERMAL, "the core is warm ground")
	check(g.is_walkable(gen.core), "the core is walkable")
	eq_int(g.resource_kind_at(gen.core), Grid.Res.VENT, "the core tile is a geothermal vent")
	check(g.is_free(gen.core - Vector2i(1, 1), Vector2i(3, 3)), "there is room to build on the core")

	check(gen.lanes.size() >= 3, "the map has approach lanes")
	check(gen.chokepoints.size() >= 1, "at least one lane has a defensible chokepoint")
	for c: Vector2i in gen.chokepoints:
		check(g.is_walkable(c), "chokepoint %s is walkable ground" % c)
	for lane: Dictionary in gen.lanes:
		var entry: int = int(lane["entry"])
		check(g.cost[entry] != Grid.IMPASSABLE, "lane entry is walkable")
		check(mask[entry] != 0, "every lane entry connects to the city — the night can get in")

	var totals: PackedInt64Array = g.resource_totals()
	for kind: int in [Grid.Res.SCRAP, Grid.Res.COAL, Grid.Res.IRON, Grid.Res.COPPER, Grid.Res.VENT]:
		check(totals[kind] > 0, "the map carries %s" % Grid.RES_NAMES[kind])
	var scrap_near: int = 0
	for c: Vector2i in Grid.disc(gen.core, 40):
		if g.in_bounds(c) and g.resource_kind_at(c) == Grid.Res.SCRAP:
			scrap_near += g.resource_amount_at(c)
	check(scrap_near > 500, "there is scrap near the core to start on, got %d" % scrap_near)
	note("192x192 map: %.0f%% walkable, %.1f%% connected, %d lanes, %d chokepoints" % [
		walk_frac * 100.0, reach_frac * 100.0, gen.lanes.size(), gen.chokepoints.size(),
	])


func _test_richness_gradient() -> void:
	var gen: MapGenerator = _make_world(7, 192, 192)
	var g: WorldGrid = gen.grid
	var near_sum: int = 0
	var near_n: int = 0
	var far_sum: int = 0
	var far_n: int = 0
	var edge: float = 96.0
	for y: int in range(g.height):
		for x: int in range(g.width):
			var c := Vector2i(x, y)
			var kind: int = g.resource_kind_at(c)
			if kind == Grid.Res.NONE or kind == Grid.Res.VENT or kind == Grid.Res.SCRAP:
				continue
			var d: float = Vector2(c - gen.core).length() / edge
			if d < 0.35:
				near_sum += g.resource_amount_at(c)
				near_n += 1
			elif d > 0.65:
				far_sum += g.resource_amount_at(c)
				far_n += 1
	check(near_n > 0 and far_n > 0, "deposits exist both near and far")
	if near_n > 0 and far_n > 0:
		var near_avg: float = float(near_sum) / float(near_n)
		var far_avg: float = float(far_sum) / float(far_n)
		check(far_avg > near_avg * 1.6, "far ore is worth the walk: %.0f per tile out there vs %.0f at home" % [far_avg, near_avg])
		note("richness gradient: %.0f/tile near the core, %.0f/tile out at the rim (%.1fx)" % [
			near_avg, far_avg, far_avg / maxf(near_avg, 1.0),
		])


func _test_all_biomes() -> void:
	for id: StringName in [&"frozen_basin", &"shattered_flats", &"deep_rift"]:
		var res: Resource = Registry.get_item("biomes", id)
		var profile := res as BiomeProfile
		check(profile != null, "biome '%s' is authored in game/content/biomes" % id)
		if profile == null:
			continue
		check(profile.deposits.size() >= 4, "biome '%s' places at least four resource types" % id)
		Rng.reset(31337)
		var gen := MapGenerator.new(profile)
		var g: WorldGrid = gen.generate()
		var frac: float = float(g.walkable_cells) / float(g.width * g.height)
		check(frac > 0.45, "biome '%s' is playable: %.0f%% walkable" % [id, frac * 100.0])
		var mask: PackedByteArray = g.reachable_mask(gen.core)
		var reach: int = 0
		for v: int in mask:
			if v != 0:
				reach += 1
		check(float(reach) / float(g.walkable_cells) > 0.85, "biome '%s' is connected: %.0f%%" % [id, 100.0 * float(reach) / float(g.walkable_cells)])
		check(gen.lanes.size() >= 3, "biome '%s' has at least three ways in" % id)
		note("%s %dx%d: %.0f%% walkable, %.0f%% connected, %d lanes, %d chokepoints, %d carved" % [
			id, g.width, g.height, frac * 100.0,
			100.0 * float(reach) / float(g.walkable_cells),
			gen.lanes.size(), gen.chokepoints.size(), gen.carved_passes.size(),
		])
