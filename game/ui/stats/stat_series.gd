class_name LcnStatSeries
extends RefCounted
## One bounded time series. [P20]
##
## A fixed-capacity ring of 32-bit floats. Writing is O(1) and allocation-free
## after construction, which is the whole reason the recorder can afford to run
## while the simulation is running.
##
## Index 0 is always the OLDEST retained sample and `size() - 1` the newest, so
## a caller never has to know where the write head happens to be. The engine
## behind that is a single modulo; nothing here copies the buffer except
## [method halve], which the run-length track calls when it has outlived its
## own resolution.
##
## Floats, not doubles: a heat reading is a number a human reads off a chart,
## and 24 bits of mantissa is four more than the pixels can show. Cumulative
## counters are the one place that matters — see [method push], which refuses to
## let a counter series go backwards after precision loss so a differenced rate
## can never come out negative.

## Hard ceiling on a single series, so a misconfigured track cannot eat memory.
const MAX_CAPACITY: int = 8192

var capacity: int = 0

var _data: PackedFloat32Array = PackedFloat32Array()
var _head: int = 0        ## next write slot
var _count: int = 0
var _monotonic: bool = false
var _min: float = 0.0
var _max: float = 0.0
var _bounds_dirty: bool = true


## `monotonic` marks a cumulative counter: pushing a value below the last one
## clamps instead, so a differenced rate is never negative.
func _init(cap: int = 240, monotonic: bool = false) -> void:
	capacity = clampi(cap, 2, MAX_CAPACITY)
	_monotonic = monotonic
	_data.resize(capacity)
	_data.fill(0.0)


func is_monotonic() -> bool:
	return _monotonic


## Appends one sample, evicting the oldest once the ring is full.
func push(value: float) -> void:
	var v: float = value
	if is_nan(v) or is_inf(v):
		v = 0.0
	if _monotonic and _count > 0:
		v = maxf(v, last())
	_data[_head] = v
	_head = (_head + 1) % capacity
	if _count < capacity:
		_count += 1
	_bounds_dirty = true


func size() -> int:
	return _count


func is_full() -> bool:
	return _count >= capacity


func is_empty() -> bool:
	return _count == 0


## Oldest-first indexing. Out of range returns 0.0 rather than throwing, because
## a chart that is one frame ahead of the recorder must not take the game down.
func at(i: int) -> float:
	if i < 0 or i >= _count:
		return 0.0
	var start: int = (_head - _count + capacity) % capacity
	return _data[(start + i) % capacity]


func last() -> float:
	return 0.0 if _count == 0 else at(_count - 1)


func first() -> float:
	return at(0)


## Newest minus oldest. For a counter series this is "how much happened across
## everything still retained".
func span() -> float:
	return 0.0 if _count == 0 else last() - first()


## Value `n` samples back from the newest, clamped to the oldest retained.
func back(n: int) -> float:
	return at(clampi(_count - 1 - n, 0, maxi(0, _count - 1)))


func min_value() -> float:
	_refresh_bounds()
	return _min


func max_value() -> float:
	_refresh_bounds()
	return _max


func mean() -> float:
	if _count == 0:
		return 0.0
	var total: float = 0.0
	for i: int in _count:
		total += at(i)
	return total / float(_count)


## Largest value across the newest `n` samples. Used by the graphs to scale a
## window without walking the whole ring.
func max_of_last(n: int) -> float:
	if _count == 0:
		return 0.0
	var from: int = maxi(0, _count - maxi(1, n))
	var best: float = at(from)
	for i: int in range(from + 1, _count):
		best = maxf(best, at(i))
	return best


func min_of_last(n: int) -> float:
	if _count == 0:
		return 0.0
	var from: int = maxi(0, _count - maxi(1, n))
	var best: float = at(from)
	for i: int in range(from + 1, _count):
		best = minf(best, at(i))
	return best


## Oldest-first copy. For tests and for the report writer, never per frame.
func to_array() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_count)
	for i: int in _count:
		out[i] = at(i)
	return out


## Throws away every second sample, keeping index 0. This is what lets the
## whole-run track cover an unbounded run in bounded memory: the caller doubles
## its stride at the same moment, so `oldest_tick + i * stride` stays true.
func halve() -> void:
	var kept: int = int((_count + 1) / 2)
	var fresh := PackedFloat32Array()
	fresh.resize(capacity)
	fresh.fill(0.0)
	for i: int in kept:
		fresh[i] = at(i * 2)
	_data = fresh
	_head = kept % capacity
	_count = kept
	_bounds_dirty = true


func clear() -> void:
	_data.fill(0.0)
	_head = 0
	_count = 0
	_bounds_dirty = true


func _refresh_bounds() -> void:
	if not _bounds_dirty:
		return
	_bounds_dirty = false
	if _count == 0:
		_min = 0.0
		_max = 0.0
		return
	_min = at(0)
	_max = _min
	for i: int in range(1, _count):
		var v: float = at(i)
		_min = minf(_min, v)
		_max = maxf(_max, v)
