class_name LcnVfx
extends Node2D
## The effects layer. [P14] VFX & Weather
##
## Everything in this part hangs off this node, and this node has the only
## `_process` in it. One frame, one wind vector, one view rect, one budget, one
## log line — because six modules each waking up on their own is how a particle
## layer becomes untraceable the first time it costs a millisecond.
##
## WHERE IT SITS. A child of [WorldRenderer], which is a Node2D at the world
## origin, so every position in this part is a world pixel and nothing has to
## convert. The z stack inside the world, from the ground up:
##
##   8   frost creeping over freezing structures (under the buildings' feet)
##   12  spindrift torn off the settled drifts
##   19  breath          21 heat haze     22 embers   23 sparks
##   24  industrial smoke                 25 damage smoke
##   26  transient debris and ash (mixed) 28 sparks and fire (additive)
##   30  tracers, muzzles, flame cones
##   52/54/57  the three snow layers
##   58  the whiteout veil
##
## Above that the canvas layers take over and none of them are ours: 60 is
## [P13]'s post stack, 65 [P17]'s HUD, 70/72 [P19]'s lenses, 74 [P18]'s menus.
## So a blizzard can white out the world without ever whiting out an instrument,
## and the effects layer never covers a panel the player opened.
##
## WHAT IT NEVER DOES. It never writes simulation state, never connects a sim
## signal to anything that mutates, and never draws from [Rng] — that stream is
## the simulation's and pulling a number out of it here would move a replay.
## Its own randomness is a private RandomNumberGenerator with a fixed seed.
##
## THE HARNESS PROBLEM, and the fix. A visual harness run advances thousands of
## simulation ticks between two rendered frames. Every muzzle flash and every
## death in that gap arrives as a signal into an effects layer that has not had
## a frame to age anything, so without care a screenshot at dusk shows a whole
## night's worth of tracers at once. Effects are therefore aged by
## `max(frame delta, ticks elapsed x SimClock.DT)`, so what a shot shows is what
## a player at 60 fps would have been looking at at that instant.

const GROUP: StringName = &"lcn_vfx"
## Frames between the cost line in the log. The renderer logs every 120; matching
## it means the two lines land together and can be read as one budget.
const LOG_EVERY: int = 120
## Frame cost, in microseconds, above which the layer starts shedding density.
## The renderer's whole budget at a 1700-building city is 12 ms; this part has
## asked for one of them and holds itself to it.
const BUDGET_US: float = 1000.0
## Floor the adaptive quality will not go below. Below this the layer is not
## saving anything worth the loss.
const QUALITY_MIN: float = 0.25

var weather: LcnVfxWeather = null
var industry: LcnVfxIndustry = null
var combat: LcnVfxCombat = null
var decay: LcnVfxDecay = null
var breath: LcnVfxBreath = null
var burst_add: LcnVfxBurst = null
var burst_mix: LcnVfxBurst = null

var enabled: bool = true

var _renderer: WorldRenderer = null
var _model: LcnWorldModel = null
var _climate: SimSystem = null
var _has_weather: bool = false
var _view: Rect2 = Rect2()
var _wind: Vector2 = Vector2.ZERO
var _wind_strength: float = 0.0
var _frames: int = 0
var _last_tick: int = 0
var _cost_us: float = 0.0
var _peak_us: int = 0
var _quality: float = 1.0
var _calm: bool = false
var _user_density: float = 1.0
var _splat_carry: float = 0.0
var _rng := RandomNumberGenerator.new()
var _bound: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	name = "LcnVfx"
	z_index = 0
	_rng.seed = 0xB1A2E5
	_renderer = get_parent() as WorldRenderer
	if _renderer == null:
		_renderer = get_tree().get_first_node_in_group(WorldRenderer.GROUP) as WorldRenderer
	if _renderer != null:
		_model = _renderer.world_model()

	burst_mix = LcnVfxBurst.new()
	burst_mix.name = "BurstMixed"
	add_child(burst_mix)
	burst_mix.configure(LcnVfxTuning.BURST_MIX_MAX, false, 26)

	burst_add = LcnVfxBurst.new()
	burst_add.name = "BurstAdditive"
	add_child(burst_add)
	burst_add.configure(LcnVfxTuning.BURST_ADD_MAX, true, 28)

	weather = LcnVfxWeather.new()
	weather.name = "Weather"
	add_child(weather)
	weather.setup()

	industry = LcnVfxIndustry.new()
	industry.name = "Industry"
	add_child(industry)
	industry.setup(_model)

	decay = LcnVfxDecay.new()
	decay.name = "Decay"
	add_child(decay)
	decay.setup(_model, burst_add, burst_mix)

	breath = LcnVfxBreath.new()
	breath.name = "Breath"
	add_child(breath)
	breath.setup()

	combat = LcnVfxCombat.new()
	combat.name = "Combat"
	add_child(combat)
	combat.setup(burst_add, burst_mix)

	Bus.world_ready.connect(_bind_sim)
	if Sim.alive:
		_bind_sim()
	Log.info("vfx", "effects layer installed: weather + industry + combat + decay + breath")


func _bind_sim() -> void:
	_climate = Sim.get_system(&"climate")
	_has_weather = _climate != null and _climate.has_method("weather") \
		and _climate.has_method("wind")
	industry.bind_sim()
	combat.bind_sim()
	decay.bind_sim()
	breath.bind_sim()
	if _renderer != null and _model == null:
		_model = _renderer.world_model()
		industry.setup(_model)
	_bound = true
	Log.info("vfx", "bound to sim: weather=%s heat=%s combat=%s citizens=%s" % [
		"climate" if _has_weather else "absent",
		industry.stats()["fuel"],
		"live" if Sim.get_system(&"combat") != null else "absent",
		"live" if Sim.get_system(&"citizens") != null else "absent",
	])


func _process(delta: float) -> void:
	if not enabled or _renderer == null:
		return
	var t0: int = Time.get_ticks_usec()
	_frames += 1
	_read_settings()

	_view = _renderer.view_rect()
	if _view.size.x <= 1.0:
		_view = Rect2(Vector2(-960, -540), Vector2(1920, 1080))

	# A visual harness run puts thousands of ticks between two frames; a normal
	# session puts one. Ageing by whichever is larger is what makes a screenshot
	# honest — see the class comment.
	var sim_dt: float = float(maxi(0, SimClock.tick - _last_tick)) * SimClock.DT
	_last_tick = SimClock.tick
	var dt: float = maxf(delta, minf(sim_dt, 4.0))

	_update_wind(delta)

	var grade: Dictionary = _renderer.current_grade()
	var ambient: float = _model.ambient_temperature() if _model != null else -20.0

	if _has_weather:
		weather.update(delta, _view, _wind,
			_climate.call("weather"), float(_climate.call("weather_intensity")),
			float(_climate.call("storm_intensity")), float(_climate.call("visibility")),
			float(_climate.call("snow_depth")), grade, _user_density, _calm)
	else:
		# No [P09] in this build: fall back to the renderer's own storm number so
		# the sky is never simply empty. The log line above says which it is.
		var storm: float = _model.storm() if _model != null else 0.0
		weather.update(delta, _view, _wind, &"snowfall", 0.35 + storm * 0.5,
			storm, 1.0 - storm * 0.5, 0.4, grade, _user_density, _calm)

	industry.update(_view, _wind, _calm, _quality)
	decay.update(dt, _view, _wind, _quality)
	breath.update(_view, ambient, _wind, _quality)
	combat.update(dt, _view, _calm)

	_settle_snow(dt)

	burst_add.cull_rect = _view
	burst_mix.cull_rect = _view
	burst_add.step(dt, _wind * 0.35)
	burst_mix.step(dt, _wind * 0.35)
	burst_add.queue_redraw()
	burst_mix.queue_redraw()

	var used: int = Time.get_ticks_usec() - t0
	_peak_us = maxi(_peak_us, used)
	_cost_us = _cost_us * 0.9 + float(used) * 0.1 if _frames > 1 else float(used)
	_adapt()
	if _frames % LOG_EVERY == 0:
		_log_cost()


## Wind is a vector here and a scalar in the simulation, because [P09] models
## strength and this part has to draw a direction. The direction is derived from
## the campaign day and turns slowly with world time — never with wall time, and
## never from [Rng], so two replays of a seed look the same as well as compute
## the same.
func _update_wind(_delta: float) -> void:
	var strength: float = 0.25
	if _has_weather:
		strength = clampf(float(_climate.call("wind")), 0.0, 1.0)
	_wind_strength = strength
	var day: int = 1
	if _climate != null and _climate.has_method("day"):
		day = int(_climate.call("day"))
	var base: float = float(((day * 2654435761) & 0xFFFF)) / 65535.0 * TAU
	var angle: float = base + SimClock.seconds() * LcnVfxTuning.WIND_TURN_RATE \
		+ sin(SimClock.seconds() * 0.017) * 0.5
	var speed: float = strength * LcnVfxTuning.WIND_SPEED_PX
	_wind = Vector2(cos(angle), sin(angle) * LcnVfxTuning.WIND_VERTICAL) * speed


## Flakes reaching the ground. Snow that only ever falls past the camera never
## reads as accumulating; a brief pale splat where one lands is what closes the
## loop between the weather and the drifts [P01] and [P13] own.
func _settle_snow(dt: float) -> void:
	var density: float = weather.snow_density()
	if density < 0.05 or _calm or _view.size.x > 3200.0:
		return
	var rate: float = density * 26.0 * _quality
	_splat_carry += rate * dt
	var n: int = mini(int(_splat_carry), 8)
	_splat_carry -= float(n)
	for i: int in n:
		var p := Vector2(
			_rng.randf_range(_view.position.x, _view.position.x + _view.size.x),
			_rng.randf_range(_view.position.y, _view.position.y + _view.size.y))
		burst_mix.emit(p, Vector2(_wind.x * 0.05, 0.0), _rng.randf_range(0.7, 1.6),
			_rng.randf_range(2.0, 4.5),
			Color(LcnVfxTuning.SNOW_FLAKE.r, LcnVfxTuning.SNOW_FLAKE.g,
				LcnVfxTuning.SNOW_FLAKE.b, _rng.randf_range(0.18, 0.36)),
			LcnVfxBurst.Shape.SPLAT, 0.05, 0.0, 2.5)


func _read_settings() -> void:
	var g: Dictionary = Settings.graphics
	enabled = bool(g.get("vfx", true))
	_user_density = clampf(float(g.get("snow_density", 1.0)), 0.0, 1.0)
	_calm = bool(Settings.accessibility.get("reduce_motion", false))


## Adaptive quality: if the layer goes over its own budget it thins itself out
## rather than taking the frame with it. It recovers just as automatically, so a
## single heavy second does not permanently downgrade the look.
func _adapt() -> void:
	if _cost_us > BUDGET_US:
		_quality = maxf(QUALITY_MIN, _quality - 0.04)
	elif _cost_us < BUDGET_US * 0.6:
		_quality = minf(1.0, _quality + 0.02)


func _log_cost() -> void:
	var w: Dictionary = weather.stats()
	var i: Dictionary = industry.stats()
	var c: Dictionary = combat.stats()
	var d: Dictionary = decay.stats()
	Log.info("vfx", "%.3f ms (peak %.3f) q=%.2f | snow %d @%.2f whiteout %.2f | "
		% [_cost_us / 1000.0, float(_peak_us) / 1000.0, _quality,
			int(w["snow_particles"]), float(w["snow_density"]), float(w["whiteout"])]
		+ "sources f%d w%d v%d craft%d | burst %d/%d add %d/%d | beams %d shells %d | frost %d smoke %d"
		% [int(i["furnaces"]), int(i["works"]), int(i["vents"]), int(i["crafting"]),
			burst_mix.count, burst_mix.capacity, burst_add.count, burst_add.capacity,
			int(c["beams"]), int(c["shells"]), int(d["frosting"]), int(d["damaged"])])
	_peak_us = 0


## Wind as the effects layer draws it: pixels per second, direction included.
## Public because [P15]'s micro-animation and [P13]'s banners should lean the
## same way the snow does.
func wind_vector() -> Vector2:
	return _wind


func whiteout() -> float:
	return weather.whiteout()


## One dictionary a test or a critic can assert against without a screenshot.
func stats() -> Dictionary:
	var out: Dictionary = {
		"frames": _frames,
		"ms_per_frame": snappedf(_cost_us / 1000.0, 0.0001),
		"peak_ms": snappedf(float(_peak_us) / 1000.0, 0.0001),
		"quality": snappedf(_quality, 0.01),
		"budget_ms": BUDGET_US / 1000.0,
		"wind": snappedf(_wind_strength, 0.001),
		"wind_px": snappedf(_wind.length(), 0.1),
		"reduce_motion": _calm,
		"bound": _bound,
		"burst_mixed": burst_mix.count,
		"burst_additive": burst_add.count,
	}
	for src: Dictionary in [weather.stats(), industry.stats(), combat.stats(),
			decay.stats(), breath.stats()]:
		for k: String in src:
			out[k] = src[k]
	return out


## The current node in the tree, or null. Other view parts use this rather than
## a node path.
static func current() -> LcnVfx:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.get_first_node_in_group(GROUP) as LcnVfx
