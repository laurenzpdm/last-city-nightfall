extends Node
## [D2] THE BELT GALLERY — proof, in real pixels, that the factory is visible.
##
##   godot --headless --path . res://tests/items_view/item_frames.tscn -- --force-ui
##   godot            --path . res://tests/items_view/item_frames.tscn   # + PNGs
##
## A SCENE, not a `--script` entry point: a script run with `--script` compiles
## before the autoloads exist, prints nothing and exits 0 — the silent false
## green ARCHITECTURE.md §6.1 exists to stop.
##
## WHY THIS SUITE IS SHAPED THE WAY IT IS. This project has been burned three
## times by a test that could not fail: a sprite suite that read its own cache,
## a gallery that compared an anchor list nobody rebuilt, a reachability suite
## green in the one configuration the gate used. So the central assertion here
## is not "the layer says it drew 40 items". It is:
##
##   render the same frame twice with the item layer VISIBLE   -> noise
##   render it once with the item layer HIDDEN                 -> signal
##   assert signal is several times noise, inside the belt tiles only
##
## Nothing but real drawn pixels moves that number. Deleting the body of
## `LcnItemLayer._draw()` takes the signal to the noise floor and this goes red;
## the noise control is measured every run rather than assumed, so weather and
## the light rig cannot fake a pass either.
##
## The factory below is built to produce all four flow states ON PURPOSE —
## a jammed dead end, a compressed line delivering into a crate, a trickle and
## an empty run — because "a saturated belt and a backed-up belt must look
## different at a glance" is not testable on a scenario where every belt is
## starved. Every line is laid with the same {system: logistics} commands a
## player's drag emits.

const OUT_DIR: String = "res://artifacts/d2_belt_gallery"
const SEED: int = 7
## Where belt_by_hand.json lays its reference factory on seed 7 — coordinates
## read off a buildability map rather than guessed. The rows below are searched
## downward from here for ground that will take a line.
const ORIGIN: Vector2i = Vector2i(108, 133)
const LINE_LEN: int = 11
## Ticks each line is fed for before anything is photographed. The segment rate
## is an EMA with a 0.05 coefficient — a one-second time constant — so a line
## has to be fed for a couple of seconds before "is it moving" is a real answer.
const WARMUP: int = 220
## Belt tiles' worth of stress used to measure the draw cost. 8 items per tile.
const STRESS_LINES: int = 12
const STRESS_LEN: int = 20
const PERF_FRAMES: int = 90

var _headless: bool = true
var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _shots: int = 0
var _root: LcnItemFlowRoot = null
var _camera: GameCamera = null
var _logi: Object = null
var _lines: Dictionary[String, Array] = {}
var _states_seen: Dictionary[int, bool] = {}
var _perf: Dictionary = {}


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	LcnLayers.force_install = true
	Settings.gameplay["edge_scroll"] = false
	_run.call_deferred()


func _run() -> void:
	Log.min_level = Log.Level.INFO
	print("── belt gallery [D2] ─────────────────────────────────────────────────")
	print("  display: %s" % ("headless" if _headless else DisplayServer.get_name()))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	await _session()
	if _root == null:
		_fail("the item layer did not install — nothing below can be tested")
		_finish()
		return

	await _build_factory()
	await _beat_states()
	await _beat_items_are_really_drawn()
	await _beat_belts_are_really_drawn()
	await _beat_arms_swing()
	await _beat_zoom()
	await _beat_perf()
	_finish()


# ------------------------------------------------------------------ session --

func _session() -> void:
	Sim.create_world(SEED)
	SimClock.set_manual(true)
	if LcnViewBootstrap.install() == null:
		_fail("[P13]'s renderer did not install")
	if GameCamera.current() == null:
		_camera = GameCamera.new()
		_camera.name = "GameCamera"
		add_child(_camera)
	else:
		_camera = GameCamera.current()
	LcnItemsBootstrap.reset_for_tests()
	_root = LcnItemsBootstrap.install()
	await _render(2)
	if _root == null:
		return
	_check(_root.is_inside_tree(), "the item layer is in the scene tree")
	_check(_root.items.is_inside_tree(), "the item surface is in the tree")
	_check(_root.belts.is_inside_tree(), "the belt-state surface is in the tree")
	_check(_root.machines.is_inside_tree(), "the machine surface is in the tree")
	_logi = Sim.get_system(&"logistics")
	_check(_logi != null, "the logistics system is present")


## Four lines, each deliberately put into one of the four states.
func _build_factory() -> void:
	if _logi == null:
		return
	# Aim first. The sample is culled to the visible rect, so a camera still
	# parked at the origin would produce a factory with no items in it — which
	# is exactly the bug the first run of this suite found in the root node.
	_look_at_factory(0.95)
	var y: int = ORIGIN.y
	for spec: Array in [["jam", false], ["saturated", true], ["flowing", true], ["starved", true]]:
		var row: int = _free_row(y)
		if row < 0:
			_fail("no buildable row for the '%s' line" % String(spec[0]))
			return
		_lay(row, bool(spec[1]))
		_lines[String(spec[0])] = [row]
		y = row + 2
	SimClock.advance(2)

	# Feed them differently. This is the whole point of the suite: the same belt
	# in four supply conditions has to look like four different things.
	for t: int in WARMUP:
		_feed("jam", 8)
		_feed("saturated", 8)
		if t % 6 == 0:
			_feed("flowing", 1)
		if t == 0:
			_feed("starved", 2)
		SimClock.advance(1)
		# A frame every so often, so the view samples a moving factory rather
		# than only its final state.
		if t % 40 == 0:
			await get_tree().process_frame
	await _render(3)


## Lays one belt run left to right, with a crate at the end unless `dead_end`.
func _lay(row: int, sink: bool) -> void:
	Sim.submit_command({"system": &"logistics", "op": "place_line", "kind": &"belt_mk1",
		"from": [ORIGIN.x, row], "to": [ORIGIN.x + LINE_LEN - 1, row], "rot": 0, "free": true})
	if sink:
		Sim.submit_command({"system": &"logistics", "op": "place", "kind": &"crate",
			"cell": [ORIGIN.x + LINE_LEN, row], "free": true})


func _feed(line: String, count: int) -> void:
	if not _lines.has(line):
		return
	var row: int = int(_lines[line][0])
	Sim.submit_command({"system": &"logistics", "op": "insert",
		"cell": [ORIGIN.x, row], "item": &"copper_ore", "count": count})


## First row at or below `from` where the whole run and its crate will stand.
func _free_row(from: int) -> int:
	for y: int in range(from, from + 24):
		var ok: bool = true
		for x: int in range(ORIGIN.x, ORIGIN.x + LINE_LEN + 1):
			var check: Dictionary = _logi.call("can_place", &"belt_mk1", Vector2i(x, y), 0)
			if not bool(check["ok"]):
				ok = false
				break
		if ok:
			return y
	return -1


# -------------------------------------------------------------------- beats --

## All four states, at once, on four belts a player can see side by side.
func _beat_states() -> void:
	_look_at_factory(0.95)
	await _render(4)
	var seen: Dictionary[int, int] = {}
	for b: Dictionary in _root.read.belts:
		var s: int = int(b["state"])
		seen[s] = int(seen.get(s, 0)) + 1
		_states_seen[s] = true
	for s2: int in [LcnItemFlowRead.Flow.STARVED, LcnItemFlowRead.Flow.FLOWING,
			LcnItemFlowRead.Flow.SATURATED, LcnItemFlowRead.Flow.BACKED_UP]:
		_check(seen.has(s2), "a %s belt exists to be drawn (%d tile(s))" % [
			String(LcnItemFlowRead.FLOW_NAMES[s2]), int(seen.get(s2, 0))])
	# Four states that look the same are one state with four names.
	var cols: Array[Color] = []
	for s3: int in 4:
		cols.append(LcnBeltFlowLayer.state_color(s3))
	var distinct: bool = true
	for i: int in 4:
		for j: int in range(i + 1, 4):
			if _near_color(cols[i], cols[j], 0.18):
				distinct = false
	_check(distinct, "the four flow colours are distinguishable from each other")
	_check(_root.read.items.size() > 0,
		"items_for_view() returned items to draw (%d)" % _root.read.items.size())
	await _shoot("01_four_states")


## THE CENTRAL ASSERTION. Real pixels, measured against a real noise floor.
func _beat_items_are_really_drawn() -> void:
	_look_at_factory(0.95)
	await _render(3)
	var drawn: int = _root.items.items_drawn
	_check(drawn > 0, "the item surface drew bodies this frame (%d)" % drawn)
	if _headless:
		# get_image() on a headless viewport returns nothing to compare.
		_check(true, "pixel proof skipped: no display (assertions above still ran)")
		return
	var rects: Array[Rect2i] = _belt_rects()
	var a: Image = await _capture()
	var b: Image = await _capture()
	var noise: int = _diff(a, b, rects)
	_root.items.visible = false
	var c: Image = await _capture()
	_root.items.visible = true
	var signal_px: int = _diff(b, c, rects)
	print("  pixels: %d changed when the items were hidden, against a %d noise floor" % [
		signal_px, noise])
	_check(signal_px > maxi(60, noise * 4),
		"hiding the items changes the frame far beyond the frame's own noise (%d vs %d)" % [
			signal_px, noise])
	_perf["item_pixels"] = signal_px
	_perf["frame_noise"] = noise


func _beat_belts_are_really_drawn() -> void:
	if _headless:
		return
	var rects: Array[Rect2i] = _belt_rects()
	var a: Image = await _capture()
	var b: Image = await _capture()
	var noise: int = _diff(a, b, rects)
	_root.belts.visible = false
	var c: Image = await _capture()
	_root.belts.visible = true
	var signal_px: int = _diff(b, c, rects)
	_check(signal_px > maxi(60, noise * 4),
		"hiding the belt-state paint changes the frame beyond its noise (%d vs %d)" % [
			signal_px, noise])
	_perf["belt_pixels"] = signal_px


## An arm that never leaves its parked angle is not swinging.
func _beat_arms_swing() -> void:
	# The reference factory has arms; this suite's four lines do not, so put one
	# in: a crate, an arm lifting out of it onto the flowing line.
	var row: int = int(_lines["flowing"][0]) if _lines.has("flowing") else ORIGIN.y
	Sim.submit_command({"system": &"logistics", "op": "place", "kind": &"crate",
		"cell": [ORIGIN.x - 2, row], "free": true})
	Sim.submit_command({"system": &"logistics", "op": "place", "kind": &"inserter_mk1",
		"cell": [ORIGIN.x - 1, row], "rot": 0, "free": true})
	SimClock.advance(2)
	Sim.submit_command({"system": &"logistics", "op": "insert",
		"cell": [ORIGIN.x - 2, row], "item": &"iron_plate", "count": 200})
	SimClock.advance(2)

	var fractions: Dictionary[int, bool] = {}
	var held_seen: bool = false
	for _i: int in 90:
		SimClock.advance(1)
		await get_tree().process_frame
		for a: Dictionary in _root.read.arms:
			var f: float = LcnMachineMotionLayer.swing_fraction(
				int(a["phase"]), float(a["timer"]), float(a["half"]), 0.0)
			fractions[int(round(f * 10.0))] = true
			if int(a["held"]) > 0:
				held_seen = true
	_check(_root.read.arms.size() > 0, "there is an arm to draw (%d)" % _root.read.arms.size())
	_check(fractions.size() >= 4,
		"the arm sweeps through the swing rather than snapping (%d distinct positions)" % fractions.size())
	_check(held_seen, "the arm is seen carrying a hand of items")
	_look_at_factory(1.4)
	await _render(3)
	_check(_root.machines.arms_drawn > 0,
		"the machine surface drew the arm (%d)" % _root.machines.arms_drawn)
	await _shoot("02_arm_and_splitter")


## The zoom contract, asserted at the thresholds rather than described.
func _beat_zoom() -> void:
	var rows: Array[Array] = [
		[1.6, "close"], [0.8, "normal"], [0.42, "far"], [0.24, "strategic"],
	]
	var last_radius: float = 0.0
	for r: Array in rows:
		var z: float = float(r[0])
		_look_at_factory(z)
		await _render(3)
		var st: Dictionary = _root.stats()
		print("  zoom %.2f -> band %d, fade %.2f, %d item(s), %d belt tile(s)" % [
			float(st["zoom"]), int(st["band"]), float(st["item_fade"]),
			int(st["items_drawn"]), int(st["belts_drawn"])])
		if z >= 0.6:
			_check(int(st["items_drawn"]) > 0, "items are drawn at %s zoom" % String(r[1]))
		# A body must never shrink below legibility as the camera pulls out.
		var radius_px: float = _root.items.body_radius() * float(st["zoom"])
		if int(st["items_drawn"]) > 0:
			_check(radius_px >= LcnItemLayer.MIN_SCREEN_RADIUS - 0.01,
				"an item body stays at least %.2f screen px at %s (%.2f)" % [
					LcnItemLayer.MIN_SCREEN_RADIUS, String(r[1]), radius_px])
		if z <= 0.25:
			_check(float(st["item_fade"]) <= 0.001,
				"individual items are gone at strategic zoom")
			_check(int(st["items_drawn"]) == 0, "and none are drawn")
			_check(int(st["belts_drawn"]) > 0,
				"but the flow ribbons still are (%d)" % int(st["belts_drawn"]))
		last_radius = radius_px
		await _shoot("03_zoom_%s" % String(r[1]))
	_check(last_radius > 0.0, "the zoom sweep reached strategic")


## The number the mandate asks for: what it costs to draw a full factory.
func _beat_perf() -> void:
	var built: int = _build_stress()
	_look_at_factory(0.62)
	await _render(6)
	var items_in_flight: int = _root.read.items.size()
	var draw_total: int = 0
	var item_draw: int = 0
	var frames: int = 0
	for _i: int in PERF_FRAMES:
		SimClock.advance(1)
		await get_tree().process_frame
		if _root.items.items_drawn <= 0:
			continue
		draw_total += int(_root.stats()["draw_us"])
		item_draw += _root.items.draw_us
		frames += 1
	frames = maxi(frames, 1)
	_perf["stress_tiles"] = built
	_perf["items_in_flight"] = items_in_flight
	_perf["items_drawn"] = _root.items.items_drawn
	_perf["draw_us_all"] = int(draw_total / frames)
	_perf["draw_us_items"] = int(item_draw / frames)
	_perf["read_us"] = _root.read.read_us
	print("  DRAW COST: %d items in flight, %d drawn — items %d us, all three surfaces %d us, read %d us/tick" % [
		items_in_flight, int(_perf["items_drawn"]), int(_perf["draw_us_items"]),
		int(_perf["draw_us_all"]), int(_perf["read_us"])])
	_check(items_in_flight >= 1000,
		"the stress really put a factory's worth of items in flight (%d)" % items_in_flight)
	# Not a gate on a number the integrator has not measured alone — this only
	# catches a collapse into per-item draw calls, which is two orders out.
	_check(int(_perf["draw_us_items"]) < 60000,
		"drawing them is a batched cost, not a per-item one (%d us)" % int(_perf["draw_us_items"]))
	await _shoot("04_stress")


## Packs belts until there are well over a thousand items on them.
func _build_stress() -> int:
	var y: int = ORIGIN.y + 14
	var laid: int = 0
	var rows: Array[int] = []
	for _i: int in STRESS_LINES:
		var row: int = _free_row(y)
		if row < 0:
			break
		Sim.submit_command({"system": &"logistics", "op": "place_line", "kind": &"belt_mk1",
			"from": [ORIGIN.x, row], "to": [ORIGIN.x + STRESS_LEN - 1, row], "rot": 0,
			"free": true})
		rows.append(row)
		laid += STRESS_LEN
		y = row + 2
	SimClock.advance(2)
	# Every tile of every line, several times: a dead-ended run packs solid.
	var kinds: Array[StringName] = [&"copper_ore", &"iron_plate", &"coal", &"gear", &"ammo_shell"]
	for pass_i: int in 6:
		for i: int in rows.size():
			for x: int in range(ORIGIN.x, ORIGIN.x + STRESS_LEN):
				Sim.submit_command({"system": &"logistics", "op": "insert",
					"cell": [x, rows[i]], "item": kinds[(i + pass_i) % kinds.size()],
					"count": 8})
		SimClock.advance(1)
	SimClock.advance(20)
	return laid


# ------------------------------------------------------------------ helpers --

func _look_at_factory(zoom_level: float) -> void:
	if _camera == null:
		return
	var rows: Array = _lines.values()
	var mid_y: float = float(ORIGIN.y + 6)
	if not rows.is_empty():
		mid_y = float(int(rows[rows.size() / 2][0]))
	var centre := Vector2(float(ORIGIN.x + LINE_LEN / 2) * 32.0 + 16.0, mid_y * 32.0 + 16.0)
	_camera.set_zoom_level(zoom_level, false)
	_camera.focus_on(centre, true)


## Screen rectangles of every belt tile this suite laid. The pixel comparison
## looks only here, so weather over the rest of the map cannot drown the signal.
func _belt_rects() -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	var xf: Transform2D = get_viewport().get_canvas_transform()
	for b: Dictionary in _root.read.belts:
		var cell: Vector2i = b["cell_v"]
		var a: Vector2 = xf * (Vector2(cell) * 32.0)
		var c: Vector2 = xf * (Vector2(cell + Vector2i.ONE) * 32.0)
		var r := Rect2i(Vector2i(a.floor()), Vector2i((c - a).ceil()))
		if r.size.x > 0 and r.size.y > 0:
			out.append(r)
	return out


func _capture() -> Image:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


## Pixels differing by more than a threshold, inside the given rectangles only.
func _diff(a: Image, b: Image, rects: Array[Rect2i]) -> int:
	if a == null or b == null or a.get_size() != b.get_size():
		return 0
	var bounds := Rect2i(Vector2i.ZERO, a.get_size())
	var n: int = 0
	for r: Rect2i in rects:
		var clipped: Rect2i = r.intersection(bounds)
		for y: int in range(clipped.position.y, clipped.end.y):
			for x: int in range(clipped.position.x, clipped.end.x):
				var ca: Color = a.get_pixel(x, y)
				var cb: Color = b.get_pixel(x, y)
				if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.09:
					n += 1
	return n


func _near_color(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) < tol


## Frames WITHOUT advancing the simulation, so a pixel comparison is not also
## comparing two different ticks of the world.
func _render(n: int) -> void:
	for _i: int in n:
		await get_tree().process_frame


func _shoot(shot_name: String) -> void:
	if _headless:
		return
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name]))
	_shots += 1


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ✓ %s" % what)
		return
	_failures.append(what)
	print("  ✗ %s" % what)


func _fail(what: String) -> void:
	_checks += 1
	_failures.append(what)
	print("  ✗ %s" % what)


func _finish() -> void:
	print("──────────────────────────────────────────────────────────────────────")
	if _root != null:
		print("  %s" % _root.read.summary())
		print("  stats: %s" % JSON.stringify(_root.stats()))
	if not _perf.is_empty():
		print("  perf: %s" % JSON.stringify(_perf))
	if not _headless:
		print("  %d shot(s) in %s" % [_shots, OUT_DIR])
	if _failures.is_empty():
		print(" belt gallery  %d checks passed" % _checks)
		print("TESTS PASSED")
		get_tree().quit(0)
		return
	for f: String in _failures:
		print("  FAILED: %s" % f)
	print(" belt gallery  %d checks, %d failed" % [_checks, _failures.size()])
	print("TESTS FAILED")
	get_tree().quit(1)
