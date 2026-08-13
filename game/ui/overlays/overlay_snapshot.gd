class_name LcnOverlaySnapshot
extends RefCounted
## [P19] The flattened, read-only picture of the simulation that every lens draws.
##
## WHY THIS EXISTS. The heat solver already computes, per tick, a per-node route
## distance, transmission efficiency, served fraction, bottleneck tile and choke
## reason, plus a per-network bottleneck list. Reading that graph of RefCounted
## objects sixty times a second, from six different lenses, would be both slow
## and a standing invitation for a view to poke a simulation field. So the
## simulation is read ONCE per sample into flat Packed arrays, and the lenses
## only ever see those.
##
## Two hard properties:
##   * **it never writes.** Every call in here is a documented read accessor.
##     tests/overlays proves it by serialising the whole sim before and after a
##     thousand samples and diffing the JSON.
##   * **it is cheap.** Sampling is 4 Hz by default and touches each heat node
##     once; drawing at 60 Hz touches only Packed arrays. Measured cost is in
##     `last_cost_us`, logged by the overlay root.

const TILE: float = 32.0

## Sections, so a lens only pays for what it actually draws.
const S_HEAT: int = 1 << 0
const S_BUILD: int = 1 << 1
const S_WARMTH: int = 1 << 2

## Sample cadence in ticks. Heat rebuilds routing at most once a tick; the eye
## cannot read faster than this and the arrays cost real memory traffic.
const SAMPLE_TICKS: int = 5

## Hard cap on thermal-field samples, so a strategic-zoom warmth lens cannot
## turn into a full-map temperature query.
const WARMTH_BUDGET: int = 14000

var heat: HeatSystem = null
var build: BuildSystem = null
var climate: ClimateSystem = null
var grid: GridSystem = null
var probe: LcnOverlayProbe = LcnOverlayProbe.new()

# --- networks (few; plain dictionaries are fine) ---------------------------
var nets: Array[Dictionary] = []
var net_slot: Dictionary[int, int] = {}
var net_row: Dictionary[int, int] = {}
var bottlenecks: Array[Dictionary] = []
var totals: Dictionary = {}
var ambient_c: float = -18.0

# --- heat nodes (hot path: parallel packed arrays) -------------------------
var node_count: int = 0
var node_id: PackedInt32Array = PackedInt32Array()
var node_x: PackedInt32Array = PackedInt32Array()
var node_y: PackedInt32Array = PackedInt32Array()
var node_w: PackedInt32Array = PackedInt32Array()
var node_h: PackedInt32Array = PackedInt32Array()
var node_slot: PackedInt32Array = PackedInt32Array()
var node_net: PackedInt32Array = PackedInt32Array()
var node_state: PackedInt32Array = PackedInt32Array()
var node_flags: PackedInt32Array = PackedInt32Array()
var node_dirs: PackedInt32Array = PackedInt32Array()
var node_link: PackedInt32Array = PackedInt32Array()
var node_choke: PackedInt32Array = PackedInt32Array()
var node_bx: PackedInt32Array = PackedInt32Array()
var node_by: PackedInt32Array = PackedInt32Array()
var node_served: PackedFloat32Array = PackedFloat32Array()
var node_load: PackedFloat32Array = PackedFloat32Array()
var node_temp: PackedFloat32Array = PackedFloat32Array()
var node_freeze: PackedFloat32Array = PackedFloat32Array()
var node_demand: PackedFloat32Array = PackedFloat32Array()
var node_output: PackedFloat32Array = PackedFloat32Array()
var node_fuel: PackedFloat32Array = PackedFloat32Array()
var node_eta: PackedFloat32Array = PackedFloat32Array()
var node_cool: PackedFloat32Array = PackedFloat32Array()
var node_kind: Array[StringName] = []
var node_row: Dictionary[int, int] = {}

# --- buildings ([P11], for the always-on layer and the coverage lens) ------
var bld_count: int = 0
var bld_id: PackedInt32Array = PackedInt32Array()
var bld_x: PackedInt32Array = PackedInt32Array()
var bld_y: PackedInt32Array = PackedInt32Array()
var bld_w: PackedInt32Array = PackedInt32Array()
var bld_h: PackedInt32Array = PackedInt32Array()
var bld_state: PackedInt32Array = PackedInt32Array()
var bld_workers: PackedInt32Array = PackedInt32Array()
var bld_need: PackedInt32Array = PackedInt32Array()
var bld_flags: PackedInt32Array = PackedInt32Array()
var bld_hp: PackedFloat32Array = PackedFloat32Array()
var bld_progress: PackedFloat32Array = PackedFloat32Array()
var bld_reach: PackedFloat32Array = PackedFloat32Array()
var bld_kind: Array[StringName] = []
var bld_row: Dictionary[int, int] = {}

const B_TURRET: int = 1 << 0
const B_HOUSING: int = 1 << 1
const B_STORAGE: int = 1 << 2
const B_CRAFTER: int = 1 << 3
const B_EXTRACTOR: int = 1 << 4
const B_GHOST: int = 1 << 5
const B_HEAT: int = 1 << 6    ## also a heat entity, so node_row has a row for it

# --- warmth field ---------------------------------------------------------
var warm_w: int = 0
var warm_h: int = 0
var warm_step: int = 1
var warm_origin: Vector2i = Vector2i.ZERO
var warm: PackedFloat32Array = PackedFloat32Array()
var warm_min: float = 0.0
var warm_max: float = 0.0

# --- diagnostics ----------------------------------------------------------
var last_tick: int = -1
var last_cost_us: int = 0
var samples: int = 0
var alive: bool = false

var _heat_tick: int = -10000
var _build_tick: int = -10000
var _warm_key: String = ""
var _prev_temp: Dictionary[int, float] = {}
var _prev_temp_tick: int = -1
var _dirty: bool = true


## Resolves the systems. Called on world_ready and whenever a lookup came back
## empty, so a snapshot created before the world exists heals itself.
func bind() -> void:
	heat = Sim.get_system(&"heat") as HeatSystem
	build = Sim.get_system(&"build") as BuildSystem
	climate = Sim.get_system(&"climate") as ClimateSystem
	grid = Sim.get_system(&"grid") as GridSystem
	probe.bind()
	alive = heat != null or build != null
	_heat_tick = -10000
	_build_tick = -10000
	_warm_key = ""
	_prev_temp.clear()
	_prev_temp_tick = -1
	_dirty = true


## Something structural changed (a placement, a network split). Forces the next
## sample to rebuild even if the cadence would have skipped it.
func mark_dirty() -> void:
	_dirty = true


## Refreshes the requested sections if they are stale. `tick` is SimClock.tick.
func sample(tick: int, sections: int) -> void:
	if heat == null and build == null:
		return
	var t0: int = Time.get_ticks_usec()
	var due: bool = _dirty or tick - _heat_tick >= SAMPLE_TICKS
	if (sections & S_HEAT) != 0 and due:
		_sample_heat(tick)
		_heat_tick = tick
	if (sections & S_BUILD) != 0 and (_dirty or tick - _build_tick >= SAMPLE_TICKS):
		_sample_buildings()
		_build_tick = tick
	if due:
		_dirty = false
	last_tick = tick
	samples += 1
	last_cost_us = Time.get_ticks_usec() - t0


# =========================================================================
# heat
# =========================================================================

func _sample_heat(tick: int) -> void:
	nets.clear()
	net_slot.clear()
	net_row.clear()
	bottlenecks.clear()
	node_row.clear()
	node_kind.clear()
	node_count = 0
	if heat == null:
		totals = {}
		return

	totals = heat.totals()
	ambient_c = float(totals.get("ambient", -18.0))

	var ids: PackedInt32Array = heat.network_ids()
	var slot: int = 0
	for nid: int in ids:
		var stats: Dictionary = heat.network_stats(nid)
		if stats.is_empty():
			continue
		net_slot[nid] = slot
		net_row[nid] = nets.size()
		stats["slot"] = slot
		nets.append(stats)
		for raw: Variant in stats.get("bottlenecks", []):
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var b: Dictionary = (raw as Dictionary).duplicate()
			b["net"] = nid
			b["slot"] = slot
			bottlenecks.append(b)
		slot += 1

	bottlenecks.sort_custom(_worse_bottleneck)

	var keys: Array = heat.nodes.keys()
	keys.sort()
	var n: int = keys.size()
	_resize_nodes(n)
	var graph: HeatGraph = heat.graph()
	var dt_s: float = maxf(0.05, float(tick - _prev_temp_tick) * SimClock.DT)
	var track_cool: bool = _prev_temp_tick >= 0
	var next_temp: Dictionary[int, float] = {}

	var i: int = 0
	for id: int in keys:
		var nd: HeatNode = heat.nodes[id]
		var d: HeatDef = nd.def
		node_id[i] = id
		node_x[i] = nd.bbox_origin.x
		node_y[i] = nd.bbox_origin.y
		node_w[i] = nd.bbox_size.x
		node_h[i] = nd.bbox_size.y
		var nid2: int = graph.net_of.get(id, -1)
		node_net[i] = nid2
		node_slot[i] = net_slot.get(nid2, -1)
		node_state[i] = nd.state
		node_served[i] = nd.served
		node_temp[i] = nd.temp_c
		node_freeze[i] = d.freeze_below
		node_demand[i] = nd.demand
		node_output[i] = nd.output
		node_eta[i] = nd.route_eta
		node_kind.append(nd.kind)
		node_row[id] = i

		var cap: float = d.capacity
		node_load[i] = clampf(nd.throughput / cap, 0.0, 1.0) if cap > 0.0 else 0.0
		node_fuel[i] = clampf(nd.fuel_stock / d.fuel_capacity, 0.0, 1.0) if d.fuel_capacity > 0.0 else 1.0

		var flags: int = 0
		if d.is_producer():
			flags |= LcnOverlayDefs.F_PRODUCER
		if d.is_consumer():
			flags |= LcnOverlayDefs.F_CONSUMER
		if d.conducts():
			flags |= LcnOverlayDefs.F_CONDUIT
		if d.is_buffer():
			flags |= LcnOverlayDefs.F_BUFFER
		if d.radiates():
			flags |= LcnOverlayDefs.F_RADIATOR
		if d.repeater:
			flags |= LcnOverlayDefs.F_REPEATER
		if nd.frozen:
			flags |= LcnOverlayDefs.F_FROZEN
		if not nd.enabled:
			flags |= LcnOverlayDefs.F_DISABLED
		if nd.starved_fuel:
			flags |= LcnOverlayDefs.F_STARVED_FUEL
		if nd.route_dist < 0 and nd.enabled and not nd.frozen:
			flags |= LcnOverlayDefs.F_UNREACHABLE
		if d.is_consumer() and nd.served < 0.999 and nd.enabled:
			flags |= LcnOverlayDefs.F_STARVED
		if nid2 < 0 and d.is_consumer():
			flags |= LcnOverlayDefs.F_NO_NETWORK
		node_flags[i] = flags

		node_choke[i] = _choke_id(nd.bottleneck_kind)
		node_bx[i] = -1
		node_by[i] = -1
		if nd.bottleneck_node >= 0:
			var src: HeatNode = heat.nodes.get(nd.bottleneck_node)
			if src != null:
				node_bx[i] = src.center_cell.x
				node_by[i] = src.center_cell.y

		# Cooling rate in degrees per second, from the previous sample. This is
		# what turns "cold" into "frozen in 14 s", which is the only form of the
		# number a player can act on.
		var cool: float = 0.0
		if track_cool:
			var prev: float = _prev_temp.get(id, nd.temp_c)
			cool = (prev - nd.temp_c) / dt_s
		node_cool[i] = cool
		next_temp[id] = nd.temp_c
		i += 1

	node_count = n
	_prev_temp = next_temp
	_prev_temp_tick = tick
	_mark_choking_tiles()
	_compute_flow_dirs(graph)


func _resize_nodes(n: int) -> void:
	node_id.resize(n)
	node_x.resize(n)
	node_y.resize(n)
	node_w.resize(n)
	node_h.resize(n)
	node_slot.resize(n)
	node_net.resize(n)
	node_state.resize(n)
	node_flags.resize(n)
	node_dirs.resize(n)
	node_link.resize(n)
	node_choke.resize(n)
	node_bx.resize(n)
	node_by.resize(n)
	node_served.resize(n)
	node_load.resize(n)
	node_temp.resize(n)
	node_freeze.resize(n)
	node_demand.resize(n)
	node_output.resize(n)
	node_fuel.resize(n)
	node_eta.resize(n)
	node_cool.resize(n)


func _mark_choking_tiles() -> void:
	for b: Dictionary in bottlenecks:
		var row: int = node_row.get(int(b.get("node", -1)), -1)
		if row >= 0:
			node_flags[row] |= LcnOverlayDefs.F_CHOKED


## Which way heat is actually moving through each conduit tile.
##
## The solver's routing tree already answers it: a neighbour that the BFS
## reached one hop LATER is downstream of this tile. Recovering it here costs
## one pass over the adjacency list and means the flow arrows on screen are the
## solver's own routes rather than a plausible-looking guess.
func _compute_flow_dirs(graph: HeatGraph) -> void:
	for i: int in node_count:
		node_dirs[i] = 0
		node_link[i] = 0
	if heat == null:
		return
	for i2: int in node_count:
		var id: int = node_id[i2]
		var me: HeatNode = heat.nodes.get(id)
		if me == null:
			continue
		var links: PackedInt32Array = graph.neigh.get(id, PackedInt32Array())
		var flow: int = 0
		var wired: int = 0
		for other: int in links:
			var row: int = node_row.get(other, -1)
			if row < 0 or node_net[row] != node_net[i2]:
				continue
			var on: HeatNode = heat.nodes.get(other)
			if on == null:
				continue
			var bit: int = LcnOverlayDefs.dir_bit(me.center_cell, on.center_cell)
			wired |= bit
			if me.route_dist >= 0 and on.route_dist > me.route_dist:
				flow |= bit
		node_dirs[i2] = flow
		node_link[i2] = wired


static func _choke_id(kind: StringName) -> int:
	match kind:
		&"capacity":
			return LcnOverlayDefs.Choke.CAPACITY
		&"supply":
			return LcnOverlayDefs.Choke.SUPPLY
		&"unreachable":
			return LcnOverlayDefs.Choke.UNREACHABLE
	return LcnOverlayDefs.Choke.NONE


static func _worse_bottleneck(a: Dictionary, b: Dictionary) -> bool:
	var ca: int = int(a.get("consumers", 0))
	var cb: int = int(b.get("consumers", 0))
	if ca != cb:
		return ca > cb
	return int(a.get("node", 0)) < int(b.get("node", 0))


# =========================================================================
# buildings
# =========================================================================

func _sample_buildings() -> void:
	bld_row.clear()
	bld_kind.clear()
	bld_count = 0
	if build == null:
		return
	var list: Array[BuildingInstance] = build.all_buildings()
	var n: int = list.size()
	bld_id.resize(n)
	bld_x.resize(n)
	bld_y.resize(n)
	bld_w.resize(n)
	bld_h.resize(n)
	bld_state.resize(n)
	bld_workers.resize(n)
	bld_need.resize(n)
	bld_flags.resize(n)
	bld_hp.resize(n)
	bld_progress.resize(n)
	bld_reach.resize(n)

	# Without a citizens system every building reports zero crew, and badging the
	# whole city with "no crew" is noise. -1 means "nobody staffs anything yet".
	var staffed: bool = probe.has_citizens()
	var i: int = 0
	for b: BuildingInstance in list:
		var d: BuildingDef = b.def
		var r: Rect2i = b.rect()
		bld_id[i] = b.id
		bld_x[i] = r.position.x
		bld_y[i] = r.position.y
		bld_w[i] = maxi(1, r.size.x)
		bld_h[i] = maxi(1, r.size.y)
		bld_state[i] = b.state
		bld_workers[i] = b.workers if staffed else -1
		bld_need[i] = d.workers_required if d != null else 0
		bld_hp[i] = b.health_ratio()
		bld_progress[i] = b.progress_ratio()
		bld_kind.append(b.kind)
		bld_row[b.id] = i

		var flags: int = 0
		var reach: float = 0.0
		if d != null:
			if d.has_tag(&"turret") or String(d.weapon_id) != "":
				flags |= B_TURRET
				# The real weapon range, read from the weapon definition. Falling
				# back to vision radius would draw a defence ring that is not the
				# ring the guns actually shoot inside, which is worse than none.
				var probed: float = probe.weapon_range(d.weapon_id)
				reach = probed if probed > 0.0 else maxf(d.vision_radius, 8.0)
			elif d.vision_radius > 0.0:
				reach = d.vision_radius
			if d.residents > 0 or d.has_tag(&"housing"):
				flags |= B_HOUSING
			if d.storage_capacity > 0 or d.has_tag(&"storage"):
				flags |= B_STORAGE
			if not d.recipes.is_empty() or d.has_tag(&"crafter"):
				flags |= B_CRAFTER
			if String(d.extracts) != "":
				flags |= B_EXTRACTOR
		if not b.is_complete():
			flags |= B_GHOST
		if node_row.has(b.id):
			flags |= B_HEAT
		bld_flags[i] = flags
		bld_reach[i] = reach
		i += 1
	bld_count = n


# =========================================================================
# warmth field
# =========================================================================

## Samples ambient+radiant temperature over the visible rectangle into a small
## scalar field. One texel per tile until the view gets large, then a coarser
## step — the field is drawn through a linear filter, so a 2x step is invisible
## and a full-map query is never issued.
func sample_warmth(view: Rect2, force: bool = false) -> void:
	if heat == null:
		warm_w = 0
		warm_h = 0
		return
	var pad: float = TILE * 2.0
	var lo := Vector2i(int(floor((view.position.x - pad) / TILE)), int(floor((view.position.y - pad) / TILE)))
	var hi := Vector2i(int(ceil((view.end.x + pad) / TILE)), int(ceil((view.end.y + pad) / TILE)))
	var w: int = maxi(2, hi.x - lo.x)
	var h: int = maxi(2, hi.y - lo.y)
	var step: int = 1
	while (w / step) * (h / step) > WARMTH_BUDGET and step < 16:
		step += 1
	var sw: int = maxi(2, w / step)
	var sh: int = maxi(2, h / step)
	var key: String = "%d,%d,%d,%d,%d,%d" % [lo.x, lo.y, sw, sh, step, last_tick / SAMPLE_TICKS]
	if key == _warm_key and not force:
		return
	_warm_key = key
	warm_origin = lo
	warm_step = step
	warm_w = sw
	warm_h = sh
	warm.resize(sw * sh)
	var base: float = heat.ambient()
	ambient_c = base
	var lowest: float = 9999.0
	var highest: float = -9999.0
	var field: WarmthField = heat.warmth_field()
	for y: int in sh:
		var row: int = y * sw
		var cy: int = lo.y + y * step
		for x: int in sw:
			var v: float = base + field.value_at(Vector2i(lo.x + x * step, cy))
			warm[row + x] = v
			lowest = minf(lowest, v)
			highest = maxf(highest, v)
	warm_min = lowest
	warm_max = highest


func warm_rect() -> Rect2:
	return Rect2(
		Vector2(warm_origin) * TILE,
		Vector2(float(warm_w * warm_step), float(warm_h * warm_step)) * TILE)


# =========================================================================
# queries the lenses and the legend use
# =========================================================================

func network_count() -> int:
	return nets.size()


func slot_of_network(nid: int) -> int:
	return net_slot.get(nid, -1)


func stats_of_network(nid: int) -> Dictionary:
	var row: int = net_row.get(nid, -1)
	return nets[row] if row >= 0 else {}


func node_rect(i: int) -> Rect2:
	return Rect2(
		Vector2(float(node_x[i]), float(node_y[i])) * TILE,
		Vector2(float(node_w[i]), float(node_h[i])) * TILE)


func node_center(i: int) -> Vector2:
	return Vector2(
		(float(node_x[i]) + float(node_w[i]) * 0.5) * TILE,
		(float(node_y[i]) + float(node_h[i]) * 0.5) * TILE)


func bld_rect(i: int) -> Rect2:
	return Rect2(
		Vector2(float(bld_x[i]), float(bld_y[i])) * TILE,
		Vector2(float(bld_w[i]), float(bld_h[i])) * TILE)


func bld_center(i: int) -> Vector2:
	return Vector2(
		(float(bld_x[i]) + float(bld_w[i]) * 0.5) * TILE,
		(float(bld_y[i]) + float(bld_h[i]) * 0.5) * TILE)


## Seconds until this building freezes at its current cooling rate, or -1 when
## it is not cooling toward the line.
func freeze_eta(i: int) -> float:
	var margin: float = node_temp[i] - node_freeze[i]
	if margin <= 0.0:
		return 0.0
	var rate: float = node_cool[i]
	if rate <= 0.01:
		return -1.0
	return margin / rate


## How many consumers are short of heat right now, city-wide.
func starved_count() -> int:
	var n: int = 0
	for i: int in node_count:
		if (node_flags[i] & LcnOverlayDefs.F_STARVED) != 0:
			n += 1
	return n


func frozen_count() -> int:
	var n: int = 0
	for i: int in node_count:
		if (node_flags[i] & LcnOverlayDefs.F_FROZEN) != 0:
			n += 1
	return n


## The single worst thing happening to the heat grid, as one sentence. The
## legend puts this under the title; it is the line a stranger reads first.
func headline() -> String:
	if node_count == 0:
		return "no heat network yet"
	if not bottlenecks.is_empty():
		var b: Dictionary = bottlenecks[0]
		var cell: Array = b.get("cell", [0, 0])
		if String(b.get("reason", "")) == "capacity":
			return "%s at (%d, %d) is over capacity %.0f/%.0f — %d starved" % [
				String(b.get("kind", "line")), int(cell[0]), int(cell[1]),
				float(b.get("load", 0.0)), float(b.get("capacity", 0.0)),
				int(b.get("consumers", 0))]
		return "network %d cannot generate enough — %d starved" % [
			int(b.get("net", 0)), int(b.get("consumers", 0))]
	var frozen: int = frozen_count()
	if frozen > 0:
		return "%d building%s frozen" % [frozen, "" if frozen == 1 else "s"]
	var starved: int = starved_count()
	if starved > 0:
		return "%d building%s short of heat" % [starved, "" if starved == 1 else "s"]
	if nets.size() > 1:
		return "%d separate grids — they do not share heat" % nets.size()
	return "grid nominal"
