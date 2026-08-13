class_name LcnStatTrack
extends RefCounted
## One resolution of the history. [P20]
##
## A track is a set of [LcnStatSeries] that all advance together: every series
## holds a sample for exactly the same ticks, so index `i` means the same moment
## in every one of them and a chart can read three curves without interpolating.
##
## Three of these make the whole history:
##
## [codeblock]
##   FINE   every  10 ticks (0.5 s)   240 samples   the last two minutes
##   MID    every 100 ticks (5 s)     288 samples   the last twenty-four minutes
##   RUN    every 400 ticks (20 s)    300 samples   grows by halving, forever
## [/codeblock]
##
## The RUN track is the interesting one. When it fills it throws away every
## second sample and doubles its stride, so a ten-hour run costs exactly the
## same memory as a ten-minute one and the earliest hour is still on the chart,
## just coarser. That is the trade Factorio's "all" tab makes and it is the only
## one that keeps a whole campaign readable.
##
## Time is not stored per sample. `tick_at(i) == oldest_tick + i * stride` is
## exact because samples are only ever taken on a multiple of the stride, and it
## survives halving because the stride doubles in the same call.

## Ticks between samples. Doubles each time a growing track halves.
var stride: int = 10
var capacity: int = 240
## Absolute simulation tick of sample 0. Advances as the ring evicts.
var oldest_tick: int = 0
## Absolute simulation tick of the newest sample.
var latest_tick: int = 0
## When true the track doubles its stride instead of forgetting the beginning.
var grows: bool = false
## Set once the track has halved at least once, so a chart can say "coarse".
var halvings: int = 0

var _series: Dictionary[StringName, LcnStatSeries] = {}
var _names: Array[StringName] = []
var _count: int = 0
var _next_tick: int = 0


func _init(sample_stride: int = 10, cap: int = 240, growing: bool = false) -> void:
	stride = maxi(1, sample_stride)
	capacity = clampi(cap, 4, LcnStatSeries.MAX_CAPACITY)
	grows = growing


## Declares a series before any sampling happens. `monotonic` marks a cumulative
## counter. Declaring twice is a no-op, so a late-arriving item is cheap.
func declare(key: StringName, monotonic: bool = false) -> LcnStatSeries:
	var existing: LcnStatSeries = _series.get(key)
	if existing != null:
		return existing
	var s := LcnStatSeries.new(capacity, monotonic)
	# A series declared after sampling started is back-filled with its first
	# value so index i still names the same tick in every series on the track.
	for _i: int in _count:
		s.push(0.0)
	_series[key] = s
	_names.append(key)
	_names.sort()
	return s


func has(key: StringName) -> bool:
	return _series.has(key)


func series(key: StringName) -> LcnStatSeries:
	return _series.get(key)


## Every declared key, sorted. Sorted because a report walks them and two runs
## of the same build must produce the same report.
func keys() -> Array[StringName]:
	return _names.duplicate()


func sample_count() -> int:
	return _count


func is_due(tick: int) -> bool:
	return tick >= _next_tick


## Writes one sample across every declared series. Keys missing from `values`
## hold their previous value, so a reading that is only refreshed every fifth
## sample still draws as a line instead of a comb.
func push_sample(tick: int, values: Dictionary) -> void:
	if _count >= capacity:
		if grows:
			_halve()
		else:
			oldest_tick += stride
	for key: StringName in _names:
		var s: LcnStatSeries = _series[key]
		var v: float = float(values[key]) if values.has(key) else s.last()
		s.push(v)
	if _count == 0:
		oldest_tick = tick
	_count = mini(_count + 1, capacity)
	latest_tick = tick
	_next_tick = tick + stride


## Absolute tick of sample `i`. Exact: samples land on stride multiples.
func tick_at(i: int) -> int:
	return oldest_tick + i * stride


## Seconds of world time this track currently covers.
func window_seconds() -> float:
	if _count <= 1:
		return 0.0
	return float((_count - 1) * stride) * 0.05


## Seconds between two samples, for turning a counter delta into a rate.
func sample_seconds() -> float:
	return float(stride) * 0.05


## Index of the newest sample at or before `tick`, or -1.
func index_at_tick(tick: int) -> int:
	if _count == 0:
		return -1
	var i: int = int(floor(float(tick - oldest_tick) / float(stride)))
	return clampi(i, 0, _count - 1)


## Units per minute of a counter series across its newest `window` samples.
## Returns 0 for a level series, which has no meaningful rate.
func rate_per_minute(key: StringName, window: int = 6) -> float:
	var s: LcnStatSeries = _series.get(key)
	if s == null or s.size() < 2:
		return 0.0
	var n: int = clampi(window, 1, s.size() - 1)
	var delta: float = s.last() - s.back(n)
	var seconds: float = float(n) * sample_seconds()
	if seconds <= 0.0:
		return 0.0
	return delta * 60.0 / seconds


func clear() -> void:
	for key: StringName in _names:
		_series[key].clear()
	_count = 0
	_next_tick = 0
	oldest_tick = 0
	latest_tick = 0
	halvings = 0


## Bytes of sample storage this track holds. The memory claim, measured.
func memory_bytes() -> int:
	return _names.size() * capacity * 4


func _halve() -> void:
	for key: StringName in _names:
		_series[key].halve()
	_count = int((_count + 1) / 2)
	stride *= 2
	halvings += 1
