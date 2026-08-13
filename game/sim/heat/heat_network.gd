class_name HeatNetwork
extends RefCounted
## One connected component of the heat graph: its cached routing, its balance
## sheet for the tick, and the evidence a player needs to understand a brownout.

var id: int = 0

# --- cached routing (rebuilt only when the graph or the live source set moves) ---
var dist: Dictionary[int, int] = {}
var eta: Dictionary[int, float] = {}
var parent: Dictionary[int, int] = {}
var root: Dictionary[int, int] = {}
var paths: Dictionary[int, PackedInt32Array] = {}
var route_version: int = -1     ## graph version the routing was built from
var route_sig: int = 0          ## hash of the live source set
var route_dirty: bool = true    ## set when an in-tick reroute overwrote the cache
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


func clear_routing() -> void:
	dist.clear()
	eta.clear()
	parent.clear()
	root.clear()
	paths.clear()
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
