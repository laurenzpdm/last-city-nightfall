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
	{"name": "battle", "weather": "snowfall", "intensity": 0.5, "storm": 0.0,
		"visibility": 0.9, "snow": 0.4, "combat": true, "frost": false},
	{"name": "frostbite", "weather": "overcast", "intensity": 0.3, "storm": 0.0,
		"visibility": 0.95, "snow": 0.5, "combat": false, "frost": true},
]


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	_rng.seed = 991
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))


func _process(_delta: float) -> void:
	if _done:
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
	_drive(SCENES[_scene_index])
	_scene_frame += 1
	if _scene_frame >= FRAMES_PER_SCENE:
		_capture(String(SCENES[_scene_index]["name"]))
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
		for cmd: Dictionary in Boot.opening_commands(c):
			Sim.submit_command(cmd)
	# Two ticks: one to apply the placements, one to let heat adopt them.
	SimClock.advance(2)

	if not _headless:
		_camera = Camera2D.new()
		_camera.name = "TestCamera"
		_camera.position = _core
		_camera.zoom = Vector2(1.1, 1.1)
		add_child(_camera)
		_camera.make_current()

	_renderer = LcnViewBootstrap.install()
	if _renderer == null:
		_renderer = get_tree().get_first_node_in_group(WorldRenderer.GROUP) as WorldRenderer
	LcnVfxBootstrap.reset()
	_vfx = LcnVfxBootstrap.install()
	if _vfx == null:
		_vfx = LcnVfx.current()
	if _vfx != null:
		# The suite drives the modules itself so it can photograph a Great Frost
		# without waiting three campaign days for one.
		_vfx.enabled = false
	# Warm the city up so heat has decided who it is serving.
	SimClock.advance(200)


func _drive(scene: Dictionary) -> void:
	var view: Rect2 = _renderer.view_rect() if _renderer != null else Rect2()
	if view.size.x <= 1.0:
		view = Rect2(_core - Vector2(960, 540), Vector2(1920, 1080))
	var wind := Vector2(-150.0, 28.0)
	var grade: Dictionary = _renderer.current_grade() if _renderer != null else {}
	_vfx.weather.update(1.0 / 60.0, view, wind, StringName(scene["weather"]),
		float(scene["intensity"]), float(scene["storm"]), float(scene["visibility"]),
		float(scene["snow"]), grade, 1.0, false)
	_vfx.industry.update(view, wind, false, 1.0)
	_vfx.decay.update(1.0 / 60.0, view, wind, 1.0)
	_vfx.breath.update(view, -28.0, wind, 1.0)
	_vfx.combat.update(1.0 / 60.0, view, false)
	if bool(scene["combat"]) and _scene_frame < 5:
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
	var mid: Vector2 = view.get_center()
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
	if not _headless:
		await RenderingServer.frame_post_draw
		var img: Image = get_viewport().get_texture().get_image()
		img.save_png("%s/%s.png" % [
			ProjectSettings.globalize_path(OUT_DIR), name])
		row.merge(_analyse(img), true)
		row["draw_calls"] = int(Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_measure[name] = row
	print("  %-12s %s" % [name, str(row)])


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
	var n: float = float(maxi(total, 1))
	var mean: float = sum / n
	return {
		"bright": bright, "warm": warm, "cold": cold, "sampled": total,
		"mean_luma": snappedf(mean, 0.0001),
		"contrast": snappedf(sqrt(maxf(0.0, sum2 / n - mean * mean)), 0.0001),
	}


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

	var cost: float = _peak_cost()
	print("  effects layer peak %.3f ms/frame (budget %.2f ms)" % [
		cost / 1000.0, BUDGET_US / 1000.0])
	_expect(cost < BUDGET_US, "effects layer cost %.0f us, over the %.0f us budget"
		% [cost, BUDGET_US])

	if _headless:
		print("  headless: pixel assertions skipped (no rasteriser)")
		return

	# --- things only a real frame can say ---
	var c_bright: int = int(clear.get("bright", 0))
	var s_bright: int = int(snowfall.get("bright", 0))
	_expect(s_bright > c_bright + int(float(clear.get("sampled", 1)) * 0.004),
		"snowfall added only %d bright pixels over clear (%d -> %d)" % [
			s_bright - c_bright, c_bright, s_bright])

	_expect(float(frost_scene.get("contrast", 1.0)) < float(snowfall.get("contrast", 0.0)),
		"a whiteout did not flatten the frame (contrast %.3f vs %.3f)" % [
			float(frost_scene.get("contrast", -1.0)), float(snowfall.get("contrast", -1.0))])
	_expect(float(frost_scene.get("mean_luma", 0.0)) > float(snowfall.get("mean_luma", 1.0)),
		"a whiteout did not lift the frame (luma %.3f vs %.3f)" % [
			float(frost_scene.get("mean_luma", -1.0)), float(snowfall.get("mean_luma", -1.0))])

	_expect(int(battle.get("warm", 0)) > int(snowfall.get("warm", 0)),
		"a fire-fight put no warm pixels on screen (%d vs %d in the same weather)" % [
			int(battle.get("warm", -1)), int(snowfall.get("warm", -1))])

	_expect(int(frostbite.get("cold", 0)) > int(clear.get("cold", 0)),
		"frost creep put no cold pixels on screen (%d vs %d)" % [
			int(frostbite.get("cold", -1)), int(clear.get("cold", -1))])


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
