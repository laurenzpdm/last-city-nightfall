class_name HeatRoute
extends RefCounted
## One routing solution over a network, stored densely by local node index.
##
## Two of these exist per network: the PRIMARY one, which survives across ticks
## for as long as nothing routing-relevant changed, and a SCRATCH one, which
## in-tick residual reroutes write to. Keeping them apart is the whole point —
## before this the residual pass wrote over the cache and then had to declare it
## dirty, so a network with any deficit at all re-ran a full BFS every tick, and
## a network in deficit is most of every night.
##
## Paths are cached with an epoch stamp rather than by clearing an array of a
## thousand entries: a reroute bumps `epoch` and every stale path is invalid at
## once, at the cost of one integer compare when it is read.

var dist: PackedInt32Array = PackedInt32Array()    ## hops from the source, -1 = unreachable
var eta: PackedFloat64Array = PackedFloat64Array() ## transmission efficiency of that route
var parent: PackedInt32Array = PackedInt32Array()  ## previous node on the route, -1 = root
var root: PackedInt32Array = PackedInt32Array()    ## the source that claimed this node

var paths: Array[PackedInt32Array] = []            ## sink -> node chain, sink first, source last
var stamp: Array[int] = []                         ## which epoch that cached path belongs to
var epoch: int = 0

var valid: bool = false                            ## false until a route has been laid
## Hash of every input the router branched on to produce this solution: the seed
## set, the tiles that were saturated shut, and the gates in HeatFlow._route_sig.
## Same signature, same answer — that is what makes reusing it sound rather than
## hopeful. 0 means "never laid".
var sig: int = 0


## Sizes every array for a network of `n` nodes. Called once per topology build,
## not per tick — the arrays are then reused for the life of the topology.
func resize(n: int) -> void:
	dist.resize(n)
	eta.resize(n)
	parent.resize(n)
	root.resize(n)
	paths.resize(n)
	stamp.resize(n)
	for i: int in n:
		stamp[i] = -1
	epoch = 0
	valid = false


## Invalidates every cached path without touching a thousand array slots.
func bump() -> void:
	epoch += 1
