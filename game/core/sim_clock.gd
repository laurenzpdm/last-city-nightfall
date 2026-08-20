extends Node
## Fixed-step tick driver. The simulation advances in whole ticks at TICK_HZ,
## regardless of frame rate. Rendering interpolates with `alpha`; it never
## drives state. This is what makes a run replayable.

const TICK_HZ: int = 20
const DT: float = 1.0 / float(TICK_HZ)
## Guard against spiral-of-death after a stall: never catch up more than this.
const MAX_CATCHUP_TICKS: int = 8

var tick: int = 0
var running: bool = false
var speed: float = 1.0          ## 0 = paused, 1 = normal, 2/3 = fast forward
var alpha: float = 0.0          ## 0..1 interpolation factor for the view layer

var _accum: float = 0.0
var _manual: bool = false       ## harness drives ticks itself


func _ready() -> void:
	process_priority = -100


func reset() -> void:
	tick = 0
	_accum = 0.0
	alpha = 0.0


func start() -> void:
	running = true


func pause() -> void:
	running = false


## Harness mode: the clock stops advancing on its own; call advance() by hand.
func set_manual(on: bool) -> void:
	_manual = on


## Run exactly n ticks immediately. Used by the harness and by tests.
func advance(n: int = 1) -> void:
	for _i: int in n:
		tick += 1
		Sim._advance(tick)
		Bus.tick_advanced.emit(tick)


func _process(delta: float) -> void:
	if _manual or not running or speed <= 0.0:
		return
	_accum += delta * speed
	var steps: int = 0
	while _accum >= DT and steps < MAX_CATCHUP_TICKS:
		_accum -= DT
		steps += 1
		tick += 1
		Sim._advance(tick)
		Bus.tick_advanced.emit(tick)
	if steps >= MAX_CATCHUP_TICKS:
		_accum = 0.0
	alpha = clampf(_accum / DT, 0.0, 1.0)


## True when ticks are actually being delivered. The interface asks THIS, never
## `running`: in manual mode the harness and the test fixtures drive advance()
## by hand, `running` stays false, and a clock widget reading `running` prints
## PAUSED over a countdown that is visibly counting down. Every screenshot this
## build has ever shipped carried that contradiction in the top centre.
func is_advancing() -> bool:
	return _manual or (running and speed > 0.0)


## Seconds of in-world time elapsed. Use this, never Time.get_ticks_msec().
func seconds() -> float:
	return float(tick) * DT
