class_name HeatNode
extends RefCounted
## One building as the heat network sees it: a vertex with a footprint, a role,
## a thermal state and a service record. Everything the player needs to answer
## "why is this thing cold?" lives on this object.

enum State {
	ONLINE,    ## getting everything it asked for (or asking for nothing)
	BROWNOUT,  ## partially served — runs slower, radiates less
	OFFLINE,   ## shed, starved or switched off
	FROZEN,    ## internal temperature collapsed; dead until it thaws
}

const TILE: float = 32.0

var id: int = 0
var kind: StringName = &""
var cell: Vector2i = Vector2i.ZERO      ## origin cell as placed
var rot: int = 0
var def: HeatDef = null
var footprint: Array[Vector2i] = []
var bbox_origin: Vector2i = Vector2i.ZERO
var bbox_size: Vector2i = Vector2i.ONE
var center_cell: Vector2i = Vector2i.ZERO
var world_pos: Vector2 = Vector2.ZERO

var enabled: bool = true
var priority: int = 50
var state: int = State.ONLINE

# --- per-tick flow record -------------------------------------------------
var base_demand: float = 0.0   ## what it needs to operate, cold-scaled, u/s
var demand: float = 0.0        ## base + thermal-mass recharge — what the grid sees
var delivered: float = 0.0     ## what actually reached its operation, u/s
var served: float = 1.0        ## delivered / base_demand, 1.0 when it asks for nothing
var output: float = 0.0        ## what the generator actually pushed, u/s
var throughput: float = 0.0    ## flow passing through this tile, u/s
var route_dist: int = -1       ## tiles from the source that feeds it, -1 = unrouted
var route_eta: float = 1.0     ## transmission efficiency of that route, 0..1
var bottleneck_node: int = -1  ## id of the tile that choked it, -1 = none
var bottleneck_kind: StringName = &""  ## &"capacity" | &"supply" | &"unreachable"

# --- persistent state -----------------------------------------------------
var net: int = -1
var site_bonus: float = 1.0    ## terrain multiplier on output, e.g. a geothermal vent
var stored: float = 0.0        ## grid buffer charge, units
var local_stored: float = 0.0  ## private thermal mass, units
var fuel_stock: float = 0.0    ## items in the local bunker
var fuel_factor: float = 1.0   ## 0..1 how well the burner was fed last tick
var temp_c: float = 15.0       ## internal temperature
var frozen: bool = false
var cold_ticks: int = 0        ## consecutive ticks below the freeze threshold
var frozen_ticks: int = 0
var radiance_cur: float = 0.0  ## smoothed radiant strength actually emitted
var repeater_live: bool = true ## a starved booster pump stops repeating next tick
var starved_fuel: bool = false


func setup(node_id: int, node_kind: StringName, origin: Vector2i, d: HeatDef, rotation: int = 0) -> void:
	id = node_id
	kind = node_kind
	cell = origin
	rot = rotation
	def = d
	priority = d.priority
	footprint = d.footprint_at(origin, rotation)
	if footprint.is_empty():
		footprint = [origin]
	var lo: Vector2i = footprint[0]
	var hi: Vector2i = footprint[0]
	for c: Vector2i in footprint:
		lo.x = mini(lo.x, c.x)
		lo.y = mini(lo.y, c.y)
		hi.x = maxi(hi.x, c.x)
		hi.y = maxi(hi.y, c.y)
	bbox_origin = lo
	bbox_size = hi - lo + Vector2i.ONE
	center_cell = lo + Vector2i(bbox_size.x / 2, bbox_size.y / 2)
	world_pos = Vector2(
		(float(lo.x) + float(bbox_size.x) * 0.5) * TILE,
		(float(lo.y) + float(bbox_size.y) * 0.5) * TILE)
	served = 1.0


## Radiant strength multiplier, 0..1. A generator glows while it burns, a pipe
## glows with the load it carries, a buffer with its charge, a heated building
## with how well it is served. The most generous applicable role wins, so a full
## accumulator still glows while idle.
func radiance_factor() -> float:
	if not enabled or frozen:
		return 0.0
	var f: float = 0.0
	var any: bool = false
	if def.is_producer():
		f = maxf(f, fuel_factor)
		any = true
	if def.is_consumer():
		f = maxf(f, served)
		any = true
	if def.is_buffer() and def.storage > 0.0:
		f = maxf(f, stored / def.storage)
		any = true
	if def.conducts() and def.capacity > 0.0:
		f = maxf(f, clampf(throughput / def.capacity, 0.0, 1.0))
		any = true
	return f if any else 1.0


func is_working() -> bool:
	return enabled and not frozen and state != State.OFFLINE


## What another system should multiply its own rate by: a browned-out turret
## fires slower, a browned-out machine crafts slower, a frozen one does nothing.
func power_factor() -> float:
	if not enabled or frozen:
		return 0.0
	if def.demand <= 0.0:
		return 1.0
	return clampf(served, 0.0, 1.0)
