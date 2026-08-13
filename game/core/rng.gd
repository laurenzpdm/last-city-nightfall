extends Node
## The ONLY source of randomness in the simulation.
## Named streams stay independent, so adding a roll in one system cannot
## shift the sequence in another — that is what keeps replays stable.

var seed_value: int = 0
var _streams: Dictionary[String, RandomNumberGenerator] = {}


## Reseeds everything. Call once at world creation, never mid-run.
func reset(new_seed: int) -> void:
	seed_value = new_seed
	_streams.clear()
	Log.info("rng", "seeded %d" % new_seed)


## Independent, deterministic stream for a named consumer, e.g. "threat", "mapgen".
func stream(name: String) -> RandomNumberGenerator:
	var existing: RandomNumberGenerator = _streams.get(name)
	if existing != null:
		return existing
	var r := RandomNumberGenerator.new()
	r.seed = hash_combine(seed_value, name.hash())
	_streams[name] = r
	return r


## Snapshot of every stream's position, for save/replay verification.
func snapshot() -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = _streams.keys()
	keys.sort()
	for k: String in keys:
		out[k] = _streams[k].state
	return out


func restore(snap: Dictionary) -> void:
	var keys: Array = snap.keys()
	keys.sort()
	for k: String in keys:
		stream(k).state = int(snap[k])


static func hash_combine(a: int, b: int) -> int:
	var h: int = a
	h = (h ^ b) * 0x100000001b3
	return h & 0x7FFFFFFFFFFFFFFF
