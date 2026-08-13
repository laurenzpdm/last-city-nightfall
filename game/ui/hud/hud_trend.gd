class_name LcnHudTrend
extends RefCounted
## Rate of change for anything the HUD shows as a number, and — separately — the
## much stricter question of whether that rate may be turned into a PREDICTION. [P17]
##
## "You have 1,400 iron" is a fact. "You have 1,400 iron and it is falling by
## 90 a minute, so you are out in fifteen minutes" is a decision. This class is
## the difference between the two, and it is why every stock on the resource rail
## carries an arrow instead of just a count.
##
## ── WHY THE PROJECTION IS ITS OWN THING ──────────────────────────────────────
##
## The first version of this file fitted one line through the history and divided
## the stock by its slope. In a real run that printed **"Timber runs out in 25
## seconds"** in red while the checkpoints show timber going 715 → 495 and then
## sitting at 495 for the next three minutes. The slope was not wrong; the
## PREDICTION was. A city builder spends materials in *steps* — a row of pipes is
## bought in one tick — and a step is not a rate. Fit a line through a step and
## you get a steep slope that describes something which already finished happening.
##
## An alert that cries wolf is worse than no alert: it teaches the player to stop
## reading the panel that will later tell them the truth. So a projection here has
## to clear four gates, all of them cheap:
##
##   1. **Enough history.** `PROJECTION_MIN_SAMPLES` observations spanning at
##      least `PROJECTION_MIN_SPAN` in-world seconds. Never from one sample, and
##      never from the six seconds after a world loads.
##   2. **Still falling.** The most recent half of the window must have a negative
##      slope of its own. A step drop that has since gone flat fails here, because
##      the recent half is flat.
##   3. **Falling repeatedly, not once.** At least `SUSTAIN_SHARE` of the sample
##      intervals in the window must be downward. A single 220-unit purchase
##      inside a 24-sample window scores 1/23 and is refused; a burner eating coal
##      every second scores ~1.0 and is believed. This is the gate that actually
##      separates a spend from a drain.
##   4. **Bigger than the noise.** The net fall across the recent half has to beat
##      max(1 unit, 1% of the stock), so integer jitter never becomes a deadline.
##
## What survives all four is reported as the SHALLOWER of the whole-window and
## recent-half slopes, so when the two disagree the player is given the longer,
## calmer number. Being late with a warning costs a player one trip to the map.
## Being wrong costs the HUD its credibility.
##
## Sampling is on a fixed in-world cadence (never on frames, so a stutter cannot
## invent a trend) into a short ring per key.

const DEFAULT_SAMPLE_SECONDS: float = 2.0
const DEFAULT_HISTORY: int = 30

## Gates 1-4 above. Tuned against artifacts/*/state.json for the first_night run:
## these values refuse every step-spend in it and still catch the coal burn.
const PROJECTION_MIN_SAMPLES: int = 12
const PROJECTION_MIN_SPAN: float = 20.0
const SUSTAIN_SHARE: float = 0.5
const NOISE_FLOOR_SHARE: float = 0.01

var sample_seconds: float = DEFAULT_SAMPLE_SECONDS
var history_size: int = DEFAULT_HISTORY

var _values: Dictionary[StringName, PackedFloat32Array] = {}
var _last_sample_at: Dictionary[StringName, float] = {}
var _slope_per_second: Dictionary[StringName, float] = {}
var _drain_per_second: Dictionary[StringName, float] = {}
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
	_drain_per_second[key] = _measure_drain(ring)
	return true


## Change per in-world minute, as measured over the whole window. This is an
## OBSERVATION and it is allowed to be spiky — it is what the arrow on a stock
## chip points at. It is NOT what a countdown may be built from; use
## `sustained_per_minute()` for that.
func per_minute(key: StringName) -> float:
	return _slope_per_second.get(key, 0.0) * 60.0


func per_second(key: StringName) -> float:
	return _slope_per_second.get(key, 0.0)


## The fall per in-world minute that this class is willing to stand behind, or
## 0.0 when nothing here is trustworthy. Always <= |per_minute|.
func sustained_per_minute(key: StringName) -> float:
	return _drain_per_second.get(key, 0.0) * 60.0


## True when a countdown may be shown for this key at all.
func is_draining(key: StringName) -> bool:
	return _drain_per_second.get(key, 0.0) > 0.0


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


## In-world seconds until this stock hits zero at the SUSTAINED rate, or -1 when
## no honest prediction is available. The number that turns a stock into a
## deadline — and the number that has to be refused when it would be a lie.
func seconds_to_zero(key: StringName) -> float:
	var drain: float = _drain_per_second.get(key, 0.0)
	if drain <= 0.0:
		return -1.0
	var v: float = value(key)
	if v <= 0.0:
		return 0.0
	return v / drain


## How much of the window backs the current projection, 0..1. The alert layer
## uses it to hold a warning back until it is properly established.
func confidence(key: StringName) -> float:
	var ring: PackedFloat32Array = _values.get(key, PackedFloat32Array())
	if ring.size() < 2 or _drain_per_second.get(key, 0.0) <= 0.0:
		return 0.0
	return clampf(float(ring.size()) / float(history_size), 0.0, 1.0)


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


## In-world seconds of history behind this key. Below PROJECTION_MIN_SPAN no
## prediction is possible at all, whatever the numbers say.
func span_seconds(key: StringName) -> float:
	return float(maxi(0, samples(key) - 1)) * sample_seconds


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
	_drain_per_second.erase(key)


func reset() -> void:
	_values.clear()
	_last_sample_at.clear()
	_slope_per_second.clear()
	_drain_per_second.clear()
	_latest.clear()


# ==================================================================  internals =

## The four gates, in the cheap-first order. Returns a POSITIVE drain per second,
## or 0.0 for "do not predict from this".
func _measure_drain(ring: PackedFloat32Array) -> float:
	var n: int = ring.size()
	if n < PROJECTION_MIN_SAMPLES:
		return 0.0
	if float(n - 1) * sample_seconds < PROJECTION_MIN_SPAN:
		return 0.0

	# Gate 3 first: it is one pass and it rejects the common case (a purchase).
	var falls: int = 0
	for i: int in range(1, n):
		if ring[i] < ring[i - 1]:
			falls += 1
	if float(falls) < float(n - 1) * SUSTAIN_SHARE:
		return 0.0

	var whole: float = _fit_slope(ring)
	if whole >= 0.0:
		return 0.0
	var half_from: int = n / 2
	var recent: PackedFloat32Array = ring.slice(half_from)
	var half: float = _fit_slope(recent)
	if half >= 0.0:
		return 0.0

	var net_recent: float = ring[half_from] - ring[n - 1]
	var floor_units: float = maxf(1.0, absf(ring[n - 1]) * NOISE_FLOOR_SHARE)
	if net_recent < floor_units:
		return 0.0

	# The shallower of the two, so a disagreement always resolves in the player's
	# favour: a longer countdown, never a shorter one.
	return -maxf(whole, half)


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
