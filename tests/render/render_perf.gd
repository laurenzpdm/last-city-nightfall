extends Node
## The renderer at stress-city scale. [P13]
##
##   godot --headless --path . res://tests/render/render_perf.tscn
##   godot            --path . res://tests/render/render_perf.tscn   # + GPU
##
## A SCENE, not a --script entry point: a script run with --script compiles
## before the autoloads are registered, so naming Rng or SimClock in it fails to
## compile, prints nothing and exits 0 — the silent false green ARCHITECTURE.md
## §6.1 exists to prevent.
##
## DEFECT (critic, defect 6): "entity drawing costs 36 ms of CPU for 206
## buildings, a 27 fps ceiling before the sim even runs, projecting to ~300 ms
## per frame at the 1717-building stress city."
##
## That projection is the thing to disprove, and a 206-building reference run
## cannot disprove it. This builds the stress city directly — 1700 structures
## across every archetype — drives real frames through the real renderer, and
## prints what each stage actually costs.
##
## Headless measures the CPU stages, which are the ones that scaled badly. Run it
## with a display attached and the same numbers come back with the GPU-side draw
## cost filled in as well; both are printed either way, and the gate is on the
## CPU stages so the suite means the same thing on a build machine.

const BUILDINGS: int = 1700
const WARMUP_FRAMES: int = 12
const SAMPLE_FRAMES: int = 60

## Per-frame CPU budget for the whole renderer at 1700 buildings, in
## microseconds, with headroom for a loaded build machine. The reference numbers
## on an M3 Max are collect ~1.2 ms, ground ~1.0 ms, entity draw ~4.7 ms with all
## 1581 on-screen structures drawn — against a first-pass projection of ~300 ms.
const BUDGET_TOTAL_US: float = 12000.0
const BUDGET_COLLECT_US: float = 3000.0
const BUDGET_GROUND_US: float = 2500.0

var _renderer: WorldRenderer = null
var _frame: int = 0
var _collect: Array[float] = []
var _draw: Array[float] = []
var _ground: Array[float] = []
var _headless: bool = false
var _placed: int = 0
var _centre: Vector2 = Vector2.ZERO


var _done: bool = false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"


func _process(_delta: float) -> void:
	if _done:
		return
	_frame += 1
	if _frame == 1:
		_build_world()
		return
	if _renderer == null:
		print("render perf: no renderer could be installed")
		print("TESTS FAILED")
		_finish(1)
		return
	if _frame <= WARMUP_FRAMES + 1:
		# The renderer installs its fallback camera inside its own _process, which
		# has not necessarily run when the world is built. Keep asserting the
		# framing through warm-up so the measurement really is of a full screen.
		_frame_camera()
		return
	if _frame <= WARMUP_FRAMES + 1 + SAMPLE_FRAMES:
		var es: Dictionary = _renderer.entities.stats()
		var ts: Dictionary = _renderer.terrain.stats()
		_collect.append(float(es["collect_us"]))
		_draw.append(float(es["draw_us"]))
		_ground.append(float(ts["update_us"]))
		return
	_report()


func _finish(code: int) -> void:
	_done = true
	get_tree().quit(code)


func _build_world() -> void:
	Rng.reset(11)
	SimClock.reset()
	# Instantiated directly, not through LcnViewBootstrap: the bootstrap declines
	# under a headless display server, and the CPU stages this measures are
	# exactly the ones that still run there.
	var packed: PackedScene = load(LcnViewBootstrap.SCENE) as PackedScene
	if packed == null:
		return
	_renderer = packed.instantiate() as WorldRenderer
	if _renderer == null:
		return
	get_tree().root.add_child(_renderer)
	# No simulation: this measures the RENDERER, so the world is synthetic and
	# every archetype and footprint the atlas can hold is present in it.
	var model: LcnWorldModel = _renderer.world_model()
	model.attach()
	model.drop_preview_buildings()
	var archs: Array[StringName] = LcnSpriteFactory.archetypes()
	var side: int = int(ceil(sqrt(float(BUILDINGS))))
	var id: int = 1
	for i: int in BUILDINGS:
		var arch: StringName = archs[i % archs.size()]
		var cell := Vector2i(20 + (i % side) * 3, 20 + (i / side) * 3)
		model.add_building(id, _kind_for(arch), cell)
		id += 1
		_placed += 1
	var centre := Vector2(float(20 + side * 3) * 0.5, float(20 + side * 3) * 0.5) * 32.0
	_renderer.terrain.bind_world()
	_renderer.entities.bind_field(_renderer.terrain.field)
	_centre = centre
	_frame_camera()


## Far enough out that the WHOLE stress city is on screen. A partial view would
## be measuring the culler, not the renderer.
func _frame_camera() -> void:
	var cam: Camera2D = _find_camera(get_tree().root)
	if cam == null:
		return
	cam.position = _centre
	cam.zoom = Vector2(0.30, 0.30)
	cam.force_update_scroll()


## An id that resolves back to the archetype we want, so add_building exercises
## the real archetype_for path rather than a private back door.
static func _kind_for(arch: StringName) -> StringName:
	match arch:
		&"hearth": return &"the_hearth"
		&"generator": return &"coal_generator"
		&"heat_plant": return &"geothermal_tap"
		&"radiator": return &"warmth_radiator"
		&"accumulator": return &"heat_accumulator"
		&"foundry": return &"smelter"
		&"workshop": return &"workshop"
		&"assembler": return &"assembly_hall"
		&"research_hall": return &"survey_hall"
		&"kitchen": return &"field_kitchen"
		&"habitat": return &"housing_block"
		&"greenhouse": return &"greenhouse"
		&"depot": return &"storage_yard"
		&"silo": return &"granary"
		&"mine": return &"mine_shaft"
		&"drill": return &"ore_drill"
		&"collector": return &"scrap_collector"
		&"turret": return &"turret_mount"
		&"pylon": return &"relay_pylon"
		&"watchtower": return &"watchtower"
		&"wall": return &"wall"
		&"pipe": return &"heat_pipe"
		&"belt": return &"belt_line"
		&"splitter": return &"splitter_mk1"
		&"underground": return &"underground_mk1"
		&"arm": return &"inserter_mk1"
		&"long_arm": return &"long_arm_mk1"
		&"crate": return &"crate"
		&"road": return &"rubble_road"
		&"ruin": return &"ruin_pile"
		&"dead_tree": return &"dead_tree"
		&"rock": return &"rock_outcrop"
		&"wreck": return &"wreck_hulk"
	return &"workshop"


func _find_camera(n: Node) -> Camera2D:
	for c: Node in n.get_children():
		if c is Camera2D:
			return c
		var f: Camera2D = _find_camera(c)
		if f != null:
			return f
	return null


static func _avg(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var s: float = 0.0
	for v: float in a:
		s += v
	return s / float(a.size())


static func _p95(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var c: Array[float] = a.duplicate()
	c.sort()
	return c[mini(int(float(c.size()) * 0.95), c.size() - 1)]


func _report() -> void:
	var es: Dictionary = _renderer.entities.stats()
	var ts: Dictionary = _renderer.terrain.stats()
	var collect: float = _avg(_collect)
	var draw: float = _avg(_draw)
	var ground: float = _avg(_ground)
	var total: float = collect + draw + ground
	var fails: Array[String] = []

	print("────────────────────────────────────────────────────────────────")
	print(" render perf — %d structures, %s" % [
		_placed, "headless (CPU stages only)" if _headless else "with a display"])
	print("────────────────────────────────────────────────────────────────")
	print("  visible buildings   %d" % int(es["visible_buildings"]))
	print("  atlas sprites       %d  (one texture for every entity pass)" % int(es["atlas_sprites"]))
	print("  ground field        %d KB, detail %.2f" % [int(ts["field_kb"]), float(ts["detail"])])
	print("    kind %d us  snow %d us  heat+soot %d us  city %d us  (last refresh of each)" % [
		int(ts["kind_us"]), int(ts["snow_us"]), int(ts["sources_us"]), int(ts["city_us"])])
	print("  collect             %7.0f us avg   %7.0f us p95" % [collect, _p95(_collect)])
	print("    cull %d us  heat sources %d us  light buckets %d us" % [
		int(es["cull_us"]), int(es["sources_us"]), int(es["bucket_us"])])
	print("  ground update       %7.0f us avg   %7.0f us p95" % [ground, _p95(_ground)])
	print("  entity draw         %7.0f us avg   %7.0f us p95%s" % [
		draw, _p95(_draw), "   (0 without a display)" if _headless else ""])
	print("  renderer total      %7.0f us avg" % total)
	if not _headless:
		print("  draw calls          %d" % int(Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	print("")
	print("  reference: the first pass measured 36 ms of entity draw and 797 draw")
	print("  calls at 206 buildings, and projected ~300 ms here.")

	if int(es["visible_buildings"]) < 1200:
		fails.append("only %d buildings were visible — the measurement is not of a city"
			% int(es["visible_buildings"]))
	if collect > BUDGET_COLLECT_US:
		fails.append("collect %.0f us over budget %.0f us" % [collect, BUDGET_COLLECT_US])
	if ground > BUDGET_GROUND_US:
		fails.append("ground update %.0f us over budget %.0f us" % [ground, BUDGET_GROUND_US])
	if collect + ground + (0.0 if _headless else draw) > BUDGET_TOTAL_US:
		fails.append("renderer total %.0f us over budget %.0f us" % [total, BUDGET_TOTAL_US])

	print("────────────────────────────────────────────────────────────────")
	if fails.is_empty():
		print(" %d structure(s), renderer at %.2f ms/frame — under the %.0f ms budget" % [
			_placed, total / 1000.0, BUDGET_TOTAL_US / 1000.0])
		print("TESTS PASSED")
		_finish(0)
		return
	for f: String in fails:
		print("  FAIL %s" % f)
	print("TESTS FAILED")
	_finish(1)
