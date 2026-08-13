class_name MapGenerator
extends RefCounted
## Builds a whole world from a [BiomeProfile] and the "mapgen" Rng stream.
##
## The map is an argument, not scenery. Every pass exists to create a specific
## pressure the player has to answer:
##
## * a **geothermal core** at the centre — the only warm ground on the plain, and
##   the reason anybody stayed here. It is small. You will outgrow it.
## * **ridge arcs and chasms** that cut the basin into rings, so there is always a
##   line worth holding and a flank worth worrying about.
## * **old highways** running from the core to the horizon. They are the cheapest
##   ground to walk on, which means they are also how the dark gets in — every
##   lane is measured for its narrowest point and handed to the game as a
##   chokepoint.
## * **wrecks and ruins** near the core: free scrap, enough to start, never enough
##   to finish.
## * **ore that gets richer the further out it lies**. That gradient is the whole
##   economy in one line of maths.

## How far past its minimum ring the guaranteed starter patch of each resource
## may fall. Small on purpose: the first patch has to be walkable-to on day one.
const STARTER_BAND: int = 6

var profile: BiomeProfile
var grid: WorldGrid
var core: Vector2i = Vector2i.ZERO
## One entry per approach lane: entry cell, chokepoint cell, path, heading.
var lanes: Array[Dictionary] = []
var chokepoints: Array[Vector2i] = []
## Passes cut through ridge walls to reach isolated pockets — flanking routes.
var carved_passes: Array[Vector2i] = []
var stats: Dictionary = {}

var _w: int = 0
var _h: int = 0
var _inv_max: float = 1.0
var _max_radius: float = 1.0
var _reach: PackedByteArray = PackedByteArray()
var _n_elev: FastNoiseLite
var _n_ridge: FastNoiseLite
var _n_chasm: FastNoiseLite
var _n_lake: FastNoiseLite
var _n_drift: FastNoiseLite
var _n_wobble: FastNoiseLite


func _init(biome: BiomeProfile) -> void:
	profile = biome if biome != null else BiomeProfile.fallback()


## Generates the world. Deterministic for a given seed: same seed, same map.
func generate() -> WorldGrid:
	var rng: RandomNumberGenerator = Rng.stream("mapgen")
	_w = maxi(profile.width, 64)
	_h = maxi(profile.height, 64)
	grid = WorldGrid.new(_w, _h)
	core = Vector2i(_w / 2, _h / 2)
	_max_radius = float(mini(_w, _h)) * 0.5
	_inv_max = 1.0 / _max_radius

	_build_noise(rng)
	_pass_terrain()
	_pass_core(rng)
	_pass_border()
	_pass_roads(rng)
	_pass_ruins(rng)
	grid.rebuild_all_costs()
	_pass_connect()
	_reach = grid.reachable_mask(core)
	_pass_deposits(rng)
	_pass_convoys(rng)
	_pass_chokepoints()
	grid.rebuild_all_costs()
	_collect_stats()
	return grid


# ---------------------------------------------------------------- noise setup

func _build_noise(rng: RandomNumberGenerator) -> void:
	# Order matters: each draw advances the stream, so the sequence is the seed.
	_n_elev = _make(rng, profile.elevation_frequency, profile.elevation_octaves, false)
	_n_ridge = _make(rng, profile.ridge_frequency, 3, true)
	_n_chasm = _make(rng, profile.chasm_frequency, 2, true)
	_n_lake = _make(rng, profile.lake_frequency, 2, false)
	_n_drift = _make(rng, profile.drift_frequency, 2, false)
	_n_wobble = _make(rng, 0.03, 2, false)


func _make(rng: RandomNumberGenerator, freq: float, octaves: int, ridged: bool) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = rng.randi()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_octaves = maxi(octaves, 1)
	n.fractal_type = FastNoiseLite.FRACTAL_RIDGED if ridged else FastNoiseLite.FRACTAL_FBM
	return n


# ---------------------------------------------------------------- terrain

## Single sweep: elevation, ridges, chasms, frozen lakes, drifts and snow depth.
## Written chunk-local and handed over in one move — 65 000 indexed writes into a
## chunked store would cost more than all the noise put together.
func _pass_terrain() -> void:
	var core_r: float = float(profile.core_radius)
	var ash_r: float = float(profile.ash_radius)
	var rock_e: int = profile.rock_elevation
	var snow_base: int = profile.snow_base
	var snow_drift: int = profile.snow_drift
	var snow_cap: int = profile.snow_cap
	var cxf: float = float(core.x)
	var cyf: float = float(core.y)

	for cy: int in range(grid.chunks_y):
		for cx: int in range(grid.chunks_x):
			var chunk: GridChunk = grid.chunk_by_coord(cx, cy)
			var lt: PackedByteArray = PackedByteArray()
			var le: PackedByteArray = PackedByteArray()
			var ls: PackedByteArray = PackedByteArray()
			lt.resize(Grid.CHUNK_AREA)
			le.resize(Grid.CHUNK_AREA)
			ls.resize(Grid.CHUNK_AREA)
			var ox: int = cx << Grid.CHUNK_SHIFT
			var oy: int = cy << Grid.CHUNK_SHIFT
			for ly: int in range(Grid.CHUNK_SIZE):
				var wy: int = oy + ly
				var fy: float = float(wy)
				var dy: float = fy - cyf
				var base_i: int = ly << Grid.CHUNK_SHIFT
				for lx: int in range(Grid.CHUNK_SIZE):
					var i: int = base_i + lx
					var wx: int = ox + lx
					if wx >= _w or wy >= _h:
						lt[i] = Grid.Terrain.RIDGE
						le[i] = 255
						continue
					var fx: float = float(wx)
					var dx: float = fx - cxf
					var dist: float = sqrt(dx * dx + dy * dy)
					var dn: float = dist * _inv_max
					var basin: float = pow(minf(dn, 1.0), profile.basin_exponent) * profile.rim_height
					var e: float = basin + _n_elev.get_noise_2d(fx, fy) * profile.terrain_roughness
					var elev: int = clampi(int(e * 150.0) + 45, 0, 255)
					le[i] = elev

					var t: int = Grid.Terrain.SNOW
					if dist <= core_r:
						t = Grid.Terrain.GEOTHERMAL
					elif dist <= ash_r:
						t = Grid.Terrain.ASH
					else:
						var ridge_thr: float = profile.ridge_threshold - cos(dn * TAU * profile.ridge_rings) * profile.ridge_ring_strength
						if dn > profile.ridge_min_distance and _n_ridge.get_noise_2d(fx, fy) > ridge_thr:
							t = Grid.Terrain.RIDGE
						elif dn > profile.chasm_min_distance and _n_chasm.get_noise_2d(fx, fy) > profile.chasm_threshold:
							t = Grid.Terrain.CHASM
						elif elev >= rock_e:
							t = Grid.Terrain.ROCK
						elif elev < rock_e - 42 and _n_lake.get_noise_2d(fx, fy) < profile.lake_threshold:
							t = Grid.Terrain.ICE
						elif _n_drift.get_noise_2d(fx, fy) > profile.drift_threshold:
							t = Grid.Terrain.DEEP_SNOW
					lt[i] = t

					if (Grid.TERRAIN_FLAGS[t] & Grid.F_WARM) != 0:
						ls[i] = 0
					else:
						var d: float = _n_drift.get_noise_2d(fx * 1.7, fy * 1.7)
						ls[i] = clampi(snow_base + int(d * float(snow_drift)), 0, snow_cap)
			chunk.adopt(lt, le, ls)


## The warm ground: buildable, snow-free, and ringed by vents worth capping.
func _pass_core(rng: RandomNumberGenerator) -> void:
	for c: Vector2i in Grid.disc(core, profile.core_clear_radius):
		if not grid.in_bounds(c):
			continue
		var t: int = grid.terrain_at(c)
		if t == Grid.Terrain.RIDGE or t == Grid.Terrain.CHASM:
			grid.set_terrain(c, Grid.Terrain.GRAVEL)

	grid.set_resource(core, Grid.Res.VENT, profile.vent_output * 2)
	var placed: int = 0
	var attempts: int = 0
	while placed < profile.core_vents and attempts < 200:
		attempts += 1
		var a: float = rng.randf() * TAU
		var r: float = rng.randf_range(float(profile.core_radius) * 0.4, float(profile.core_radius))
		var c: Vector2i = core + Vector2i(int(round(cos(a) * r)), int(round(sin(a) * r)))
		if not grid.in_bounds(c) or grid.resource_amount_at(c) > 0:
			continue
		if (grid.flags_at(c) & Grid.F_WALK) == 0:
			continue
		grid.set_resource(c, Grid.Res.VENT, int(float(profile.vent_output) * rng.randf_range(0.8, 1.25)))
		placed += 1


func _pass_border() -> void:
	var b: int = maxi(profile.border_thickness, 1)
	for y: int in range(_h):
		var edge_row: bool = y < b or y >= _h - b
		for x: int in range(_w):
			if edge_row:
				grid.set_terrain(Vector2i(x, y), Grid.Terrain.RIDGE)
			elif x < b or x >= _w - b:
				grid.set_terrain(Vector2i(x, y), Grid.Terrain.RIDGE)


# ---------------------------------------------------------------- roads

## Old highways out of the city. They follow low ground, cut through ridges where
## they must, and end at the world edge — which is exactly where the night comes from.
func _pass_roads(rng: RandomNumberGenerator) -> void:
	lanes.clear()
	var count: int = maxi(profile.lane_count, 1)
	var base_angle: float = rng.randf() * TAU
	var limit: int = int(_max_radius * 2.4)
	var margin: int = maxi(profile.border_thickness, 1) + 1

	for i: int in range(count):
		var heading: float = base_angle + TAU * float(i) / float(count) + rng.randf_range(-0.22, 0.22)
		var p: Vector2 = Vector2(float(core.x), float(core.y))
		var path: PackedInt32Array = PackedInt32Array()
		var last: Vector2i = core
		var wob: float = rng.randf() * 100.0
		var steps: int = 0
		while steps < limit:
			steps += 1
			var cell: Vector2i = Vector2i(int(round(p.x)), int(round(p.y)))
			if cell.x < margin or cell.y < margin or cell.x >= _w - margin or cell.y >= _h - margin:
				break
			if cell != last or path.is_empty():
				_paint_road(cell, _axis_perp(heading))
				path.append(grid.index_of(cell))
				last = cell
			# Wander, then lean downhill: highways were cut through valleys.
			wob += 0.12
			heading += _n_wobble.get_noise_2d(wob * 12.0, float(i) * 40.0) * profile.lane_wobble * 0.16
			var perp: Vector2 = Vector2(-sin(heading), cos(heading))
			var left: Vector2i = cell + Vector2i(int(round(perp.x * 3.0)), int(round(perp.y * 3.0)))
			var right: Vector2i = cell - Vector2i(int(round(perp.x * 3.0)), int(round(perp.y * 3.0)))
			var slope: float = float(grid.elevation_at(right) - grid.elevation_at(left))
			heading += slope * profile.lane_valley_bias
			p += Vector2(cos(heading), sin(heading))

		if path.is_empty():
			continue
		lanes.append({
			"entry": path[path.size() - 1],
			"choke": -1,
			"width": 0,
			"heading": heading,
			"path": path,
		})


## Axis-aligned normal of a heading. Widening a pass along a diagonal would only
## thicken it by one tile on each corner; along an axis it opens a real gap.
func _axis_perp(heading: float) -> Vector2i:
	var nx: float = -sin(heading)
	var ny: float = cos(heading)
	if absf(nx) >= absf(ny):
		return Vector2i(1 if nx >= 0.0 else -1, 0)
	return Vector2i(0, 1 if ny >= 0.0 else -1)


func _paint_road(cell: Vector2i, perp: Vector2i) -> void:
	var t: int = grid.terrain_at(cell)
	if t == Grid.Terrain.GEOTHERMAL or t == Grid.Terrain.ASH:
		return
	grid.set_terrain(cell, Grid.Terrain.ROAD)
	# A cutting through a ridge is a pass, not a keyhole: widen it so the defence
	# there is a real fight and not one turret in a one-tile tunnel. Bridges over
	# a chasm stay single-file — that narrowness is the drama.
	if t != Grid.Terrain.RIDGE or perp == Grid.ZERO:
		return
	for side: int in [1, -1]:
		var c: Vector2i = cell + perp * side
		if grid.in_bounds(c) and grid.terrain_at(c) == Grid.Terrain.RIDGE:
			grid.set_terrain(c, Grid.Terrain.GRAVEL)


# ---------------------------------------------------------------- ruins

## The city that was here before. Rectangular blocks of collapsed housing with
## wrecked walls: cover for the defender, scrap for the desperate.
func _pass_ruins(rng: RandomNumberGenerator) -> void:
	for _c: int in range(profile.ruin_clusters):
		var a: float = rng.randf() * TAU
		var r: float = lerpf(float(profile.ruin_min_distance), float(profile.ruin_max_distance), sqrt(rng.randf()))
		var origin: Vector2i = core + Vector2i(int(round(cos(a) * r)), int(round(sin(a) * r)))
		var blocks: int = rng.randi_range(profile.ruin_blocks_min, profile.ruin_blocks_max)
		for _b: int in range(blocks):
			var bw: int = rng.randi_range(profile.ruin_block_size_min, profile.ruin_block_size_max)
			var bh: int = rng.randi_range(profile.ruin_block_size_min, profile.ruin_block_size_max)
			var off: Vector2i = Vector2i(rng.randi_range(-9, 9), rng.randi_range(-9, 9))
			var tl: Vector2i = origin + off
			for y: int in range(tl.y, tl.y + bh):
				for x: int in range(tl.x, tl.x + bw):
					var c: Vector2i = Vector2i(x, y)
					if not grid.in_bounds(c):
						continue
					var t: int = grid.terrain_at(c)
					if t == Grid.Terrain.GEOTHERMAL or t == Grid.Terrain.ASH or t == Grid.Terrain.ROAD:
						continue
					var edge: bool = x == tl.x or y == tl.y or x == tl.x + bw - 1 or y == tl.y + bh - 1
					grid.set_terrain(c, Grid.Terrain.WRECK if edge and rng.randf() < 0.55 else Grid.Terrain.RUBBLE)
					if rng.randf() < profile.ruin_scrap_chance:
						grid.set_resource(c, Grid.Res.SCRAP, rng.randi_range(profile.ruin_scrap_min, profile.ruin_scrap_max))


## Convoys that never made it out, strung along the highways.
func _pass_convoys(rng: RandomNumberGenerator) -> void:
	if lanes.is_empty():
		return
	for _i: int in range(profile.convoys):
		var lane: Dictionary = lanes[rng.randi_range(0, lanes.size() - 1)]
		var path: PackedInt32Array = lane["path"]
		if path.size() < 12:
			continue
		var start: int = rng.randi_range(4, path.size() - 6)
		var length: int = rng.randi_range(profile.convoy_length_min, profile.convoy_length_max)
		for k: int in range(length):
			var pi: int = start + k
			if pi >= path.size():
				break
			var c: Vector2i = grid.cell_of(path[pi])
			var side: Vector2i = Grid.DIRS4[rng.randi_range(0, 3)]
			var w: Vector2i = c + side
			if not grid.in_bounds(w) or grid.resource_amount_at(w) > 0:
				continue
			if (grid.flags_at(w) & Grid.F_BUILD) == 0:
				continue
			grid.set_terrain(w, Grid.Terrain.WRECK)
			grid.set_resource(w, Grid.Res.SCRAP, rng.randi_range(profile.convoy_scrap_min, profile.convoy_scrap_max))


# ---------------------------------------------------------------- connectivity

## Ridge arcs cut the basin into pockets. Any pocket big enough to matter gets a
## pass carved to the city — because a plain nobody can walk to is not terrain,
## it is wallpaper, and because every carved pass is another chokepoint the
## player has to think about.
func _pass_connect() -> void:
	var labels: Dictionary = _label_components()
	var comp: PackedInt32Array = labels["comp"]
	var sizes: PackedInt32Array = labels["sizes"]
	var reps: PackedInt32Array = labels["reps"]
	var main: int = comp[grid.index_of(core)]
	if main < 0:
		Log.error("grid", "core tile is not walkable; map is unusable")
		return

	var order: Array[int] = []
	for i: int in range(sizes.size()):
		if i != main and sizes[i] >= profile.min_pocket:
			order.append(i)
	# Biggest first: joining the large pockets often swallows the small ones.
	order.sort_custom(func(a: int, b: int) -> bool: return sizes[a] > sizes[b])

	var connected: Dictionary[int, bool] = {main: true}
	var joined: int = 0
	for cid: int in order:
		var from: Vector2i = grid.cell_of(reps[cid])
		var target: Vector2i = _nearest_connected(from, comp, connected)
		if target.x < 0:
			continue
		var mid: Vector2i = _carve(from, target)
		connected[cid] = true
		joined += 1
		if mid.x >= 0:
			carved_passes.append(mid)
	if joined > 0:
		grid.rebuild_all_costs()
	Log.debug("grid", "connectivity: %d components, joined %d pockets" % [sizes.size(), joined])


## Flood-labels every walkable component. Returns comp ids, sizes, and for each
## component the cell closest to the core — the natural place to cut a pass.
func _label_components() -> Dictionary:
	var n: int = _w * _h
	var comp: PackedInt32Array = PackedInt32Array()
	comp.resize(n)
	comp.fill(-1)
	var sizes: PackedInt32Array = PackedInt32Array()
	var reps: PackedInt32Array = PackedInt32Array()
	var offs: PackedInt32Array = PackedInt32Array([1, -1, _w, -_w])
	var queue: PackedInt32Array = PackedInt32Array()
	for start: int in range(n):
		if comp[start] != -1 or grid.cost[start] == Grid.IMPASSABLE:
			continue
		var id: int = sizes.size()
		comp[start] = id
		queue.clear()
		queue.append(start)
		var head: int = 0
		var count: int = 0
		var best: int = start
		var best_d: int = Grid.dist_sq(grid.cell_of(start), core)
		while head < queue.size():
			var c: int = queue[head]
			head += 1
			count += 1
			var d: int = Grid.dist_sq(grid.cell_of(c), core)
			if d < best_d:
				best_d = d
				best = c
			for o: int in offs:
				var nb: int = c + o
				if nb < 0 or nb >= n or comp[nb] != -1 or grid.cost[nb] == Grid.IMPASSABLE:
					continue
				comp[nb] = id
				queue.append(nb)
		sizes.append(count)
		reps.append(best)
	return {"comp": comp, "sizes": sizes, "reps": reps}


func _nearest_connected(from: Vector2i, comp: PackedInt32Array, connected: Dictionary[int, bool]) -> Vector2i:
	for r: int in range(2, profile.connect_search_radius + 1):
		for c: Vector2i in Grid.ring(from, r):
			if not grid.in_bounds(c):
				continue
			var id: int = comp[grid.index_of(c)]
			if id >= 0 and connected.has(id):
				return c
	return Vector2i(-1, -1)


## Cuts a 4-connected pass from a to b. Never diagonal-only: a staircase of
## single tiles would be blocked by the flow field's no-corner-cutting rule.
## Returns the middle of the stretch that actually had to be cut, or (-1,-1).
func _carve(a: Vector2i, b: Vector2i) -> Vector2i:
	var cut: Array[Vector2i] = []
	var p: Vector2i = a
	var guard: int = Grid.manhattan(a, b) + 4
	while p != b and guard > 0:
		guard -= 1
		# One axis per step, whichever is further out: a clean staircase.
		if absi(b.x - p.x) >= absi(b.y - p.y):
			p.x += 1 if b.x > p.x else -1
		else:
			p.y += 1 if b.y > p.y else -1
		if not grid.in_bounds(p):
			break
		if (grid.flags_at(p) & Grid.F_WALK) == 0:
			grid.set_terrain(p, Grid.Terrain.GRAVEL)
			cut.append(p)
	return cut[cut.size() / 2] if not cut.is_empty() else Vector2i(-1, -1)


# ---------------------------------------------------------------- deposits

## Ore, coal, scrap and sulfur in believable clusters, only ever on ground the
## city can actually reach, and richer the further out they sit.
func _pass_deposits(rng: RandomNumberGenerator) -> void:
	var placed_by_kind: Dictionary[int, Array] = {}
	for spec: DepositSpec in profile.deposits:
		if spec == null:
			continue
		var placed: Array = placed_by_kind.get(spec.kind, [])
		for c_i: int in range(spec.clusters):
			# The first cluster of every kind is a STARTER patch, pinned to the
			# inner quarter of its ring. Area-uniform sampling alone pushes almost
			# everything to the rim, which on a real run means the player's first
			# coal is ninety tiles from the hearth.
			var origin: Vector2i = _pick_deposit_site(rng, spec, placed, c_i == 0)
			if origin.x < 0:
				continue
			placed.append(origin)
			_grow_deposit(rng, spec, origin)
		placed_by_kind[spec.kind] = placed

	for _i: int in range(profile.outer_vents):
		var site: Vector2i = _pick_site(rng, profile.outer_vent_min_distance, profile.outer_vent_max_distance, 40)
		if site.x < 0:
			continue
		grid.set_resource(site, Grid.Res.VENT, profile.outer_vent_output)
		# A vent melts its own ground: warm rock you can actually build a plant on.
		for c: Vector2i in Grid.disc(site, 2):
			if grid.in_bounds(c) and (grid.flags_at(c) & Grid.F_WALK) != 0:
				grid.set_terrain(c, Grid.Terrain.ASH)
				grid.set_snow(c, 0)


func _pick_deposit_site(rng: RandomNumberGenerator, spec: DepositSpec, placed: Array,
		starter: bool = false) -> Vector2i:
	var dmax: int = spec.max_distance
	if starter:
		dmax = mini(spec.max_distance, spec.min_distance + STARTER_BAND)
	for _a: int in range(48):
		var site: Vector2i = _pick_site(rng, spec.min_distance, dmax, 1)
		if site.x < 0:
			continue
		var ok: bool = true
		for p: Vector2i in placed:
			if Grid.chebyshev(p, site) < spec.spacing:
				ok = false
				break
		if ok:
			return site
	return Vector2i(-1, -1)


func _pick_site(rng: RandomNumberGenerator, dmin: int, dmax: int, attempts: int) -> Vector2i:
	for _a: int in range(maxi(attempts, 1)):
		var ang: float = rng.randf() * TAU
		# sqrt keeps the sample area-uniform, so the outer rings are not starved
		var r: float = lerpf(float(dmin), float(dmax), sqrt(rng.randf()))
		var c: Vector2i = core + Vector2i(int(round(cos(ang) * r)), int(round(sin(ang) * r)))
		if not grid.in_bounds(c) or not _is_open(c):
			continue
		return c
	return Vector2i(-1, -1)


func _is_open(c: Vector2i) -> bool:
	var idx: int = grid.index_of(c)
	if idx < 0 or idx >= _reach.size() or _reach[idx] == 0:
		return false
	var t: int = grid.terrain_at(c)
	if t == Grid.Terrain.ROAD or t == Grid.Terrain.GEOTHERMAL:
		return false
	return grid.resource_amount_at(c) == 0


func _grow_deposit(rng: RandomNumberGenerator, spec: DepositSpec, origin: Vector2i) -> void:
	var size: int = rng.randi_range(spec.size_min, spec.size_max)
	var rich: float = _richness(float(Vector2(core - origin).length()))
	var radius: float = maxf(sqrt(float(size)) * 0.9, 2.0)
	var p: Vector2i = origin
	for _s: int in range(size * 3):
		if _is_open(p):
			var away: float = float(Grid.chebyshev(p, origin)) / radius
			var falloff: float = clampf(1.0 - 0.45 * away, 0.35, 1.0)
			var amount: int = int(float(spec.base_amount) * rich * falloff * rng.randf_range(0.75, 1.3))
			grid.set_resource(p, spec.kind, maxi(amount, 1))
			size -= 1
			if size <= 0:
				return
		if rng.randf() < 0.22:
			p = origin
		else:
			p += Grid.DIRS8[rng.randi_range(0, 7)]
		if not grid.in_bounds(p):
			p = origin


## The outward pressure, in one line: yield scales with distance from the fire.
func _richness(dist: float) -> float:
	var dn: float = clampf(dist * _inv_max, 0.0, 1.0)
	return 1.0 + profile.richness_gain * pow(dn, profile.richness_exponent)


# ---------------------------------------------------------------- chokepoints

## Measures the narrowest walkable crossing on every approach lane. These are the
## tiles a defender wants and an attacker has to eat — the tower defense layer
## reads them straight off the terrain.
func _pass_chokepoints() -> void:
	chokepoints.clear()
	for li: int in range(lanes.size()):
		var lane: Dictionary = lanes[li]
		var path: PackedInt32Array = lane["path"]
		if path.size() < 6:
			continue
		var best_idx: int = -1
		var best_w: int = 1 << 30
		# Skip the first tiles: the core is not a chokepoint, it is the prize.
		for pi: int in range(maxi(profile.core_clear_radius, 6), path.size() - 2):
			var c: Vector2i = grid.cell_of(path[pi])
			var nxt: Vector2i = grid.cell_of(path[pi + 1])
			var dir: Vector2i = nxt - c
			if dir == Grid.ZERO:
				continue
			var perp: Vector2i = Vector2i(-dir.y, dir.x)
			var w: int = _corridor_width(c, perp)
			if w < best_w:
				best_w = w
				best_idx = path[pi]
		if best_idx >= 0 and best_w <= profile.chokepoint_max_width:
			lane["choke"] = best_idx
			lane["width"] = best_w
			lanes[li] = lane
			chokepoints.append(grid.cell_of(best_idx))

	# Carved passes are flanking routes; they count too, if they are tight.
	for c: Vector2i in carved_passes:
		if _open_width(c) > profile.chokepoint_max_width:
			continue
		var clear: bool = true
		for e: Vector2i in chokepoints:
			if Grid.chebyshev(e, c) < 8:
				clear = false
				break
		if clear:
			chokepoints.append(c)


## Narrowest of the horizontal and vertical walkable runs through a tile.
func _open_width(c: Vector2i) -> int:
	var narrow: int = 1 << 30
	for axis: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
		narrow = mini(narrow, _corridor_width(c, axis))
	return narrow


func _corridor_width(c: Vector2i, perp: Vector2i) -> int:
	var scan: int = maxi(profile.chokepoint_scan, 2)
	var w: int = 1
	for s: int in range(1, scan + 1):
		if not grid.is_walkable(c + perp * s):
			break
		w += 1
	for s: int in range(1, scan + 1):
		if not grid.is_walkable(c - perp * s):
			break
		w += 1
	return w


# ---------------------------------------------------------------- stats

func _collect_stats() -> void:
	var hist: PackedInt32Array = grid.terrain_histogram()
	var totals: PackedInt64Array = grid.resource_totals()
	var terrain: Dictionary = {}
	for t: int in range(Grid.TERRAIN_COUNT):
		terrain[Grid.TERRAIN_NAMES[t]] = hist[t]
	var res: Dictionary = {}
	for r: int in range(1, Grid.RES_COUNT):
		res[Grid.RES_NAMES[r]] = totals[r]
	var reachable: int = 0
	for v: int in _reach:
		if v != 0:
			reachable += 1
	stats = {
		"width": _w,
		"height": _h,
		"chunks": grid.chunk_count(),
		"core": [core.x, core.y],
		"terrain": terrain,
		"resources": res,
		"walkable": grid.walkable_count(),
		"reachable": reachable,
		"lanes": lanes.size(),
		"chokepoints": chokepoints.size(),
		"carved": carved_passes.size(),
	}
