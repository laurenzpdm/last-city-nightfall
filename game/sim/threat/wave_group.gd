class_name WaveGroup
extends RefCounted
## One packet of one kind of enemy, arriving on one vector at one moment.
##
## A night is a list of these. Splitting a composition into timed groups is what
## turns an attack into a rhythm the player can fight in stages instead of one
## undifferentiated blob at the gate.

## EnemyDef id.
var enemy: StringName = &""
## How many individuals. Always a multiple of the def's pack_size.
var count: int = 0
## Budget points this group cost. Sums over a plan to WavePlan.spent.
var cost: float = 0.0
## Index into WavePlan.vectors.
var vector: int = 0
## Ticks after nightfall at which this group walks onto the map.
var delay_ticks: int = 0
## Where it enters. Cached from the vector so a spawn never needs the grid.
var spawn_cell: Vector2i = Vector2i.ZERO
## Set once the group has been handed to combat (or to the siege model).
var dispatched: bool = false
## Id combat returned for this group, or -1. Lets the director ask about it.
var handle: int = -1


func to_dict() -> Dictionary:
	return {
		"enemy": String(enemy),
		"count": count,
		"cost": snappedf(cost, 0.01),
		"vector": vector,
		"delay": delay_ticks,
		"cell": [spawn_cell.x, spawn_cell.y],
		"dispatched": dispatched,
		"handle": handle,
	}


static func from_dict(d: Dictionary) -> WaveGroup:
	var g := WaveGroup.new()
	g.enemy = StringName(String(d.get("enemy", "")))
	g.count = int(d.get("count", 0))
	g.cost = float(d.get("cost", 0.0))
	g.vector = int(d.get("vector", 0))
	g.delay_ticks = int(d.get("delay", 0))
	var c: Variant = d.get("cell", [])
	if typeof(c) == TYPE_ARRAY and (c as Array).size() >= 2:
		g.spawn_cell = Vector2i(int((c as Array)[0]), int((c as Array)[1]))
	g.dispatched = bool(d.get("dispatched", false))
	g.handle = int(d.get("handle", -1))
	return g
