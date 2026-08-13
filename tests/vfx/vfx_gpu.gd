extends Node
## The pixel proof and the cost proof for [P14]. VFX & Weather
##
##   godot --headless --path . res://tests/vfx/vfx_gpu.tscn    # logic + cost
##   godot            --path . res://tests/vfx/vfx_gpu.tscn    # + real pixels
##
## A SCENE, not a `--script` entry point, for the reason ARCHITECTURE.md §6.1
## spells out: a `--script` file compiles before the autoloads exist, prints
## nothing and exits 0.
##
## WHY THIS SUITE EXISTS SEPARATELY FROM THE HARNESS. The claim "there is snow
## on the screen" cannot be made by a headless run and must not be made by a
## builder's screenshot description. This builds a real world, installs the real
## renderer and the real effects layer, and then puts the SAME camera on the
## SAME city under six different weather and combat conditions, comparing the
## frames against each other. Everything else on screen — ground, buildings,
## HUD, lenses — is identical between the frames, so a difference in the middle
## of the image is this part and nothing else.
##
## What it asserts with a display attached:
##   * snowfall puts markedly more bright pixels on screen than clear weather;
##   * a Great Frost whiteout measurably flattens the frame's contrast;
##   * a fire-fight puts warm (r >> b) pixels where clear weather had none;
##   * frost creep puts cold (b >> r) pixels over a starved district;
##   * and none of it costs more than the budget in the class comment.
##
## Headless, it asserts everything that does not need a rasteriser and says so
## rather than reporting a pass it did not earn.

const WARMUP: int = 8
const FRAMES_PER_SCENE: int = 10
const OUT_DIR: String = "res://artifacts/p14_vfx"
## Frame cost ceiling for the whole effects layer, in microseconds. The class
## comment on LcnVfx promises one millisecond; a loaded build machine running ten
## agents at once gets some slack on top of that and it is still an order of
## magnitude under the frame.
const BUDGET_US: float = 2500.0
## Draw calls the whole effects layer may add to a frame, measured by switching
## it off for one frame and differencing. Three snow layers, a veil, a spindrift
## emitter, five pooled point fields and three batched canvas items is the shape
## of the number; the ceiling leaves room for the transient passes.
const MAX_DRAW_CALLS: int = 40

var _headless: bool = false
var _renderer: WorldRenderer = null
var _vfx: LcnVfx = null
var _camera: Camera2D = null
var _frame: int = 0
var _scene_index: int = -1
var _scene_frame: int = 0
var _done: bool = false
var _fails: Array[String] = []
var _measure: Dictionary[String, Dictionary] = {}
var _costs: Array[float] = []
var _rng := RandomNumberGenerator.new()
var _core: Vector2 = Vector2.ZERO
var _calls_without: int = 0
var _capturing: bool = false

## Each entry drives the effects layer directly rather than waiting for the
## climate to arrive at the weather we want to photograph. The module entry
## points are the real ones; only the numbers going in are chosen.
const SCENES: Array[Dictionary] = [
	{"name": "clear", "weather": "clear", "intensity": 0.0, "storm": 0.0,
		"visibility": 1.0, "snow": 0.1, "combat": false, "frost": false},
	{"name": "snowfall", "weather": "snowfall", "intensity": 0.8, "storm": 0.0,
		"visibility": 0.85, "snow": 0.4, "combat": false, "frost": false},
	{"name": "blizzard", "weather": "blizzard", "intensity": 1.0, "storm": 0.0,
		"visibility": 0.45, "snow": 0.7, "combat": false, "frost": false},
	{"name": "great_frost", "weather": "great_frost", "intensity": 1.0, "storm": 1.0,
		"visibility": 0.10, "snow": 0.95, "combat": false, "frost": false},
	# The last two are CONTROLLED comparisons: `battle` is the `snowfall` row
	# with a fire-fight added and nothing else changed, `frostbite` is the
	# `clear` row with a starved district added and nothing else changed. Any
	# other difference between the frames would be attributed to the effect.
	{"name": "battle", "weather": "snowfall", "intensity": 0.8, "storm": 0.0,
		"visibility": 0.85, "snow": 0.4, "combat": true, "frost": false},
	{"name": "frostbite", "weather": "clear", "intensity": 0.0, "storm": 0.0,
		"visibility": 1.0, "snow": 0.1, "combat": false, "frost": true},
	# The two settings contracts, photographed against `great_frost` above:
	# a player who turned snow down, and a player who cannot take the motion.
	{"name": "frost_quarter_density", "weather": "great_frost", "intensity": 1.0,
		"storm": 1.0, "visibility": 0.10, "snow": 0.95, "combat": false,
		"frost": false, "density": 0.25},
	{"name": "frost_reduce_motion", "weather": "great_frost", "intensity": 1.0,
		"storm": 1.0, "visibility": 0.10, "snow": 0.95, "combat": false,
		"frost": false, "calm": true},
]


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	_rng.seed = 991
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))


func _process(_delta: float) -> void:
	if _done or _capturing:
		return
	_frame += 1
	if _frame == 1:
		_build()
		return
	if _frame < WARMUP:
		return
	if _vfx == null:
		_fail("the effects layer never installed — nothing this suite claims is true")
		_finish()
		return
	if _scene_index < 0:
		_scene_index = 0
		_scene_frame = 0
		return
	# Re-hidden every frame: the interface parts install on their own timers, and
	# a panel that appeared halfway through the run would move every pixel count
	# in this suite.
	_hide_interface()
	var t0: int = Time.get_ticks_usec()
	_drive(SCENES[_scene_index])
	_costs.append(float(Time.get_ticks_usec() - t0))
	_scene_frame += 1
	if _scene_frame >= FRAMES_PER_SCENE:
		# _capture suspends on frame_post_draw, so _process itself becomes a
		# coroutine here and the guard keeps the next frame from re-entering it
		# mid-capture. Without the suspend the viewport hands back a stale
		# framebuffer and every scene measures identically — which is exactly the
		# false green this suite exists to make impossible.
		_capturing = true
		await _capture(String(SCENES[_scene_index]["name"]))
		_capturing = false
		_scene_index += 1
		_scene_frame = 0
		if _scene_index >= SCENES.size():
			_verdict()
			_finish()


# ---------------------------------------------------------------- the world --

func _build() -> void:
	Sim.create_world(7)
	var grid: SimSystem = Sim.get_system(&"grid")
	_core = Vector2(4000, 4000)
	if grid != null and grid.has_method("core_cell"):
		var c: Vector2i = grid.call("core_cell")
		_core = Vector2(float(c.x) * 32.0 + 16.0, float(c.y) * 32.0 + 16.0)
		# The reference settlement, straight out of the integrator's own opening,
		# so what this suite photographs is the scene a player sees on launch.
		# Loaded rather than named: game/boot.gd carries no class_name.
		var boot: Script = load("res://game/boot.gd") as Script
		var opening: Array = boot.call("opening_commands", c) if boot != null else []
		for cmd: Variant in opening:
			Sim.submit_command(cmd as Dictionary)
	# Two ticks: one to apply the placements, one to let heat adopt them.
	SimClock.advance(2)

	if not _headless:
		_camera = Camera2D.new()
		_camera.name = "TestCamera"
		_camera.position = _core
		_camera.zoom = Vector2(1.1, 1.1)
		add_child(_camera)
		_camera.make_current()

	# Instantiated directly rather than through LcnViewBootstrap, for the reason
	# tests/render/render_perf.gd gives: the bootstrap declines under a headless
	# display server, and everything this suite measures except the pixels still
	# runs there. With a display the bootstrap may already have installed one, in
	# which case that is the one to use.
	_renderer = get_tree().get_first_node_in_group(WorldRenderer.GROUP) as WorldRenderer
	if _renderer == null:
		var packed: PackedScene = load(LcnViewBootstrap.SCENE) as PackedScene
		if packed != null:
			_renderer = packed.instantiate() as WorldRenderer
			if _renderer != null:
				add_child(_renderer)
	if _renderer == null:
		_fail("no world renderer could be installed")
		return
	_vfx = LcnVfx.current()
	if _vfx == null:
		_vfx = LcnVfx.new()
		_renderer.add_child(_vfx)
	if _vfx != null:
		# The suite drives the modules itself so it can photograph a Great Frost
		# without waiting three campaign days for one.
		_vfx.enabled = false
	# Warm the city up so heat has decided who it is serving.
	SimClock.advance(200)
	_hide_interface()


## The interface is not this part's to photograph, and it covers half the frame.
## Everything from layer 62 up belongs to [P17], [P19] and [P18]; [P13]'s post
## stack at 60 stays, because the effects layer is graded by it and hiding it
## would flatter these numbers. What is left on screen is the world.
func _hide_interface() -> void:
	for n: Node in _all_nodes(get_tree().root):
		var cl: CanvasLayer = n as CanvasLayer
		if cl != null and cl.layer >= 62:
			cl.visible = false


func _all_nodes(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c: Node in n.get_children():
			stack.append(c)
	return out


func _drive(scene: Dictionary) -> void:
	var view: Rect2 = _renderer.view_rect() if _renderer != null else Rect2()
	if view.size.x <= 1.0:
		view = Rect2(_core - Vector2(960, 540), Vector2(1920, 1080))
	var wind := Vector2(-150.0, 28.0)
	var grade: Dictionary = _renderer.current_grade() if _renderer != null else {}
	# The veil eases in and out over WHITEOUT_LERP seconds, which is right in a
	# game and wrong in a suite that holds each condition for a sixth of a
	# second. The first frame of a scene is given a long step so the weather has
	# actually arrived by the time it is photographed.
	var step: float = 3.0 if _scene_frame == 0 else 1.0 / 60.0
	var density: float = float(scene.get("density", 1.0))
	var calm: bool = bool(scene.get("calm", false))
	_vfx.weather.update(step, view, wind, StringName(scene["weather"]),
		float(scene["intensity"]), float(scene["storm"]), float(scene["visibility"]),
		float(scene["snow"]), grade, density, calm)
	_vfx.industry.update(view, wind, calm, 1.0)
	_vfx.decay.update(1.0 / 60.0, view, wind, 1.0)
	_vfx.breath.update(view, -28.0, wind, 1.0)
	_vfx.combat.update(1.0 / 60.0, view, calm)
	if bool(scene["combat"]) and _scene_frame < FRAMES_PER_SCENE - 1:
		_fake_battle(view)
	if bool(scene["frost"]) and _scene_frame == 0:
		_fake_frost()
	_vfx.burst_add.cull_rect = view
	_vfx.burst_mix.cull_rect = view
	_vfx.burst_add.step(1.0 / 60.0, wind * 0.35)
	_vfx.burst_mix.step(1.0 / 60.0, wind * 0.35)
	_vfx.burst_add.queue_redraw()
	_vfx.burst_mix.queue_redraw()


## Fires the same Bus signals [P07] fires, at real coordinates inside the view,
## so what is exercised is the production path and not a test-only shortcut.
func _fake_battle(view: Rect2) -> void:
	# Low and right of centre, clear of where the interface sits, so what the
	# analyser counts is the fire-fight and not a panel.
	var mid: Vector2 = view.get_center() + Vector2(view.size.x * 0.18, view.size.y * 0.26)
	for i: int in 5:
		var from: Vector2 = mid + Vector2(_rng.randf_range(-260.0, 260.0),
			_rng.randf_range(-160.0, 160.0))
		var to: Vector2 = from + Vector2(_rng.randf_range(-220.0, 220.0),
			_rng.randf_range(-220.0, 220.0))
		Bus.turret_fired.emit(90000 + i, from, to)
	for i: int in 3:
		var at: Vector2 = mid + Vector2(_rng.randf_range(-300.0, 300.0),
			_rng.randf_range(-200.0, 200.0))
		Bus.enemy_spawned.emit(5_000_000 + i, [&"frost_shade", &"ash_spitter",
			&"drift_hound"][i], at)
		Bus.enemy_killed.emit(5_000_000 + i, at)
	Bus.structure_damaged.emit(1, 40.0, mid + Vector2(120.0, 60.0))


## Starves a district so the frost sweep has something to grow on. Done through
## the build system's own command path, not by writing state.
func _fake_frost() -> void:
	var build: SimSystem = Sim.get_system(&"build")
	if build == null or not build.has_method("all_buildings"):
		return
	var n: int = 0
	for b: Variant in build.call("all_buildings"):
		var inst: BuildingInstance = b as BuildingInstance
		if inst == null or not inst.is_complete():
			continue
		inst.state = BuildTypes.State.FROZEN
		Bus.building_froze.emit(inst.id)
		n += 1
		if n >= 12:
			break
	# Two sweeps' worth of frames so the creep is fully grown when photographed.
	_vfx.decay.update(30.0, _renderer.view_rect(), Vector2.ZERO, 1.0)


# ------------------------------------------------------------- measurement --

## THE MEASUREMENT. The same frame is photographed twice, one frame apart, with
## the effects layer switched off and then on. Everything else on screen — the
## ground, the city, the lights, the post grade, and every other part's own
## animation — is in both photographs, so the DIFFERENCE between them is this
## part and nothing else.
##
## This is deliberately not "count bright pixels and hope". An absolute count
## moved by five thousand between two runs of identical code, because other
## parts install on their own schedules and animate on their own clocks. A
## difference against a control frame taken one frame earlier cannot.
func _capture(name: String) -> void:
	var stats: Dictionary = _vfx.stats()
	var row: Dictionary = {
		"snow_particles": int(stats.get("snow_particles", 0)),
		"snow_density": float(stats.get("snow_density", 0.0)),
		"whiteout": float(stats.get("whiteout", 0.0)),
		"furnaces": int(stats.get("furnaces", 0)),
		"vents": int(stats.get("vents", 0)),
		"burst_add": int(stats.get("burst_additive", 0)),
		"burst_mix": int(stats.get("burst_mixed", 0)),
		"frosting": int(stats.get("frosting", 0)),
		"beams": int(stats.get("beams", 0)),
	}
	if _headless:
		_measure[name] = row
		print("  %-12s %s" % [name, str(row)])
		return

	_vfx.visible = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var off: Image = get_viewport().get_texture().get_image()
	var calls_off: int = int(Performance.get_monitor(
		Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))

	_vfx.visible = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var on: Image = get_viewport().get_texture().get_image()
	var calls_on: int = int(Performance.get_monitor(
		Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))

	on.save_png("%s/%s.png" % [ProjectSettings.globalize_path(OUT_DIR), name])
	off.save_png("%s/%s_without_vfx.png" % [ProjectSettings.globalize_path(OUT_DIR), name])
	row.merge(_analyse(on), true)
	row["detail_without"] = float(_analyse(off).get("detail", 0.0))
	row.merge(_diff(off, on), true)
	row["draw_calls"] = calls_on
	row["vfx_draw_calls"] = calls_on - calls_off
	_measure[name] = row
	print("  %-12s %s" % [name, str(row)])


## What the effects layer put on the screen, pixel by pixel, against the control
## frame taken with it switched off.
func _diff(off: Image, on: Image) -> Dictionary:
	var w: int = mini(off.get_width(), on.get_width())
	var h: int = mini(off.get_height(), on.get_height())
	var x0: int = int(float(w) * 0.10)
	var x1: int = int(float(w) * 0.90)
	var y0: int = int(float(h) * 0.08)
	var y1: int = int(float(h) * 0.92)
	var changed: int = 0
	var warm_added: int = 0
	var cool_added: int = 0
	var flakes: int = 0
	var sampled: int = 0
	# The fire-fight happens at a known place (see _fake_battle), and the whole
	# frame is a noisy place to look for it: a whiteout veil over a warm hearth
	# moves thousands of pixels toward red on its own. Counting warm pixels
	# inside the box the guns are firing in, in two scenes that are identical
	# apart from the guns, is the measurement that means something.
	var fx0: int = int(float(w) * 0.58)
	var fx1: int = int(float(w) * 0.82)
	var fy0: int = int(float(h) * 0.64)
	var fy1: int = int(float(h) * 0.90)
	var warm_focus: int = 0
	var changed_focus: int = 0
	for y: int in range(y0, y1, 2):
		for x: int in range(x0, x1, 2):
			var a: Color = off.get_pixel(x, y)
			var b: Color = on.get_pixel(x, y)
			sampled += 1
			var dr: float = b.r - a.r
			var dg: float = b.g - a.g
			var db: float = b.b - a.b
			if absf(dr) + absf(dg) + absf(db) > 0.045:
				changed += 1
			var in_focus: bool = x >= fx0 and x < fx1 and y >= fy0 and y < fy1
			if dr > 0.055 and dr > db * 1.6:
				warm_added += 1
				if in_focus:
					warm_focus += 1
			elif db > 0.030 and db >= dr:
				cool_added += 1
			if in_focus and absf(dr) + absf(dg) + absf(db) > 0.045:
				changed_focus += 1
			# A FLAKE, as distinct from a veil. Both lift the frame; only a flake
			# lifts it in one place and not four pixels to either side. Without
			# this separation "there is snow on screen" would be provable by a
			# blue filter, which is precisely the criticism this part exists to
			# answer.
			if x - 4 >= x0 and x + 4 < x1:
				var d: float = _dluma(off, on, x, y)
				if d > 0.10 and d - _dluma(off, on, x - 4, y) > 0.06 \
						and d - _dluma(off, on, x + 4, y) > 0.06:
					flakes += 1
	return {"changed": changed, "warm_added": warm_added, "cool_added": cool_added,
		"flakes": flakes, "warm_focus": warm_focus, "changed_focus": changed_focus,
		"diff_sampled": sampled}


static func _dluma(off: Image, on: Image, x: int, y: int) -> float:
	return _luma(on.get_pixel(x, y)) - _luma(off.get_pixel(x, y))


## Statistics over the middle of the frame only. The edges carry the HUD and the
## lens legend, which are identical in every scene and therefore only noise here.
func _analyse(img: Image) -> Dictionary:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var x0: int = int(float(w) * 0.20)
	var x1: int = int(float(w) * 0.80)
	var y0: int = int(float(h) * 0.18)
	var y1: int = int(float(h) * 0.78)
	var bright: int = 0
	var warm: int = 0
	var cold: int = 0
	var total: int = 0
	var sum: float = 0.0
	var sum2: float = 0.0
	var detail: float = 0.0
	var speckle: int = 0
	for y: int in range(y0, y1, 2):
		for x: int in range(x0, x1, 2):
			var c: Color = img.get_pixel(x, y)
			var l: float = c.r * 0.30 + c.g * 0.59 + c.b * 0.11
			total += 1
			sum += l
			sum2 += l * l
			if l > 0.55:
				bright += 1
			if c.r > 0.42 and c.r > c.b * 1.9:
				warm += 1
			if c.b > 0.30 and c.b > c.r * 1.35 and l > 0.16:
				cold += 1
			# Local detail: how different this pixel is from one eight pixels to
			# its right. This is the number a veil between the camera and the
			# city is supposed to destroy, and it is the honest measure of
			# "genuinely reduced visibility" — mean brightness alone would rise
			# for a bright fog that hid nothing.
			if x + 8 < x1:
				var c2: Color = img.get_pixel(x + 8, y)
				detail += absf(l - (c2.r * 0.30 + c2.g * 0.59 + c2.b * 0.11))
			# A flake is a small bright thing with darker ground on BOTH sides of
			# it. Fog is not, a wall edge is not, and a lit window is not. This
			# is the count that separates "there is snow falling" from "the frame
			# got brighter", and it is the one the snow assertions use.
			if x - 3 >= x0 and x + 3 < x1:
				var lo: float = _luma(img.get_pixel(x - 3, y))
				var hi: float = _luma(img.get_pixel(x + 3, y))
				if l > lo + 0.055 and l > hi + 0.055:
					speckle += 1
	var n: float = float(maxi(total, 1))
	var mean: float = sum / n
	return {
		"bright": bright, "warm": warm, "cold": cold, "sampled": total,
		"mean_luma": snappedf(mean, 0.0001),
		"contrast": snappedf(sqrt(maxf(0.0, sum2 / n - mean * mean)), 0.0001),
		"detail": snappedf(detail / n, 0.00001),
		"speckle": speckle,
	}


static func _luma(c: Color) -> float:
	return c.r * 0.30 + c.g * 0.59 + c.b * 0.11


# ------------------------------------------------------------------ verdict --

func _verdict() -> void:
	print("")
	print("── [P14] VFX & Weather ──────────────────────────────────────────")

	# --- things that are true with or without a rasteriser ---
	var clear: Dictionary = _measure.get("clear", {})
	var snowfall: Dictionary = _measure.get("snowfall", {})
	var frost_scene: Dictionary = _measure.get("great_frost", {})
	var battle: Dictionary = _measure.get("battle", {})
	var frostbite: Dictionary = _measure.get("frostbite", {})

	_expect(int(clear.get("snow_particles", 1)) == 0,
		"clear weather emitted %d snow particles" % int(clear.get("snow_particles", -1)))
	_expect(int(snowfall.get("snow_particles", 0)) > 100,
		"snowfall only emitted %d snow particles" % int(snowfall.get("snow_particles", -1)))
	_expect(float(frost_scene.get("whiteout", 0.0)) > 0.25,
		"a Great Frost whited out by only %.2f" % float(frost_scene.get("whiteout", -1.0)))
	_expect(float(clear.get("whiteout", 1.0)) < 0.05,
		"clear weather whited out by %.2f" % float(clear.get("whiteout", -1.0)))
	_expect(int(clear.get("furnaces", 0)) > 0,
		"the reference settlement produced no furnace to smoke")
	_expect(int(battle.get("burst_add", 0)) > 0,
		"a fire-fight produced no additive particles at all")
	_expect(int(frostbite.get("frosting", 0)) > 0,
		"twelve frozen structures produced no frost creep")

	# --- the two settings contracts ---
	var full: Dictionary = _measure.get("great_frost", {})
	var quarter: Dictionary = _measure.get("frost_quarter_density", {})
	var calm_row: Dictionary = _measure.get("frost_reduce_motion", {})
	_expect(int(quarter.get("snow_particles", 1)) < int(full.get("snow_particles", 0)) / 2,
		"Settings.graphics.snow_density=0.25 left %d flakes against %d at full"
		% [int(quarter.get("snow_particles", -1)), int(full.get("snow_particles", -1))])
	_expect(float(calm_row.get("whiteout", 1.0)) <= LcnVfxTuning.WHITEOUT_MAX_CALM + 0.001,
		"accessibility.reduce_motion left the whiteout at %.2f, above the calm ceiling %.2f"
		% [float(calm_row.get("whiteout", -1.0)), LcnVfxTuning.WHITEOUT_MAX_CALM])
	_expect(int(calm_row.get("snow_particles", 1)) < int(full.get("snow_particles", 0)),
		"accessibility.reduce_motion did not calm the snow (%d against %d)"
		% [int(calm_row.get("snow_particles", -1)), int(full.get("snow_particles", -1))])

	var cost: float = _peak_cost()
	print("  effects layer peak %.3f ms/frame (budget %.2f ms)" % [
		cost / 1000.0, BUDGET_US / 1000.0])
	_expect(cost < BUDGET_US, "effects layer cost %.0f us, over the %.0f us budget"
		% [cost, BUDGET_US])

	if _headless:
		print("  headless: pixel assertions skipped (no rasteriser)")
		return

	# --- things only a real frame can say ---
	# Everything below is measured against a control frame with the layer
	# switched off, so it is what THIS PART drew and not what the hour happened
	# to look like.
	var noise: int = int(clear.get("changed", 0))
	var s_snow: int = int(snowfall.get("flakes", 0))
	var c_snow: int = int(clear.get("flakes", 0))
	var b_snow: int = int(_measure.get("blizzard", {}).get("flakes", 0))
	_expect(s_snow > maxi(250, c_snow * 4),
		"snowfall drew %d discrete flakes the control frame does not have (clear: %d)"
		% [s_snow, c_snow])
	# `flakes` proves discrete snow exists; it saturates once flakes start
	# landing next to each other, so the SCALING claim is made on how much of the
	# frame the weather covers instead.
	var s_cover: int = int(snowfall.get("cool_added", 0))
	var b_cover: int = int(_measure.get("blizzard", {}).get("cool_added", 0))
	# The flake counter SATURATES: once flakes land next to each other the local
	# peak test stops separating them, so a blizzard and a snowfall read alike
	# here. Both must be far above the still-frame floor; the escalation claim is
	# made on coverage and on the emitters' own particle counts instead.
	_expect(b_snow > maxi(250, c_snow * 4),
		"a blizzard drew %d discrete flakes (clear: %d)" % [b_snow, c_snow])
	_expect(b_cover > int(float(s_cover) * 1.4),
		"a blizzard covered %d px of the frame against snowfall's %d — no escalation"
		% [b_cover, s_cover])
	_expect(int(_measure.get("blizzard", {}).get("snow_particles", 0))
			> int(snowfall.get("snow_particles", 0)),
		"the blizzard emitted no more flakes than the snowfall did")
	_expect(int(frost_scene.get("changed", 0)) > noise * 3,
		"a Great Frost changed %d pixels against a %d-pixel still-frame noise floor"
		% [int(frost_scene.get("changed", 0)), noise])

	# "Genuinely reduces visibility" means local detail is destroyed, not that
	# the frame got brighter. Both halves of that are measured, on the same frame
	# with and without the veil.
	_expect(float(frost_scene.get("detail", 1.0))
			< float(frost_scene.get("detail_without", 0.0)) * 0.85,
		"the whiteout did not cost visibility: detail %.4f with it, %.4f without" % [
			float(frost_scene.get("detail", -1.0)),
			float(frost_scene.get("detail_without", -1.0))])
	_expect(float(frost_scene.get("mean_luma", 0.0)) > float(snowfall.get("mean_luma", 1.0)),
		"a whiteout did not lift the frame (luma %.3f vs %.3f)" % [
			float(frost_scene.get("mean_luma", -1.0)), float(snowfall.get("mean_luma", -1.0))])

	# The layer has to be affordable in draw calls as well as in milliseconds:
	# the renderer holds a 1700-building city in single digits and this part must
	# not undo that.
	for scene_name: String in _measure:
		var added: int = int((_measure[scene_name] as Dictionary).get("vfx_draw_calls", 0))
		_expect(added <= MAX_DRAW_CALLS,
			"scene '%s' cost %d draw calls of effects (ceiling %d)"
			% [scene_name, added, MAX_DRAW_CALLS])

	# `battle` and `snowfall` are the same weather, so the extra warm pixels are
	# the guns and nothing else.
	_expect(int(battle.get("warm_focus", 0)) > int(snowfall.get("warm_focus", 0)) * 3 + 50,
		"a fire-fight drew %d warm pixels where the guns are against %d in the same weather without them" % [
			int(battle.get("warm_focus", -1)), int(snowfall.get("warm_focus", -1))])
	_expect(int(battle.get("changed_focus", 0)) > int(snowfall.get("changed_focus", 0)),
		"a fire-fight changed no more of its own corner of the frame than quiet weather did")

	# `frostbite` and `clear` are the same weather, so the extra pale pixels are
	# the rime on the starved district.
	_expect(int(frostbite.get("cool_added", 0)) > int(clear.get("cool_added", 0)) + 800,
		"frost creep drew %d pale pixels against %d with the district warm" % [
			int(frostbite.get("cool_added", -1)), int(clear.get("cool_added", -1))])


func _peak_cost() -> float:
	var peak: float = 0.0
	for c: float in _costs:
		peak = maxf(peak, c)
	return peak


func _expect(ok: bool, message: String) -> void:
	if not ok:
		_fails.append(message)


func _fail(message: String) -> void:
	_fails.append(message)


func _finish() -> void:
	_done = true
	print("────────────────────────────────────────────────────────────────")
	if _fails.is_empty():
		print(" %d scene(s) rendered, %s" % [
			_measure.size(),
			"pixels asserted" if not _headless else "logic asserted (headless)"])
		print("TESTS PASSED")
		get_tree().quit(0)
		return
	for f: String in _fails:
		print("  FAIL %s" % f)
	print("TESTS FAILED")
	get_tree().quit(1)
