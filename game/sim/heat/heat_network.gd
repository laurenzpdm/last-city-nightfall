class_name HeatNetwork
extends RefCounted
## One connected component of the heat graph: its cached routing, its balance
## sheet for the tick, and the evidence a player needs to understand a brownout.

var id: int = 0

# --- dense topology + cached routing -----------------------------------------
# `topo` holds the index space, the CSR adjacency and BOTH routing solutions:
# the cross-tick cache and the in-tick residual scratch. Keeping them apart is
# why a network running a deficit no longer re-routes from scratch every tick.
var topo: HeatTopology = null
var route_sig: int = 0          ## hash of every routing-relevant gate
var route_dirty: bool = true    ## something changed that the signature cannot see
var routed_ticks: int = 0       ## how often we had to rebuild — a perf tell

# --- last solved balance sheet ---
var supply: float = 0.0         ## producer capacity available this tick, u/s
var supply_used: float = 0.0
var demand: float = 0.0
var delivered: float = 0.0
var deficit: float = 0.0
var loss: float = 0.0
var buffer: float = 0.0
var buffer_capacity: float = 0.0
var charge: float = 0.0
var discharge: float = 0.0
var producers: int = 0
var consumers: int = 0
var brownouts: int = 0
var starved: int = 0
var bottlenecks: Array[Dictionary] = []

# --- alert throttling ---
var last_shortfall_tick: int = -100000
var last_alert_key: StringName = &""
var last_alert_tick: int = -100000


func _init(net_id: int) -> void:
	id = net_id


## The dense view of this network, rebuilt only when the graph version moves.
## Everything expensive about a solve is addressed through this.
func topology(members: PackedInt32Array, nodes: Dictionary[int, HeatNode],
		neigh: Dictionary[int, PackedInt32Array], graph_version: int) -> HeatTopology:
	if topo == null:
		topo = HeatTopology.new()
	if not topo.matches(graph_version, members):
		topo.build(members, nodes, neigh, graph_version)
		route_dirty = true
	return topo


func clear_routing() -> void:
	if topo != null:
		topo.primary.valid = false
		topo.primary.bump()
		topo.scratch.bump()
	route_dirty = true


func stats(node_count: int) -> Dictionary:
	var worst: Dictionary = {}
	if not bottlenecks.is_empty():
		worst = bottlenecks[0]
	return {
		"id": id,
		"nodes": node_count,
		"supply": snappedf(supply, 0.001),
		"supply_used": snappedf(supply_used, 0.001),
		"demand": snappedf(demand, 0.001),
		"delivered": snappedf(delivered, 0.001),
		"deficit": snappedf(deficit, 0.001),
		"loss": snappedf(loss, 0.001),
		"buffer": snappedf(buffer, 0.001),
		"buffer_capacity": snappedf(buffer_capacity, 0.001),
		"charge": snappedf(charge, 0.001),
		"discharge": snappedf(discharge, 0.001),
		"producers": producers,
		"consumers": consumers,
		"brownouts": brownouts,
		"starved": starved,
		"bottlenecks": bottlenecks.duplicate(true),
		"worst_bottleneck": worst,
	}
