class_name LcnTweenKit
extends RefCounted
## Tween helpers with the house curves already in them. [P15]
##
## This exists so that no other part ever has to write
## `create_tween().tween_property(...).set_trans(Tween.TRANS_CUBIC)` again and
## pick a duration out of the air. Every helper takes a duration from the timing
## vocabulary (see timing.gd), applies the curve that belongs with it, and
## honours `accessibility.reduce_motion` by cutting straight to the end value.
##
##     LcnTweenKit.pop(icon)                              # it was clicked
##     LcnTweenKit.fade_in(tooltip, LcnTiming.QUICK)      # it appeared
##     LcnTweenKit.slide_in(panel, Vector2(0, 24))        # it opened with intent
##     LcnTweenKit.count(setter, 0.0, 412.0, self)        # the number travelled
##
## Godot's own TRANS_* set has no SETTLE, no ANTICIPATE and no IMPACT, so every
## helper drives the value through `tween_method` and LcnEase rather than
## `set_trans`. The cost is one script call per frame per tween, which is
## nothing against the ~40 tweens a busy interface runs.
##
## Every helper is null-safe and tree-safe: a node that leaves the tree kills its
## own tween, and passing null is a no-op rather than a crash.

## Interpolates any property of any Node through a house curve.
## Returns the Tween so the caller can chain `.finished`, or null when the
## motion was collapsed (reduce_motion) or the target was invalid.
static func to(node: Node, property: NodePath, from: Variant, to_value: Variant,
		seconds: float = LcnTiming.QUICK,
		kind: LcnEase.Kind = LcnEase.Kind.CUBIC_OUT) -> Tween:
	if node == null or not node.is_inside_tree():
		return null
	var dur: float = LcnTiming.meaningful(seconds)
	if dur <= 0.0:
		node.set_indexed(property, to_value)
		return null
	var step := func(k: float) -> void:
		node.set_indexed(property, lerp(from, to_value, LcnEase.apply(kind, k)))
	var t: Tween = node.create_tween()
	t.tween_method(step, 0.0, 1.0, dur)
	return t


## The universal "it was pressed / it was chosen / it landed" gesture: a fast
## overshoot in scale and a settle back. `peak` 1.08 is the house default —
## enough to see, not enough to notice as an animation.
##
## One curve, two phases: out to the peak on QUART_OUT so the departure carries
## the speed, back on SETTLE so the return carries the weight.
static func pop(item: CanvasItem, peak: float = 1.08,
		seconds: float = LcnTiming.SNAP) -> Tween:
	if item == null or not item.is_inside_tree():
		return null
	var dur: float = LcnTiming.decorative(seconds)
	if dur <= 0.0:
		_set_scale(item, Vector2.ONE)
		return null
	var step := func(k: float) -> void:
		var s: float = 1.0
		if k < 0.38:
			s = lerpf(1.0, peak, LcnEase.apply(LcnEase.Kind.QUART_OUT, k / 0.38))
		else:
			s = lerpf(peak, 1.0, LcnEase.apply(LcnEase.Kind.SETTLE, (k - 0.38) / 0.62))
		_set_scale(item, Vector2(s, s))
	var t: Tween = item.create_tween()
	t.tween_method(step, 0.0, 1.0, dur)
	return t


## Fades a CanvasItem in. Never linear: a linear alpha ramp reads as fog, an
## eased one reads as an arrival.
static func fade_in(item: CanvasItem, seconds: float = LcnTiming.QUICK,
		kind: LcnEase.Kind = LcnEase.Kind.CUBIC_OUT) -> Tween:
	return _fade(item, 0.0, 1.0, seconds, kind)


## Fades a CanvasItem out. Faster than in, on purpose: things should leave
## quicker than they arrive or the interface feels sticky.
static func fade_out(item: CanvasItem, seconds: float = LcnTiming.SNAP,
		kind: LcnEase.Kind = LcnEase.Kind.QUAD_IN) -> Tween:
	return _fade(item, 1.0, 0.0, seconds, kind)


## A panel that opens with intent: it travels from `offset` to rest while it
## fades in, both on the same curve, so the two read as one movement.
static func slide_in(item: CanvasItem, offset: Vector2 = Vector2(0.0, 18.0),
		seconds: float = LcnTiming.SETTLE,
		kind: LcnEase.Kind = LcnEase.Kind.SETTLE) -> Tween:
	if item == null or not item.is_inside_tree():
		return null
	var rest: Vector2 = _position_of(item)
	var dur: float = LcnTiming.meaningful(seconds)
	if dur <= 0.0:
		_set_position(item, rest)
		item.modulate.a = 1.0
		return null
	var start: Vector2 = rest + offset
	var step := func(k: float) -> void:
		var e: float = LcnEase.apply(kind, k)
		_set_position(item, start.lerp(rest, e))
		# Alpha finishes at 70% of the travel: a panel still fading when it stops
		# moving reads as unfinished.
		item.modulate.a = clampf(e / 0.7, 0.0, 1.0)
	var t: Tween = item.create_tween()
	t.tween_method(step, 0.0, 1.0, dur)
	return t


## A number that travels instead of snapping. `setter` receives the value every
## frame; this never touches a label itself, so the caller keeps its formatting.
static func count(setter: Callable, from: float, to_value: float, host: Node,
		seconds: float = LcnTiming.SWELL,
		kind: LcnEase.Kind = LcnEase.Kind.QUART_OUT) -> Tween:
	if host == null or not host.is_inside_tree() or not setter.is_valid():
		return null
	var dur: float = LcnTiming.meaningful(seconds)
	if dur <= 0.0 or is_equal_approx(from, to_value):
		setter.call(to_value)
		return null
	var step := func(k: float) -> void:
		setter.call(lerpf(from, to_value, LcnEase.apply(kind, k)))
	var t: Tween = host.create_tween()
	t.tween_method(step, 0.0, 1.0, dur)
	return t


## A refusal: three fast lateral shakes that decay. For a rejected placement, a
## locked tech node, a law you cannot afford. Reads as "no" without a modal.
static func deny(item: CanvasItem, amplitude: float = 6.0,
		seconds: float = LcnTiming.QUICK) -> Tween:
	if item == null or not item.is_inside_tree():
		return null
	var rest: Vector2 = _position_of(item)
	var dur: float = LcnTiming.decorative(seconds)
	if dur <= 0.0:
		return null
	var step := func(k: float) -> void:
		var decay: float = 1.0 - LcnEase.apply(LcnEase.Kind.QUAD_OUT, k)
		_set_position(item, rest + Vector2(sin(k * TAU * 3.0) * amplitude * decay, 0.0))
	var restore := func() -> void:
		_set_position(item, rest)
	var t: Tween = item.create_tween()
	t.tween_method(step, 0.0, 1.0, dur)
	t.tween_callback(restore)
	return t


## A pulse of colour that returns to where it started. For "this value just
## changed" and "this alert just arrived".
static func flash_modulate(item: CanvasItem, tint: Color,
		seconds: float = LcnTiming.QUICK) -> Tween:
	if item == null or not item.is_inside_tree():
		return null
	var rest: Color = item.modulate
	var dur: float = LcnTiming.decorative(seconds)
	if dur <= 0.0:
		return null
	var step := func(k: float) -> void:
		item.modulate = rest.lerp(tint, LcnEase.apply(LcnEase.Kind.PULSE, k))
	var restore := func() -> void:
		item.modulate = rest
	var t: Tween = item.create_tween()
	t.tween_method(step, 0.0, 1.0, dur)
	t.tween_callback(restore)
	return t


# --- internals ----------------------------------------------------------------

static func _fade(item: CanvasItem, from_a: float, to_a: float, seconds: float,
		kind: LcnEase.Kind) -> Tween:
	if item == null or not item.is_inside_tree():
		return null
	var dur: float = LcnTiming.meaningful(seconds)
	if dur <= 0.0:
		item.modulate.a = to_a
		return null
	item.modulate.a = from_a
	var step := func(k: float) -> void:
		item.modulate.a = lerpf(from_a, to_a, LcnEase.apply(kind, k))
	var t: Tween = item.create_tween()
	t.tween_method(step, 0.0, 1.0, dur)
	return t


## Control and Node2D disagree about what "scale" and "position" mean, and both
## are used across this build, so the helpers speak both.
static func _set_scale(item: CanvasItem, s: Vector2) -> void:
	var c := item as Control
	if c != null:
		c.pivot_offset = c.size * 0.5
		c.scale = s
		return
	var n := item as Node2D
	if n != null:
		n.scale = s


static func _position_of(item: CanvasItem) -> Vector2:
	var c := item as Control
	if c != null:
		return c.position
	var n := item as Node2D
	return n.position if n != null else Vector2.ZERO


static func _set_position(item: CanvasItem, p: Vector2) -> void:
	var c := item as Control
	if c != null:
		c.position = p
		return
	var n := item as Node2D
	if n != null:
		n.position = p
