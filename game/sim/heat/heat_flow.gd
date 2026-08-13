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
##
## HOW IT IS REPRESENTED, AND WHY THAT IS PART OF THE DESIGN
## Every table here is a PackedArray addressed by a LOCAL NODE INDEX handed out
## by HeatTopology in ascending building-id order, not a Dictionary keyed by
## building id. Two consequences, both load-bearing:
##
##   * Determinism stops depending on remembering to sort. Iterating 0..n-1 is
##     iterating in sorted-id order by construction, so the `keys.sort()` calls
##     that used to guard every dictionary walk are gone rather than trusted —
##     including the one that sat INSIDE the progressive-filling round loop,
##     re-sorting a thousand keys twelve times per tier per pass for an order
##     that could not change.
##   * The solve got roughly five times cheaper. A hashed lookup and a method
##     call per graph edge is what made a 1400-node network cost 24 ms a tick.
##
## The residual reroutes in step 3 write to a SEPARATE routing object from the
## cross-tick cache (HeatTopology.scratch vs .primary), so a network that runs a
## deficit no longer invalidates its own routing every tick. That single change
## is worth more than every micro-optimisation in this file.

const EPS: float = 0.000001
const BIG: float = 1.0e12
const MAX_ROUNDS: int = 12       ## progressive-filling rounds per tier
const MAX_PASSES: int = 3        ## rerouting attempts per tier
const MAX_LEVELS: int = 8192
const LOCAL_RECHARGE_RATE: float = 0.08  ## fraction of a building's own store per second

## Bottleneck reasons, stored as bytes on the hot path and worded on the way out.
const B_NONE: int = 0
const B_CAPACITY: int = 1
const B_SUPPLY: int = 2

var _nodes: Dictionary[int, HeatNode] = {}
var _net: HeatNetwork = null
var _topo: HeatTopology = null
var _n: int = 0
var _dt: float = 0.05

# --- current routing ----------------------------------------------------------
# Either the network's cross-tick cache or the residual scratch. The PackedArrays
# are read-only aliases (CoW keeps that free); `_route_cur` is the object that
# owns the lazily-built path cache, which is an Array and therefore aliases by
# reference exactly like the dictionary it replaced.
var _route_cur: HeatRoute = null
var _dist: PackedInt32Array = PackedInt32Array()
var _eta: PackedFloat64Array = PackedFloat64Array()
var _parent: PackedInt32Array = PackedInt32Array()

# --- per-solve scratch, grown to the largest network ever solved --------------
var _size: int = 0
var _cap: PackedFloat64Array = PackedFloat64Array()       ## residual throughput per tile
var _cap_full: PackedFloat64Array = PackedFloat64Array()  ## nominal throughput per tile
var _avail: PackedFloat64Array = PackedFloat64Array()     ## residual availability per source
var _has_avail: PackedByteArray = PackedByteArray()       ## it IS a source, even at zero left
var _prod_avail: PackedFloat64Array = PackedFloat64Array()## producer share offered this tick
var _buf_avail: PackedFloat64Array = PackedFloat64Array() ## buffer share offered in phase B
var _load: PackedFloat64Array = PackedFloat64Array()      ## flow that actually passed a tile
var _rem: PackedFloat64Array = PackedFloat64Array()       ## unmet demand per sink, u/s
var _got: PackedFloat64Array = PackedFloat64Array()       ## delivered per sink, u/s
var _acc: PackedFloat64Array = PackedFloat64Array()       ## per-round accumulator
var _choked: PackedInt32Array = PackedInt32Array()        ## consumers this tile choked
var _choked_kind: PackedByteArray = PackedByteArray()
var _eta_mult: PackedFloat64Array = PackedFloat64Array()  ## per-tile efficiency factor
var _eta_reset: PackedByteArray = PackedByteArray()       ## a live repeater restores 1.0
var _mark: PackedInt32Array = PackedInt32Array()          ## stamp for the touched-node union
var _mark_epoch: int = 0

# --- BFS scratch, likewise grown once -----------------------------------------
var _cand_eta: PackedFloat64Array = PackedFloat64Array()
var _cand_par: PackedInt32Array = PackedInt32Array()
var _cand_mark: PackedInt32Array = PackedInt32Array()
var _cand_epoch: int = 0

var _avail_ids: PackedInt32Array = PackedInt32Array()
var _producers: PackedInt32Array = PackedInt32Array()
var _buffers: PackedInt32Array = PackedInt32Array()
var _sinks: PackedInt32Array = PackedInt32Array()
var _choked_list: PackedInt32Array = PackedInt32Array()
var _tiers: PackedInt32Array = PackedInt32Array()
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
	_net = net
	_dt = dt
	_topo = net.topology(members, nodes, neigh, graph_version)
	_n = _topo.count
	_grow(_n)
	_reset()
	_classify(cold_mult, autarky)

	var live: PackedInt32Array = _live_sources(_producers)
	# The cache key has to cover EVERYTHING the router branches on, not just which
	# generators are lit: a switched-off pipe, a frozen trunk and a starved booster
	# pump all change the routes. Keying on sources alone made identical world
	# state produce two different answers depending on cache history.
	var sig: int = _route_sig
	if not _topo.primary.valid or net.route_dirty or net.route_sig != sig:
		_route(live, false)
		net.route_sig = sig
		net.route_dirty = false
		net.routed_ticks += 1
	else:
		_use_route(_topo.primary)

	for tier: int in _tiers:
		_serve_tier(_tier_members[tier])
	_phase_buffers()
	_phase_charge()
	_write_back()


## Grows every scratch table to hold the largest network solved so far. Nothing
## ever shrinks: a tick that solves six networks then reuses the same buffers,
## and .fill() on the whole array is a memset, so the slack costs nothing.
func _grow(n: int) -> void:
	if n <= _size:
		return
	_size = n
	_cap.resize(n)
	_cap_full.resize(n)
	_avail.resize(n)
	_has_avail.resize(n)
	_prod_avail.resize(n)
	_buf_avail.resize(n)
	_load.resize(n)
	_rem.resize(n)
	_got.resize(n)
	_acc.resize(n)
	_choked.resize(n)
	_choked_kind.resize(n)
	_eta_mult.resize(n)
	_eta_reset.resize(n)
	_mark.resize(n)
	_cand_eta.resize(n)
	_cand_par.resize(n)
	_cand_mark.resize(n)
	_mark.fill(-1)
	_cand_mark.fill(-1)


func _reset() -> void:
	_cap.fill(0.0)
	_cap_full.fill(0.0)
	_avail.fill(0.0)
	_has_avail.fill(0)
	_prod_avail.fill(0.0)
	_buf_avail.fill(0.0)
	_load.fill(0.0)
	_rem.fill(0.0)
	_got.fill(0.0)
	_acc.fill(0.0)
	_choked.fill(0)
	_choked_kind.fill(0)
	_choked_list.resize(0)
	_avail_ids.resize(0)
	_producers.resize(0)
	_buffers.resize(0)
	_sinks.resize(0)
	_tiers.resize(0)
	_tier_members.clear()
	_loss_acc = 0.0
	_route_sig = 1469598103
	_net.bottlenecks = []
	_net.charge = 0.0
	_net.discharge = 0.0


## Classifies every member, sizes this tick's supply and demand, and fills the
## per-tile capacity table. Local indices ascend with building id, so everything
## downstream of here is in a stable order without a single sort.
func _classify(cold_mult: float, autarky: bool) -> void:
	var topo: HeatTopology = _topo
	var ids: PackedInt32Array = topo.ids
	var conducts: PackedByteArray = topo.conducts
	var loss: PackedFloat64Array = topo.loss_per_tile
	var refs: Array[HeatNode] = topo.refs
	var supply: float = 0.0
	var demand: float = 0.0
	var buffer: float = 0.0
	var buffer_cap: float = 0.0
	var producers: int = 0
	var consumers: int = 0
	var by_tier: Dictionary[int, Array] = {}
	var sig: int = _route_sig

	for i: int in _n:
		var bid: int = ids[i]
		var n: HeatNode = refs[i]
		var d: HeatDef = n.def
		n.delivered = 0.0
		n.throughput = 0.0
		n.bottleneck_node = -1
		n.bottleneck_kind = &""
		if conducts[i] != 0:
			# A conduit that is switched off or frozen carries nothing. Without this
			# the player-facing switch was inert for every pipe, buffer and pump in
			# the game, and a frozen trunk kept conducting at full throughput.
			var cap: float = d.capacity * tech_throughput if (n.enabled and not n.frozen) else 0.0
			_cap_full[i] = cap
			var boosting: bool = topo.repeater[i] != 0 and n.repeater_live
			if cap > EPS:
				sig = ((sig * 31) ^ (bid * 4 + 1)) & 0x7FFFFFFF
				if boosting:
					sig = ((sig * 31) ^ (bid * 4 + 2)) & 0x7FFFFFFF
			if boosting:
				_eta_reset[i] = 1
				_eta_mult[i] = 1.0
			else:
				_eta_reset[i] = 0
				_eta_mult[i] = 1.0 - clampf(loss[i] * tech_loss, 0.0, 0.95)
		else:
			_cap_full[i] = BIG
			_eta_reset[i] = 0
			_eta_mult[i] = 1.0
		_cap[i] = _cap_full[i]

		if topo.producer[i] != 0:
			producers += 1
			n.fuel_factor = _fuel_factor(n, autarky)
			var peak: float = d.output * n.site_bonus * tech_output
			var ramp_cap: float = n.output + peak * d.ramp * _dt
			var avail: float = minf(peak, maxf(0.0, ramp_cap)) * n.fuel_factor
			if not n.enabled or n.frozen:
				avail = 0.0
			if avail > EPS:
				_prod_avail[i] = avail
				_avail[i] = avail
				_has_avail[i] = 1
				_avail_ids.append(i)
				_producers.append(i)
				sig = ((sig * 31) ^ (bid * 4 + 3)) & 0x7FFFFFFF
			supply += avail
		if topo.buffer[i] != 0:
			buffer += n.stored
			buffer_cap += d.storage * tech_buffer
			if n.enabled and not n.frozen:
				_buffers.append(i)

		if topo.consumer[i] != 0:
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
				_rem[i] = n.demand
				_got[i] = 0.0
				# A machine that BOTH makes and burns heat serves itself first,
				# at no transmission loss, and only then queues for the network.
				# Without this it was seeded as its own BFS root, became its own
				# exclusive supply, and could never draw the rest of what it
				# needed from the grid it was standing on: the smelter (produces
				# 4, consumes 14) ran at 27% forever and blamed itself in its own
				# bottleneck report. Self-service is also physically the truth —
				# the heat never leaves the building.
				if topo.producer[i] != 0:
					var own: float = minf(_avail[i], n.demand)
					if own > EPS:
						_got[i] = own
						_rem[i] = n.demand - own
						_avail[i] = _avail[i] - own
						if _avail[i] <= EPS:
							_avail[i] = 0.0
							_has_avail[i] = 0
				_sinks.append(i)
				# Array, not PackedInt32Array: a packed array inside a Dictionary
				# copies on write, which would make this grouping quadratic.
				var tier: Array = by_tier.get(n.priority, [])
				tier.append(i)
				by_tier[n.priority] = tier
			else:
				n.served = 1.0
		else:
			n.base_demand = 0.0
			n.demand = 0.0
			n.served = 1.0

	# Research moves transmission loss and conduit capacity, and both of those
	# decide routes. Folding them into the signature is what makes a finished
	# node reroute the grid instead of waiting for the next placement.
	sig = ((sig * 31) ^ (hash(tech_loss) & 0x7FFFFFFF)) & 0x7FFFFFFF
	sig = ((sig * 31) ^ (hash(tech_throughput) & 0x7FFFFFFF)) & 0x7FFFFFFF
	_route_sig = sig

	var tiers: Array = by_tier.keys()
	tiers.sort()
	tiers.reverse()
	for t: int in tiers:
		_tiers.append(t)
		# Members were appended in ascending local index, which is ascending
		# building id — already the order the old code paid a sort to reach.
		_tier_members[t] = PackedInt32Array(by_tier[t])

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
	for i: int in candidates:
		if _avail[i] > EPS:
			out.append(i)
	return out


# --- routing --------------------------------------------------------------

## Points the solver at an already-laid routing solution without recomputing it.
func _use_route(r: HeatRoute) -> void:
	_route_cur = r
	_dist = r.dist
	_eta = r.eta
	_parent = r.parent


## Level-synchronous multi-source BFS. Exact for "fewest hops, then best
## efficiency", because efficiency only shrinks along a path: the best route of
## length L+1 must extend a best route of length L.
##
## `residual` picks the scratch routing object instead of the cross-tick cache.
## The two are separate storage on purpose — an in-tick reroute over the
## saturated graph is a different answer to a different question, and letting it
## overwrite the cache is what used to force a full BFS every tick for any
## network carrying a deficit.
func _route(seeds: PackedInt32Array, residual: bool) -> void:
	var topo: HeatTopology = _topo
	var r: HeatRoute = topo.scratch if residual else topo.primary

	var dist: PackedInt32Array = r.dist
	var eta: PackedFloat64Array = r.eta
	var parent: PackedInt32Array = r.parent
	var root: PackedInt32Array = r.root
	dist.fill(-1)
	eta.fill(1.0)
	parent.fill(-1)
	root.fill(-1)

	var frontier: PackedInt32Array = seeds.duplicate()
	frontier.sort()
	for s: int in frontier:
		dist[s] = 0
		eta[s] = 1.0
		parent[s] = -1
		root[s] = s

	var nb_start: PackedInt32Array = topo.nb_start
	var nb_list: PackedInt32Array = topo.nb_list
	var conducts: PackedByteArray = topo.conducts
	var level: int = 0
	while not frontier.is_empty() and level < MAX_LEVELS:
		_cand_epoch += 1
		var epoch: int = _cand_epoch
		var touched: PackedInt32Array = PackedInt32Array()
		for u: int in frontier:
			var u_conducts: bool = conducts[u] != 0
			# Only a conductor forwards heat. A source that is not a conductor
			# (a lone hearth) still pushes into whatever conductor touches it.
			if not u_conducts and dist[u] != 0:
				continue
			if u_conducts and _cap[u] <= EPS:
				continue
			var eu: float = eta[u]
			var e: int = nb_start[u]
			var e_end: int = nb_start[u + 1]
			while e < e_end:
				var v: int = nb_list[e]
				e += 1
				if dist[v] >= 0:
					continue
				var v_conducts: bool = conducts[v] != 0
				if v_conducts and _cap[v] <= EPS:
					continue

				var ev: float = eu
				if v_conducts:
					ev = 1.0 if _eta_reset[v] != 0 else eu * _eta_mult[v]
				if _cand_mark[v] != epoch:
					_cand_mark[v] = epoch
					_cand_eta[v] = ev
					_cand_par[v] = u
					touched.append(v)
				else:
					var have: float = _cand_eta[v]
					if ev > have + EPS or (absf(ev - have) <= EPS and u < _cand_par[v]):
						_cand_eta[v] = ev
						_cand_par[v] = u
		# Ascending local index is ascending building id, so the level is settled
		# in the same stable order the old sorted key walk produced.
		touched.sort()
		var next_frontier: PackedInt32Array = PackedInt32Array()
		for v: int in touched:
			dist[v] = level + 1
			eta[v] = _cand_eta[v]
			parent[v] = _cand_par[v]
			root[v] = root[_cand_par[v]]
			next_frontier.append(v)
		frontier = next_frontier
		level += 1

	r.dist = dist
	r.eta = eta
	r.parent = parent
	r.root = root
	r.valid = true
	r.bump()
	_use_route(r)


## Path from a sink up to its source, source last. The sink itself is on the
## path when it conducts (its own throughput limits its intake) or when it is
## its own source (a generator that also consumes).
func _path_for(sink: int) -> PackedInt32Array:
	var r: HeatRoute = _route_cur
	if r.stamp[sink] == r.epoch:
		return r.paths[sink]
	if _dist[sink] < 0:
		return PackedInt32Array()
	var p: PackedInt32Array = PackedInt32Array()
	if _topo.conducts[sink] != 0 or _has_avail[sink] != 0:
		p.append(sink)
	var cur: int = _parent[sink]
	var guard: int = 0
	while cur >= 0 and guard < MAX_LEVELS:
		p.append(cur)
		cur = _parent[cur]
		guard += 1
	r.paths[sink] = p
	r.stamp[sink] = r.epoch
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
		var live: PackedInt32Array = _live_sources(_avail_ids)
		if live.is_empty():
			return
		_route(live, true)


func _tier_unmet(tier: PackedInt32Array) -> float:
	var s: float = 0.0
	for c: int in tier:
		s += _rem[c]
	return s


## Progressive filling. Returns true when a constraint saturated, which is the
## signal that rerouting over the residual graph might still find heat.
func _fill(tier: PackedInt32Array) -> bool:
	var active: PackedInt32Array = PackedInt32Array()
	for c: int in tier:
		if _rem[c] <= EPS:
			continue
		if _path_for(c).is_empty():
			var un: HeatNode = _topo.refs[c]
			if un.bottleneck_node < 0:
				un.bottleneck_kind = &"unreachable"
			continue
		active.append(c)
	if active.is_empty():
		return false

	# The union of every active path, sorted ONCE. `active` only ever shrinks
	# across rounds, so this superset stays correct for all of them and a node
	# that drops out simply accumulates zero and is skipped. The old code
	# rebuilt and re-sorted this key set inside the round loop — twelve sorts of
	# a thousand keys per tier per pass, for an order that cannot change.
	_mark_epoch += 1
	var epoch: int = _mark_epoch
	var touched: PackedInt32Array = PackedInt32Array()
	var r: HeatRoute = _route_cur
	for c: int in active:
		for node: int in r.paths[c]:
			if _mark[node] != epoch:
				_mark[node] = epoch
				touched.append(node)
	touched.sort()

	var saturated: bool = false
	var rounds: int = 0
	while not active.is_empty() and rounds < MAX_ROUNDS:
		rounds += 1
		for node: int in touched:
			_acc[node] = 0.0
		for c: int in active:
			var need: float = _rem[c] / maxf(_eta[c], EPS)
			for node: int in r.paths[c]:
				_acc[node] += need

		var t: float = 1.0
		var binding: int = -1
		var binding_kind: int = B_NONE
		for node: int in touched:
			var a: float = _acc[node]
			if a <= EPS:
				continue
			var through: float = _eta[node] * a
			if through > EPS:
				var tn: float = _cap[node] / through
				if tn < t:
					t = tn
					binding = node
					binding_kind = B_CAPACITY
			if _has_avail[node] != 0:
				var tr: float = _avail[node] / a
				if tr < t:
					t = tr
					binding = node
					binding_kind = B_SUPPLY
		t = clampf(t, 0.0, 1.0)

		for c: int in active:
			var give: float = t * _rem[c]
			if give <= 0.0:
				continue
			_got[c] += give
			_loss_acc += give * (1.0 / maxf(_eta[c], EPS) - 1.0)
			_rem[c] = maxf(0.0, _rem[c] - give)
		for node: int in touched:
			var used: float = _acc[node] * t
			if used <= 0.0:
				continue
			var flow: float = _eta[node] * used
			_load[node] += flow
			_cap[node] = maxf(0.0, _cap[node] - flow)
			if _has_avail[node] != 0:
				_avail[node] = maxf(0.0, _avail[node] - used)

		if t >= 1.0 - EPS or binding < 0:
			break
		saturated = true
		var next_active: PackedInt32Array = PackedInt32Array()
		var froze_any: bool = false
		for c: int in active:
			if r.paths[c].has(binding):
				var nd: HeatNode = _topo.refs[c]
				nd.bottleneck_node = _topo.ids[binding]
				nd.bottleneck_kind = &"capacity" if binding_kind == B_CAPACITY else &"supply"
				if _choked[binding] == 0:
					_choked_list.append(binding)
				_choked[binding] += 1
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
		unmet += _rem[c]
	if unmet <= EPS:
		return
	var added: bool = false
	for i: int in _buffers:
		var n: HeatNode = _topo.refs[i]
		var out: float = minf(n.def.discharge_rate, n.stored / _dt)
		if out <= EPS:
			continue
		_buf_avail[i] = out
		if _has_avail[i] == 0:
			_has_avail[i] = 1
			_avail_ids.append(i)
		_avail[i] += out
		added = true
	if not added:
		return
	_route(_live_sources(_avail_ids), true)
	for tier: int in _tiers:
		_serve_tier(_tier_members[tier])


## Whatever production is left over after every consumer is served tops up the
## buffers, routed and capacity-limited exactly like any other draw.
func _phase_charge() -> void:
	var sources: PackedInt32Array = PackedInt32Array()
	for i: int in _producers:
		if _avail[i] > EPS and _buf_avail[i] <= 0.0:
			sources.append(i)
	if sources.is_empty():
		return

	var tier: PackedInt32Array = PackedInt32Array()
	var saved_rem: PackedFloat64Array = PackedFloat64Array()
	var saved_got: PackedFloat64Array = PackedFloat64Array()
	for i: int in _buffers:
		var n: HeatNode = _topo.refs[i]
		if _buf_avail[i] > 0.0:
			continue  # it discharged this tick; do not turn around and refill it
		var room: float = maxf(0.0, n.def.storage * tech_buffer - n.stored) / _dt
		var want: float = minf(n.def.charge_rate, room)
		if want <= EPS:
			continue
		saved_rem.append(_rem[i])
		saved_got.append(_got[i])
		_rem[i] = want
		_got[i] = 0.0
		tier.append(i)
	if tier.is_empty():
		return

	_route(sources, true)
	_fill(tier)
	for k: int in tier.size():
		var i2: int = tier[k]
		var n2: HeatNode = _topo.refs[i2]
		var got: float = _got[i2]
		n2.stored = minf(n2.def.storage * tech_buffer, n2.stored + got * _dt)
		_net.charge += got
		# Charging is not demand: it must never show up as a deficit.
		_rem[i2] = saved_rem[k]
		_got[i2] = saved_got[k]


# --- write back -----------------------------------------------------------

func _write_back() -> void:
	var topo: HeatTopology = _topo
	var ids: PackedInt32Array = topo.ids
	var refs: Array[HeatNode] = topo.refs
	var delivered: float = 0.0
	var unmet: float = 0.0
	var supply_used: float = 0.0
	var discharge: float = 0.0
	var buffer_now: float = 0.0
	var brownouts: int = 0
	var starved: int = 0

	for i: int in _n:
		var n: HeatNode = refs[i]
		var d: HeatDef = n.def
		n.throughput = _load[i]
		n.route_dist = _dist[i]
		n.route_eta = _eta[i]

		if topo.producer[i] != 0 or topo.buffer[i] != 0:
			var offered: float = _prod_avail[i] + _buf_avail[i]
			var used: float = maxf(0.0, offered - _avail[i])
			var from_prod: float = minf(used, _prod_avail[i])
			var from_buf: float = maxf(0.0, used - from_prod)
			if topo.producer[i] != 0:
				n.output = from_prod
				supply_used += from_prod
			if topo.buffer[i] != 0:
				if from_buf > 0.0:
					n.stored = maxf(0.0, n.stored - from_buf * _dt)
					discharge += from_buf
				if d.leak > 0.0:
					n.stored = maxf(0.0, n.stored * (1.0 - d.leak * _dt))
				buffer_now += n.stored

		if topo.consumer[i] != 0:
			if n.demand > EPS:
				var got: float = _got[i]
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

		n.starved_fuel = topo.producer[i] != 0 and n.fuel_factor < 0.999
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
	if _choked_list.is_empty():
		return
	var ids: PackedInt32Array = _topo.ids
	var choked: PackedInt32Array = _choked_list.duplicate()
	choked.sort()
	var out: Array[Dictionary] = []
	for i: int in choked:
		var node: HeatNode = _nodes.get(ids[i])
		if node == null:
			continue
		var cap: float = _cap_full[i]
		out.append({
			"node": ids[i],
			"kind": String(node.kind),
			"cell": [node.cell.x, node.cell.y],
			"reason": "supply" if _choked_kind[i] == B_SUPPLY else "capacity",
			"load": snappedf(_load[i], 0.001),
			"capacity": snappedf(0.0 if cap >= BIG else cap, 0.001),
			"consumers": _choked[i],
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ca: int = int(a["consumers"])
		var cb: int = int(b["consumers"])
		if ca != cb:
			return ca > cb
		return int(a["node"]) < int(b["node"]))
	_net.bottlenecks = out
