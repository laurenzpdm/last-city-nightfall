class_name LcnImpulse
extends RefCounted
## A scalar that gets kicked and comes back down. [P15]
##
## Half of what "feel" means is a value that reacts and recovers: a hover lift,
## an alert glow, the pressure of a night falling, a bar that got hit. A Tween
## is the wrong tool for those, because they are interrupted constantly and a
## Tween restarted every frame just snaps. An impulse absorbs the interruption:
## kick it again while it is decaying and the two add, the loudest one wins the
## decay rate, and it is still a single float to read.
##
##     var lift := LcnImpulse.new()
##     lift.kick(1.0, LcnTiming.SNAP, LcnEase.Kind.BACK_OUT)   # on hover enter
##     lift.advance(dt)                                        # once per frame
##     sprite.position.y = -4.0 * lift.value()
##
## Deterministic: same kicks at the same dt produce the same values, so a visual
## regression run diffs cleanly and the decay is testable.

## 0..1 charge left in the impulse.
var charge: float = 0.0
## Seconds the current charge takes to bleed out.
var span: float = LcnTiming.QUICK
## Curve the value is read through.
var kind: LcnEase.Kind = LcnEase.Kind.QUART_OUT
## Set true for an impulse that should HOLD at full until released — a hover
## that lasts as long as the cursor does, rather than a hit that decays.
var sustained: bool = false

var _elapsed: float = 0.0
var _peak: float = 0.0


func _init(default_kind: LcnEase.Kind = LcnEase.Kind.QUART_OUT) -> void:
	kind = default_kind


## Adds an impact. `strength` 0..1, `seconds` how long it takes to bleed out.
## A stronger kick raises the peak; a longer one wins the decay, so a small
## repeating tick can never cut a large event short.
func kick(strength: float, seconds: float = LcnTiming.QUICK,
		curve: LcnEase.Kind = LcnEase.Kind.QUART_OUT) -> void:
	var s: float = clampf(strength, 0.0, 1.0)
	if s <= 0.0:
		return
	if charge > 0.001:
		span = maxf(span * remaining01(), seconds)
		_peak = maxf(_peak, s)
		charge = clampf(charge + s * 0.6, 0.0, 1.0)
	else:
		span = maxf(seconds, 0.01)
		_peak = s
		charge = s
	kind = curve
	_elapsed = 0.0


## Holds the impulse at `level` without decaying. For hover and selection, where
## the state ends when the player says so, not when a timer says so.
func hold(level: float = 1.0, seconds: float = LcnTiming.SNAP,
		curve: LcnEase.Kind = LcnEase.Kind.BACK_OUT) -> void:
	if sustained and charge > 0.0:
		_peak = maxf(_peak, clampf(level, 0.0, 1.0))
		return
	sustained = true
	kick(level, seconds, curve)


## Ends a held impulse; it now decays like any other.
func release(seconds: float = LcnTiming.SNAP) -> void:
	if not sustained:
		return
	sustained = false
	span = maxf(seconds, 0.01)
	_elapsed = 0.0


func advance(dt: float) -> void:
	if charge <= 0.0:
		return
	_elapsed += maxf(dt, 0.0)
	if sustained:
		# A held impulse still runs its attack, it just does not fall off the end.
		_elapsed = minf(_elapsed, span)
		return
	if _elapsed >= span:
		charge = 0.0
		_elapsed = 0.0
		_peak = 0.0


## The value to read. 0 when nothing is happening.
func value() -> float:
	if charge <= 0.0:
		return 0.0
	var k: float = clampf(_elapsed / maxf(span, 0.0001), 0.0, 1.0)
	if sustained:
		# Attack only: rise to the peak on the chosen curve and stay there.
		return _peak * LcnEase.apply(kind, k)
	return _peak * (1.0 - LcnEase.apply(kind, k))


## Fraction of the impulse still to run, 1 at the kick, 0 when spent.
func remaining01() -> float:
	if charge <= 0.0:
		return 0.0
	return 1.0 - clampf(_elapsed / maxf(span, 0.0001), 0.0, 1.0)


func active() -> bool:
	return charge > 0.0


func reset() -> void:
	charge = 0.0
	_elapsed = 0.0
	_peak = 0.0
	sustained = false
