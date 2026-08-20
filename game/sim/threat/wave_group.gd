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
## Which ARRIVAL MOMENT this packet belongs to. Every group sharing an echelon
## walks onto the map on the same tick, which is what makes a night a wave
## instead of a metronome — see ThreatSystem._distribute.
var echelon: int = 0
## Where in the arrival window this packet belongs, 0..1. Stamped at
## distribution time, when the length of the night is not yet known; turned into
## `delay_ticks` at nightfall, when it is. A night that runs from dusk to dawn
## has to spread its arrivals over ITS length, not over a constant somebody
## picked while there was no clock in the build.
var delay_frac: float = 0.0
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
		"delay_frac": snappedf(delay_frac, 0.001),
		"echelon": echelon,
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
	g.delay_frac = float(d.get("delay_frac", 0.0))
	g.echelon = int(d.get("echelon", 0))
	var c: Variant = d.get("cell", [])
	if typeof(c) == TYPE_ARRAY and (c as Array).size() >= 2:
		g.spawn_cell = Vector2i(int((c as Array)[0]), int((c as Array)[1]))
	g.dispatched = bool(d.get("dispatched", false))
	g.handle = int(d.get("handle", -1))
	return g
