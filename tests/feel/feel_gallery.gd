extends Node
## THE FEEL GALLERY. [P15] — proof that the juice exists, one beat at a time.
##
##   godot --headless --path . res://tests/feel/feel_gallery.tscn   # assertions
##   godot            --path . res://tests/feel/feel_gallery.tscn   # + PNGs
##
## A SCENE, not a `--script` entry point: a script run with `--script` compiles
## before the autoloads are registered, so naming Sim or SimClock in it fails to
## compile, prints nothing and exits 0 — the silent false green ARCHITECTURE.md
## §6.1 exists to prevent.
##
## WHY THIS EXISTS. The reference harness run photographs seven ticks out of
## eleven thousand. A dust puff lives 0.32 s — six ticks — so the chance that the
## reference run catches one is close to zero, and "the placement feels good now"
## would be a claim with no evidence behind it. This drives every beat the feel
## layer knows about, against the REAL renderer, the REAL camera and the REAL
## simulation, and photographs each one two frames after it fires, when the
## effect is mid-life.
##
## It asserts headlessly too, which is what makes it a gate rather than a demo:
## every beat has to move a number in `LcnFeel.stats()`. A screenshot proves it
## looks like something; the assertion proves it happened at all.
##
## Placement and demolition go through `Sim.submit_command`, so they are the same
## code path a player's click takes. Combat and climate beats are emitted on the
## Bus directly — that is the documented contract between the simulation and the
## view, and waiting five thousand real ticks for dusk would make this suite
## useless as a gate.

const OUT_DIR: String = "res://artifacts/p15_gallery"
const SEED: int = 7
## Ticks advanced per rendered frame. World effects age on SimClock, so a beat
## photographed two frames later is 0.1 s into its life — mid-flight for a
## SETTLE, still bright for an IMPACT.
const TICKS_PER_FRAME: int = 1

var _headless: bool = true
var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _shots: int = 0
var _feel: LcnFeel = null
var _camera: GameCamera = null
var _build: SimSystem = null
var _core: Vector2i = Vector2i(128, 128)


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	# The whole view has to exist even without a display, or this suite could
	# only ever run on a developer's desk. LcnLayers is the one switch for that.
	LcnLayers.force_install = true
	# The pointer sits at (0, 0) in a windowless run, which is an edge-scroll
	# command as far as [P16] is concerned: over a hundred and fifty frames the
	# camera walks off the city and every view-culled layer correctly draws
	# nothing. Switch it off for the duration.
	Settings.gameplay["edge_scroll"] = false
	_run.call_deferred()


func _run() -> void:
	Log.min_level = Log.Level.INFO
	print("── feel gallery ──────────────────────────────────────────────────────")
	print("  display: %s" % ("headless (assertions only)" if _headless else DisplayServer.get_name()))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	await _build_session()
	if _feel == null:
		_fail("the feel layer did not install — nothing below can be tested")
		_finish()
		return

	await _beat_opening()
	await _beat_hover()
	await _beat_place()
	await _beat_complete()
	await _beat_damage()
	await _beat_demolish()
	await _beat_freeze()
	await _beat_reject()
	await _beat_nightfall()
	await _beat_assault()
	await _beat_reduce_motion()
	_finish()


# ------------------------------------------------------------------ session --

func _build_session() -> void:
	Sim.create_world(SEED)
	var renderer: WorldRenderer = LcnViewBootstrap.install()
	if renderer == null:
		_fail("[P13]'s renderer did not install")
	if GameCamera.current() == null:
		_camera = GameCamera.new()
		_camera.name = "GameCamera"
		add_child(_camera)
	else:
		_camera = GameCamera.current()
	_feel = LcnFeelBootstrap.install()
	await _frames(2)

	_build = Sim.get_system(&"build")
	var grid: SimSystem = Sim.get_system(&"grid")
	if grid != null and grid.has_method("core_cell"):
		_core = grid.call("core_cell")
	# The same opening settlement a player is handed on launch, through the same
	# command path — so what this suite photographs is what a player sees.
	for cmd: Dictionary in load("res://game/boot.gd").opening_commands(_core):
		Sim.submit_command(cmd)
	SimClock.advance(2)
	if _camera != null:
		# Aimed ABOVE the city on purpose, so the settlement sits in the lower
		# half of the frame and [P22]'s day-one chapter card — which opens on
		# every real session and is centred — does not stand between the camera
		# and the thing being photographed.
		_recentre()
	await _frames(3)
	_check(_feel.is_inside_tree(), "the feel layer is in the scene tree")
	_check(_feel.world.is_inside_tree(), "the world FX surface is in the tree")
	_check(_feel.screen.is_inside_tree(), "the screen FX surface is in the tree")


# -------------------------------------------------------------------- beats --

## Nothing has happened. What the player should still see is a city that is
## alive: warmth breathing, pipes pulsing.
func _beat_opening() -> void:
	await _frames(6)
	var s: Dictionary = _feel.stats()
	_check(int((s["idle"] as Dictionary)["anchors"]) > 0,
		"the settled city has breathing anchors (%d)" % int((s["idle"] as Dictionary)["anchors"]))
	await _shoot("01_idle_life")


func _beat_hover() -> void:
	var cell: Vector2i = _core + Vector2i(-1, -1)   # the hearth
	# Through the real API, not by poking the surface: LcnFeel drives hover from
	# the cursor every frame and would overwrite anything set behind its back —
	# which is exactly the bug this call caught the first time it was written.
	_feel.focus_structure(_first_building_id())
	_feel.hover.set_ground(cell, true)
	await _frames(3)
	_check(_feel.hover.hover_lift_px > 0.5,
		"the hovered structure lifted (%.2f px)" % _feel.hover.hover_lift_px)
	await _shoot("02_hover_lift")
	# and a selection on top of it
	_feel.hover.set_selection([Rect2(Vector2(_core + Vector2i(3, 1)) * 32.0,
		Vector2(4.0, 4.0) * 32.0)])
	await _frames(4)
	_check(int((_feel.stats()["hover"] as Dictionary)["selected"]) == 1, "a selection is drawn")
	await _shoot("03_selection")
	_feel.hover.set_selection([])
	_feel.focus_structure(-1)


func _beat_place() -> void:
	var before: int = _feel.world.pool.spawned
	Sim.submit_command({"system": &"build", "op": "place", "kind": "warmth_radiator",
		"cell": [_core.x + 6, _core.y - 4], "rot": 0, "free": true, "instant": true})
	SimClock.advance(1)
	await _frames(2)
	_check(_feel.world.pool.spawned > before,
		"placing a building spawned effects (%d)" % (_feel.world.pool.spawned - before))
	_check(_feel.world.pool.count() > 0, "and they are alive on the frame after the click")
	await _shoot("04_placement_stamp")


func _beat_complete() -> void:
	var id: int = _first_building_id()
	var before: int = _feel.world.pool.spawned
	Bus.building_state_changed.emit(id, LcnWorldModel.BUILD_OPERATIONAL)
	await _frames(2)
	_check(_feel.world.pool.spawned > before, "construction completing lands with weight")
	await _shoot("05_completion")


func _beat_damage() -> void:
	var at: Vector2 = Vector2(_core + Vector2i(5, 3)) * 32.0
	var trauma_before: float = _camera.shake_trauma()
	Bus.structure_damaged.emit(_first_building_id(), 60.0, at)
	await _frames(1)
	_check(_camera.shake_trauma() > trauma_before, "a heavy hit shakes the camera")
	_check(_feel.stats()["beat"] == "hit", "and reports itself as a hit beat")
	await _frames(1)
	await _shoot("06_damage")


func _beat_demolish() -> void:
	var before: int = _feel.world.pool.spawned
	var cell: Vector2i = _core + Vector2i(6, -4)
	var b: Object = _build.call("building_at", cell) if _build != null else null
	if b != null:
		Sim.submit_command({"system": &"build", "op": "remove", "id": int(b.get("id")),
			"instant": true})
		SimClock.advance(1)
	else:
		Bus.building_removed.emit(-1, cell)
	await _frames(2)
	_check(_feel.world.pool.spawned > before, "demolition throws debris")
	await _shoot("07_demolition")


func _beat_freeze() -> void:
	Bus.building_froze.emit(_first_building_id())
	await _frames(2)
	_check(float((_feel.stats()["screen"] as Dictionary)["edge"]) > 0.0,
		"freezing pushes cold in from the edges of the frame")
	await _shoot("08_freeze")


func _beat_reject() -> void:
	var before: int = _feel.world.pool.spawned
	Bus.placement_rejected.emit(_core + Vector2i(-2, -2), "occupied")
	await _frames(1)
	_check(_feel.world.pool.spawned > before, "a refused placement is felt, not swallowed")
	await _shoot("09_rejected")


## The one the whole build is named after — and the one beat this suite refuses
## to fake. The world is RUN forward until [P09]'s climate says the night has
## started, so what is photographed is the real hour arriving, not a signal
## emitted by a test. Roughly six thousand ticks at 600+ ticks/s.
func _beat_nightfall() -> void:
	var arrived: Array[bool] = [false]
	var on_night: Callable = func(_day: int) -> void: arrived[0] = true
	Bus.night_started.connect(on_night)
	var spent: int = 0
	while not arrived[0] and spent < 12000:
		SimClock.advance(200)
		spent += 200
	Bus.night_started.disconnect(on_night)
	_check(arrived[0], "the climate reached nightfall on its own (%d ticks)" % spent)
	if not arrived[0]:
		Bus.night_started.emit(1)
	await _frames(2)
	_check(_feel.nightfall_progress() > 0.0,
		"nightfall is under way (%.2f)" % _feel.nightfall_progress())
	_check(float((_feel.stats()["screen"] as Dictionary)["sweep"]) > 0.0,
		"and the sweep is crossing the frame")
	# Photographed mid-travel, not on the frame it fired: the band starts above
	# the frame, so a shot two frames in photographs an empty sky and proves
	# nothing. 40 frames is roughly a quarter of the way across at 60 Hz.
	await _frames(40)
	_check(float((_feel.stats()["screen"] as Dictionary)["sweep"]) > 0.0,
		"and it is still crossing it when the shutter opens")
	await _shoot("10_nightfall_sweep")
	# Long enough for the continuous night pressure to ease in behind the sweep:
	# the sweep is the event, the vignette is the hour, and the second shot is
	# there to prove the hour outlives the event.
	await _frames(90)
	_check(_feel.night_pressure() > 0.3,
		"and the night keeps its pressure on the frame afterwards (%.2f)" % _feel.night_pressure())
	await _shoot("11_night_pressure")


func _beat_assault() -> void:
	Bus.wave_started.emit(1, 0.7)
	var muzzle: Vector2 = Vector2(_core + Vector2i(14, 9)) * 32.0
	for i: int in 4:
		Bus.turret_fired.emit(i, muzzle, muzzle + Vector2(180.0, -60.0 * float(i)))
		Bus.enemy_killed.emit(5000 + i, muzzle + Vector2(200.0, -40.0 * float(i)))
		SimClock.advance(2)
	await _frames(2)
	_check(_feel.threat_pressure() > 0.0,
		"a wave puts pressure on the frame (%.2f)" % _feel.threat_pressure())
	await _shoot("12_assault")


## Reduced motion is not a footnote. Every decorative effect has to be gone and
## the layer still has to be alive and drawing the informative parts.
func _beat_reduce_motion() -> void:
	var saved: bool = bool(Settings.accessibility.get("reduce_motion", false))
	# By this point the world has run into a real night and most of the city has
	# frozen, and a frozen structure legitimately stops breathing — so put one
	# warm, working thing back on the map, or this beat would assert that nothing
	# equals nothing.
	Sim.submit_command({"system": &"build", "op": "place", "kind": "coal_generator",
		# Above the core, because the camera is aimed above the city and a
		# structure placed below it would sit outside the frame — which looks
		# exactly like a layer that stopped working.
		"cell": [_core.x - 8, _core.y - 7], "rot": 0, "free": true, "instant": true})
	SimClock.advance(2)
	# Counted BEFORE the toggle. By this point the world has run into a real
	# night and part of the city has frozen, and a frozen structure legitimately
	# stops breathing — so the honest assertion is that reduce motion changes
	# nothing about WHAT is lit, only about whether it moves.
	var anchors_before: int = int((_feel.stats()["idle"] as Dictionary)["anchors"])
	Settings.accessibility["reduce_motion"] = true
	_feel.world.pool.clear()
	Bus.night_started.emit(2)
	Bus.structure_damaged.emit(_first_building_id(), 60.0, Vector2(_core) * 32.0)
	await _frames(3)
	var s: Dictionary = _feel.stats()
	_check(float((s["screen"] as Dictionary)["sweep"]) == 0.0,
		"reduce motion: no screen sweep")
	_check(not bool(s["hit_stop"]), "reduce motion: no hit-stop")
	# Re-frame first: 170 frames have passed since the last time anything aimed
	# the camera, and this beat is about warmth, not about where the lens is.
	_recentre()
	await _frames(35)
	var idle_before: Dictionary = _feel.stats()["idle"]
	_check(anchors_before > 0,
		"there is warmth on the map to preserve (%d anchors from %d seen, %d in view, zoom %.2f)" % [
			anchors_before, int(idle_before["seen"]), int(idle_before["in_view"]),
			float(idle_before["zoom"])])
	_check(int((s["idle"] as Dictionary)["anchors"]) == anchors_before,
		"reduce motion: the same %d anchors stay lit, they just stop moving" % anchors_before)
	await _shoot("13_reduce_motion")
	Settings.accessibility["reduce_motion"] = saved


# ------------------------------------------------------------------ plumbing --

## Puts the camera back where the gallery wants it, aimed above the settlement.
func _recentre() -> void:
	if _camera == null:
		return
	_camera.focus_on(Vector2(_core) * 32.0 + Vector2(0.0, -300.0), true)
	_camera.set_zoom_level(1.15, false)


func _first_building_id() -> int:
	if _build == null:
		return 1
	var all: Array = _build.call("all_buildings")
	return int(all[0].get("id")) if not all.is_empty() else 1


func _frames(n: int) -> void:
	for _i: int in n:
		SimClock.advance(TICKS_PER_FRAME)
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
	if _feel != null:
		var s: Dictionary = _feel.stats()
		print("  feel: %.3f ms/frame, %d events, pool %d/%d, %d anchors" % [
			float(s["frame_us"]) / 1000.0, int(s["events"]),
			int((s["world"] as Dictionary)["alive"]), LcnFeel.POOL,
			int((s["idle"] as Dictionary)["anchors"])])
	if not _headless:
		print("  %d shot(s) in %s" % [_shots, OUT_DIR])
	if _failures.is_empty():
		print(" feel gallery  %d checks passed" % _checks)
		print("TESTS PASSED")
		get_tree().quit(0)
		return
	for f: String in _failures:
		print("  FAILED: %s" % f)
	print(" feel gallery  %d checks, %d failed" % [_checks, _failures.size()])
	print("TESTS FAILED")
	get_tree().quit(1)
