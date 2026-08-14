extends Node
## The feel layer's frame budget, measured. [P15]
##
##   godot --headless --path . res://tests/feel/feel_perf.tscn
##   godot            --path . res://tests/feel/feel_perf.tscn   # + the GPU side
##
## A SCENE, not a `--script` entry point — see ARCHITECTURE.md §6.1.
##
## THE CLAIM UNDER TEST: "a juice layer is free". It is not free, it is cheap,
## and the difference has to be a number. This drives the layer at its WORST
## case — a full effect pool, a full anchor list, a stress city, every screen
## treatment on at once — and fails the build if it drifts.
##
## Worst case is the right thing to measure because the pool is fixed: 256 rows
## is 256 rows whether the city is dying or idle, which is exactly the property
## that makes the cost predictable. If the worst case fits, every case fits.
##
## Headless measures the CPU side (spawn, prune, anchor rebuild, impulses) and
## whether `_draw` ran at all; with a display attached the draw cost is filled in
## and gated as well. Both are printed either way, and the verdict says which
## numbers it is standing on.

const BUILDINGS: int = 900
const WARMUP_FRAMES: int = 10
const SAMPLE_FRAMES: int = 60

## Per-frame budget for the whole feel layer at a full pool, in microseconds.
## The reference numbers on an M3 Max with a display are ~40 us of _process and
## ~180 us of drawing with all 256 effects on screen. The gate is set at roughly
## 4x the reference so a loaded build machine does not fail an honest build,
## while a genuine regression — an unpooled particle system, an uncapped anchor
## list — is one to two orders of magnitude away and cannot hide under it.
const BUDGET_PROCESS_US: float = 900.0
const BUDGET_DRAW_US: float = 2200.0
## The whole layer's share of a 16.6 ms frame. Above this it is not juice, it is
## a second renderer.
const BUDGET_TOTAL_US: float = 3000.0

var _headless: bool = true
var _feel: LcnFeel = null
var _frame: int = 0
var _process_us: Array[float] = []
var _draw_us: Array[float] = []
## Per-surface draw samples, so a budget failure names the surface that spent it
## instead of leaving the next reader to bisect four of them.
var _surface_us: Dictionary[String, Array] = {
	"world": [] as Array[float], "idle": [] as Array[float],
	"hover": [] as Array[float], "screen": [] as Array[float],
}
var _draw_calls: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _done: bool = false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	LcnLayers.force_install = true
	# The pointer reads (0, 0) in a windowless run, which [P16] correctly treats
	# as a hold on the top-left edge-scroll ramp: over the 70 frames sampled here
	# the camera walked off the city at ~45 px/frame and parked in the map
	# corner, so the idle layer's view cull correctly rejected all 441
	# structures and the anchor budget was measured against an empty list.
	# Same fixture defect, same fix, as `feel_gallery.gd`.
	Settings.gameplay["edge_scroll"] = false
	process_priority = 500       # after LcnFeel, so its numbers are this frame's


func _process(_delta: float) -> void:
	if _done:
		return
	_frame += 1
	if _frame == 1:
		_setup()
		return
	if _feel == null:
		_finish()
		return
	_churn()
	if _frame <= WARMUP_FRAMES + 1:
		return
	var s: Dictionary = _feel.stats()
	_process_us.append(float(s["frame_us"]))
	var drawn: float = 0.0
	for surface: String in ["world", "idle", "hover", "screen"]:
		var us: float = float((s[surface] as Dictionary)["draw_us"])
		(_surface_us[surface] as Array[float]).append(us)
		drawn += us
	_draw_us.append(drawn)
	if drawn > 0.0:
		_draw_calls += 1
	if _process_us.size() >= SAMPLE_FRAMES:
		_finish()


func _setup() -> void:
	print("── feel perf ─────────────────────────────────────────────────────────")
	Sim.create_world(11)
	LcnViewBootstrap.install()
	if GameCamera.current() == null:
		var cam := GameCamera.new()
		cam.name = "GameCamera"
		add_child(cam)
	_feel = LcnFeelBootstrap.install()
	if _feel == null:
		_failures.append("the feel layer did not install")
		return
	_stress_city()
	SimClock.advance(2)
	var cam2: GameCamera = GameCamera.current()
	if cam2 != null:
		# Bounds FIRST. Without them the camera clamps to its default roaming
		# rect, never reaches the city, and every view-culled layer downstream
		# correctly draws nothing — which looks exactly like a broken layer.
		var grid: SimSystem = Sim.get_system(&"grid")
		if grid != null and grid.has_method("map_size"):
			var size: Vector2i = grid.call("map_size")
			cam2.set_world_bounds(Rect2(Vector2.ZERO, Vector2(size) * 32.0))
		cam2.set_zoom_level(1.0, false)
		# Frame the city that was actually built, not the cell it was aimed at:
		# the ground refuses some placements, and a camera pointed at empty snow
		# makes every view-culled layer correctly draw nothing.
		cam2.focus_on(_city_centre(), true)


## A dense city, so the idle-life layer has far more candidates than its cap and
## the anchor walk is doing real work rather than finding nothing.
func _stress_city() -> void:
	var build: SimSystem = Sim.get_system(&"build")
	if build == null:
		return
	var c: Vector2i = _core()
	var kinds: Array[String] = [
		"heat_pipe", "warmth_radiator", "housing_block", "workshop",
		"coal_generator", "storage_yard", "wall",
	]
	var placed: int = 0
	var ring: int = 2
	while placed < BUILDINGS and ring < 46:
		for i: int in range(-ring, ring + 1, 3):
			if placed >= BUILDINGS:
				break
			for corner: Vector2i in [
				Vector2i(i, -ring), Vector2i(i, ring),
				Vector2i(-ring, i), Vector2i(ring, i),
			]:
				if placed >= BUILDINGS:
					break
				Sim.submit_command({
					"system": &"build", "op": "place",
					"kind": kinds[placed % kinds.size()],
					"cell": [c.x + corner.x, c.y + corner.y],
					"rot": 0, "free": true, "instant": true,
				})
				placed += 1
		ring += 3
	SimClock.advance(1)
	print("  stress city: %d placement commands submitted" % placed)


## Refill the pool to capacity every frame and keep every screen treatment lit,
## so the sample is the worst case and not an average.
func _churn() -> void:
	var c: Vector2 = Vector2(_core()) * 32.0
	for i: int in 24:
		var at: Vector2 = c + Vector2(float((i * 137) % 900) - 450.0, float((i * 271) % 700) - 350.0)
		_feel.world.dust(at, 1.0)
		_feel.world.sparks(at, 6, LcnPalette.CAUTION)
		_feel.world.ring(at, 40.0, LcnPalette.WARM_EDGE, 0.6)
		_feel.world.embers(at, 4, LcnPalette.EMBER)
		_feel.world.shards(at, 6, LcnPalette.RUST)
		_feel.world.tracer(at, at + Vector2(160.0, -90.0), LcnPalette.WARM_CORE)
		_feel.world.stamp(Rect2(at, Vector2(96.0, 96.0)), LcnPalette.WARM_CORE)
		_feel.world.flash(at, Vector2(40.0, 30.0), LcnPalette.EMBER)
		_feel.world.frost(at, 64.0, LcnPalette.ICE_BLUE)
	_feel.hover.set_hover(1, Rect2(c, Vector2(160.0, 160.0)), &"hearth", Vector2i(5, 5))
	_feel.hover.set_selection([Rect2(c + Vector2(200.0, 0.0), Vector2(128.0, 128.0))])
	_feel.screen.night_pressure = 0.9
	_feel.screen.threat_pressure = 0.8
	_feel.screen.cold_pressure = 0.7
	_feel.screen.wash(LcnPalette.DANGER, 0.5)
	_feel.screen.edge_pulse(LcnPalette.DANGER, 0.6)
	if _frame % 30 == 0:
		_feel.screen.sweep(LcnPalette.COLD_DEEP)
	SimClock.advance(1)


## Mean position of what the renderer can actually see.
func _city_centre() -> Vector2:
	var r: WorldRenderer = get_tree().get_first_node_in_group(WorldRenderer.GROUP)
	if r == null:
		return Vector2(_core()) * 32.0
	var b: Array[Dictionary] = r.world_model().buildings()
	if b.is_empty():
		return Vector2(_core()) * 32.0
	var sum := Vector2.ZERO
	for e: Dictionary in b:
		sum += e["centre"] as Vector2
	return sum / float(b.size())


func _core() -> Vector2i:
	var grid: SimSystem = Sim.get_system(&"grid")
	if grid != null and grid.has_method("core_cell"):
		return grid.call("core_cell")
	return Vector2i(128, 128)


func _finish() -> void:
	_done = true
	if _feel != null and not _process_us.is_empty():
		var s: Dictionary = _feel.stats()
		var proc_avg: float = _avg(_process_us)
		var proc_max: float = _max(_process_us)
		var draw_avg: float = _avg(_draw_us)
		var draw_max: float = _max(_draw_us)
		print("  pool          %d alive of %d, %d spawned, %d overwritten" % [
			int((s["world"] as Dictionary)["alive"]), LcnFeel.POOL,
			int((s["world"] as Dictionary)["spawned"]), int((s["world"] as Dictionary)["dropped"])])
		var idle: Dictionary = s["idle"]
		print("  idle anchors  %d (cap %d) — %d structures offered, %d survived the view cull, zoom %.2f" % [
			int(idle["anchors"]), LcnFeelIdleLife.MAX_ANCHORS,
			int(idle["seen"]), int(idle["in_view"]), float(idle["zoom"])])
		print("  view rect     %s" % String(idle["view"]))
		print("  _process      avg %6.1f us   max %6.1f us   (budget %.0f)" % [
			proc_avg, proc_max, BUDGET_PROCESS_US])
		print("  _draw         avg %6.1f us   max %6.1f us   (budget %.0f)  %s" % [
			draw_avg, draw_max, BUDGET_DRAW_US,
			"measured" if _draw_calls > 0 else "NOT MEASURED — no drawing in this environment"])
		for surface: String in ["world", "idle", "hover", "screen"]:
			var per: Array[float] = _surface_us[surface]
			print("    %-8s    avg %6.1f us   max %6.1f us" % [surface, _avg(per), _max(per)])
		print("  total         avg %6.1f us   of a 16600 us frame (%.2f%%)" % [
			proc_avg + draw_avg, (proc_avg + draw_avg) / 166.0])

		_check(int((s["world"] as Dictionary)["alive"]) <= LcnFeel.POOL,
			"the pool never exceeds its capacity")
		_check(int(idle["anchors"]) <= LcnFeelIdleLife.MAX_ANCHORS,
			"the anchor list stays capped at a %d-building city" % BUILDINGS)
		# A cap that is never reached proves nothing. This is the assertion that
		# would have caught the layer quietly drawing nothing for a whole phase.
		_check(int(idle["anchors"]) > 0,
			"and the city actually breathes (%d anchors from %d structures)" % [
				int(idle["anchors"]), int(idle["seen"])])
		_check(proc_max <= BUDGET_PROCESS_US,
			"_process stays inside %.0f us (worst frame %.1f)" % [BUDGET_PROCESS_US, proc_max])
		if _draw_calls > 0:
			_check(draw_max <= BUDGET_DRAW_US,
				"_draw stays inside %.0f us (worst frame %.1f)" % [BUDGET_DRAW_US, draw_max])
			_check(proc_avg + draw_avg <= BUDGET_TOTAL_US,
				"the whole layer stays inside %.0f us per frame" % BUDGET_TOTAL_US)
		else:
			print("  note: this environment never called _draw, so the draw budget was")
			print("        not exercised. Run this scene with a display to gate it.")
	elif _failures.is_empty():
		_failures.append("no frames were sampled")

	print("──────────────────────────────────────────────────────────────────────")
	if _failures.is_empty():
		print(" feel perf  %d checks passed" % _checks)
		print("TESTS PASSED")
		get_tree().quit(0)
		return
	for f: String in _failures:
		print("  FAILED: %s" % f)
	print(" feel perf  %d checks, %d failed" % [_checks, _failures.size()])
	print("TESTS FAILED")
	get_tree().quit(1)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ✓ %s" % what)
		return
	_failures.append(what)
	print("  ✗ %s" % what)


func _avg(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var sum: float = 0.0
	for v: float in a:
		sum += v
	return sum / float(a.size())


func _max(a: Array[float]) -> float:
	var m: float = 0.0
	for v: float in a:
		m = maxf(m, v)
	return m
