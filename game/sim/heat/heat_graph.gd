class_name HeatGraph
extends RefCounted
## Occupancy map + adjacency + connected components of the heat network.
##
## Connection rule: two buildings are linked when their footprints touch
## orthogonally AND at least one of them conducts (heat_capacity > 0). Two
## machines standing side by side are NOT connected — you have to run a pipe.
## That single rule is what makes base layout a real decision.
##
## Components are maintained incrementally. Placing a tile unions components in
## near-constant time; removing one marks only its own component dirty and the
## next settle() re-floods that component alone. The whole world is never
## rebuilt because one pipe was picked up. rebuild_all() exists purely so tests
## can prove the incremental result equals the from-scratch result.

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

var occ: Dictionary[Vector2i, int] = {}            ## cell -> building id
var neigh: Dictionary[int, PackedInt32Array] = {}  ## building id -> sorted linked ids
var net_of: Dictionary[int, int] = {}              ## building id -> network id
var members: Dictionary[int, PackedInt32Array] = {}## network id -> sorted building ids
var version: int = 0                               ## bumped on every structural change

var _nodes: Dictionary[int, HeatNode] = {}
var _next_net: int = 1
var _dirty: Dictionary[int, bool] = {}
var _changed: Dictionary[int, bool] = {}


func _init(node_table: Dictionary[int, HeatNode]) -> void:
	_nodes = node_table


## True when every cell of the footprint is free.
func can_place(node: HeatNode) -> bool:
	for c: Vector2i in node.footprint:
		if occ.has(c):
			return false
	return true


func add(node: HeatNode) -> bool:
	if not can_place(node):
		return false
	for c: Vector2i in node.footprint:
		occ[c] = node.id
	var links: PackedInt32Array = _compute_links(node)
	neigh[node.id] = links
	for other: int in links:
		var arr: PackedInt32Array = neigh.get(other, PackedInt32Array())
		if not arr.has(node.id):
			arr.append(node.id)
			arr.sort()
			neigh[other] = arr
	_join(node.id, links)
	version += 1
	return true


func remove(id: int) -> bool:
	var node: HeatNode = _nodes.get(id)
	if node == null:
		return false
	for c: Vector2i in node.footprint:
		if occ.get(c, -1) == id:
			occ.erase(c)
	for other: int in neigh.get(id, PackedInt32Array()):
		var arr: PackedInt32Array = neigh.get(other, PackedInt32Array())
		var at: int = arr.find(id)
		if at >= 0:
			arr.remove_at(at)
			neigh[other] = arr
	neigh.erase(id)

	var nid: int = net_of.get(id, -1)
	net_of.erase(id)
	if nid >= 0:
		var mem: PackedInt32Array = members.get(nid, PackedInt32Array())
		var at2: int = mem.find(id)
		if at2 >= 0:
			mem.remove_at(at2)
		if mem.is_empty():
			members.erase(nid)
			_dirty.erase(nid)
		else:
			members[nid] = mem
			_dirty[nid] = true
		_changed[nid] = true
	version += 1
	return true


## Re-splits every component that lost a tile since the last call.
## Returns the network ids whose membership changed, sorted — the caller
## announces them on Bus.network_changed.
func settle() -> PackedInt32Array:
	if not _dirty.is_empty():
		var dirty_ids: Array = _dirty.keys()
		dirty_ids.sort()
		_dirty.clear()
		for nid: int in dirty_ids:
			_resplit(nid)
	var out: PackedInt32Array = PackedInt32Array()
	if _changed.is_empty():
		return out
	var keys: Array = _changed.keys()
	keys.sort()
	_changed.clear()
	for k: int in keys:
		out.append(k)
	return out


## Sorted network ids that currently exist.
func network_ids() -> PackedInt32Array:
	var keys: Array = members.keys()
	keys.sort()
	var out: PackedInt32Array = PackedInt32Array()
	for k: int in keys:
		out.append(k)
	return out


## Discards every component and re-derives them from adjacency alone.
## Only used by tests and by save loading.
func rebuild_all() -> void:
	net_of.clear()
	members.clear()
	_dirty.clear()
	_next_net = 1
	var ids: Array = _nodes.keys()
	ids.sort()
	for id: int in ids:
		if net_of.has(id):
			continue
		var nid: int = _next_net
		_next_net += 1
		var comp: PackedInt32Array = _flood(id, {})
		comp.sort()
		for m: int in comp:
			net_of[m] = nid
		members[nid] = comp
		_changed[nid] = true
	version += 1


## Partition as a comparable value: sorted list of sorted member lists.
## Network *ids* legitimately differ between an incremental run and a rebuild;
## the partition must not.
func partition_signature() -> Array:
	var sig: Array = []
	for nid: int in network_ids():
		var mem: PackedInt32Array = members[nid]
		var one: Array = []
		for m: int in mem:
			one.append(m)
		sig.append(one)
	sig.sort_custom(func(a: Array, b: Array) -> bool:
		if a.is_empty():
			return true
		if b.is_empty():
			return false
		return int(a[0]) < int(b[0]))
	return sig


func _compute_links(node: HeatNode) -> PackedInt32Array:
	var seen: Dictionary[int, bool] = {}
	var self_conducts: bool = node.def.conducts()
	for c: Vector2i in node.footprint:
		for off: Vector2i in NEIGHBOR_OFFSETS:
			var other: int = occ.get(c + off, -1)
			if other < 0 or other == node.id or seen.has(other):
				continue
			var on: HeatNode = _nodes.get(other)
			if on == null:
				continue
			if self_conducts or on.def.conducts():
				seen[other] = true
	var out: PackedInt32Array = PackedInt32Array()
	var keys: Array = seen.keys()
	keys.sort()
	for k: int in keys:
		out.append(k)
	return out


func _join(id: int, links: PackedInt32Array) -> void:
	var nets: Dictionary[int, bool] = {}
	for other: int in links:
		var n: int = net_of.get(other, -1)
		if n >= 0:
			nets[n] = true
	if nets.is_empty():
		var nid: int = _next_net
		_next_net += 1
		net_of[id] = nid
		var mem: PackedInt32Array = PackedInt32Array()
		mem.append(id)
		members[nid] = mem
		_changed[nid] = true
		return

	var candidates: Array = nets.keys()
	candidates.sort()
	# Merge into the biggest component so relabelling stays cheap; ties go to the
	# lowest id so the outcome does not depend on dictionary order.
	var keep: int = candidates[0]
	var best: int = members.get(keep, PackedInt32Array()).size()
	for c: int in candidates:
		var sz: int = members.get(c, PackedInt32Array()).size()
		if sz > best:
			best = sz
			keep = c
	var kept: PackedInt32Array = members.get(keep, PackedInt32Array())
	for c: int in candidates:
		if c == keep:
			continue
		for m: int in members.get(c, PackedInt32Array()):
			net_of[m] = keep
			kept.append(m)
		members.erase(c)
		_changed[c] = true
	net_of[id] = keep
	kept.append(id)
	kept.sort()
	members[keep] = kept
	_changed[keep] = true


func _resplit(nid: int) -> void:
	var mem: PackedInt32Array = members.get(nid, PackedInt32Array())
	if mem.size() <= 1:
		return
	var visited: Dictionary[int, bool] = {}
	var comps: Array[PackedInt32Array] = []
	for m: int in mem:
		if visited.has(m):
			continue
		var comp: PackedInt32Array = _flood(m, visited)
		comp.sort()
		comps.append(comp)
	if comps.size() <= 1:
		return
	# The largest fragment inherits the id (fewest relabels, and the trunk of a
	# network keeps its identity in the UI when a spur is cut off).
	var keep_at: int = 0
	for i: int in range(comps.size()):
		if comps[i].size() > comps[keep_at].size():
			keep_at = i
	for i: int in range(comps.size()):
		var target: int = nid
		if i != keep_at:
			target = _next_net
			_next_net += 1
		for m: int in comps[i]:
			net_of[m] = target
		members[target] = comps[i]
		_changed[target] = true


func _flood(start: int, visited: Dictionary) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var stack: PackedInt32Array = PackedInt32Array()
	stack.append(start)
	visited[start] = true
	while not stack.is_empty():
		var u: int = stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		out.append(u)
		for v: int in neigh.get(u, PackedInt32Array()):
			if visited.has(v):
				continue
			visited[v] = true
			stack.append(v)
	return out
