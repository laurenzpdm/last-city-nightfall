class_name HeatSystem
extends SimSystem
## [P02] Heat & Power Network — the spine of the game.
##
## Heat is the power grid, the warmth that keeps citizens alive, and the
## ammunition the turrets burn. One resource, three genres. This system owns:
##
##   * the network GRAPH — generators, conduits, buffers and consumers wired by
##     adjacency, with connected components maintained incrementally (HeatGraph)
##   * the per-tick FLOW SOLVE — routing, throughput limits, distance loss,
##     priority load shedding, buffers, and a traceable bottleneck for every
##     browned-out building (HeatFlow)
##   * the radiant WARMTH FIELD — degrees above ambient on every tile, which is
##     what citizens and buildings actually feel (WarmthField)
##   * THERMAL state — every building has an internal temperature; lose heat
##     long enough and it freezes, and a frozen generator takes its network
##     down with it
##
## Everything a definition needs to join the network is data: drop a .tres in
## game/content/buildings/ with heat_output / heat_demand / heat_capacity /
## heat_storage fields (see HeatBuildingDef) and it is a heat entity. No code
## in this folder knows the name of a single building.
##
## Contracts other parts use:
##   warmth_at(cell) -> float            degrees above ambient at a tile
##   temperature_at(cell) -> float       ambient + warmth, what a citizen feels
##   network_of(building_id) -> int      which network a building sits on
##   network_stats(nid) -> Dictionary    supply, demand, buffer, deficit, loss...
##   power_factor(building_id) -> float  0..1 rate multiplier for machines/turrets
##   register_building(id, kind, cell)   [P11] build calls this (or emits on Bus)
##   deliver_fuel(id, item, amount)      [P03] logistics feeds the burners

const SYSTEM_ORDER: int = 25          ## after climate (10) and grid (20)
const TILE: float = 32.0

# --- thermal model --------------------------------------------------------
const COMFORT_C: float = 10.0         ## below this the cold starts costing extra heat
const DEMAND_PER_DEGREE: float = 0.010
const INTERNAL_C_PER_UNIT: float = 1.6
const SELF_HEAT_FRAC: float = 0.15    ## a burning generator warms its own shell
const WARM_RATE: float = 0.020        ## per tick, heating up (~2.5 s)
const COOL_RATE: float = 0.002        ## per tick, cooling down (~25 s) — insulation slows it further
const THAW_MARGIN: float = 8.0
const FREEZE_HOLD_TICKS: int = 60     ## 3 s below the line before it actually freezes
const DEFAULT_AMBIENT_C: float = -18.0

# --- radiance / field -----------------------------------------------------
const WARMTH_REFRESH_TICKS: int = 5   ## heat diffuses slowly; 4 Hz is plenty
const RADIANCE_SMOOTH: float = 0.08

# --- events ---------------------------------------------------------------
const SHORTFALL_EVERY: int = 20       ## at most one shortfall signal per network per second
const ALERT_EVERY: int = 100          ## and one worded alert per 5 s unless the cause changes
const SEV_WARN: int = 1               ## severity 2+ is reserved for real faults; a brownout is gameplay
const FUEL_PULL_EVERY: int = 10
const LOCAL_ID_BASE: int = 1000000    ## ids we mint ourselves never collide with [P11]'s

var nodes: Dictionary[int, HeatNode] = {}

var _graph: HeatGraph = null
var _flow: HeatFlow = null
var _warmth: WarmthField = null
var _defs: Dictionary[StringName, HeatDef] = {}
var _nets: Dictionary[int, HeatNetwork] = {}
var _ids: PackedInt32Array = PackedInt32Array()
var _ids_dirty: bool = true
var _next_local_id: int = LOCAL_ID_BASE

var _ambient_c: float = DEFAULT_AMBIENT_C
var _cold_mult: float = 1.0
var _fuel_autarky: bool = true
var _climate: SimSystem = null
var _grid: SimSystem = null
var _build: SimSystem = null
var _fuel_source: SimSystem = null
var _has_ambient: bool = false
var _has_loss_mult: bool = false
var _has_set_frozen: bool = false
var _has_resource_amount: bool = false

var _total_supply: float = 0.0
var _total_demand: float = 0.0
var _total_delivered: float = 0.0
var _total_deficit: float = 0.0
var _total_loss: float = 0.0
var _total_buffer: float = 0.0
var _brownouts: int = 0
var _frozen_count: int = 0


func system_name() -> StringName:
	return &"heat"


func setup() -> void:
	order = SYSTEM_ORDER
	nodes = {}
	_graph = HeatGraph.new(nodes)
	_flow = HeatFlow.new()
	_warmth = WarmthField.new()
	_nets = {}
	_defs = {}
	_ids = PackedInt32Array()
	_ids_dirty = true
	_next_local_id = LOCAL_ID_BASE
	_ambient_c = DEFAULT_AMBIENT_C
	_load_defs()


func post_setup() -> void:
	_climate = Sim.get_system(&"climate")
	_grid = Sim.get_system(&"grid")
	_build = Sim.get_system(&"build")
	_has_ambient = _climate != null and _climate.has_method("ambient_temperature")
	_has_loss_mult = _climate != null and _climate.has_method("heat_loss_multiplier")
	_has_set_frozen = _build != null and _build.has_method("set_frozen")
	_has_resource_amount = _grid != null and _grid.has_method("resource_amount_at")
	var logistics: SimSystem = Sim.get_system(&"logistics")
	var production: SimSystem = Sim.get_system(&"production")
	_fuel_source = logistics if logistics != null else production
	# Nobody hauls fuel yet: burners run on faith so the network is still
	# testable in isolation. The moment [P03] or [P04] exists, fuel is real.
	_fuel_autarky = logistics == null and production == null
	Log.info("heat", "ready — %d heat definitions, climate=%s build=%s grid=%s fuel=%s" % [
		_defs.size(), str(_climate != null), str(_build != null), str(_grid != null),
		"autarky" if _fuel_autarky else "metered"])


func step(tick: int) -> void:
	_sync_from_build()
	var changed: PackedInt32Array = _graph.settle()
	for nid: int in changed:
		if not _graph.members.has(nid):
			_nets.erase(nid)
		else:
			_network(nid).route_dirty = true
		Bus.network_changed.emit(nid)

	_ambient_c = _read_ambient()
	_cold_mult = _read_loss_multiplier()

	_total_supply = 0.0
	_total_demand = 0.0
	_total_delivered = 0.0
	_total_deficit = 0.0
	_total_loss = 0.0
	_total_buffer = 0.0
	_brownouts = 0

	for nid: int in _graph.network_ids():
		var net: HeatNetwork = _network(nid)
		_flow.solve(net, _graph.members[nid], nodes, _graph.neigh,
			SimClock.DT, _cold_mult, _graph.version, _fuel_autarky)
		_total_supply += net.supply
		_total_demand += net.demand
		_total_delivered += net.delivered
		_total_deficit += net.deficit
		_total_loss += net.loss
		_total_buffer += net.buffer
		_brownouts += net.brownouts
		_report(net, tick)

	_burn_fuel()
	_thermal()
	_radiate(tick)
	if tick % FUEL_PULL_EVERY == 0:
		_pull_fuel()


# =========================================================================
# public API — everything another part is allowed to touch
# =========================================================================

## Degrees Celsius of radiant warmth on a tile, on top of the climate ambient.
func warmth_at(cell: Vector2i) -> float:
	return _warmth.value_at(cell)


## What a citizen standing on this tile actually feels, in degrees Celsius.
func temperature_at(cell: Vector2i) -> float:
	return _ambient_c + _warmth.value_at(cell)


## Outdoor temperature this tick, straight from [P09] climate when it exists.
func ambient() -> float:
	return _ambient_c


## Network id a building belongs to, or -1.
func network_of(building_id: int) -> int:
	return _graph.net_of.get(building_id, -1)


## Balance sheet of one network: supply, demand, buffer, deficit, loss, plus the
## bottleneck list the HUD needs to explain a brownout. Empty when unknown.
func network_stats(nid: int) -> Dictionary:
	var net: HeatNetwork = _nets.get(nid)
	if net == null or not _graph.members.has(nid):
		return {}
	return net.stats(_graph.members[nid].size())


## Every live network id, sorted.
func network_ids() -> PackedInt32Array:
	return _graph.network_ids()


## Tiles that choked a network this tick, worst first.
func bottlenecks_of(nid: int) -> Array[Dictionary]:
	var net: HeatNetwork = _nets.get(nid)
	if net == null:
		return []
	return net.bottlenecks.duplicate(true)


## Adds a building to the heat world. Returns false when the kind has no heat
## behaviour (a plain house is simply not a heat entity), when the id is taken,
## or when the footprint overlaps something. [P11] build owns placement rules;
## this only owns the network.
func register_building(building_id: int, kind: StringName, cell: Vector2i, rot: int = 0) -> bool:
	if nodes.has(building_id):
		return false
	var def: HeatDef = _def_for(kind)
	if def == null or not def.participates():
		return false
	var node := HeatNode.new()
	node.setup(building_id, kind, cell, def, rot)
	# Fresh construction is warm from the work that built it; without this every
	# building placed in a blizzard would freeze before its heat ever arrived.
	node.temp_c = maxf(_ambient_c, def.freeze_below + 15.0)
	node.site_bonus = _site_bonus(node)
	node.local_stored = def.local_buffer * 0.5
	nodes[building_id] = node
	if not _graph.add(node):
		nodes.erase(building_id)
		Bus.placement_rejected.emit(cell, "heat: footprint blocked")
		return false
	_ids_dirty = true
	var nid: int = _graph.net_of.get(building_id, -1)
	if nid >= 0:
		_network(nid).route_dirty = true
	if def.radiates():
		_warmth.set_source(building_id, node.bbox_origin, node.bbox_size, def.radius, 0.0)
	Log.debug("heat", "registered #%d %s at %s (net %d)" % [building_id, kind, str(cell), nid])
	return true


## Removes a building from the heat world. Its component is re-split on the next
## tick, and only that component.
func unregister_building(building_id: int) -> bool:
	var node: HeatNode = nodes.get(building_id)
	if node == null:
		return false
	if node.def.radiates():
		_warmth.remove_source(building_id)
	_graph.remove(building_id)
	nodes.erase(building_id)
	_ids_dirty = true
	return true


func has_building(building_id: int) -> bool:
	return nodes.has(building_id)


## 0..1 rate multiplier for whatever the building does: a browned-out turret
## fires slower, a browned-out machine crafts slower, a frozen one does nothing.
func power_factor(building_id: int) -> float:
	var n: HeatNode = nodes.get(building_id)
	return n.power_factor() if n != null else 0.0


## Fraction of the heat a building asked for that it actually got, 0..1.
func served_of(building_id: int) -> float:
	var n: HeatNode = nodes.get(building_id)
	return n.served if n != null else 0.0


## HeatNode.State — ONLINE / BROWNOUT / OFFLINE / FROZEN.
func state_of(building_id: int) -> int:
	var n: HeatNode = nodes.get(building_id)
	return n.state if n != null else HeatNode.State.OFFLINE


func is_frozen(building_id: int) -> bool:
	var n: HeatNode = nodes.get(building_id)
	return n.frozen if n != null else false


## Internal temperature of a building in degrees Celsius.
func temperature_of(building_id: int) -> float:
	var n: HeatNode = nodes.get(building_id)
	return n.temp_c if n != null else _ambient_c


## Why this building is cold: {node, cell, kind} of the tile that choked it, or
## an empty dictionary when nothing did.
func bottleneck_of(building_id: int) -> Dictionary:
	var n: HeatNode = nodes.get(building_id)
	if n == null or n.bottleneck_node < 0:
		var reason: Dictionary = {}
		if n != null and n.bottleneck_kind != &"":
			reason["kind"] = String(n.bottleneck_kind)
		return reason
	var b: HeatNode = nodes.get(n.bottleneck_node)
	return {
		"node": n.bottleneck_node,
		"kind": String(n.bottleneck_kind),
		"cell": [b.cell.x, b.cell.y] if b != null else [0, 0],
		"building": String(b.kind) if b != null else "",
	}


## [P03] logistics drops fuel into a burner's bunker. Returns how much was
## accepted, so a belt knows what to keep.
func deliver_fuel(building_id: int, item: StringName, amount: float) -> float:
	var n: HeatNode = nodes.get(building_id)
	if n == null or n.def.fuel == &"" or item != n.def.fuel:
		return 0.0
	var room: float = maxf(0.0, n.def.fuel_capacity - n.fuel_stock)
	var take: float = minf(room, maxf(0.0, amount))
	n.fuel_stock += take
	return take


func fuel_stock_of(building_id: int) -> float:
	var n: HeatNode = nodes.get(building_id)
	return n.fuel_stock if n != null else 0.0


func set_building_enabled(building_id: int, on: bool) -> void:
	var n: HeatNode = nodes.get(building_id)
	if n == null or n.enabled == on:
		return
	n.enabled = on
	var nid: int = _graph.net_of.get(building_id, -1)
	if nid >= 0:
		_network(nid).route_dirty = true


func set_building_priority(building_id: int, priority: int) -> void:
	var n: HeatNode = nodes.get(building_id)
	if n == null:
		return
	n.priority = clampi(priority, 0, 100)


## City-wide totals, the same numbers metrics() reports.
func totals() -> Dictionary:
	return {
		"supply": snappedf(_total_supply, 0.001),
		"demand": snappedf(_total_demand, 0.001),
		"delivered": snappedf(_total_delivered, 0.001),
		"deficit": snappedf(_total_deficit, 0.001),
		"loss": snappedf(_total_loss, 0.001),
		"buffer": snappedf(_total_buffer, 0.001),
		"networks": _graph.members.size(),
		"buildings": nodes.size(),
		"frozen": _frozen_count,
		"brownouts": _brownouts,
		"ambient": snappedf(_ambient_c, 0.01),
		"avg_warmth": snappedf(_warmth.average(), 0.01),
	}


## Sorted [x, y, degrees] triples for the overlay layer and for saves.
func warmth_snapshot() -> Array:
	return _warmth.snapshot()


## Throws away the incremental component bookkeeping and re-derives it from
## adjacency. Used by tests and by save loading — never needed in play.
func rebuild_networks() -> void:
	_graph.rebuild_all()
	for nid: int in _graph.network_ids():
		_network(nid).clear_routing()
	var stale: Array = _nets.keys()
	stale.sort()
	for nid: int in stale:
		if not _graph.members.has(nid):
			_nets.erase(nid)


## Forces the next tick to rebuild every route from scratch. Tests use it to
## prove the cached routing equals the fresh one.
func invalidate_routes() -> void:
	for nid: int in _nets:
		_nets[nid].route_dirty = true


func graph() -> HeatGraph:
	return _graph


func warmth_field() -> WarmthField:
	return _warmth


# =========================================================================
# commands (harness scenarios, [P11] build, debug console)
# =========================================================================

func handle_command(cmd: Dictionary) -> void:
	var op: String = String(cmd.get("op", ""))
	match op:
		"place":
			var kind: StringName = StringName(String(cmd.get("kind", "")))
			var cell: Vector2i = _to_cell(cmd.get("cell", []))
			var id: int = int(cmd.get("id", _mint_id()))
			if not register_building(id, kind, cell, int(cmd.get("rot", 0))):
				Log.warn("heat", "place rejected: %s at %s" % [kind, str(cell)])
		"line":
			_place_line(StringName(String(cmd.get("kind", ""))),
				_to_cell(cmd.get("from", [])), _to_cell(cmd.get("to", [])))
		"remove":
			unregister_building(int(cmd.get("id", -1)))
		"remove_at":
			var found: int = _graph.occ.get(_to_cell(cmd.get("cell", [])), -1)
			if found >= 0:
				unregister_building(found)
		"set_enabled":
			set_building_enabled(int(cmd.get("id", -1)), bool(cmd.get("on", true)))
		"set_priority":
			set_building_priority(int(cmd.get("id", -1)), int(cmd.get("priority", 50)))
		"deliver_fuel":
			var amount: float = deliver_fuel(int(cmd.get("id", -1)),
				StringName(String(cmd.get("item", ""))), float(cmd.get("amount", 0.0)))
			Log.debug("heat", "fuel delivered %.1f" % amount)
		"fuel_all":
			_fuel_all(StringName(String(cmd.get("item", ""))), float(cmd.get("amount", 0.0)))
		"dump":
			_dump()
		_:
			Log.warn("heat", "unknown command op '%s'" % op)


func _place_line(kind: StringName, from: Vector2i, to: Vector2i) -> void:
	var cur: Vector2i = from
	var guard: int = 0
	while guard < 4096:
		guard += 1
		if not _graph.occ.has(cur):
			register_building(_mint_id(), kind, cur)
		if cur == to:
			return
		if cur.x != to.x:
			cur.x += signi(to.x - cur.x)
		elif cur.y != to.y:
			cur.y += signi(to.y - cur.y)
		else:
			return


func _fuel_all(item: StringName, amount: float) -> void:
	for id: int in _sorted_ids():
		var n: HeatNode = nodes[id]
		if n.def.fuel == item:
			n.fuel_stock = minf(n.def.fuel_capacity, n.fuel_stock + amount)


func _dump() -> void:
	for nid: int in _graph.network_ids():
		var s: Dictionary = network_stats(nid)
		Log.info("heat", "net %d: supply %.1f demand %.1f delivered %.1f deficit %.1f loss %.2f buffer %.0f" % [
			nid, float(s.get("supply", 0.0)), float(s.get("demand", 0.0)),
			float(s.get("delivered", 0.0)), float(s.get("deficit", 0.0)),
			float(s.get("loss", 0.0)), float(s.get("buffer", 0.0))])


# =========================================================================
# internals
# =========================================================================

func _load_defs() -> void:
	var count: int = 0
	for id: StringName in Registry.ids("buildings"):
		var res: Resource = Registry.get_item("buildings", id)
		var def: HeatDef = HeatDef.from_resource(id, res)
		if not def.participates():
			continue
		_defs[id] = def
		count += 1
	Log.debug("heat", "%d building definitions carry heat behaviour" % count)


func _def_for(kind: StringName) -> HeatDef:
	var cached: HeatDef = _defs.get(kind)
	if cached != null:
		return cached
	if not Registry.has("buildings", kind):
		return null
	var def: HeatDef = HeatDef.from_resource(kind, Registry.get_item("buildings", kind))
	if not def.participates():
		return null
	_defs[kind] = def
	return def


## Pulls the finished buildings out of [P11] every tick. Build runs at order 15,
## heat at 25, so anything completed this tick is already on the network this
## tick. A pull instead of a Bus subscription on purpose: a RefCounted system
## that subscribes to an autoload signal is never released, and the heat state
## of a building belongs to whoever owns the building, not to a signal replay.
func _sync_from_build() -> void:
	if _build == null or not _build.has_method("all_buildings"):
		return
	var raw: Variant = _build.call("all_buildings")
	if typeof(raw) != TYPE_ARRAY:
		return
	var list: Array = raw
	var seen: Dictionary[int, bool] = {}
	for entry: Variant in list:
		var b: Object = entry
		if b == null or not b.has_method("is_complete"):
			continue
		if not bool(b.call("is_complete")):
			continue
		var id: int = int(b.get("id"))
		seen[id] = true
		var n: HeatNode = nodes.get(id)
		if n == null:
			if register_building(id, StringName(String(b.get("kind"))),
					b.get("cell"), int(b.get("rot"))):
				n = nodes.get(id)
			if n == null:
				continue
		var on: bool = bool(b.get("enabled"))
		if n.enabled != on:
			set_building_enabled(id, on)
		# BuildingInstance.heat_stored is documented as ours to write.
		b.set("heat_stored", n.stored + n.local_stored)
	for id: int in _sorted_ids().duplicate():
		if id >= LOCAL_ID_BASE or seen.has(id):
			continue
		unregister_building(id)


func _network(nid: int) -> HeatNetwork:
	var net: HeatNetwork = _nets.get(nid)
	if net == null:
		net = HeatNetwork.new(nid)
		_nets[nid] = net
	return net


func _mint_id() -> int:
	var id: int = _next_local_id
	_next_local_id += 1
	return id


func _sorted_ids() -> PackedInt32Array:
	if not _ids_dirty:
		return _ids
	var keys: Array = nodes.keys()
	keys.sort()
	_ids = PackedInt32Array()
	for k: int in keys:
		_ids.append(k)
	_ids_dirty = false
	return _ids


func _to_cell(v: Variant) -> Vector2i:
	match typeof(v):
		TYPE_VECTOR2I:
			return v
		TYPE_VECTOR2:
			var f: Vector2 = v
			return Vector2i(int(f.x), int(f.y))
		TYPE_ARRAY:
			var a: Array = v
			if a.size() >= 2:
				return Vector2i(int(a[0]), int(a[1]))
		TYPE_DICTIONARY:
			var d: Dictionary = v
			return Vector2i(int(d.get("x", 0)), int(d.get("y", 0)))
	return Vector2i.ZERO


## [P09] climate owns the weather; we only ask how cold it is outside.
func _read_ambient() -> float:
	if not _has_ambient:
		return DEFAULT_AMBIENT_C
	var v: Variant = _climate.call("ambient_temperature")
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return DEFAULT_AMBIENT_C


## Wind, storms and a deepening winter all make the same building cost more heat
## to keep alive. [P09] owns that curve; without it we fall back to a plain
## linear one so the system still behaves in isolation.
func _read_loss_multiplier() -> float:
	if _has_loss_mult:
		var v: Variant = _climate.call("heat_loss_multiplier")
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			return maxf(1.0, float(v))
	return 1.0 + maxf(0.0, COMFORT_C - _ambient_c) * DEMAND_PER_DEGREE


## [P01] grid owns the ground. A fuel-free generator sunk into a richer vent
## draws more out of it. Never a penalty, so a missing grid changes nothing.
func _site_bonus(node: HeatNode) -> float:
	if not _has_resource_amount or node.def.fuel != &"" or not node.def.is_producer():
		return 1.0
	var best: int = 0
	for c: Vector2i in node.footprint:
		var v: Variant = _grid.call("resource_amount_at", c)
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			best = maxi(best, int(v))
	return 1.0 + clampf(float(best) / 2000.0, 0.0, 0.5)


func _burn_fuel() -> void:
	if _fuel_autarky:
		return
	var dt: float = SimClock.DT
	for id: int in _sorted_ids():
		var n: HeatNode = nodes[id]
		if n.def.fuel == &"" or n.def.fuel_per_unit <= 0.0 or not n.enabled or n.frozen:
			continue
		# A lit hearth burns coal for the warmth it throws into the street even
		# when nothing draws from it — self_burn is what radiance actually costs.
		var burned: float = (n.output + n.def.self_burn) * n.def.fuel_per_unit * dt
		if burned <= 0.0:
			continue
		n.fuel_stock = maxf(0.0, n.fuel_stock - burned)


## Pull-style hookup for [P03]/[P04]: if a hauling system exists and exposes
## request_fuel(building_id, item, amount) -> float, half-empty bunkers ask.
func _pull_fuel() -> void:
	if _fuel_autarky or _fuel_source == null or not _fuel_source.has_method("request_fuel"):
		return
	for id: int in _sorted_ids():
		var n: HeatNode = nodes[id]
		if n.def.fuel == &"" or n.fuel_stock > n.def.fuel_capacity * 0.5:
			continue
		var want: float = n.def.fuel_capacity - n.fuel_stock
		var got: Variant = _fuel_source.call("request_fuel", id, n.def.fuel, want)
		if typeof(got) == TYPE_FLOAT or typeof(got) == TYPE_INT:
			n.fuel_stock = minf(n.def.fuel_capacity, n.fuel_stock + float(got))


## Internal temperature, freezing, thawing, and the state machine other parts
## read. This is where a heat shortfall turns into a city that dies.
func _thermal() -> void:
	var frozen: int = 0
	for id: int in _sorted_ids():
		var n: HeatNode = nodes[id]
		var d: HeatDef = n.def
		var outside: float = _ambient_c + _warmth.value_at(n.center_cell)
		var gain: float = INTERNAL_C_PER_UNIT * (n.delivered + n.output * SELF_HEAT_FRAC)
		var target: float = outside + gain * (1.0 + d.insulation * 1.5)
		var rate: float = WARM_RATE
		if target < n.temp_c:
			rate = COOL_RATE * (1.0 - d.insulation * 0.6)
		n.temp_c += (target - n.temp_c) * rate

		if n.temp_c <= d.freeze_below:
			n.cold_ticks += 1
			if not n.frozen and n.cold_ticks >= FREEZE_HOLD_TICKS:
				n.frozen = true
				n.frozen_ticks = 0
				_announce_frozen(n, true)
				Bus.alert_raised.emit(SEV_WARN, &"building_froze",
					"%s froze at %.0f°C" % [n.def.display_name, n.temp_c], n.world_pos)
				Log.info("heat", "#%d %s froze (net %d, %.1f°C)" % [
					id, n.kind, network_of(id), n.temp_c])
				var nid: int = network_of(id)
				if nid >= 0:
					_network(nid).route_dirty = true
		else:
			n.cold_ticks = 0
		if n.frozen:
			n.frozen_ticks += 1
			if n.temp_c >= d.freeze_below + THAW_MARGIN:
				n.frozen = false
				n.cold_ticks = 0
				_announce_frozen(n, false)
				Log.info("heat", "#%d %s thawed after %d ticks" % [id, n.kind, n.frozen_ticks])
				var nid2: int = network_of(id)
				if nid2 >= 0:
					_network(nid2).route_dirty = true
			else:
				frozen += 1
		n.state = _state_for(n)
	_frozen_count = frozen


## The lifecycle state of a building belongs to [P11], so when it exists we ask
## it to flip the flag (it emits building_state_changed and building_froze
## itself). Standing alone, heat announces the freeze on its own.
func _announce_frozen(n: HeatNode, frozen: bool) -> void:
	if _has_set_frozen:
		_build.call("set_frozen", n.id, frozen)
	elif frozen:
		Bus.building_froze.emit(n.id)


func _state_for(n: HeatNode) -> int:
	if n.frozen:
		return HeatNode.State.FROZEN
	if not n.enabled:
		return HeatNode.State.OFFLINE
	if n.demand <= 0.0:
		return HeatNode.State.ONLINE
	if n.served >= 0.999:
		return HeatNode.State.ONLINE
	if n.served >= 0.25:
		return HeatNode.State.BROWNOUT
	return HeatNode.State.OFFLINE


## Radiant sources follow how hard the building is actually working, smoothed so
## the field does not strobe, and only repainted four times a second.
func _radiate(tick: int) -> void:
	for id: int in _sorted_ids():
		var n: HeatNode = nodes[id]
		if not n.def.radiates():
			continue
		var target: float = n.def.radiance * n.radiance_factor()
		n.radiance_cur += (target - n.radiance_cur) * RADIANCE_SMOOTH
		_warmth.set_source(id, n.bbox_origin, n.bbox_size, n.def.radius, n.radiance_cur)
	if tick % WARMTH_REFRESH_TICKS == 0:
		_warmth.flush()


## Turns a shortfall into something the player can find on the map: the network,
## the size of the hole, and the tile that caused it.
func _report(net: HeatNetwork, tick: int) -> void:
	if net.deficit <= 0.001:
		net.last_alert_key = &""
		return
	if tick - net.last_shortfall_tick >= SHORTFALL_EVERY:
		net.last_shortfall_tick = tick
		Bus.heat_shortfall.emit(net.id, net.deficit)

	var key: StringName = &"heat_supply"
	var text: String = "Network %d short %.0f heat/s — not enough generation" % [net.id, net.deficit]
	var pos: Vector2 = Vector2.ZERO
	if not net.bottlenecks.is_empty():
		var b: Dictionary = net.bottlenecks[0]
		var bnode: HeatNode = nodes.get(int(b.get("node", -1)))
		if bnode != null:
			pos = bnode.world_pos
		if String(b.get("reason", "")) == "capacity":
			key = StringName("heat_capacity_%d" % int(b.get("node", -1)))
			text = "%s at (%d, %d) is over capacity: %.0f/%.0f — %d buildings starved" % [
				String(b.get("kind", "line")), int((b["cell"] as Array)[0]), int((b["cell"] as Array)[1]),
				float(b.get("load", 0.0)), float(b.get("capacity", 0.0)), int(b.get("consumers", 0))]
		else:
			key = StringName("heat_supply_%d" % net.id)
			text = "Network %d short %.0f heat/s — %d buildings starved" % [
				net.id, net.deficit, int(b.get("consumers", 0))]
	if key != net.last_alert_key or tick - net.last_alert_tick >= ALERT_EVERY:
		net.last_alert_key = key
		net.last_alert_tick = tick
		Bus.alert_raised.emit(SEV_WARN, key, text, pos)


# =========================================================================
# persistence + metrics
# =========================================================================

func serialize() -> Dictionary:
	var buildings: Array = []
	for id: int in _sorted_ids():
		var n: HeatNode = nodes[id]
		buildings.append({
			"id": id,
			"kind": String(n.kind),
			"cell": [n.cell.x, n.cell.y],
			"rot": n.rot,
			"net": _graph.net_of.get(id, -1),
			"state": n.state,
			"enabled": n.enabled,
			"frozen": n.frozen,
			"temp": snappedf(n.temp_c, 0.01),
			"served": snappedf(n.served, 0.001),
			"demand": snappedf(n.demand, 0.001),
			"output": snappedf(n.output, 0.001),
			"flow": snappedf(n.throughput, 0.001),
			"stored": snappedf(n.stored, 0.01),
			"local": snappedf(n.local_stored, 0.01),
			"fuel": snappedf(n.fuel_stock, 0.01),
			"dist": n.route_dist,
			"eta": snappedf(n.route_eta, 0.0001),
			"bottleneck": n.bottleneck_node,
		})
	var nets: Array = []
	for nid: int in _graph.network_ids():
		nets.append(network_stats(nid))
	var t: Dictionary = totals()
	t["peak_warmth"] = snappedf(_warmth.peak(), 0.01)
	t["warm_cells"] = _warmth.warm_cells()
	return {
		"buildings": buildings,
		"networks": nets,
		"totals": t,
		"next_local_id": _next_local_id,
	}


func deserialize(data: Dictionary) -> void:
	for id: int in _sorted_ids().duplicate():
		unregister_building(id)
	nodes.clear()
	_ids_dirty = true
	_warmth.clear()
	_nets.clear()
	_next_local_id = int(data.get("next_local_id", LOCAL_ID_BASE))
	for raw: Dictionary in data.get("buildings", []):
		var id: int = int(raw.get("id", -1))
		var kind: StringName = StringName(String(raw.get("kind", "")))
		var cell: Vector2i = _to_cell(raw.get("cell", []))
		if not register_building(id, kind, cell, int(raw.get("rot", 0))):
			continue
		var n: HeatNode = nodes[id]
		n.enabled = bool(raw.get("enabled", true))
		n.frozen = bool(raw.get("frozen", false))
		n.state = int(raw.get("state", HeatNode.State.ONLINE))
		n.temp_c = float(raw.get("temp", 15.0))
		n.served = float(raw.get("served", 1.0))
		n.output = float(raw.get("output", 0.0))
		n.stored = float(raw.get("stored", 0.0))
		n.local_stored = float(raw.get("local", 0.0))
		n.fuel_stock = float(raw.get("fuel", 0.0))
	rebuild_networks()
	Log.info("heat", "restored %d heat buildings" % nodes.size())


func metrics() -> Dictionary:
	return {
		"total_supply": snappedf(_total_supply, 0.01),
		"total_demand": snappedf(_total_demand, 0.01),
		"delivered": snappedf(_total_delivered, 0.01),
		"deficit": snappedf(_total_deficit, 0.01),
		"loss": snappedf(_total_loss, 0.01),
		"buffer": snappedf(_total_buffer, 0.01),
		"networks": _graph.members.size(),
		"buildings": nodes.size(),
		"frozen_buildings": _frozen_count,
		"brownouts": _brownouts,
		"avg_warmth": snappedf(_warmth.average(), 0.01),
		"ambient": snappedf(_ambient_c, 0.01),
	}
