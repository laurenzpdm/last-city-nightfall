class_name HeatTopology
extends RefCounted
## The dense, index-based shape of one heat network, rebuilt only when the graph
## version moves.
##
## WHY THIS EXISTS. The solver used to address everything by building id through
## Dictionaries: `_dist.has(v)`, `_nodes.get(v)`, `nv.def.conducts()`,
## `_cap.get(v, 0.0)` — roughly ten hashed lookups and two method calls per graph
## EDGE, and a 1400-node network has ~5600 edge relaxations per routing pass.
## That cost 2.5 ms per reroute and the tick did four of them.
##
## Here every node of a network gets a local index 0..n-1 assigned in ASCENDING
## BUILDING ID order. That single choice buys three things at once:
##   * every per-node table becomes a PackedArray indexed in O(1) with no hashing,
##   * adjacency becomes a flat CSR pair (`nb_start` / `nb_list`) instead of a
##     dictionary of PackedInt32Arrays, and
##   * iterating 0..n-1 IS iterating in sorted-id order, so the `keys.sort()`
##     calls that determinism used to require disappear rather than being trusted.
##
## Everything on here is derived from the graph and from HeatDef, both of which
## only change when a building is placed or removed. Per-tick state (capacity
## left, availability, demand) stays in HeatFlow's own scratch.

var version: int = -1                   ## HeatGraph.version this was built from
var count: int = 0

var ids: PackedInt32Array = PackedInt32Array()      ## local index -> building id, ascending
var index: Dictionary[int, int] = {}                ## building id -> local index

var nb_start: PackedInt32Array = PackedInt32Array() ## size count+1, CSR offsets
var nb_list: PackedInt32Array = PackedInt32Array()  ## neighbour local indices

var conducts: PackedByteArray = PackedByteArray()
var producer: PackedByteArray = PackedByteArray()
var consumer: PackedByteArray = PackedByteArray()
var buffer: PackedByteArray = PackedByteArray()
var repeater: PackedByteArray = PackedByteArray()
var loss_per_tile: PackedFloat64Array = PackedFloat64Array()

var primary: HeatRoute = HeatRoute.new()
var scratch: HeatRoute = HeatRoute.new()


## True when this topology still describes the network it was built for.
## `HeatGraph.version` bumps on every placement and removal, and membership can
## only change through one of those, so the version is the whole test — the size
## and endpoint checks are belt and braces against a recycled network id.
func matches(graph_version: int, members: PackedInt32Array) -> bool:
	if version != graph_version or count != members.size():
		return false
	if count == 0:
		return true
	return ids[0] == members[0] and ids[count - 1] == members[count - 1]


func build(members: PackedInt32Array, nodes: Dictionary[int, HeatNode],
		neigh: Dictionary[int, PackedInt32Array], graph_version: int) -> void:
	version = graph_version
	count = members.size()
	ids = members.duplicate()
	index.clear()
	for i: int in count:
		index[ids[i]] = i

	conducts.resize(count)
	producer.resize(count)
	consumer.resize(count)
	buffer.resize(count)
	repeater.resize(count)
	loss_per_tile.resize(count)

	nb_start.resize(count + 1)
	nb_list.resize(0)
	var written: int = 0
	for i: int in count:
		nb_start[i] = written
		var node: HeatNode = nodes.get(ids[i])
		if node == null:
			conducts[i] = 0
			producer[i] = 0
			consumer[i] = 0
			buffer[i] = 0
			repeater[i] = 0
			loss_per_tile[i] = 0.0
			continue
		var d: HeatDef = node.def
		conducts[i] = 1 if d.conducts() else 0
		producer[i] = 1 if d.is_producer() else 0
		consumer[i] = 1 if d.is_consumer() else 0
		buffer[i] = 1 if d.is_buffer() else 0
		repeater[i] = 1 if d.repeater else 0
		loss_per_tile[i] = d.loss_per_tile
		for other: int in neigh.get(ids[i], PackedInt32Array()):
			var j: int = index.get(other, -1)
			if j < 0:
				continue  # a neighbour outside this component cannot carry its heat
			nb_list.append(j)
			written += 1
	nb_start[count] = written

	primary.resize(count)
	scratch.resize(count)
