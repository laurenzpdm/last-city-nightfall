class_name LcnFeel
extends Node
## The feel layer. [P15] Juice, weight, response, and the night arriving.
##
## One node. It listens to the Bus, owns four drawing surfaces, and turns
## simulated events into things a player can feel:
##
##   LcnFeelIdleLife   z -18  the city breathing while nothing happens
##   LcnFeelWorldFx    z   5  dust, sparks, rings, debris, tracers, stamps
##   LcnFeelHoverFx    z   6  the lift, the brackets, the selection
##   LcnFeelScreenFx  L  61  washes, edge pressure, the nightfall sweep
##
## plus two things that are not surfaces: camera impulses through
## GameCamera.shake, and hit-stop through Engine.time_scale.
##
## ── THE TWO CLOCKS ───────────────────────────────────────────────────────────
##
## World effects age on SimClock (they freeze when the player pauses, run triple
## at 3x). Interface response ages on unscaled frame time (hover still answers a
## paused game). Both are in LcnTiming; nothing here keeps a third clock.
##
## ── COST ─────────────────────────────────────────────────────────────────────
##
## Two budgets, because this part spends in two places:
##   * FRAME: everything drawn here is culled to the view, pooled at a fixed
##     size and capped. `stats()` reports the measured microseconds per stage
##     and `tests/feel/feel_perf.tscn` fails the build if the total drifts.
##   * TICK: every Bus handler below runs INSIDE a simulation tick, because
##     that is where the signal is emitted. The tick budget is 50 ms and heat
##     already has 86% of it, so a handler here is a bounds check and a few
##     float writes — never a lookup, never an allocation, never a redraw.
##     Anything that needs the world is resolved once on world_ready and cached.
##
## ── FOR OTHER PARTS ──────────────────────────────────────────────────────────
##
##     var feel: LcnFeel = LcnFeel.instance()
##     feel.shake(0.4, LcnTiming.SETTLE)          # an impact you own
##     feel.world.dust(pos)                       # a puff you own
##     feel.screen.wash(colour, 0.3)              # a frame you own
##     feel.nightfall_progress()                  # 0..1, for a grade or a cue
##     feel.beat.connect(...)                     # named beats, for [P23] audio
##
## The `beat` signal is deliberately on this node rather than on the Bus: the Bus
## is core-owned and one-directional sim → view, and a nightfall cue is a VIEW
## event that audio and the grade both want. Group: `lcn_feel`.

const GROUP: StringName = &"lcn_feel"
const TILE: float = 32.0

## A named feel beat, for [P13]'s grade and [P23]'s audio to hang cues on.
## `strength` is 0..1 and `at` is a world position, or Vector2.ZERO for "the frame".
signal beat(name: StringName, strength: float, at: Vector2)

## Effect pool size. 256 rows is ~14 KB and comfortably more than a busy night
## can put on screen at once.
const POOL: int = 256

## The loudest impulse any single event may request, before settings scaling.
const SHAKE_CEILING: float = 0.55
## Minimum seconds between camera impulses of the same class, so forty turrets
## firing in one tick still read as one volley.
const SHAKE_COOLDOWN: float = 0.06
## Hit-stop never lasts longer than this and never slows time further than this.
const HIT_STOP_MAX: float = 0.09
const HIT_STOP_SCALE: float = 0.28
const HIT_STOP_COOLDOWN: float = 0.6

static var _instance: LcnFeel = null

var world: LcnFeelWorldFx = null
var hover: LcnFeelHoverFx = null
var idle: LcnFeelIdleLife = null
var screen: LcnFeelScreenFx = null

var enabled: bool = true

# --- cached, resolved once on world_ready, never per event --------------------
var _renderer: WorldRenderer = null
var _camera: GameCamera = null
var _build: SimSystem = null
var _climate: SimSystem = null
var _threat: SimSystem = null
var _model: LcnWorldModel = null

# --- continuous pressures -----------------------------------------------------
var _night01: float = 0.0
var _threat01: float = 0.0
var _cold01: float = 0.0
var _nightfall := LcnImpulse.new(LcnEase.Kind.SINE_IN_OUT)

# --- rate limiting ------------------------------------------------------------
var _last_shake: float = -99.0
var _last_tracer: float = -99.0
var _last_hit_stop: float = -99.0
var _hit_stop_left: float = 0.0
var _time_scale_saved: float = 1.0
var _hover_override: int = -1
var _placements_this_tick: int = 0
var _placement_tick: int = -1

# --- diagnostics ---------------------------------------------------------------
var _disabled: Dictionary[StringName, bool] = {}
var _frames: int = 0
var _cost_us_avg: float = 0.0
var _events: int = 0
var _last_beat: StringName = &""


## The installed feel layer, or null when the view is not built (headless).
static func instance() -> LcnFeel:
	if _instance != null and is_instance_valid(_instance):
		return _instance
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	_instance = tree.get_first_node_in_group(GROUP) as LcnFeel
	return _instance


func _ready() -> void:
	name = "LcnFeel"
	add_to_group(GROUP)
	_instance = self
	# After the renderer and the camera, before the HUD reads anything: the
	# hover state has to be resolved in the same frame the cursor moved.
	process_priority = -40

	_read_disable_flags()

	idle = LcnFeelIdleLife.new()
	world = LcnFeelWorldFx.new(POOL)
	hover = LcnFeelHoverFx.new()
	screen = LcnFeelScreenFx.new()

	_attach_surfaces()
	_connect_bus()
	if Sim.alive:
		_on_world_ready()
	Log.info("feel", "installed: idle z%d, world z%d, hover z%d, screen layer %d — pool %d" % [
		LcnFeelIdleLife.Z, LcnFeelWorldFx.Z, LcnFeelHoverFx.Z,
		LcnFeelScreenFx.LAYER, POOL])


## Bisect switch. `--feel-disable=world,hover,idle,screen,process,bus` (or `all`)
## turns pieces of this layer off at launch. It exists because "the feel layer
## broke the harness" is a sentence that has to be turned into "this surface
## broke the harness" in one run rather than four edits.
func _read_disable_flags() -> void:
	for a: String in OS.get_cmdline_user_args():
		if not a.begins_with("--feel-disable="):
			continue
		for part: String in a.substr(15).split(",", false):
			_disabled[StringName(part.strip_edges())] = true
	if not _disabled.is_empty():
		var keys: Array = _disabled.keys()
		keys.sort()
		Log.warn("feel", "disabled by command line: %s" % ", ".join(PackedStringArray(
			keys.map(func(k: Variant) -> String: return String(k)))))


func _off(what: StringName) -> bool:
	return _disabled.has(&"all") or _disabled.has(what)


## World surfaces go under the renderer so the camera transform moves them and
## [P13]'s post stack grades them; the screen surface goes on this node, which
## is already in the tree, because a CanvasLayer needs no world transform.
##
## Parented to nodes that are ALREADY in the tree, never to `tree.root` from
## inside a `_ready` — that call is refused by Godot and leaves an orphan, which
## is exactly how this build lost its entire build menu for a phase.
func _attach_surfaces() -> void:
	var host: Node = get_tree().get_first_node_in_group(WorldRenderer.GROUP)
	if host == null:
		host = self
	if not _off(&"idle"):
		host.add_child(idle)
	if not _off(&"world"):
		host.add_child(world)
	if not _off(&"hover"):
		host.add_child(hover)
	if not _off(&"screen"):
		add_child(screen)
	for n: Node in [idle, world, hover, screen]:
		if n.get_parent() == null:
			continue
		if not n.is_inside_tree():
			Log.error("feel", "%s failed to enter the tree — that surface is dead" % n.name)


func _exit_tree() -> void:
	# Never leave the engine slowed down because a hit-stop was running when the
	# scene changed.
	if not is_equal_approx(Engine.time_scale, 1.0) and _hit_stop_left > 0.0:
		Engine.time_scale = _time_scale_saved
	if _instance == self:
		_instance = null


func _connect_bus() -> void:
	if _off(&"bus"):
		return
	Bus.world_ready.connect(_on_world_ready)
	Bus.building_placed.connect(_on_placed)
	Bus.building_removed.connect(_on_removed)
	Bus.building_state_changed.connect(_on_state)
	Bus.building_froze.connect(_on_froze)
	Bus.placement_rejected.connect(_on_rejected)
	Bus.structure_damaged.connect(_on_damaged)
	Bus.enemy_killed.connect(_on_enemy_killed)
	Bus.turret_fired.connect(_on_turret_fired)
	Bus.night_started.connect(_on_night)
	Bus.day_started.connect(_on_day)
	Bus.wave_incoming.connect(_on_wave_incoming)
	Bus.wave_started.connect(_on_wave_started)
	Bus.wave_cleared.connect(_on_wave_cleared)
	Bus.alert_raised.connect(_on_alert)
	Bus.law_enacted.connect(_on_law)
	Bus.research_completed.connect(_on_research)
	Bus.game_over.connect(_on_game_over)


func _on_world_ready() -> void:
	_renderer = get_tree().get_first_node_in_group(WorldRenderer.GROUP) as WorldRenderer
	_camera = GameCamera.current()
	_build = Sim.get_system(&"build")
	_climate = Sim.get_system(&"climate")
	_threat = Sim.get_system(&"threat")
	_model = _renderer.world_model() if _renderer != null else null
	if _model != null:
		idle.bind(_model)
	hover.sprites = _renderer.sprite_factory() if _renderer != null else null
	if _camera != null and not _camera.hover_cell_changed.is_connected(_on_hover_cell):
		_camera.hover_cell_changed.connect(_on_hover_cell)
		_camera.selection_changed.connect(_on_selection)


# ================================================================== the frame ==

func _process(delta: float) -> void:
	if not enabled or _off(&"process"):
		return
	var t0: int = Time.get_ticks_usec()
	_frames += 1
	var ui_dt: float = LcnTiming.advance_ui(delta / maxf(Engine.time_scale, 0.05))
	_advance_hit_stop(ui_dt)

	var view: Rect2 = _visible_rect()
	var grade: Dictionary = _renderer.current_grade() if _renderer != null else {}
	var zoom: float = _camera.zoom_level() if _camera != null else 1.0

	_update_pressures(ui_dt)
	_update_hover()

	# World effects age on SIM time; the interface ages on frame time.
	if world.is_inside_tree():
		world.refresh(LcnTiming.world_now(), view, grade, zoom)
	if idle.is_inside_tree():
		# The BREATH runs on world time (it stops when the world does); the
		# anchor REBUILD runs on interface time, or a paused or harness-driven
		# session would rebuild the list every single frame.
		idle.refresh(_sim_dt(ui_dt), ui_dt, view, grade, zoom, _night01)
	if hover.is_inside_tree():
		hover.refresh(ui_dt, grade, zoom)
	if screen.is_inside_tree():
		screen.refresh(ui_dt)

	var us: float = float(Time.get_ticks_usec() - t0)
	_cost_us_avg = _cost_us_avg * 0.92 + us * 0.08 if _frames > 1 else us
	if _frames % 240 == 0:
		_log_cost()


## What is on screen right now, in world pixels. [P16]'s camera is asked first
## because it is the authority and it is computed THIS frame; [P13]'s renderer is
## the fallback and its rect is one frame old, since this layer deliberately
## ticks before it. An empty rect means "cull nothing" downstream rather than
## "cull everything", which is the difference between a city that breathes and a
## layer that silently draws nothing.
func _visible_rect() -> Rect2:
	if _camera != null and _camera.has_method("visible_world_rect"):
		var r: Rect2 = _camera.visible_world_rect()
		if r.size.x > 1.0:
			return r
	if _renderer != null:
		return _renderer.view_rect()
	return Rect2()


## Sim seconds elapsed since the last frame, which is what the idle layer breathes
## on. Zero while paused, triple at 3x, and never a spike after a stall.
func _sim_dt(ui_dt: float) -> float:
	var speed: float = SimClock.speed if SimClock.running else 0.0
	return clampf(ui_dt * speed, 0.0, 0.2)


## Night and threat are STATES, not events, so they are read every frame from
## the simulation rather than latched from a signal. A player should feel the
## night coming for half a minute, not be told about it for one frame.
func _update_pressures(ui_dt: float) -> void:
	_nightfall.advance(ui_dt)
	var day_t: float = _model.day_fraction() if _model != null else 0.0
	# Darkness as the palette itself defines it, so the vignette and the grade
	# can never disagree about what hour it is.
	var phase: StringName = LcnPalette.phase_at(day_t)
	var dark: float = 0.0
	match phase:
		&"night": dark = 1.0
		&"dusk": dark = 0.62
		&"dawn": dark = 0.42
		&"evening": dark = 0.5
		_: dark = 0.0
	# Ease toward it rather than snapping between phases.
	_night01 = lerpf(_night01, dark, clampf(ui_dt * 1.6, 0.0, 1.0))

	var ambient: float = _model.ambient_temperature() if _model != null else 0.0
	_cold01 = LcnEase.ramp(-ambient, 18.0, 46.0, LcnEase.Kind.QUAD_IN)

	_threat01 = maxf(0.0, _threat01 - ui_dt * 0.22)
	screen.night_pressure = _night01 * 0.85 + _nightfall.value() * 0.15
	screen.threat_pressure = _threat01
	screen.cold_pressure = _cold01 * _night01


## The structure under the cursor, resolved through the build system so it is one
## lookup rather than a scan, and applied to the hover surface every frame.
func _update_hover() -> void:
	if _hover_override >= 0:
		return
	if _camera == null:
		return
	var inside: bool = _camera.is_hovering()
	var cell: Vector2i = _camera.hovered_cell()
	hover.set_ground(cell, inside)
	if not inside or _build == null:
		hover.clear_hover()
		return
	var b: Object = _build.call("building_at", cell)
	if b == null:
		hover.clear_hover()
		return
	var id: int = int(b.get("id"))
	if id == hover.hover_id:
		return
	var kind: StringName = b.get("kind")
	var origin: Vector2i = b.get("cell")
	var def: Resource = b.get("def")
	var tiles: Vector2i = Vector2i.ONE
	if def != null and typeof(def.get("size")) == TYPE_VECTOR2I:
		tiles = def.get("size")
	var rect := Rect2(Vector2(origin) * TILE, Vector2(tiles) * TILE)
	hover.set_hover(id, rect, LcnSpriteFactory.archetype_for(kind), tiles)


## Points the hover treatment at a named structure regardless of where the
## cursor is, so something other than the mouse can say "this one" — [P21]'s
## tutorial pointing at the hearth, a quest marker, an alert asking to be looked
## at. Pass -1 to hand control back to the cursor.
func focus_structure(id: int) -> void:
	_hover_override = id
	if id < 0:
		hover.clear_hover()
		return
	var b: Object = _build.call("get_building", id) if _build != null else null
	if b == null:
		_hover_override = -1
		return
	var origin: Vector2i = b.get("cell")
	var tiles: Vector2i = _tiles_of(b.get("kind"))
	hover.set_hover(id, Rect2(Vector2(origin) * TILE, Vector2(tiles) * TILE),
		LcnSpriteFactory.archetype_for(b.get("kind")), tiles)


func _on_hover_cell(cell: Vector2i, inside: bool) -> void:
	hover.set_ground(cell, inside)


func _on_selection(ids: PackedInt32Array, cell_rect: Rect2i) -> void:
	var rects: Array[Rect2] = []
	if ids.size() > 0 and _build != null:
		for id: int in ids:
			var b: Object = _build.call("get_building", id)
			if b == null:
				continue
			var origin: Vector2i = b.get("cell")
			var tiles: Vector2i = Vector2i.ONE
			var def: Resource = b.get("def")
			if def != null and typeof(def.get("size")) == TYPE_VECTOR2I:
				tiles = def.get("size")
			rects.append(Rect2(Vector2(origin) * TILE, Vector2(tiles) * TILE))
			if rects.size() >= 32:
				break
	elif cell_rect.size.x > 0:
		rects.append(Rect2(Vector2(cell_rect.position) * TILE, Vector2(cell_rect.size) * TILE))
	hover.set_selection(rects)
	if not rects.is_empty():
		_emit_beat(&"select", 0.2, rects[0].get_center())


# ============================================================ simulated events ==
#
# Everything below runs inside a simulation tick. Cheap, bounded, no allocation
# that is not a pool write.

## A structure appeared. The stamp is the confirmation, the dust is the weight,
## and the ring is the snap to the grid.
func _on_placed(_id: int, kind: StringName, cell: Vector2i) -> void:
	if not enabled:
		return
	_events += 1
	# The opening settlement drops fifteen buildings in one tick and a scenario
	# can drop a whole pipe run; past a handful in one tick the effect is noise,
	# so the rest are placed silently and only the count is felt.
	var tick: int = SimClock.tick
	if tick != _placement_tick:
		_placement_tick = tick
		_placements_this_tick = 0
	_placements_this_tick += 1
	if _placements_this_tick > 6:
		return
	var tiles: Vector2i = _tiles_of(kind)
	var rect := Rect2(Vector2(cell) * TILE, Vector2(tiles) * TILE)
	var centre: Vector2 = rect.get_center()
	world.stamp(rect, LcnPalette.WARM_CORE)
	world.dust(centre + Vector2(0.0, rect.size.y * 0.35), 0.5 + 0.1 * float(tiles.x * tiles.y))
	world.ring(centre, maxf(rect.size.x, rect.size.y) * 0.8, LcnPalette.WARM_EDGE, 0.35,
		LcnTiming.SETTLE)
	_shake(0.06 + 0.012 * float(tiles.x * tiles.y), LcnTiming.SNAP, 30.0)
	_emit_beat(&"place", 0.3, centre)


## Construction finished. This is a small triumph and gets a warmer, larger
## response than the placement did — the player waited for it.
func _on_state(id: int, state: int) -> void:
	if not enabled or state != LcnWorldModel.BUILD_OPERATIONAL:
		return
	var b: Object = _build.call("get_building", id) if _build != null else null
	if b == null:
		return
	var centre: Vector2 = b.call("world_center")
	world.ring(centre, 46.0, LcnPalette.WARM_CORE, 0.7, LcnTiming.HEAVY)
	world.flash(centre, Vector2(30.0, 22.0), Color(LcnPalette.WARM_WHITE, 0.55), LcnTiming.QUICK)
	world.embers(centre, 4, LcnPalette.EMBER, 30.0)
	_emit_beat(&"complete", 0.45, centre)


## A structure came down. Debris, a heavy puff and a real shake: demolition is
## the one thing in a city builder that has to feel like a loss.
func _on_removed(_id: int, cell: Vector2i) -> void:
	if not enabled:
		return
	var at: Vector2 = Vector2(cell) * TILE + Vector2(TILE, TILE) * 0.5
	world.shards(at, 7, LcnPalette.RUST, 130.0)
	world.dust(at, 1.0, Color(0.62, 0.63, 0.66, 0.62))
	world.ring(at, 52.0, Color(0.55, 0.52, 0.50, 0.7), 0.6, LcnTiming.HEAVY)
	_shake(0.16, LcnTiming.SETTLE, 17.0)
	_emit_beat(&"demolish", 0.5, at)


func _on_froze(id: int) -> void:
	if not enabled:
		return
	var b: Object = _build.call("get_building", id) if _build != null else null
	var at: Vector2 = b.call("world_center") if b != null else Vector2.ZERO
	world.frost(at, 64.0, Color(LcnPalette.ICE_BLUE, 0.85))
	screen.edge_pulse(Color(LcnPalette.ICE_BLUE, 0.55), 0.35, LcnTiming.HEAVY)
	_emit_beat(&"freeze", 0.5, at)


## A refusal has to be felt or the player thinks the click was dropped.
func _on_rejected(cell: Vector2i, _reason: String) -> void:
	if not enabled:
		return
	var at: Vector2 = Vector2(cell) * TILE + Vector2(TILE, TILE) * 0.5
	world.ring(at, 26.0, Color(LcnPalette.DANGER, 0.9), 0.8, LcnTiming.QUICK)
	world.flash(at, Vector2(TILE, TILE), Color(LcnPalette.DANGER, 0.30), LcnTiming.SNAP)
	_shake(0.035, LcnTiming.FLICK, 40.0)
	_emit_beat(&"deny", 0.2, at)


## Damage scales the whole response: sparks, shake, and — above the threshold —
## hit-stop. A rifle round and a collapsing wall must not feel the same.
func _on_damaged(_id: int, amount: float, pos: Vector2) -> void:
	if not enabled:
		return
	_events += 1
	var heft: float = clampf(amount / 40.0, 0.05, 1.0)
	world.sparks(pos, int(3.0 + heft * 8.0), LcnPalette.CAUTION, Vector2(0.0, -1.0), 90.0 + heft * 160.0)
	world.flash(pos, Vector2(20.0, 16.0) * (0.6 + heft), Color(LcnPalette.EMBER, 0.5 * heft),
		LcnTiming.FLICK + 0.04)
	if heft > 0.28:
		world.dust(pos, heft * 0.8, Color(0.58, 0.56, 0.55, 0.5))
		screen.wash(Color(LcnPalette.DANGER, 0.16 * heft), heft, LcnTiming.QUICK)
	_shake(0.05 + heft * 0.32, LcnTiming.SNAP + heft * 0.2, 26.0 - heft * 8.0)
	if heft > 0.75:
		_hit_stop()
	_emit_beat(&"hit", heft, pos)


func _on_enemy_killed(_id: int, pos: Vector2) -> void:
	if not enabled:
		return
	world.embers(pos, 5, LcnPalette.EMBER, 46.0)
	world.ring(pos, 22.0, Color(LcnPalette.EMBER, 0.75), 0.25, LcnTiming.QUICK)
	_emit_beat(&"kill", 0.25, pos)


## Forty turrets can fire in one tick. One tracer per 60 ms keeps a volley
## reading as a volley without turning the pool over four times a second.
func _on_turret_fired(_id: int, from: Vector2, to: Vector2) -> void:
	if not enabled:
		return
	var now: float = LcnTiming.world_now()
	if now - _last_tracer < 0.06:
		return
	_last_tracer = now
	world.tracer(from, to, Color(LcnPalette.WARM_CORE, 0.9))
	world.flash(from, Vector2(12.0, 10.0), Color(LcnPalette.WARM_WHITE, 0.75), LcnTiming.FLICK)
	_shake(0.03, LcnTiming.FLICK, 44.0)


# ---------------------------------------------------------------- the world ---

## NIGHTFALL. The one moment the whole build is named after, and it gets the
## full vocabulary: a sweep across the frame on SINE_IN_OUT (the night does not
## arrive at constant speed), a long cold vignette that stays, and a low slow
## camera rumble that reads as the temperature dropping rather than as an impact.
func _on_night(day: int) -> void:
	if not enabled:
		return
	_nightfall.kick(1.0, LcnTiming.EVENT, LcnEase.Kind.SINE_IN_OUT)
	screen.sweep(Color(LcnPalette.COLD_DEEP, 0.92), LcnTiming.EVENT, true)
	screen.edge_pulse(Color(LcnPalette.COLD_HIGH, 0.7), 0.85, LcnTiming.EVENT)
	# 8 Hz, deep: a rumble, not a rattle. Half a second so it is under the sweep
	# rather than an event of its own.
	_shake(0.22, LcnTiming.HEAVY, 8.0, true)
	Log.info("feel", "nightfall on day %d — sweep %.2fs, cold vignette held" % [
		day, LcnTiming.EVENT])
	_emit_beat(&"nightfall", 1.0, Vector2.ZERO)


func _on_day(day: int) -> void:
	if not enabled:
		return
	_nightfall.reset()
	screen.sweep(Color(LcnPalette.WARM_MID, 0.26), LcnTiming.EVENT * 0.8, false)
	Log.info("feel", "dawn of day %d" % day)
	_emit_beat(&"dawn", 0.7, Vector2.ZERO)


## Threat pressure rises as the wave gets closer, so the vignette breathes faster
## the less time is left. Nothing else in the frame behaves like that.
func _on_wave_incoming(_wave: int, seconds_until: float) -> void:
	if not enabled:
		return
	_threat01 = maxf(_threat01, LcnEase.ramp(90.0 - clampf(seconds_until, 0.0, 90.0),
		0.0, 90.0, LcnEase.Kind.QUAD_IN))


func _on_wave_started(wave: int, strength: float) -> void:
	if not enabled:
		return
	_threat01 = clampf(0.55 + strength * 0.3, 0.0, 1.0)
	screen.edge_pulse(Color(LcnPalette.DANGER, 0.75), 0.9, LcnTiming.EVENT * 0.6)
	_shake(0.3, LcnTiming.HEAVY, 11.0, true)
	_emit_beat(&"assault", clampf(strength, 0.2, 1.0), Vector2.ZERO)
	Log.info("feel", "wave %d felt at strength %.2f" % [wave, strength])


func _on_wave_cleared(_wave: int) -> void:
	_threat01 = 0.0
	screen.edge_pulse(Color(LcnPalette.GOOD, 0.4), 0.5, LcnTiming.EVENT * 0.5)
	_emit_beat(&"relief", 0.4, Vector2.ZERO)


## Alert urgency is proportional to severity, and only severity 2+ is allowed to
## touch the frame. An interface that flashes at everything is an interface the
## player learns to ignore.
func _on_alert(severity: int, key: StringName, _text: String, pos: Vector2) -> void:
	if not enabled or severity < 1:
		return
	if severity >= 2:
		screen.edge_pulse(Color(LcnPalette.DANGER, 0.6), 0.7, LcnTiming.HEAVY)
		_shake(0.10, LcnTiming.SETTLE, 14.0)
	if pos != Vector2.ZERO:
		var col: Color = LcnPalette.DANGER if severity >= 2 else LcnPalette.CAUTION
		world.ring(pos, 40.0, Color(col, 0.8), 0.5, LcnTiming.HEAVY)
	_emit_beat(&"alert", clampf(float(severity) * 0.35, 0.2, 1.0), pos)
	if severity >= 2:
		Log.debug("feel", "alert '%s' at severity %d felt" % [key, severity])


func _on_law(_id: StringName) -> void:
	screen.wash(Color(LcnPalette.WARM_MID, 0.14), 0.6, LcnTiming.HEAVY)
	_emit_beat(&"law", 0.6, Vector2.ZERO)


func _on_research(_id: StringName) -> void:
	screen.edge_pulse(Color(LcnPalette.GOOD, 0.35), 0.55, LcnTiming.HEAVY)
	_emit_beat(&"research", 0.5, Vector2.ZERO)


func _on_game_over(_reason: String) -> void:
	screen.wash(Color(LcnPalette.COLD_ABYSS, 0.85), 1.0, LcnTiming.EVENT)
	_shake(0.4, LcnTiming.EVENT * 0.5, 6.0, true)
	_emit_beat(&"game_over", 1.0, Vector2.ZERO)


# ================================================================ the impulses ==

## Camera impulse, rate-limited and settings-scaled. `heavy` bypasses the
## cooldown, because a nightfall must never be swallowed by a turret volley.
func shake(strength: float, seconds: float = LcnTiming.SETTLE,
		frequency: float = -1.0, heavy: bool = false) -> void:
	_shake(strength, seconds, frequency, heavy)


func _shake(strength: float, seconds: float, frequency: float, heavy: bool = false) -> void:
	var scale: float = LcnTiming.shake_scale()
	if scale <= 0.0:
		return
	var now: float = LcnTiming.world_now()
	if not heavy and now - _last_shake < SHAKE_COOLDOWN:
		return
	_last_shake = now
	if _camera == null:
		_camera = GameCamera.current()
	if _camera == null:
		return
	# GameCamera applies Settings itself; clamping here is about this part never
	# asking for more than the design allows, whatever a caller passes in.
	_camera.shake(minf(strength, SHAKE_CEILING), seconds, frequency)


## Hit-stop: the frame holds for a breath so a heavy impact lands. Bounded hard —
## 90 ms at 0.28x, once every 0.6 s — because anything more turns a frame drop
## into a design decision, and skipped entirely under the harness, where the
## clock is manual and time_scale would only distort the run.
func _hit_stop() -> void:
	if not LcnTiming.hit_stop_enabled():
		return
	var now: float = LcnTiming.world_now()
	if now - _last_hit_stop < HIT_STOP_COOLDOWN:
		return
	_last_hit_stop = now
	_hit_stop_left = HIT_STOP_MAX
	if Harness.active:
		return
	_time_scale_saved = Engine.time_scale
	Engine.time_scale = HIT_STOP_SCALE


## Advanced on UNSCALED time, or a hit-stop would take 1/0.28 as long to release
## as it asked for.
func _advance_hit_stop(ui_dt: float) -> void:
	if _hit_stop_left <= 0.0:
		return
	_hit_stop_left -= ui_dt
	if _hit_stop_left <= 0.0:
		_hit_stop_left = 0.0
		if not Harness.active:
			Engine.time_scale = _time_scale_saved


func _emit_beat(n: StringName, strength: float, at: Vector2) -> void:
	_last_beat = n
	beat.emit(n, clampf(strength, 0.0, 1.0), at)


# ================================================================ diagnostics ==

## How far through a nightfall the world is, 0 when it is not happening.
## [P13]'s grade and [P23]'s audio can ride this instead of keeping their own.
func nightfall_progress() -> float:
	return _nightfall.value()


## Continuous darkness pressure, 0 at noon, 1 deep in the night.
func night_pressure() -> float:
	return _night01


func threat_pressure() -> float:
	return _threat01


func hit_stopped() -> bool:
	return _hit_stop_left > 0.0


## Everything a test or a log line needs, in one dictionary.
func stats() -> Dictionary:
	return {
		"frame_us": snappedf(_cost_us_avg, 0.1),
		"events": _events,
		"beat": String(_last_beat),
		"night": snappedf(_night01, 0.001),
		"threat": snappedf(_threat01, 0.001),
		"nightfall": snappedf(_nightfall.value(), 0.001),
		"hit_stop": _hit_stop_left > 0.0,
		"world": world.stats(),
		"hover": hover.stats(),
		"idle": idle.stats(),
		"screen": screen.stats(),
	}


func _log_cost() -> void:
	var w: Dictionary = world.stats()
	var i: Dictionary = idle.stats()
	Log.info("feel", "frame %.3f ms | fx %d alive / %d drawn %.3f ms | idle %d anchors %.3f ms | hover %.3f ms | screen %.3f ms" % [
		_cost_us_avg / 1000.0,
		int(w["alive"]), int(w["drawn"]), float(w["draw_us"]) / 1000.0,
		int(i["anchors"]), float(i["draw_us"]) / 1000.0,
		float((hover.stats())["draw_us"]) / 1000.0,
		float((screen.stats())["draw_us"]) / 1000.0,
	])


## Footprint of a kind, straight from the registry so this works whether or not
## [P11] is present. Cached by the registry itself, so it is a dictionary probe.
func _tiles_of(kind: StringName) -> Vector2i:
	var def: Resource = Registry.get_item("buildings", kind)
	if def != null and typeof(def.get("size")) == TYPE_VECTOR2I:
		var s: Vector2i = def.get("size")
		if s.x > 0 and s.y > 0:
			return s
	return Vector2i.ONE
