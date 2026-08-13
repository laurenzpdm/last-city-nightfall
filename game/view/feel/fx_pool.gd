class_name LcnFxPool
extends RefCounted
## Fixed-size, allocation-free store for short-lived world effects. [P15]
##
## Everything the feel layer puts in the world — dust, sparks, rings, embers,
## debris, frost — is one row in here. Flat packed arrays rather than an Array
## of Dictionaries, for two reasons that both showed up in this build already:
## a Dictionary probe per effect per frame is ~2 us and there can be two hundred
## of them, and a growing array is a hitch waiting for the first big night.
##
## The pool NEVER grows and never allocates after construction. When it is full
## the oldest row is overwritten, so a thousand simultaneous deaths cost exactly
## the same as ten and the frame budget is a constant.
##
## Ageing is by WORLD time (LcnTiming.world_now), not frame delta: effects belong
## to simulated events, so they freeze when the player pauses and run triple at
## 3x speed, and — the reason this matters for the gate — a harness run that
## advances 1400 ticks between two rendered frames ages them correctly instead of
## playing 70 seconds of dust in one frame.

enum Kind {
	DUST,    ## a soft ground puff that expands and drifts. Placement, impact, collapse.
	RING,    ## an expanding circle outline. Snap-to-grid, completion, shockwave.
	SPARK,   ## a short streak with gravity. Welding, hits, muzzle grit.
	FLASH,   ## a filled rect that fades. Completion, damage, muzzle.
	EMBER,   ## a rising warm dot that flickers out. Death, fire, the hearth.
	SHARD,   ## a spinning debris triangle that falls. Demolition, destruction.
	FROST,   ## a pale expanding hexagon. A building freezing.
	TRACER,  ## a fading line from A to B. Turret fire.
	STAMP,   ## a footprint rect that snaps inward. Placement confirmation.
}

## Floats per row: x y vx vy born life size p0 p1 seed r g b a
const STRIDE: int = 14
const F_X: int = 0
const F_Y: int = 1
const F_VX: int = 2
const F_VY: int = 3
const F_BORN: int = 4
const F_LIFE: int = 5
const F_SIZE: int = 6
const F_P0: int = 7
const F_P1: int = 8
const F_SEED: int = 9
const F_R: int = 10
const F_G: int = 11
const F_B: int = 12
const F_A: int = 13

var capacity: int = 256

var _kind: PackedInt32Array = PackedInt32Array()
var _data: PackedFloat32Array = PackedFloat32Array()
var _alive: PackedInt32Array = PackedInt32Array()   ## 1 = occupied
var _next: int = 0
var _count: int = 0
## Monotonic, for a test that wants to know the pool actually recycled.
var spawned: int = 0
var dropped: int = 0


func _init(cap: int = 256) -> void:
	capacity = maxi(8, cap)
	_kind.resize(capacity)
	_alive.resize(capacity)
	_data.resize(capacity * STRIDE)
	clear()


func clear() -> void:
	_kind.fill(0)
	_alive.fill(0)
	_data.fill(0.0)
	_next = 0
	_count = 0


## Writes one effect. Returns its slot index.
##
## `life` is clamped to LcnTiming.MAX_EFFECT_LIFE, so no caller can leak a
## particle that outlives the frame budget it was granted.
func spawn(kind: Kind, pos: Vector2, vel: Vector2, life: float, size: float,
		col: Color, p0: float = 0.0, p1: float = 0.0, seed_value: float = 0.0) -> int:
	var i: int = _claim()
	var o: int = i * STRIDE
	_kind[i] = int(kind)
	_alive[i] = 1
	_data[o + F_X] = pos.x
	_data[o + F_Y] = pos.y
	_data[o + F_VX] = vel.x
	_data[o + F_VY] = vel.y
	_data[o + F_BORN] = LcnTiming.world_now()
	_data[o + F_LIFE] = clampf(life, 0.02, LcnTiming.MAX_EFFECT_LIFE)
	_data[o + F_SIZE] = size
	_data[o + F_P0] = p0
	_data[o + F_P1] = p1
	_data[o + F_SEED] = seed_value
	_data[o + F_R] = col.r
	_data[o + F_G] = col.g
	_data[o + F_B] = col.b
	_data[o + F_A] = col.a
	spawned += 1
	return i


## Retires everything whose life has run out. O(capacity), no allocation.
func prune(now: float) -> void:
	for i: int in capacity:
		if _alive[i] == 0:
			continue
		var o: int = i * STRIDE
		if now - _data[o + F_BORN] >= _data[o + F_LIFE]:
			_alive[i] = 0
			_count -= 1


func count() -> int:
	return _count


func alive_at(i: int) -> bool:
	return _alive[i] == 1


func kind_at(i: int) -> int:
	return _kind[i]


func field(i: int, f: int) -> float:
	return _data[i * STRIDE + f]


func position_at(i: int) -> Vector2:
	var o: int = i * STRIDE
	return Vector2(_data[o + F_X], _data[o + F_Y])


func velocity_at(i: int) -> Vector2:
	var o: int = i * STRIDE
	return Vector2(_data[o + F_VX], _data[o + F_VY])


func color_at(i: int) -> Color:
	var o: int = i * STRIDE
	return Color(_data[o + F_R], _data[o + F_G], _data[o + F_B], _data[o + F_A])


## 0 at birth, 1 at death. The single number every draw path needs.
func age01(i: int, now: float) -> float:
	var o: int = i * STRIDE
	return clampf((now - _data[o + F_BORN]) / maxf(_data[o + F_LIFE], 0.0001), 0.0, 1.0)


## Deterministic per-effect jitter in -1..1, so two hundred puffs do not all
## look the same without ever touching a random number generator.
func wobble(i: int, channel: int) -> float:
	var s: int = int(_data[i * STRIDE + F_SEED]) * 2654435761 + channel * 40503
	s = (s ^ (s >> 13)) & 0x7FFFFFFF
	return float(s % 20001) / 10000.0 - 1.0


func _claim() -> int:
	# One pass looking for a free slot from the rotating cursor. Bounded by
	# capacity, so the worst case is a full pool and the cost is a constant.
	for _step: int in capacity:
		var i: int = _next
		_next = (_next + 1) % capacity
		if _alive[i] == 0:
			_count += 1
			return i
	# Full: overwrite the slot the cursor is on. The oldest effect in a full
	# pool is the least interesting thing on screen.
	var victim: int = _next
	_next = (_next + 1) % capacity
	dropped += 1
	return victim
