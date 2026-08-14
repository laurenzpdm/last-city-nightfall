class_name CameraTests
extends RefCounted
## [P16] Camera & Input — headless tests for everything that decides camera feel.
##
## Every assertion here runs against the real classes at a fixed dt, with no nodes and
## no autoloads, so a claim like "zoom anchors on the cursor" is a measured fact rather
## than a description. Node-level behaviour (event routing, Camera2D transform, Settings)
## is covered by CameraNodeTests.

const DT: float = 1.0 / 60.0
const VIEWPORT: Vector2 = Vector2(1920.0, 1080.0)

var failures: PackedStringArray = PackedStringArray()
var checks: int = 0
var _case: String = ""
## Signal counters live on the instance: GDScript lambdas capture locals by value, so
## an `int` incremented inside one would never reach the assertion.
var _box_events: int = 0
var _hover_events: int = 0


class StubProvider extends RefCounted:
	var point_id: int = -1
	var rect_ids: PackedInt32Array = PackedInt32Array()
	var last_rect: Rect2 = Rect2()

	func entity_at_world(_pos: Vector2) -> int:
		return point_id

	func entities_in_world_rect(rect: Rect2) -> PackedInt32Array:
		last_rect = rect
		return rect_ids


## Mirrors game/core/settings.gd's storage contract without touching the player's file.
class SettingsStub extends RefCounted:
	const PATH: String = "user://camera_test_settings.cfg"
	var gameplay: Dictionary = {}

	func get_value(section: String, key: String, fallback: Variant = null) -> Variant:
		if section != "gameplay":
			return fallback
		return gameplay.get(key, fallback)

	func set_value(section: String, key: String, value: Variant) -> void:
		if section == "gameplay":
			gameplay[key] = value

	func save_to_disk() -> void:
		var cfg := ConfigFile.new()
		for k: String in gameplay:
			cfg.set_value("gameplay", k, gameplay[k])
		cfg.save(PATH)

	func load_from_disk() -> void:
		var cfg := ConfigFile.new()
		if cfg.load(PATH) != OK:
			return
		gameplay.clear()
		if not cfg.has_section("gameplay"):
			return
		for k: String in cfg.get_section_keys("gameplay"):
			gameplay[k] = cfg.get_value("gameplay", k)

	func wipe() -> void:
		gameplay.clear()
		if FileAccess.file_exists(PATH):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


# --- runner --------------------------------------------------------------------

func run_all() -> Dictionary:
	failures = PackedStringArray()
	checks = 0
	var cases: Array[StringName] = [
		&"test_zoom_anchors_on_cursor",
		&"test_zoom_clamps",
		&"test_zoom_converges",
		&"test_pan_is_zoom_invariant",
		&"test_pan_accelerates_and_stops",
		&"test_momentum_is_killable",
		&"test_bounds_clamping",
		&"test_drag_holds_the_grabbed_point",
		&"test_focus_arrives_and_yields",
		&"test_shake_decay",
		&"test_shake_superposition_and_determinism",
		&"test_readability_thresholds",
		&"test_edge_scroll_ramp",
		&"test_screen_world_roundtrip",
		&"test_rig_serialisation",
		&"test_cell_maths",
		&"test_click_versus_box_select",
		&"test_keybind_event_roundtrip",
		&"test_keybind_labels_never_degrade_to_numbers",
		&"test_keybind_rebinding",
		&"test_keybind_persistence",
	]
	for case: StringName in cases:
		_case = String(case)
		call(case)
	return {
		"name": "camera",
		"checks": checks,
		"failed": failures.size(),
		"failures": failures,
	}


# --- assertions ----------------------------------------------------------------

func _ok(condition: bool, what: String) -> void:
	checks += 1
	if not condition:
		failures.append("%s: %s" % [_case, what])


func _near(a: float, b: float, tol: float, what: String) -> void:
	checks += 1
	if absf(a - b) > tol:
		failures.append("%s: %s (%.6f vs %.6f, tol %.6f)" % [_case, what, a, b, tol])


func _near_v(a: Vector2, b: Vector2, tol: float, what: String) -> void:
	checks += 1
	if a.distance_to(b) > tol:
		failures.append("%s: %s (%s vs %s, tol %.6f)" % [_case, what, str(a), str(b), tol])


func _eq_i(a: int, b: int, what: String) -> void:
	checks += 1
	if a != b:
		failures.append("%s: %s (%d vs %d)" % [_case, what, a, b])


func _eq_s(a: String, b: String, what: String) -> void:
	checks += 1
	if a != b:
		failures.append("%s: %s ('%s' vs '%s')" % [_case, what, a, b])


func _on_box_changed(_rect: Rect2, active: bool) -> void:
	if active:
		_box_events += 1


func _on_hover_changed(_cell: Vector2i, _world_pos: Vector2, _inside: bool) -> void:
	_hover_events += 1


func _make_rig(clamped: bool = false) -> CameraRig:
	var rig := CameraRig.new()
	rig.set_viewport_size(VIEWPORT)
	rig.clamp_enabled = clamped
	return rig


func _run(rig: CameraRig, seconds: float) -> void:
	var steps: int = int(round(seconds / DT))
	for _i: int in steps:
		rig.advance(DT)


# --- zoom ----------------------------------------------------------------------

## The single most important camera detail in a builder: the tile under the cursor must
## stay under the cursor for the whole smoothed zoom, not just at the end.
func test_zoom_anchors_on_cursor() -> void:
	var anchors: Array[Vector2] = [
		Vector2(0.0, 0.0), Vector2(1920.0, 1080.0), Vector2(640.0, 300.0),
		Vector2(960.0, 540.0), Vector2(1700.0, 90.0),
	]
	var step_counts: Array[float] = [1.0, -1.0, 3.0, -4.0, 0.5]
	for anchor: Vector2 in anchors:
		for steps: float in step_counts:
			var rig: CameraRig = _make_rig()
			rig.position = Vector2(137.0, -412.0)
			rig.set_zoom_immediate(1.0)
			var target_world: Vector2 = rig.screen_to_world(anchor)
			rig.zoom_by(steps, anchor)
			var worst: float = 0.0
			for _i: int in 90:
				rig.advance(DT)
				worst = maxf(worst, rig.screen_to_world(anchor).distance_to(target_world))
			# Sub-pixel at every frame, not merely at the end. 0.05 leaves room for the
			# 32-bit floats Vector2 uses at world coordinates in the thousands.
			_ok(worst < 0.05, "anchor %s drifted %.5f px over a %.1f-step zoom" % [str(anchor), worst, steps])

	# A second zoom mid-flight must re-anchor without a jump.
	var rig2: CameraRig = _make_rig()
	rig2.set_zoom_immediate(1.0)
	var a2: Vector2 = Vector2(300.0, 800.0)
	var w2: Vector2 = rig2.screen_to_world(a2)
	rig2.zoom_by(2.0, a2)
	_run(rig2, 0.05)
	rig2.zoom_by(2.0, a2)
	_run(rig2, 0.6)
	_near_v(rig2.screen_to_world(a2), w2, 0.05, "stacked zoom lost the anchor")


func test_zoom_clamps() -> void:
	var rig: CameraRig = _make_rig()
	rig.zoom_by(100.0, VIEWPORT * 0.5)
	_run(rig, 2.0)
	_near(rig.zoom, rig.tuning.zoom_max, 0.0001, "zoom did not clamp to max")
	rig.zoom_by(-500.0, VIEWPORT * 0.5)
	_run(rig, 3.0)
	_near(rig.zoom, rig.tuning.zoom_min, 0.0001, "zoom did not clamp to min")
	_ok(rig.target_zoom_level() >= rig.tuning.zoom_min - 0.0001, "target zoom escaped the clamp")

	# set_zoom_immediate obeys the same limits.
	rig.set_zoom_immediate(99.0)
	_near(rig.zoom, rig.tuning.zoom_max, 0.0001, "immediate zoom ignored max")
	rig.set_zoom_immediate(0.0001)
	_near(rig.zoom, rig.tuning.zoom_min, 0.0001, "immediate zoom ignored min")


func test_zoom_converges() -> void:
	var rig: CameraRig = _make_rig()
	rig.set_zoom_immediate(1.0)
	rig.zoom_by(3.0, VIEWPORT * 0.5)
	var target: float = rig.target_zoom_level()
	_run(rig, 0.5)
	_near(rig.zoom, target, 0.001, "zoom has not settled after 0.5 s")
	# Half-life honesty: after one half-life the remaining log gap is halved.
	var rig2: CameraRig = _make_rig()
	rig2.set_zoom_immediate(1.0)
	rig2.zoom_by(4.0, VIEWPORT * 0.5)
	var gap0: float = log(rig2.target_zoom_level()) - log(rig2.zoom)
	rig2.advance(rig2.tuning.zoom_smooth_halflife)
	var gap1: float = log(rig2.target_zoom_level()) - log(rig2.zoom)
	_near(gap1 / gap0, 0.5, 0.01, "zoom half-life is off")


# --- pan -----------------------------------------------------------------------

## Feel must not change with zoom: the same key press moves the world across the screen
## at the same rate whether you are inspecting a belt or looking at the whole plain.
func test_pan_is_zoom_invariant() -> void:
	var travels: Array[float] = []
	for z: float in [0.3, 1.0, 2.5]:
		var rig: CameraRig = _make_rig()
		rig.set_zoom_immediate(z)
		rig.position = Vector2.ZERO
		rig.set_pan_input(Vector2.RIGHT)
		_run(rig, 1.0)
		travels.append(rig.position.length() * z)
	for i: int in travels.size():
		_near(travels[i], travels[0], travels[0] * 0.01, "screen travel differs at zoom index %d" % i)
	_ok(travels[0] > 1000.0, "one second of panning barely moved (%.1f px)" % travels[0])


func test_pan_accelerates_and_stops() -> void:
	var rig: CameraRig = _make_rig()
	rig.set_zoom_immediate(1.0)
	rig.set_pan_input(Vector2.RIGHT)
	var reached: float = -1.0
	var over: bool = false
	for i: int in 120:
		rig.advance(DT)
		var speed: float = rig.velocity_screen().length()
		if speed > rig.tuning.pan_speed + 0.001:
			over = true
		if reached < 0.0 and speed >= rig.tuning.pan_speed - 1.0:
			reached = float(i + 1) * DT
	_ok(not over, "pan speed overshot the maximum")
	_ok(reached > 0.0 and reached < 0.2, "took %.3f s to reach full pan speed" % reached)

	# Release: a short, controlled glide. No floatiness.
	rig.set_pan_input(Vector2.ZERO)
	var start: Vector2 = rig.position
	var stopped_after: float = -1.0
	for i: int in 120:
		rig.advance(DT)
		if rig.velocity_screen() == Vector2.ZERO:
			stopped_after = float(i + 1) * DT
			break
	_ok(stopped_after > 0.0 and stopped_after < 0.35, "glide lasted %.3f s" % stopped_after)
	var glide: float = rig.position.distance_to(start)
	_ok(glide < 200.0, "glide carried %.1f px after release" % glide)


func test_momentum_is_killable() -> void:
	var rig: CameraRig = _make_rig()
	rig.set_zoom_immediate(1.0)
	rig.set_pan_input(Vector2.RIGHT)
	_run(rig, 0.3)
	rig.set_pan_input(Vector2.ZERO)
	rig.advance(DT)
	_ok(rig.velocity_screen().length() > 100.0, "no momentum to kill")
	rig.stop_motion()
	var frozen: Vector2 = rig.position
	_run(rig, 0.5)
	_near_v(rig.position, frozen, 0.0001, "camera kept moving after stop_motion")

	# A drag also kills a running glide instantly.
	rig.set_pan_input(Vector2.LEFT)
	_run(rig, 0.3)
	rig.set_pan_input(Vector2.ZERO)
	rig.begin_drag(Vector2(500.0, 500.0))
	_ok(rig.velocity_screen() == Vector2.ZERO, "drag did not kill momentum")


# --- bounds --------------------------------------------------------------------

func test_bounds_clamping() -> void:
	var rig: CameraRig = _make_rig(true)
	rig.set_zoom_immediate(1.0)
	rig.set_world_bounds(Rect2(0.0, 0.0, 20000.0, 20000.0))
	rig.position = Vector2(-9999.0, -9999.0)
	rig.advance(DT)
	_near_v(rig.position, Vector2(960.0, 540.0), 0.01, "camera left the world on the low side")
	rig.position = Vector2(999999.0, 999999.0)
	rig.advance(DT)
	_near_v(rig.position, Vector2(20000.0 - 960.0, 20000.0 - 540.0), 0.05, "camera left the world on the high side")
	_ok(rig.is_clamped(), "clamping was not reported")

	# Momentum into the wall dies at the wall instead of pressing against it.
	rig.position = Vector2(19000.0, 10000.0)
	rig.set_pan_input(Vector2.RIGHT)
	_run(rig, 1.5)
	_near(rig.position.x, 20000.0 - 960.0, 0.05, "did not stop at the eastern edge")
	rig.set_pan_input(Vector2.ZERO)
	rig.advance(DT)
	_near(rig.velocity_screen().x, 0.0, 0.0001, "velocity survived the wall")

	# A world smaller than the view pins the camera to its centre.
	rig.set_world_bounds(Rect2(0.0, 0.0, 800.0, 600.0))
	rig.position = Vector2(-5000.0, 5000.0)
	rig.advance(DT)
	_near_v(rig.position, Vector2(400.0, 300.0), 0.01, "small world was not centred")

	# Zooming out far enough that the view exceeds the world also centres, never jitters.
	rig.set_world_bounds(Rect2(0.0, 0.0, 20000.0, 20000.0))
	rig.position = Vector2(10000.0, 10000.0)
	rig.set_zoom_immediate(rig.tuning.zoom_min)
	rig.advance(DT)
	_ok(rig.visible_world_rect().size.x > 8000.0, "min zoom does not show a district")


# --- drag ----------------------------------------------------------------------

func test_drag_holds_the_grabbed_point() -> void:
	for z: float in [0.4, 1.0, 2.0]:
		var rig: CameraRig = _make_rig()
		rig.set_zoom_immediate(z)
		rig.position = Vector2(600.0, -250.0)
		var grab: Vector2 = Vector2(410.0, 690.0)
		var grabbed_world: Vector2 = rig.screen_to_world(grab)
		rig.begin_drag(grab)
		var path: Array[Vector2] = [
			Vector2(430.0, 700.0), Vector2(520.0, 640.0), Vector2(900.0, 300.0), Vector2(120.0, 950.0),
		]
		for p: Vector2 in path:
			rig.update_drag(p)
			rig.advance(DT)
			_near_v(rig.screen_to_world(p), grabbed_world, 0.02, "drag slipped at zoom %.2f" % z)
		# Throwing the map leaves momentum going the way the hand was going.
		rig.update_drag(Vector2(60.0, 950.0))
		rig.advance(DT)
		rig.end_drag()
		_ok(rig.velocity_screen().x > 0.0, "throw did not carry momentum at zoom %.2f" % z)


# --- focus ---------------------------------------------------------------------

func test_focus_arrives_and_yields() -> void:
	var rig: CameraRig = _make_rig()
	rig.set_zoom_immediate(1.0)
	rig.position = Vector2.ZERO
	var target: Vector2 = Vector2(2400.0, -1800.0)
	rig.focus_on(target, false)
	_ok(rig.is_focusing(), "focus did not start")
	_run(rig, 0.05)
	_ok(rig.position.distance_to(target) < Vector2.ZERO.distance_to(target), "focus moved the wrong way")
	_run(rig, 1.2)
	_near_v(rig.position, target, 0.01, "focus never arrived")
	_ok(not rig.is_focusing(), "focus never finished")

	# Immediate focus is a teleport.
	rig.focus_on(Vector2(-500.0, 500.0), true)
	_near_v(rig.position, Vector2(-500.0, 500.0), 0.001, "immediate focus did not teleport")

	# Player input wins over an automated move, on the same frame.
	rig.position = Vector2.ZERO
	rig.focus_on(target, false)
	_run(rig, 0.1)
	rig.set_pan_input(Vector2.LEFT)
	_ok(not rig.is_focusing(), "focus survived player input")
	var before: Vector2 = rig.position
	_run(rig, 0.4)
	_ok(rig.position.x < before.x, "camera did not follow the player after interrupting focus")

	# Framing a rectangle picks a zoom that fits it.
	var rig2: CameraRig = _make_rig()
	rig2.set_zoom_immediate(2.0)
	var area: Rect2 = Rect2(0.0, 0.0, 3840.0, 2160.0)
	rig2.focus_on_rect(area, 0.0, true)
	_near_v(rig2.position, area.get_center(), 0.01, "focus_on_rect missed the centre")
	_near(rig2.zoom, 0.5, 0.001, "focus_on_rect picked the wrong zoom")


# --- shake ---------------------------------------------------------------------

func test_shake_decay() -> void:
	var shake := CameraShake.new()
	shake.add(1.0, 0.5, 20.0)
	_near(shake.trauma, 1.0, 0.0001, "trauma did not charge")
	var elapsed: float = 0.0
	while shake.active() and elapsed < 2.0:
		shake.advance(DT)
		elapsed += DT
		var o: Vector2 = shake.offset()
		_ok(absf(o.x) <= shake.max_offset_px + 0.0001 and absf(o.y) <= shake.max_offset_px + 0.0001,
			"shake offset exceeded the cap")
	_near(elapsed, 0.5, DT * 1.5, "trauma did not bleed off over its duration")
	_ok(shake.offset() == Vector2.ZERO, "shake still displacing after decay")
	_near(shake.roll(), 0.0, 0.0, "shake still rolling after decay")

	# Half the trauma is a quarter of the displacement: small hits stay subtle.
	var s2 := CameraShake.new()
	s2.add(0.5, 1.0)
	_near(s2.amount(), 0.25, 0.0001, "displacement curve is not trauma squared")
	var o2: Vector2 = s2.offset()
	_ok(absf(o2.x) <= s2.max_offset_px * 0.25 + 0.0001, "half trauma displaced more than a quarter")


func test_shake_superposition_and_determinism() -> void:
	var shake := CameraShake.new()
	shake.add(0.3, 0.4)
	shake.add(0.3, 0.4)
	_near(shake.trauma, 0.6, 0.0001, "trauma did not accumulate")
	shake.add(1.0, 0.4)
	_near(shake.trauma, 1.0, 0.0001, "trauma exceeded 1")

	# The longest request governs the decay; a pistol tick cannot cut a rumble short.
	var long_shake := CameraShake.new()
	long_shake.add(1.0, 1.0)
	long_shake.add(0.1, 0.05)
	long_shake.advance(0.5)
	_ok(long_shake.trauma > 0.4, "a short hit truncated a long rumble (trauma %.3f)" % long_shake.trauma)

	# Same calls, same numbers — a visual regression run must diff cleanly.
	var a := CameraShake.new()
	var b := CameraShake.new()
	a.add(0.8, 0.6, 18.0)
	b.add(0.8, 0.6, 18.0)
	for _i: int in 20:
		a.advance(DT)
		b.advance(DT)
		_near_v(a.offset(), b.offset(), 0.0, "shake is not deterministic")

	# Smooth, not white noise: at 8 Hz a frame can never jump the full amplitude.
	var c := CameraShake.new()
	c.add(1.0, 2.0, 8.0)
	var previous: Vector2 = c.offset()
	var biggest_step: float = 0.0
	for _i: int in 100:
		c.advance(DT)
		var now: Vector2 = c.offset()
		biggest_step = maxf(biggest_step, now.distance_to(previous))
		previous = now
	_ok(biggest_step < c.max_offset_px * 0.8,
		"shake jumps like white noise (%.2f px in one frame)" % biggest_step)


# --- readability ----------------------------------------------------------------

func test_readability_thresholds() -> void:
	var t := CameraTuning.new()
	_eq_i(t.detail_level_for(2.0), CameraTuning.DETAIL_CLOSE, "2.0 should be close")
	_eq_i(t.detail_level_for(0.8), CameraTuning.DETAIL_NORMAL, "0.8 should be normal")
	_eq_i(t.detail_level_for(0.4), CameraTuning.DETAIL_FAR, "0.4 should be far")
	_eq_i(t.detail_level_for(0.25), CameraTuning.DETAIL_STRATEGIC, "0.25 should be strategic")

	# Crossing out and back in yields three transitions each way.
	var level: int = t.detail_level_for(2.0)
	var out_transitions: int = 0
	var z: float = 2.0
	while z > 0.2:
		var next: int = t.detail_level_step(z, level)
		if next != level:
			out_transitions += 1
		level = next
		z -= 0.005
	_eq_i(out_transitions, 3, "wrong number of transitions zooming out")
	var in_transitions: int = 0
	while z < 2.0:
		var next2: int = t.detail_level_step(z, level)
		if next2 != level:
			in_transitions += 1
		level = next2
		z += 0.005
	_eq_i(in_transitions, 3, "wrong number of transitions zooming in")
	_eq_i(level, CameraTuning.DETAIL_CLOSE, "did not end up close again")

	# A zoom dithering on a boundary must not strobe the overlays.
	var dither_level: int = t.detail_level_for(t.detail_normal)
	var flips: int = 0
	for i: int in 200:
		var wobble: float = t.detail_normal * (1.0 + (0.02 if i % 2 == 0 else -0.02))
		var next3: int = t.detail_level_step(wobble, dither_level)
		if next3 != dither_level:
			flips += 1
		dither_level = next3
	_eq_i(flips, 0, "hysteresis failed: overlays would strobe on the boundary")


func test_edge_scroll_ramp() -> void:
	var size: Vector2 = VIEWPORT
	var margin: float = 14.0
	_ok(CameraRig.edge_scroll_dir(size * 0.5, size, margin) == Vector2.ZERO, "centre should not scroll")
	var left: Vector2 = CameraRig.edge_scroll_dir(Vector2(0.0, 540.0), size, margin)
	_near(left.x, -1.0, 0.0001, "hard left edge is not full speed")
	_near(left.y, 0.0, 0.0001, "left edge should not scroll vertically")
	var right: Vector2 = CameraRig.edge_scroll_dir(Vector2(size.x, 540.0), size, margin)
	_near(right.x, 1.0, 0.0001, "hard right edge is not full speed")
	var corner: Vector2 = CameraRig.edge_scroll_dir(Vector2(0.0, 0.0), size, margin)
	_near_v(corner, Vector2(-1.0, -1.0), 0.0001, "corner should scroll on both axes")
	var soft: Vector2 = CameraRig.edge_scroll_dir(Vector2(margin * 0.5, 540.0), size, margin)
	_ok(soft.x < 0.0 and soft.x > -1.0, "ramp is not gradual (%.3f)" % soft.x)
	var previous: float = 0.0
	for i: int in 15:
		var here: float = -CameraRig.edge_scroll_dir(Vector2(margin - float(i), 540.0), size, margin).x
		_ok(here >= previous - 0.0001, "ramp is not monotonic")
		previous = here
	_ok(CameraRig.edge_scroll_dir(Vector2(-40.0, 540.0), size, margin) == Vector2.ZERO,
		"mouse well outside the window should not scroll")


# --- transforms -----------------------------------------------------------------

func test_screen_world_roundtrip() -> void:
	for z: float in [0.22, 0.5, 1.0, 3.0]:
		var rig: CameraRig = _make_rig()
		rig.set_zoom_immediate(z)
		rig.position = Vector2(-1234.0, 5678.0)
		for p: Vector2 in [Vector2.ZERO, VIEWPORT, Vector2(333.0, 777.0)]:
			_near_v(rig.world_to_screen(rig.screen_to_world(p)), p, 0.01, "round trip failed at zoom %.2f" % z)
		var rect: Rect2 = rig.visible_world_rect()
		_near_v(rect.get_center(), rig.position, 0.01, "visible rect is not centred on the camera")
		_near(rect.size.x, VIEWPORT.x / z, 0.01, "visible rect width is wrong")


func test_rig_serialisation() -> void:
	var rig: CameraRig = _make_rig(true)
	rig.set_world_bounds(Rect2(-500.0, -500.0, 9000.0, 9000.0))
	rig.set_zoom_immediate(1.75)
	rig.position = Vector2(1200.0, 900.0)
	var data: Dictionary = rig.serialize()
	var json: Variant = JSON.parse_string(JSON.stringify(data))
	_ok(typeof(json) == TYPE_DICTIONARY, "camera state is not JSON-safe")
	var restored: CameraRig = _make_rig(true)
	restored.deserialize(json)
	_near_v(restored.position, rig.position, 0.01, "position did not survive a save")
	_near(restored.zoom, rig.zoom, 0.001, "zoom did not survive a save")
	_ok(restored.world_bounds.size == rig.world_bounds.size, "bounds did not survive a save")


# --- selection ------------------------------------------------------------------

func test_cell_maths() -> void:
	var t: int = CameraTuning.TILE_SIZE
	_ok(SelectionController.world_to_cell(Vector2(0.0, 0.0), t) == Vector2i(0, 0), "origin cell")
	_ok(SelectionController.world_to_cell(Vector2(31.9, 31.9), t) == Vector2i(0, 0), "inside first cell")
	_ok(SelectionController.world_to_cell(Vector2(32.0, 32.0), t) == Vector2i(1, 1), "second cell")
	# The classic off-by-one: truncation puts -0.5 in cell 0, floor puts it in cell -1.
	_ok(SelectionController.world_to_cell(Vector2(-0.5, -0.5), t) == Vector2i(-1, -1), "negative cell floors")
	_ok(SelectionController.world_to_cell(Vector2(-32.0, -33.0), t) == Vector2i(-1, -2), "negative cell edge")
	_ok(SelectionController.cell_centre(Vector2i(2, 3), t) == Vector2(80.0, 112.0), "cell centre")

	var rect: Rect2i = SelectionController.cell_rect(Vector2(100.0, 200.0), Vector2(10.0, 20.0), t)
	_ok(rect == Rect2i(0, 0, 4, 7), "cell rect should normalise reversed corners, got %s" % str(rect))
	var single: Rect2i = SelectionController.cell_rect(Vector2(40.0, 40.0), Vector2(41.0, 41.0), t)
	_ok(single == Rect2i(1, 1, 1, 1), "a tiny drag should cover exactly one cell")


func test_click_versus_box_select() -> void:
	var sel := SelectionController.new()
	var provider := StubProvider.new()
	sel.provider = provider
	provider.point_id = 7
	provider.rect_ids = PackedInt32Array([3, 1, 2])

	_box_events = 0
	_hover_events = 0
	sel.box_changed.connect(_on_box_changed)
	sel.hover_changed.connect(_on_hover_changed)

	# A click: under the drag threshold, so it stays a point query.
	sel.press(Vector2(64.0, 64.0), Vector2(100.0, 100.0), false)
	sel.motion(Vector2(66.0, 64.0), Vector2(102.0, 100.0))
	_ok(not sel.box_active, "a 2 px wobble became a box select")
	sel.release(Vector2(66.0, 64.0), Vector2(102.0, 100.0))
	_ok(sel.selected == PackedInt32Array([7]), "click did not select the entity under the cursor")
	_ok(sel.selected_cells == Rect2i(2, 2, 1, 1), "click selection reported the wrong cell")

	# A drag: crosses the threshold, becomes a box, returns sorted ids.
	sel.press(Vector2(0.0, 0.0), Vector2(100.0, 100.0), false)
	sel.motion(Vector2(200.0, 100.0), Vector2(300.0, 200.0))
	_ok(sel.box_active, "a 200 px drag did not become a box select")
	_ok(_box_events > 0, "box_changed never fired")
	sel.release(Vector2(200.0, 100.0), Vector2(300.0, 200.0))
	_ok(sel.selected == PackedInt32Array([1, 2, 3]), "box select did not return sorted ids")
	_ok(sel.selected_cells == Rect2i(0, 0, 7, 4), "box select reported the wrong cell rect")

	# Shift keeps what was already selected.
	provider.rect_ids = PackedInt32Array([9])
	sel.press(Vector2(500.0, 500.0), Vector2(700.0, 700.0), true)
	sel.motion(Vector2(700.0, 700.0), Vector2(900.0, 900.0))
	sel.release(Vector2(700.0, 700.0), Vector2(900.0, 900.0))
	_ok(sel.selected == PackedInt32Array([1, 2, 3, 9]), "shift-select replaced instead of adding")

	# Cancel abandons the box without touching the committed selection.
	sel.press(Vector2(0.0, 0.0), Vector2(0.0, 0.0), false)
	sel.motion(Vector2(400.0, 400.0), Vector2(400.0, 400.0))
	sel.cancel()
	_ok(not sel.box_active, "cancel left the box up")
	_ok(sel.selected == PackedInt32Array([1, 2, 3, 9]), "cancel wiped the selection")
	sel.clear()
	_ok(sel.selected.is_empty() and not sel.has_selection, "clear did not clear")

	# Hover reports cells and only fires when the cell actually changes.
	_hover_events = 0
	sel.set_hover(Vector2(10.0, 10.0), true)
	sel.set_hover(Vector2(20.0, 20.0), true)
	sel.set_hover(Vector2(40.0, 10.0), true)
	_eq_i(_hover_events, 2, "hover fired on every pixel instead of every cell")
	_ok(sel.hovered_cell == Vector2i(1, 0), "hover cell is wrong")


# --- keybinds --------------------------------------------------------------------

func test_keybind_event_roundtrip() -> void:
	Keybinds.install()
	var actions: Array[StringName] = Keybinds.actions()
	_ok(actions.size() >= 25, "action map is suspiciously small (%d)" % actions.size())
	for required: StringName in [
			&"build", &"cancel", &"rotate", &"copy", &"paste", &"blueprint", &"pause",
			&"speed_1", &"speed_2", &"speed_3", &"overlay_1", &"overlay_5", &"quick_save",
			&"cam_pan_up", &"cam_zoom_in", &"cam_drag", &"select"]:
		_ok(InputMap.has_action(required), "action '%s' is missing from InputMap" % required)

	for action: StringName in actions:
		var events: Array[InputEvent] = Keybinds.events_for(action)
		_ok(not events.is_empty(), "action '%s' has no default binding" % action)
		for e: InputEvent in events:
			var data: Dictionary = Keybinds.event_to_dict(e)
			_ok(not data.is_empty(), "event for '%s' does not serialise" % action)
			# Through JSON, because that is what a config file effectively is.
			var round_tripped: Variant = JSON.parse_string(JSON.stringify(data))
			var rebuilt: InputEvent = Keybinds.event_from_dict(round_tripped)
			_ok(rebuilt != null, "event for '%s' does not deserialise" % action)
			_ok(Keybinds.event_signature(rebuilt) == Keybinds.event_signature(e),
				"binding for '%s' changed across a round trip" % action)
		_ok(Keybinds.event_label(events[0]) != "", "action '%s' has no readable label" % action)

	# Every binding is unique inside its context; a fresh map has no collisions.
	for action2: StringName in actions:
		for e2: InputEvent in Keybinds.events_for(action2):
			var clash: Array[StringName] = Keybinds.conflicts(action2, e2)
			_ok(clash.is_empty(), "default bindings collide: %s vs %s" % [action2, str(clash)])


## Labels must survive a display server that cannot answer "what is this key called".
##
## The bindings are all PHYSICAL keycodes, so event_label() has to resolve one through
## the keyboard layout — and the headless driver answers that with an engine error
## instead of a value. Guarding the lookup is only half the fix: the fallback has to
## still name the key. `!= ""` does not catch that, because "87" is a non-empty string
## and a player reading "87" for W has been served a bug with full marks from the suite.
func test_keybind_labels_never_degrade_to_numbers() -> void:
	Keybinds.install()
	Keybinds.reset_all()

	for action: StringName in Keybinds.actions():
		for e: InputEvent in Keybinds.events_for(action):
			var label: String = Keybinds.event_label(e)
			_ok(label != "", "action '%s' has an empty label" % action)
			var k := e as InputEventKey
			if k == null:
				continue
			# The exact degradation the guard exists to prevent: the raw scancode.
			var raw: String = str(int(k.physical_keycode))
			_ok(not label.ends_with(raw),
				"action '%s' labelled as the bare keycode '%s'" % [action, label])

	# Function keys carry the same name on every keyboard layout, so this pins the
	# fallback itself rather than whatever layout the machine running the suite has.
	var f7 := InputEventKey.new()
	f7.physical_keycode = KEY_F7
	_eq_s(Keybinds.event_label(f7), "F7", "a physical-only function key lost its name")

	# Non-key bindings never touch the layout and must be unaffected by the guard.
	_eq_s(Keybinds.binding_label(&"cam_drag"), "Middle Mouse", "mouse label changed")
	_eq_s(Keybinds.binding_label(&"cam_zoom_in"), "Wheel Up", "wheel label changed")
	_ok(Keybinds.binding_label(&"quick_save").begins_with("Ctrl+")
			or Keybinds.binding_label(&"quick_save").begins_with("Cmd+"),
		"a modifier binding lost its prefix")


func test_keybind_rebinding() -> void:
	Keybinds.install()
	Keybinds.reset_all()

	var f9 := InputEventKey.new()
	f9.physical_keycode = KEY_F9
	_ok(Keybinds.rebind(&"rotate", f9), "rebinding rotate to F9 failed")
	_ok(Keybinds.is_overridden(&"rotate"), "rebind was not recorded as an override")
	var bound: bool = false
	for e: InputEvent in InputMap.action_get_events(&"rotate"):
		var k := e as InputEventKey
		if k != null and k.physical_keycode == KEY_F9:
			bound = true
	_ok(bound, "InputMap did not receive the new binding")

	# Colliding rebinds are refused, and refusing must not damage the old binding.
	var b_key := InputEventKey.new()
	b_key.physical_keycode = KEY_B
	_ok(not Keybinds.rebind(&"rotate", b_key), "a colliding rebind was accepted")
	_ok(Keybinds.conflicts(&"rotate", b_key).has(&"build"), "conflict was not attributed to build")
	var still_f9: bool = false
	for e2: InputEvent in InputMap.action_get_events(&"rotate"):
		var k2 := e2 as InputEventKey
		if k2 != null and k2.physical_keycode == KEY_F9:
			still_f9 = true
	_ok(still_f9, "a refused rebind destroyed the existing binding")
	_ok(Keybinds.rebind(&"rotate", b_key, 0, true), "a forced rebind was refused")

	Keybinds.reset(&"rotate")
	_ok(not Keybinds.is_overridden(&"rotate"), "reset did not drop the override")
	var back_to_r: bool = false
	for e3: InputEvent in InputMap.action_get_events(&"rotate"):
		var k3 := e3 as InputEventKey
		if k3 != null and k3.physical_keycode == KEY_R:
			back_to_r = true
	_ok(back_to_r, "reset did not restore the default binding")

	# Exact-first matching: Ctrl/Cmd+B is a blueprint, plain B is the build menu.
	var plain_b := InputEventKey.new()
	plain_b.physical_keycode = KEY_B
	plain_b.pressed = true
	_ok(Keybinds.match_pressed(plain_b) == &"build", "plain B did not resolve to build")
	var mod_b := InputEventKey.new()
	mod_b.physical_keycode = KEY_B
	mod_b.pressed = true
	mod_b.command_or_control_autoremap = true
	_ok(Keybinds.match_pressed(mod_b) == &"blueprint", "Ctrl+B did not resolve to blueprint")
	# Shift+click must still select: no exact match, so the loose pass catches it.
	var shift_click := InputEventMouseButton.new()
	shift_click.button_index = MOUSE_BUTTON_LEFT
	shift_click.pressed = true
	shift_click.shift_pressed = true
	_ok(Keybinds.match_pressed(shift_click) == &"select", "shift+click stopped selecting")

	Keybinds.reset_all()


func test_keybind_persistence() -> void:
	Keybinds.install()
	Keybinds.reset_all()
	var settings := SettingsStub.new()
	settings.wipe()

	var f9 := InputEventKey.new()
	f9.physical_keycode = KEY_F9
	f9.shift_pressed = true
	_ok(Keybinds.rebind(&"quick_save", f9), "rebinding quick_save failed")
	Keybinds.persist(settings)

	# Everything the player changed must survive a full trip through ConfigFile.
	var reloaded := SettingsStub.new()
	reloaded.load_from_disk()
	var stored: Variant = reloaded.get_value("gameplay", "keybinds", {})
	_ok(typeof(stored) == TYPE_DICTIONARY and (stored as Dictionary).has("quick_save"),
		"rebind did not reach the config file")

	Keybinds.reset_all()
	_ok(not Keybinds.is_overridden(&"quick_save"), "reset_all did not clear overrides")
	Keybinds.restore(reloaded)
	_ok(Keybinds.is_overridden(&"quick_save"), "restore did not bring the override back")
	var found: bool = false
	for e: InputEvent in InputMap.action_get_events(&"quick_save"):
		var k := e as InputEventKey
		if k != null and k.physical_keycode == KEY_F9 and k.shift_pressed:
			found = true
	_ok(found, "restored binding never reached InputMap")

	# Garbage in the config must not take the action map down with it.
	Keybinds.from_dict({"quick_save": "not an array", "no_such_action": [{"type": "key", "physical": 65}]})
	_ok(InputMap.has_action(&"quick_save"), "malformed config destroyed an action")
	Keybinds.reset_all()
	settings.wipe()
