class_name LcnSoundBank
extends RefCounted
## [P23] The bake. Owns every synthesised stream and the budget that builds them.
##
## The catalogue costs a bit under a second of arithmetic. Spending it in one
## call would be a visible freeze, so the bank keeps a queue of [LcnSynthJob]s
## and `pump(usec)` spends a fixed slice of each frame on it. The five sounds the
## first second of the game actually needs are baked up front (`essential()`,
## about 120 ms, hidden behind world generation); everything else lands over the
## following couple of seconds and any cue asked for before its stream exists is
## counted, not played.
##
## Nothing here is random in the simulation's sense: every job seeds its own
## RandomNumberGenerator from a constant in the recipe. `Rng.stream()` is never
## touched, so nothing the player hears can move a replay by one bit.

## Microseconds of each frame the bank may spend building. The catalogue is
## about two seconds of arithmetic in total, so the budget is generous while the
## game is opening — nobody is playing yet and the frame is already busy with
## world generation — and drops to a background trickle afterwards.
const EAGER_BUDGET_USEC: int = 4000
const DEFAULT_BUDGET_USEC: int = 2000
## Frames the eager budget lasts. Ten seconds at 60 fps, which finishes the whole
## bake with room to spare — and anything the game actually asks for before then
## jumps the queue through `promote()`, so the wait is never audible.
const EAGER_FRAMES: int = 600

## Work units handed to a job between two checks of the clock.
##
## This replaced two failed attempts at predicting how long a slice would take,
## and the reason both failed is worth writing down: the phases of a job differ
## in cost by more than an order of magnitude. Rendering five detuned partials
## runs at about 0.7 samples per microsecond; scrubbing and encoding the finished
## buffer runs at about sixteen. A single "samples per microsecond" figure
## learned from the fast phases sized a slice of the slow one at 25 000 samples,
## and one uninterruptible slice became a 64 ms frame — a worse dropped frame
## than the one the chunking was added to prevent.
##
## So the bank stops predicting and starts measuring: hand over a small fixed
## quantum, look at the clock, decide again. The worst overshoot is one quantum
## of the slowest phase, about 1.5 ms, and it does not depend on knowing anything
## about the machine.
const SLICE_QUANTUM: int = 1024

var budget_usec: int = DEFAULT_BUDGET_USEC
var eager_budget_usec: int = EAGER_BUDGET_USEC

var _pumps: int = 0
var _peak_pump_usec: int = 0
## Which recipe was on the bench during the slowest pump. Attribution beats
## argument: without this the 64 ms frame above took three guesses to find.
var _peak_pump_key: StringName = &""

var _streams: Dictionary[StringName, AudioStreamWAV] = {}
var _queue: Array[StringName] = []
var _queued: Dictionary[StringName, bool] = {}
var _active: LcnSynthJob = null

var _built: int = 0
var _bytes: int = 0
var _build_usec: int = 0
var _misses: Dictionary[StringName, int] = {}
var _non_finite: int = 0


## Bakes the sounds the opening seconds need and queues the rest.
## Returns microseconds spent doing it.
func warm_up() -> int:
	var t0: int = Time.get_ticks_usec()
	for k: StringName in LcnSynthRecipes.essential():
		build_now(k)
	queue_all()
	return Time.get_ticks_usec() - t0


## Prefixes in the order the game needs them. The room first, then the things a
## player can trigger by hand, then the score, then the world. Anything not
## matching a prefix comes last.
const BUILD_ORDER: Array[String] = ["hearth", "wind", "city", "click", "ui_",
	"panel", "confirm", "deny", "sting", "mus_", "mach_", "shot", "impact",
	"thud", "rubble", "chord"]


## Every recipe not already built joins the queue, most useful first.
func queue_all() -> void:
	var keys: Array[StringName] = []
	for k: StringName in LcnSynthRecipes.all():
		keys.append(k)
	# Sorted, then grouped by usefulness. Deterministic on purpose: a bank that
	# finishes in a different order every run produces a different first thirty
	# seconds, which makes a bug report unreproducible.
	keys.sort()
	for prefix: String in BUILD_ORDER:
		for k: StringName in keys:
			if String(k).begins_with(prefix):
				queue(k)
	for k: StringName in keys:
		queue(k)


func queue(key: StringName) -> void:
	if _streams.has(key) or _queued.has(key):
		return
	if not LcnSynthRecipes.has(key):
		return
	_queue.append(key)
	_queued[key] = true


## Spends up to `usec` microseconds finishing queued jobs. Returns how many
## streams became available during this call.
func pump(usec: int = -1) -> int:
	_pumps += 1
	var allowance: int = usec
	if usec < 0:
		allowance = eager_budget_usec if _pumps <= EAGER_FRAMES else budget_usec
	if allowance <= 0:
		return 0
	var finished_now: int = 0
	var last_key: StringName = _active.key if _active != null else &""
	var t0: int = Time.get_ticks_usec()
	while true:
		var elapsed: int = Time.get_ticks_usec() - t0
		var remaining: int = allowance - elapsed
		if remaining <= 0:
			break
		if _active == null:
			if _queue.is_empty():
				break
			var key: StringName = _queue.pop_front()
			_queued.erase(key)
			if _streams.has(key):
				continue
			_active = LcnSynthJob.new(key, LcnSynthRecipes.spec(key))
			last_key = key
		if _active.advance(SLICE_QUANTUM):
			_adopt(_active)
			_active = null
			finished_now += 1
	var spent: int = Time.get_ticks_usec() - t0
	_build_usec += spent
	if spent > _peak_pump_usec:
		_peak_pump_usec = spent
		_peak_pump_key = last_key
	return finished_now


## Builds one stream immediately, ignoring the budget. Used for the essentials
## and by the offline baker. Returns the stream, or null for an unknown key.
func build_now(key: StringName) -> AudioStreamWAV:
	var existing: AudioStreamWAV = _streams.get(key)
	if existing != null:
		return existing
	if not LcnSynthRecipes.has(key):
		return null
	var job := LcnSynthJob.new(key, LcnSynthRecipes.spec(key))
	while not job.advance(1 << 22):
		pass
	_adopt(job)
	_queued.erase(key)
	var at: int = _queue.find(key)
	if at >= 0:
		_queue.remove_at(at)
	return job.stream


## The stream for a cue, or null when it has not been baked yet. A null is a
## silence the report counts — see `report().misses` — never an error and never
## a stall on the audio thread.
func get_stream(key: StringName) -> AudioStreamWAV:
	var s: AudioStreamWAV = _streams.get(key)
	if s == null:
		_misses[key] = int(_misses.get(key, 0)) + 1
		# Pull it to the front so a cue that was actually asked for arrives on
		# the next frame rather than in alphabetical order.
		promote(key)
	return s


## Moves a key to the head of the build queue.
func promote(key: StringName) -> void:
	if _streams.has(key) or not LcnSynthRecipes.has(key):
		return
	var at: int = _queue.find(key)
	if at > 0:
		_queue.remove_at(at)
		_queue.push_front(key)
	elif at < 0 and not _queued.has(key):
		_queue.push_front(key)
		_queued[key] = true


func has(key: StringName) -> bool:
	return _streams.has(key)


func ready_count() -> int:
	return _streams.size()


func pending_count() -> int:
	return _queue.size() + (1 if _active != null else 0)


func finished() -> bool:
	return _queue.is_empty() and _active == null


func _adopt(job: LcnSynthJob) -> void:
	if job.stream == null:
		return
	_streams[job.key] = job.stream
	_built += 1
	_bytes += job.byte_size()
	_non_finite += job.non_finite


func report() -> Dictionary:
	var miss_total: int = 0
	for k: StringName in _misses:
		miss_total += _misses[k]
	return {
		"built": _built,
		"pending": pending_count(),
		"bytes": _bytes,
		"kib": int(round(float(_bytes) / 1024.0)),
		"build_ms": snappedf(float(_build_usec) / 1000.0, 0.1),
		"peak_pump_usec": _peak_pump_usec,
		"peak_pump_key": String(_peak_pump_key),
		"misses": miss_total,
		"non_finite_samples": _non_finite,
	}
