class_name HeatFlow
extends RefCounted
## The distribution solver. One instance is reused by HeatSystem for every
## network, every tick.
##
## WHAT IT ACTUALLY SOLVES
## Per network this is a constrained flow problem, not a sum of two numbers:
##
##   1. ROUTING. Level-synchronous multi-source BFS from every live source over
##      the conducting tiles. A tile is claimed by the source that reaches it in
##      the fewest hops; ties go to the route with the better transmission
##      efficiency, then to the lower id, so the result is byte-stable.
##      Efficiency is multiplicative per tile travelled — distance costs heat —
##      and a repeater tile resets it to 1.0, which is what makes booster pumps
##      worth building.
##
##   2. ALLOCATION. Progressive filling (max-min fair, weighted by demand) over
##      three constraint families: per-tile throughput, per-source availability,
##      and per-consumer demand. Everybody grows together until one constraint
##      saturates; whoever draws through that constraint is frozen at what they
##      have and the rest keep growing. The saturating tile is recorded on every
##      consumer it choked — that is the "which pipe, and why" the HUD shows.
##
##   3. AUGMENTATION. When a tile saturates while demand is unmet and some source
##      still has heat, the network is rerouted over the residual graph
##      (saturated tiles removed) and the fill continues. Successive shortest
##      paths, capped at MAX_PASSES so a pathological base cannot stall the tick.
##
## Priority runs outside all of that: tier by tier, highest first, so life
## support is served before defence and defence before industry, and a shortfall
## always sheds from the bottom.
##
## Accounting: x is measured AT THE SOURCE. A consumer that wants `rem` u/s at
## efficiency `eta` costs `rem / eta` at the source, and the flow through any
## tile `n` on its path is `eta[n] * (rem / eta)`. That one identity keeps the
## whole solve linear — no per-edge bookkeeping, and conservation holds by
## construction: delivered + loss == drawn.

const EPS: float = 0.000001
const BIG: float = 1.0e12
const MAX_ROUNDS: int = 12       ## progressive-filling rounds per tier
const MAX_PASSES: int = 3        ## rerouting attempts per tier
const MAX_LEVELS: int = 8192
const LOCAL_RECHARGE_RATE: float = 0.08  ## fraction of a building's own store per second

var _nodes: Dictionary[int, HeatNode] = {}
var _neigh: Dictionary[int, PackedInt32Array] = {}
var _net: HeatNetwork = null
var _dt: float = 0.05

# routing — either aliases into the network's cross-tick cache, or scratch
var _dist: Dictionary[int, int] = {}
var _eta: Dictionary[int, float] = {}
var _parent: Dictionary[int, int] = {}
var _root: Dictionary[int, int] = {}
var _paths: Dictionary[int, PackedInt32Array] = {}

# per-solve scratch
var _cap: Dictionary[int, float] = {}          ## residual throughput per tile
var _cap_full: Dictionary[int, float] = {}     ## nominal throughput per tile
var _avail: Dictionary[int, float] = {}        ## residual availability per live source
var _prod_avail: Dictionary[int, float] = {}   ## producer share offered this tick
var _buf_avail: Dictionary[int, float] = {}    ## buffer share offered in phase B
var _load: Dictionary[int, float] = {}         ## flow that actually passed a tile
var _rem: Dictionary[int, float] = {}          ## unmet demand per sink, u/s
var _got: Dictionary[int, float] = {}          ## delivered per sink, u/s
var _acc: Dictionary[int, float] = {}          ## per-round accumulator
var _choked: Dictionary[int, int] = {}         ## tile id -> consumers it choked
var _choked_kind: Dictionary[int, StringName] = {}

var _producers: PackedInt32Array = PackedInt32Array()
var _buffers: PackedInt32Array = PackedInt32Array()
var _sinks: PackedInt32Array = PackedInt32Array()
var _tiers: Array[int] = []
var _tier_members: Dictionary[int, PackedInt32Array] = {}
var _loss_acc: float = 0.0
## Hash of every routing-relevant gate this tick. See solve().
var _route_sig: int = 0

# --- [P10] research modifiers -------------------------------------------------
# Set by HeatSystem once per tick from ResearchSystem.multiplier(). All default
# to 1.0, so a build with no research system, or a run before anything is
# finished, behaves exactly as it did before the tree existed. They live here
# rather than being baked into HeatDef because a completed node has to change
# what a building ALREADY STANDING does, not only what a new one costs.
var tech_output: float = 1.0        ## generator output
var tech_demand: float = 1.0        ## consumer draw
var tech_loss: float = 1.0          ## per-tile transmission loss
var tech_throughput: float = 1.0    ## conduit capacity
var tech_buffer: float = 1.0        ## accumulator storage


## Solves one network for one tick and writes the result back onto its nodes.
func solve(net: HeatNetwork, members: PackedInt32Array, nodes: Dictionary[int, HeatNode],
		neigh: Dictionary[int, PackedInt32Array], dt: float, cold_mult: float,
		graph_version: int, autarky: bool) -> void:
	_nodes = nodes
	_neigh = neigh
	_net = net
	_dt = dt
	_reset()
	_classify(members, cold_mult, autarky)

	var live: PackedInt32Array = _live_sources(_producers)
	# The cache key has to cover EVERYTHING the router branches on, not just which
	# generators are lit: a switched-off pipe, a frozen trunk and a starved booster
	# pump all change the routes. Keying on sources alone made identical world
	# state produce two different answers depending on cache history.
	var sig: int = _route_sig
	if net.route_dirty or net.route_version != graph_version or net.route_sig != sig:
		_route(live, false)
		net.route_version = graph_version
		net.route_sig = sig
		net.routed_ticks += 1
	else:
		_dist = net.dist
		_eta = net.eta
		_parent = net.parent
		_root = net.root
		_paths = net.paths

	for tier: int in _tiers:
		_serve_tier(_tier_members[tier])
	_phase_buffers()
	_phase_charge(members)
	_write_back(members)


func _reset() -> void:
	_cap.clear()
	_cap_full.clear()
	_avail.clear()
	_prod_avail.clear()
	_buf_avail.clear()
	_load.clear()
	_rem.clear()
	_got.clear()
	_acc.clear()
	_choked.clear()
	_choked_kind.clear()
	_producers = PackedInt32Array()
	_buffers = PackedInt32Array()
	_sinks = PackedInt32Array()
	_tiers = []
	_tier_members.clear()
	_loss_acc = 0.0
	_route_sig = 1469598103
	_net.bottlenecks = []
	_net.charge = 0.0
	_net.discharge = 0.0


## Classifies every member, sizes this tick's supply and demand, and fills the
## per-tile capacity table. Members arrive sorted, so everything downstream is.
func _classify(members: PackedInt32Array, cold_mult: float, autarky: bool) -> void:
	var supply: float = 0.0
	var demand: float = 0.0
	var buffer: float = 0.0
	var buffer_cap: float = 0.0
	var producers: int = 0
	var consumers: int = 0
	var by_tier: Dictionary[int, Array] = {}

	for id: int in members:
		var n: HeatNode = _nodes[id]
		var d: HeatDef = n.def
		n.delivered = 0.0
		n.throughput = 0.0
		n.bottleneck_node = -1
		n.bottleneck_kind = &""
		if d.conducts():
			# A conduit that is switched off or frozen carries nothing. Without this
			# the player-facing switch was inert for every pipe, buffer and pump in
			# the game, and a frozen trunk kept conducting at full throughput.
			_cap_full[id] = d.capacity * tech_throughput if (n.enabled and not n.frozen) else 0.0
			if _cap_full[id] > EPS:
				_route_sig = ((_route_sig * 31) ^ (id * 4 + 1)) & 0x7FFFFFFF
				if d.repeater and n.repeater_live:
					_route_sig = ((_route_sig * 31) ^ (id * 4 + 2)) & 0x7FFFFFFF
		else:
			_cap_full[id] = BIG
		_cap[id] = _cap_full[id]

		if d.is_producer():
			producers += 1
			n.fuel_factor = _fuel_factor(n, autarky)
			var peak: float = d.output * n.site_bonus * tech_output
			var ramp_cap: float = n.output + peak * d.ramp * _dt
			var avail: float = minf(peak, maxf(0.0, ramp_cap)) * n.fuel_factor
			if not n.enabled or n.frozen:
				avail = 0.0
			if avail > EPS:
				_prod_avail[id] = avail
				_avail[id] = avail
				_producers.append(id)
				_route_sig = ((_route_sig * 31) ^ (id * 4 + 3)) & 0x7FFFFFFF
			supply += avail
		if d.is_buffer():
			buffer += n.stored
			buffer_cap += d.storage * tech_buffer
			if n.enabled and not n.frozen:
				_buffers.append(id)

		if d.is_consumer():
			consumers += 1
			var base: float = d.demand * tech_demand \
				* (1.0 + (cold_mult - 1.0) * d.cold_sensitivity)
			if n.frozen:
				# A frozen building still asks for a trickle so it can thaw once
				# the network recovers. Otherwise every cascade would be final.
				base *= 0.35
			if not n.enabled:
				base = 0.0
			n.base_demand = base
			# Thermal mass: a building draws a little extra to top up its own
			# store, and spends that store to ride out the next brownout.
			var recharge: float = 0.0
			if d.local_buffer > 0.0 and base > EPS:
				recharge = minf(maxf(0.0, d.local_buffer - n.local_stored) / _dt,
					d.local_buffer * LOCAL_RECHARGE_RATE)
			n.demand = base + recharge
			if n.demand > EPS:
				demand += n.demand
				_rem[id] = n.demand
				_got[id] = 0.0
				# A machine that BOTH makes and burns heat serves itself first,
				# at no transmission loss, and only then queues for the network.
				# Without this it was seeded as its own BFS root, became its own
				# exclusive supply, and could never draw the rest of what it
				# needed from the grid it was standing on: the smelter (produces
				# 4, consumes 14) ran at 27% forever and blamed itself in its own
				# bottleneck report. Self-service is also physically the truth —
				# the heat never leaves the building.
				if d.is_producer():
					var own: float = minf(_avail.get(id, 0.0), n.demand)
					if own > EPS:
						_got[id] = own
						_rem[id] = n.demand - own
						_avail[id] = _avail[id] - own
						if _avail[id] <= EPS:
							_avail.erase(id)
				_sinks.append(id)
				var tier: Array = by_tier.get(n.priority, [])
				tier.append(id)
				by_tier[n.priority] = tier
			else:
				n.served = 1.0
		else:
			n.base_demand = 0.0
			n.demand = 0.0
			n.served = 1.0

	var tiers: Array = by_tier.keys()
	tiers.sort()
	tiers.reverse()
	for t: int in tiers:
		_tiers.append(t)
		var ids: Array = by_tier[t]
		ids.sort()
		var arr: PackedInt32Array = PackedInt32Array()
		for i: int in ids:
			arr.append(i)
		_tier_members[t] = arr

	_net.supply = supply
	_net.demand = demand
	_net.buffer = buffer
	_net.buffer_capacity = buffer_cap
	_net.producers = producers
	_net.consumers = consumers


## 1.0 when the bunker can cover a full-output tick, proportionally less when it
## is running dry — a boiler browns out gradually instead of cutting out.
func _fuel_factor(n: HeatNode, autarky: bool) -> float:
	var d: HeatDef = n.def
	if d.fuel == &"" or d.fuel_per_unit <= 0.0:
		return 1.0
	if autarky:
		return 1.0
	var need: float = (d.output + d.self_burn) * d.fuel_per_unit * _dt
	if need <= EPS:
		return 1.0
	return clampf(n.fuel_stock / need, 0.0, 1.0)


func _live_sources(candidates: PackedInt32Array) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for id: int in candidates:
		if _avail.get(id, 0.0) > EPS:
			out.append(id)
	return out


func _all_source_ids() -> PackedInt32Array:
	var keys: Array = _avail.keys()
	keys.sort()
	var out: PackedInt32Array = PackedInt32Array()
	for k: int in keys:
		out.append(k)
	return out


# --- routing --------------------------------------------------------------

## Level-synchronous multi-source BFS. Exact for "fewest hops, then best
## efficiency", because efficiency only shrinks along a path: the best route of
## length L+1 must extend a best route of length L.
func _route(seeds: PackedInt32Array, residual: bool) -> void:
	if residual:
		# Residual routing is scratch, never the cross-tick cache.
		_dist = {}
		_eta = {}
		_parent = {}
		_root = {}
		_paths = {}
		_net.route_dirty = true
	else:
		_net.clear_routing()
		_dist = _net.dist
		_eta = _net.eta
		_parent = _net.parent
		_root = _net.root
		_paths = _net.paths
		_net.route_dirty = false

	var frontier: PackedInt32Array = seeds.duplicate()
	frontier.sort()
	for s: int in frontier:
		_dist[s] = 0
		_eta[s] = 1.0
		_parent[s] = -1
		_root[s] = s

	var level: int = 0
	while not frontier.is_empty() and level < MAX_LEVELS:
		var cand_eta: Dictionary[int, float] = {}
		var cand_par: Dictionary[int, int] = {}
		for u: int in frontier:
			var nu: HeatNode = _nodes[u]
			var u_conducts: bool = nu.def.conducts()
			# Only a conductor forwards heat. A source that is not a conductor
			# (a lone hearth) still pushes into whatever conductor touches it.
			if not u_conducts and _dist[u] != 0:
				continue
			if u_conducts and _cap.get(u, 0.0) <= EPS:
				continue
			var eu: float = _eta[u]
			for v: int in _neigh.get(u, PackedInt32Array()):
				if _dist.has(v):
					continue
				var nv: HeatNode = _nodes.get(v)
				if nv == null:
					continue
				var v_conducts: bool = nv.def.conducts()
				if v_conducts and _cap.get(v, 0.0) <= EPS:
					continue
				var ev: float = eu
				if v_conducts:
					if nv.def.repeater and nv.repeater_live:
						ev = 1.0
					else:
						ev = eu * (1.0 - clampf(nv.def.loss_per_tile * tech_loss, 0.0, 0.95))
				var have: float = cand_eta.get(v, -1.0)
				if ev > have + EPS or (absf(ev - have) <= EPS and u < cand_par.get(v, 0x7FFFFFFF)):
					cand_eta[v] = ev
					cand_par[v] = u
		var keys: Array = cand_eta.keys()
		keys.sort()
		var next_frontier: PackedInt32Array = PackedInt32Array()
		for v: int in keys:
			_dist[v] = level + 1
			_eta[v] = cand_eta[v]
			_parent[v] = cand_par[v]
			_root[v] = _root[cand_par[v]]
			next_frontier.append(v)
		frontier = next_frontier
		level += 1


## Path from a sink up to its source, source last. The sink itself is on the
## path when it conducts (its own throughput limits its intake) or when it is
## its own source (a generator that also consumes).
func _path_for(sink: int) -> PackedInt32Array:
	var cached: PackedInt32Array = _paths.get(sink, PackedInt32Array())
	if not cached.is_empty():
		return cached
	if not _dist.has(sink):
		return PackedInt32Array()
	var p: PackedInt32Array = PackedInt32Array()
	var n: HeatNode = _nodes[sink]
	if n.def.conducts() or _avail.has(sink):
		p.append(sink)
	var cur: int = _parent.get(sink, -1)
	var guard: int = 0
	while cur >= 0 and guard < MAX_LEVELS:
		p.append(cur)
		cur = _parent.get(cur, -1)
		guard += 1
	_paths[sink] = p
	return p


# --- allocation -----------------------------------------------------------

func _serve_tier(tier: PackedInt32Array) -> void:
	for pass_i: int in MAX_PASSES:
		var saturated: bool = _fill(tier)
		if not saturated:
			return
		if _tier_unmet(tier) <= EPS:
			return
		if pass_i == MAX_PASSES - 1:
			return
		var live: PackedInt32Array = _live_sources(_all_source_ids())
		if live.is_empty():
			return
		_route(live, true)


func _tier_unmet(tier: PackedInt32Array) -> float:
	var s: float = 0.0
	for c: int in tier:
		s += _rem.get(c, 0.0)
	return s


## Progressive filling. Returns true when a constraint saturated, which is the
## signal that rerouting over the residual graph might still find heat.
func _fill(tier: PackedInt32Array) -> bool:
	var active: PackedInt32Array = PackedInt32Array()
	for c: int in tier:
		if _rem.get(c, 0.0) <= EPS:
			continue
		if _path_for(c).is_empty():
			var un: HeatNode = _nodes[c]
			if un.bottleneck_node < 0:
				un.bottleneck_kind = &"unreachable"
			continue
		active.append(c)
	if active.is_empty():
		return false

	var saturated: bool = false
	var rounds: int = 0
	while not active.is_empty() and rounds < MAX_ROUNDS:
		rounds += 1
		_acc.clear()
		for c: int in active:
			var need: float = _rem[c] / maxf(_eta.get(c, 1.0), EPS)
			for n: int in _paths[c]:
				_acc[n] = _acc.get(n, 0.0) + need

		var keys: Array = _acc.keys()
		keys.sort()
		var t: float = 1.0
		var binding: int = -1
		var binding_kind: StringName = &""
		for n: int in keys:
			var a: float = _acc[n]
			if a <= EPS:
				continue
			var through: float = _eta.get(n, 1.0) * a
			if through > EPS:
				var tn: float = _cap.get(n, BIG) / through
				if tn < t:
					t = tn
					binding = n
					binding_kind = &"capacity"
			if _avail.has(n):
				var tr: float = _avail[n] / a
				if tr < t:
					t = tr
					binding = n
					binding_kind = &"supply"
		t = clampf(t, 0.0, 1.0)

		for c: int in active:
			var give: float = t * _rem[c]
			if give <= 0.0:
				continue
			_got[c] = _got.get(c, 0.0) + give
			_loss_acc += give * (1.0 / maxf(_eta.get(c, 1.0), EPS) - 1.0)
			_rem[c] = maxf(0.0, _rem[c] - give)
		for n: int in keys:
			var used: float = _acc[n] * t
			if used <= 0.0:
				continue
			var flow: float = _eta.get(n, 1.0) * used
			_load[n] = _load.get(n, 0.0) + flow
			if _cap.has(n):
				_cap[n] = maxf(0.0, _cap[n] - flow)
			if _avail.has(n):
				_avail[n] = maxf(0.0, _avail[n] - used)

		if t >= 1.0 - EPS or binding < 0:
			break
		saturated = true
		var next_active: PackedInt32Array = PackedInt32Array()
		var froze_any: bool = false
		for c: int in active:
			if _paths[c].has(binding):
				var nd: HeatNode = _nodes[c]
				nd.bottleneck_node = binding
				nd.bottleneck_kind = binding_kind
				_choked[binding] = _choked.get(binding, 0) + 1
				_choked_kind[binding] = binding_kind
				froze_any = true
			else:
				next_active.append(c)
		if not froze_any:
			break
		active = next_active
	return saturated


## Buffers only run when production could not cover the tick. That keeps
## accumulators from cycling (and bleeding transmission loss) all day, and makes
## "the accumulators kicked in" a real, readable event.
func _phase_buffers() -> void:
	if _buffers.is_empty():
		return
	var unmet: float = 0.0
	for c: int in _sinks:
		unmet += _rem.get(c, 0.0)
	if unmet <= EPS:
		return
	var added: bool = false
	for id: int in _buffers:
		var n: HeatNode = _nodes[id]
		var out: float = minf(n.def.discharge_rate, n.stored / _dt)
		if out <= EPS:
			continue
		_buf_avail[id] = out
		_avail[id] = _avail.get(id, 0.0) + out
		added = true
	if not added:
		return
	_route(_live_sources(_all_source_ids()), true)
	for tier: int in _tiers:
		_serve_tier(_tier_members[tier])


## Whatever production is left over after every consumer is served tops up the
## buffers, routed and capacity-limited exactly like any other draw.
func _phase_charge(members: PackedInt32Array) -> void:
	var sources: PackedInt32Array = PackedInt32Array()
	for id: int in _producers:
		if _avail.get(id, 0.0) > EPS and _buf_avail.get(id, 0.0) <= 0.0:
			sources.append(id)
	if sources.is_empty():
		return

	var tier: PackedInt32Array = PackedInt32Array()
	var saved_rem: Dictionary[int, float] = {}
	var saved_got: Dictionary[int, float] = {}
	for id: int in members:
		var n: HeatNode = _nodes[id]
		if not n.def.is_buffer() or not n.enabled or n.frozen:
			continue
		if _buf_avail.get(id, 0.0) > 0.0:
			continue  # it discharged this tick; do not turn around and refill it
		var room: float = maxf(0.0, n.def.storage * tech_buffer - n.stored) / _dt
		var want: float = minf(n.def.charge_rate, room)
		if want <= EPS:
			continue
		saved_rem[id] = _rem.get(id, 0.0)
		saved_got[id] = _got.get(id, 0.0)
		_rem[id] = want
		_got[id] = 0.0
		tier.append(id)
	if tier.is_empty():
		return

	_route(sources, true)
	_fill(tier)
	for id: int in tier:
		var n2: HeatNode = _nodes[id]
		var got: float = _got.get(id, 0.0)
		n2.stored = minf(n2.def.storage * tech_buffer, n2.stored + got * _dt)
		_net.charge += got
		# Charging is not demand: it must never show up as a deficit.
		_rem[id] = saved_rem.get(id, 0.0)
		_got[id] = saved_got.get(id, 0.0)


# --- write back -----------------------------------------------------------

func _write_back(members: PackedInt32Array) -> void:
	var delivered: float = 0.0
	var unmet: float = 0.0
	var supply_used: float = 0.0
	var discharge: float = 0.0
	var buffer_now: float = 0.0
	var brownouts: int = 0
	var starved: int = 0

	for id: int in members:
		var n: HeatNode = _nodes[id]
		var d: HeatDef = n.def
		n.throughput = _load.get(id, 0.0)
		n.route_dist = _dist.get(id, -1)
		n.route_eta = _eta.get(id, 1.0)

		if d.is_producer() or d.is_buffer():
			var offered: float = _prod_avail.get(id, 0.0) + _buf_avail.get(id, 0.0)
			var used: float = maxf(0.0, offered - _avail.get(id, 0.0))
			var from_prod: float = minf(used, _prod_avail.get(id, 0.0))
			var from_buf: float = maxf(0.0, used - from_prod)
			if d.is_producer():
				n.output = from_prod
				supply_used += from_prod
			if d.is_buffer():
				if from_buf > 0.0:
					n.stored = maxf(0.0, n.stored - from_buf * _dt)
					discharge += from_buf
				if d.leak > 0.0:
					n.stored = maxf(0.0, n.stored * (1.0 - d.leak * _dt))
				buffer_now += n.stored

		if d.is_consumer():
			if n.demand > EPS:
				var got: float = _got.get(id, 0.0)
				var base: float = n.base_demand
				var to_base: float = minf(got, base)
				var surplus: float = got - to_base
				if d.local_buffer > 0.0 and surplus > 0.0:
					n.local_stored = minf(d.local_buffer, n.local_stored + surplus * _dt)
				if to_base < base - EPS and n.local_stored > 0.0:
					# Thermal mass carries the building through the gap. This is
					# why a short brownout is survivable and a long one is not.
					var draw: float = minf(n.local_stored, (base - to_base) * _dt)
					n.local_stored -= draw
					to_base += draw / _dt
				n.delivered = to_base
				n.served = clampf(to_base / maxf(base, EPS), 0.0, 1.0) if base > EPS else 1.0
				delivered += got
				unmet += maxf(0.0, base - to_base)
				if n.served < 0.999:
					brownouts += 1
			else:
				n.delivered = 0.0
				n.served = 1.0

		n.starved_fuel = d.is_producer() and n.fuel_factor < 0.999
		if n.starved_fuel:
			starved += 1
		if d.repeater:
			n.repeater_live = n.served >= 0.5 and not n.frozen and n.enabled

	_net.delivered = delivered
	_net.supply_used = supply_used
	_net.discharge = discharge
	_net.buffer = buffer_now
	# Deficit is the OPERATIONAL hole after thermal mass has been spent, not the
	# raw arithmetic gap — that is the number a player can act on.
	_net.deficit = unmet
	_net.loss = _loss_acc
	_net.brownouts = brownouts
	_net.starved = starved
	_collect_bottlenecks()


func _collect_bottlenecks() -> void:
	if _choked.is_empty():
		return
	var keys: Array = _choked.keys()
	keys.sort()
	var out: Array[Dictionary] = []
	for n: int in keys:
		var node: HeatNode = _nodes.get(n)
		if node == null:
			continue
		var cap: float = _cap_full.get(n, BIG)
		out.append({
			"node": n,
			"kind": String(node.kind),
			"cell": [node.cell.x, node.cell.y],
			"reason": String(_choked_kind.get(n, &"capacity")),
			"load": snappedf(_load.get(n, 0.0), 0.001),
			"capacity": snappedf(0.0 if cap >= BIG else cap, 0.001),
			"consumers": _choked[n],
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ca: int = int(a["consumers"])
		var cb: int = int(b["consumers"])
		if ca != cb:
			return ca > cb
		return int(a["node"]) < int(b["node"]))
	_net.bottlenecks = out
