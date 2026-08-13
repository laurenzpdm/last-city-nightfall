class_name LcnHudTrend
extends RefCounted
## Rate of change for anything the HUD shows as a number. [P17]
##
## "You have 1,400 iron" is a fact. "You have 1,400 iron and it is falling by
## 90 a minute, so you are out in fifteen minutes" is a decision. This class is
## the difference between the two, and it is why every stock on the resource rail
## carries an arrow instead of just a count.
##
## It samples on a fixed in-world cadence (never on frames, so a stutter cannot
## invent a trend), keeps a short ring of history per key, and fits a
## least-squares slope through it — an average of deltas swings wildly when a
## single delivery lands, a regression does not.

const DEFAULT_SAMPLE_SECONDS: float = 2.0
const DEFAULT_HISTORY: int = 24

var sample_seconds: float = DEFAULT_SAMPLE_SECONDS
var history_size: int = DEFAULT_HISTORY

var _values: Dictionary[StringName, PackedFloat32Array] = {}
var _last_sample_at: Dictionary[StringName, float] = {}
var _slope_per_second: Dictionary[StringName, float] = {}
var _latest: Dictionary[StringName, float] = {}


## Feeds one observation. `now_seconds` is in-world time (SimClock.seconds()), so
## fast-forward makes trends move faster, exactly as a player expects.
## Returns true when the sample was actually recorded.
func sample(key: StringName, value: float, now_seconds: float) -> bool:
	_latest[key] = value
	var last: float = _last_sample_at.get(key, -1000000.0)
	# The rewind check comes FIRST: a new world starts at t=0, which is also
	# "sooner than the cadence allows", and dropping that sample would leave the
	# old world's history in place to be read as a collapse.
	if now_seconds < last:
		reset_key(key)
		last = -1000000.0
	if now_seconds - last < sample_seconds:
		return false
	_last_sample_at[key] = now_seconds
	var ring: PackedFloat32Array = _values.get(key, PackedFloat32Array())
	ring.append(value)
	while ring.size() > history_size:
		ring.remove_at(0)
	_values[key] = ring
	_slope_per_second[key] = _fit_slope(ring)
	return true


## Change per in-world minute. 0 until there are at least three samples, so a
## fresh world never shows a phantom collapse.
func per_minute(key: StringName) -> float:
	return _slope_per_second.get(key, 0.0) * 60.0


func per_second(key: StringName) -> float:
	return _slope_per_second.get(key, 0.0)


func value(key: StringName) -> float:
	return _latest.get(key, 0.0)


## -1 falling, 0 steady, +1 rising. `deadzone` is per minute and should be set to
## the smallest change worth showing an arrow for.
func direction(key: StringName, deadzone: float = 0.5) -> int:
	var m: float = per_minute(key)
	if m > deadzone:
		return 1
	if m < -deadzone:
		return -1
	return 0


## In-world seconds until this stock hits zero at the current slope, or -1 when
## it is not falling. The number that turns a stock into a deadline.
func seconds_to_zero(key: StringName) -> float:
	var slope: float = per_second(key)
	if slope >= -0.0001:
		return -1.0
	var v: float = value(key)
	if v <= 0.0:
		return 0.0
	return v / -slope


## Normalised 0..1 history for a sparkline, oldest first. Empty when unknown.
func normalised(key: StringName) -> PackedFloat32Array:
	var ring: PackedFloat32Array = _values.get(key, PackedFloat32Array())
	var out := PackedFloat32Array()
	if ring.size() < 2:
		return out
	var lo: float = ring[0]
	var hi: float = ring[0]
	for v: float in ring:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var span: float = maxf(0.0001, hi - lo)
	for v2: float in ring:
		out.append((v2 - lo) / span)
	return out


func samples(key: StringName) -> int:
	return (_values.get(key, PackedFloat32Array()) as PackedFloat32Array).size()


func keys() -> Array[StringName]:
	var k: Array = _latest.keys()
	k.sort()
	var out: Array[StringName] = []
	for s: StringName in k:
		out.append(s)
	return out


func reset_key(key: StringName) -> void:
	_values.erase(key)
	_last_sample_at.erase(key)
	_slope_per_second.erase(key)


func reset() -> void:
	_values.clear()
	_last_sample_at.clear()
	_slope_per_second.clear()
	_latest.clear()


## Least squares over evenly spaced samples. x is in seconds, so the slope comes
## back in units per second regardless of the sample cadence.
func _fit_slope(ring: PackedFloat32Array) -> float:
	var n: int = ring.size()
	if n < 3:
		return 0.0
	var mean_x: float = float(n - 1) * 0.5
	var mean_y: float = 0.0
	for v: float in ring:
		mean_y += v
	mean_y /= float(n)
	var num: float = 0.0
	var den: float = 0.0
	for i: int in n:
		var dx: float = float(i) - mean_x
		num += dx * (ring[i] - mean_y)
		den += dx * dx
	if den <= 0.0:
		return 0.0
	return (num / den) / maxf(0.0001, sample_seconds)
