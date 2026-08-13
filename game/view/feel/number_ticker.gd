class_name LcnNumberTicker
extends RefCounted
## A number that travels to its new value instead of snapping. [P15]
##
## Numbers that snap are unreadable in a game where eleven of them change every
## tick: the eye cannot tell 412 changing to 380 from 412 changing to 41. A
## number that COUNTS reports its own direction and magnitude for free — you see
## it fall before you read what it fell to.
##
##     var stock := LcnNumberTicker.new(0.0)
##     stock.target = 412.0            # whenever the sim says so
##     stock.advance(dt)               # once per frame
##     label.text = "%d" % stock.rounded()
##     if stock.falling(): label.modulate = warn
##
## The travel is time-bounded, not rate-based: whatever the jump, it lands
## within `span` seconds, so a 4 -> 40000 change does not take a minute and a
## 4 -> 5 change does not take a frame. Big jumps skip straight to the end,
## because a resource that was reloaded or a save that was restored is not a
## change the player made and should not be animated.

## Where the number is going. Set it as often as you like.
var target: float = 0.0
## How long a change takes to land.
var span: float = LcnTiming.SWELL
## The curve the travel rides.
var kind: LcnEase.Kind = LcnEase.Kind.QUART_OUT
## Changes at or below this are applied instantly — noise should not animate.
var deadzone: float = 0.0001
## A change larger than this many times the current value is treated as a reset
## (load, world change) and applied without travel. 0 disables the guard.
var jump_ratio: float = 24.0

var _shown: float = 0.0
var _from: float = 0.0
var _elapsed: float = 0.0
var _travelling: bool = false
var _last_delta: float = 0.0


func _init(initial: float = 0.0, seconds: float = LcnTiming.SWELL) -> void:
	_shown = initial
	_from = initial
	target = initial
	span = seconds


## Advances the travel. Feed it interface time (unscaled frame delta), because a
## counting number is interface motion and must keep working while paused.
func advance(dt: float) -> void:
	if not _travelling:
		if absf(target - _shown) <= deadzone:
			return
		_begin()
		if not _travelling:
			return
	_elapsed += maxf(dt, 0.0)
	var k: float = clampf(_elapsed / maxf(span, 0.0001), 0.0, 1.0)
	_shown = lerpf(_from, target, LcnEase.apply(kind, k))
	if k >= 1.0:
		_shown = target
		_travelling = false


func _begin() -> void:
	var delta: float = target - _shown
	_last_delta = delta
	if LcnTiming.reduce_motion():
		_shown = target
		return
	if jump_ratio > 0.0 and absf(_shown) > 1.0 and absf(delta) > absf(_shown) * jump_ratio:
		# Not a change: a different number. Snap, and do not pretend otherwise.
		_shown = target
		return
	_from = _shown
	_elapsed = 0.0
	_travelling = true


## The value to draw.
func value() -> float:
	return _shown


func rounded() -> int:
	return int(round(_shown))


## Sets both the shown value and the target with no travel. For world creation,
## a save load, or any moment where the previous number was not this number.
func snap_to(v: float) -> void:
	_shown = v
	_from = v
	target = v
	_elapsed = 0.0
	_travelling = false
	_last_delta = 0.0


func travelling() -> bool:
	return _travelling


## Direction of the change currently being shown. Lets a widget tint itself red
## while a stock falls and green while it climbs without keeping its own state.
func rising() -> bool:
	return _travelling and _last_delta > 0.0


func falling() -> bool:
	return _travelling and _last_delta < 0.0


## How far through the current travel, 0..1. Drive a glow with it.
func progress01() -> float:
	if not _travelling:
		return 1.0
	return clampf(_elapsed / maxf(span, 0.0001), 0.0, 1.0)
