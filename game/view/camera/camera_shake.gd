class_name CameraShake
extends RefCounted
## Trauma-based screen shake. Pure math, deterministic, no engine randomness.
##
## Trauma is a 0..1 charge. Impacts add to it, it bleeds off linearly, and the actual
## displacement is trauma^exponent — so a mortar hit is violent and a rifle shot is a
## twitch, from the same call. Displacement comes from smooth value noise rather than
## white noise, because white noise reads as "broken monitor" and smooth noise reads
## as "the ground moved".
##
## Deterministic on purpose: same calls at the same dt produce the same offsets, so a
## visual regression run diffs cleanly and the decay is testable.

var trauma: float = 0.0
var frequency: float = 22.0
var decay_per_second: float = 3.0
var max_offset_px: float = 26.0
var max_roll: float = 0.02
var exponent: float = 2.0
var noise_seed: int = 0x5EED

var _time: float = 0.0


func _init(tuning: CameraTuning = null) -> void:
	if tuning != null:
		max_offset_px = tuning.shake_max_offset_px
		max_roll = tuning.shake_max_roll
		frequency = tuning.shake_default_frequency
		exponent = tuning.shake_exponent


## Add an impact. `strength` 0..1, `duration` seconds for that strength to bleed off,
## `frequency` shakes per second (low = heavy lurch, high = sharp rattle).
func add(strength: float, duration: float = 0.35, freq: float = -1.0) -> void:
	var s: float = clampf(strength, 0.0, 1.0)
	if s <= 0.0:
		return
	var d: float = s / maxf(duration, 0.02)
	var f: float = frequency if freq <= 0.0 else freq
	if trauma > 0.0001:
		# The longest-lived request wins the decay, so a pistol tick cannot cut a
		# collapsing-building rumble short. Frequency blends by how loud the new hit is.
		decay_per_second = minf(decay_per_second, d)
		frequency = lerpf(frequency, f, s)
	else:
		decay_per_second = d
		frequency = f
	trauma = clampf(trauma + s, 0.0, 1.0)


func advance(dt: float) -> void:
	if dt <= 0.0:
		return
	_time += dt
	if trauma <= 0.0:
		return
	trauma = maxf(0.0, trauma - decay_per_second * dt)
	if trauma <= 0.0:
		_time = 0.0


func active() -> bool:
	return trauma > 0.0


## Displacement curve. Public so tests and [P15] can reason about it.
func amount() -> float:
	return pow(trauma, exponent)


## Screen-space displacement in pixels.
func offset() -> Vector2:
	var a: float = amount()
	if a <= 0.0:
		return Vector2.ZERO
	var t: float = _time * frequency
	return Vector2(_noise(1, t), _noise(2, t)) * (max_offset_px * a)


## Roll in radians. Tiny by design; a top-down grid must not visibly tilt.
func roll() -> float:
	var a: float = amount()
	if a <= 0.0:
		return 0.0
	return _noise(3, _time * frequency) * max_roll * a


func reset() -> void:
	trauma = 0.0
	_time = 0.0


## Smooth value noise in [-1, 1]. One integer hash per lattice point, smoothstep between.
func _noise(channel: int, t: float) -> float:
	var i: int = int(floor(t))
	var f: float = t - float(i)
	var u: float = f * f * (3.0 - 2.0 * f)
	return lerpf(_lattice(channel, i), _lattice(channel, i + 1), u)


func _lattice(channel: int, i: int) -> float:
	var h: int = (noise_seed * 374761393 + channel * 668265263 + i * 2246822519) & 0x7FFFFFFF
	h = (h ^ (h >> 13)) * 1274126177
	h = h & 0x7FFFFFFF
	return float(h % 20001) / 10000.0 - 1.0
