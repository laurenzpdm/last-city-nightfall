class_name ThreatSystem
extends SimSystem
## [P08] Threat Director — the game's dramaturge.
##
## Nothing in here picks a wave from a list. Every night is COMPOSED: a budget
## grows on an authored curve, is bent by the drama of the campaign, by how cold
## the world has become, by how much heat the city is throwing into the dark and
## by how comfortably the player cleared the last few nights — and is then spent
## on creatures from game/content/enemies/ and aimed down approach lanes chosen
## against the defences the player has actually built.
##
## WHY THEY COME. Warmth is visible from the plain. The better the city holds
## its heat, the more of them it summons. `budget x= heat_factor(signature)` is
## not flavour text bolted on afterwards; it is a term in the equation, it is
## saturating so success is never suicide, and its sentence is in every preview.
## The player's own competence is the antagonist. That is the whole conceit.
##
## THE TELEGRAPH IS THE GAME. Four warnings before every night, each more
## precise than the last: a direction, then named approaches, then a composition
## by role, then counts. A full extra day of notice before a set piece. What is
## promised at midday is exactly what arrives at nightfall, because the plan is
## composed once and never re-rolled. The player always knows roughly what is
## coming and never has enough to be ready for all of it.
##
## THE PEAKS ARE SYNCHRONISED ON PURPOSE. WaveSchedule reads [P09]'s fixed Great
## Frost calendar and drags the campaign's set pieces onto it, so the worst
## attack lands on the coldest night — the single best moment this game can
## produce, produced by a rule rather than by a script.
##
## ADAPTATION IS DECLARED. PressureTracker may move the budget inside
## ThreatProfile.adapt_min..adapt_max — 0.80 to 1.25 as shipped — and that band,
## the current multiplier and the comfort reading behind it are in metrics(), in
## serialize() and in next_wave_preview() every tick.
##
## Contracts other parts use:
##   threat_level() -> float               0..1 for the HUD meter
##   next_wave_preview() -> Dictionary     everything the player may know, redacted
##   current_wave_report() -> Dictionary   the live night
##   last_wave_report() -> Dictionary      the post-mortem
##   active_packs() -> Array[Dictionary]   live positions when [P07] is absent
##   vectors() -> Array[Dictionary]        approach lanes and their defence rating

const ORDER: int = 70
const NAME: StringName = &"threat"
const TAG: String = "threat"
const RNG_STREAM: String = "threat"
const CATEGORY: String = "enemies"
const PROFILE_CATEGORY: String = "threat"

## Ticks between defence rescans while a wave is live. Five seconds: a turret
## finished mid-assault counts almost immediately, and the scan is one pass over
## the building list, so this never shows up in the tick budget.
const RESCORE_TICKS: int = 100
## Ticks between heat-signature samples outside of the profile's own interval.
const LOG_PERF_EVERY: int = 6000

# --- tuning and content ------------------------------------------------------
var _profile: ThreatProfile = null
var _defs: Array[EnemyDef] = []

# --- machinery ---------------------------------------------------------------
var _schedule: WaveSchedule = WaveSchedule.new()
var _planner: ApproachPlanner = ApproachPlanner.new()
var _pressure: PressureTracker = PressureTracker.new()
var _siege: SiegeResolver = SiegeResolver.new()

# --- other systems, all optional --------------------------------------------
var _climate: SimSystem = null
var _grid: SimSystem = null
var _build: SimSystem = null
var _heat: SimSystem = null
var _combat: SimSystem = null
var _has_forecast: bool = false

# --- clock -------------------------------------------------------------------
var _tick: int = 0
var _day: int = 1
var _was_night: bool = false

# --- waves -------------------------------------------------------------------
var _plan: WavePlan = null
var _state: int = ThreatDefs.WaveState.IDLE
var _wave: int = 0
## Nights that ended with nothing of the wave left alive. The player beat those.
var _waves_cleared: int = 0
## Nights that ended at all, cleanly or otherwise.
var _waves_survived: int = 0
var _waves_started: int = 0
var _night_start_tick: int = 0
var _last_report: Dictionary = {}
var _breach_reported: int = 0
var _peace: bool = false

# --- the heat hunger ---------------------------------------------------------
var _sig_sum: float = 0.0
var _sig_n: int = 0
var _heat_signature: float = 0.0

# --- night bookkeeping -------------------------------------------------------
var _night_samples: int = 0
var _night_heat_ok: int = 0
var _buildings_at_dusk: int = 0

# --- profiling. Never reaches serialize() or metrics(); see step(). ----------
var _perf_us: int = 0
var _perf_max_us: int = 0
var _perf_steps: int = 0


func _init() -> void:
	order = ORDER


func system_name() -> StringName:
	return NAME


# ==========================================================================
#  LIFECYCLE
# ==========================================================================

func setup() -> void:
	_profile = _load_profile()
	if not _profile.validate():
		Log.warn(TAG, "profile '%s' had to be clamped; check the .tres" % _profile.id)
	_load_defs()

	_pressure = PressureTracker.new(_profile)
	_schedule = WaveSchedule.new()
	_planner = ApproachPlanner.new()
	_siege = SiegeResolver.new()

	_tick = 0
	_day = 1
	_wave = 0
	_waves_cleared = 0
	_waves_survived = 0
	_waves_started = 0
	_state = ThreatDefs.WaveState.IDLE
	_plan = null
	_last_report = {}
	_breach_reported = 0
	_peace = false
	_heat_signature = 0.0
	_sig_sum = 0.0
	_sig_n = 0
	_perf_us = 0
	_perf_max_us = 0
	_perf_steps = 0


func post_setup() -> void:
	_bind()
	_schedule.build(_profile, _read_storm_calendar())
	_planner.bind(_profile, _grid, _build, _heat)
	_planner.build_vectors()
	_siege.bind(_profile, _planner, _build, _grid)
	_day = _read_day()
	_was_night = _read_is_night()
	_plan_night(_day)
	var pieces: Array[int] = _schedule.set_piece_nights()
	Log.info(TAG, "director ready: %d enemy kind(s), set pieces on %s, band %s" % [
		_defs.size(), str(pieces.slice(0, 8)), _pressure.band_label()])


func step(tick: int) -> void:
	var t0: int = Time.get_ticks_usec()  # lint:allow profiling only; never serialized
	_tick = tick

	var day: int = _read_day()
	if day != _day:
		_roll_day(day)

	if tick % _profile.heat_sample_interval == 0:
		_sample_heat()

	var night: bool = _read_is_night()
	if _plan != null and not _peace:
		if not night:
			_telegraph()
		if night and not _was_night:
			_begin_wave()
	_was_night = night

	if _state == ThreatDefs.WaveState.ACTIVE:
		_run_wave(tick, night)

	var us: int = Time.get_ticks_usec() - t0  # lint:allow profiling only
	_perf_us += us
	_perf_max_us = maxi(_perf_max_us, us)
	_perf_steps += 1
	if _perf_steps >= LOG_PERF_EVERY:
		Log.debug(TAG, "step avg %.1f us, max %d us over %d ticks" % [
			float(_perf_us) / float(_perf_steps), _perf_max_us, _perf_steps])
		_perf_us = 0
		_perf_max_us = 0
		_perf_steps = 0


# ==========================================================================
#  PUBLIC API — what the HUD reads
# ==========================================================================

## 0..1 reading of how dangerous the world is right now. Two regimes, both
## documented so the meter can never be accused of drifting on its own:
##   * while a wave is live, it is the size of that wave scaled by how much of
##     it is still standing;
##   * otherwise it is the size of the NEXT wave scaled by how close it is,
##     from `level_horizon_seconds` out.
func threat_level() -> float:
	if _plan == null:
		return 0.0
	var size: float = clampf(_plan.budget / _profile.level_reference_budget, 0.0, 1.0)
	if _state == ThreatDefs.WaveState.ACTIVE:
		var left: float = _live_fraction()
		return clampf(0.35 + 0.65 * size * (0.30 + 0.70 * left), 0.0, 1.0)
	var secs: float = seconds_until_wave()
	if secs < 0.0:
		return clampf(size * 0.30, 0.0, 1.0)
	var imminence: float = 1.0 - clampf(secs / _profile.level_horizon_seconds, 0.0, 1.0)
	return clampf(size * (0.25 + 0.75 * imminence), 0.0, 1.0)


## Everything the player is allowed to know about the coming night, redacted by
## how many warnings have gone out. The `precision` field says which rung we are
## on; -1 means the plain has not shown itself yet.
func next_wave_preview() -> Dictionary:
	if _plan == null:
		return {"wave": 0, "known": false, "precision": -1, "threat_level": threat_level()}
	var p: int = _plan.precision
	var out: Dictionary = {
		"wave": _plan.wave,
		"day": _plan.day,
		"known": p >= 0,
		"precision": p,
		"locked": _plan.locked,
		"active": _state == ThreatDefs.WaveState.ACTIVE,
		"seconds_until": snappedf(maxf(0.0, seconds_until_wave()), 0.05),
		"strength": snappedf(_strength_norm(_plan.budget), 0.001),
		"strength_label": _plan.band_label(),
		"set_piece": _plan.set_piece,
		"title": _plan.title,
		"storm_synced": _plan.storm_synced,
		"storm": _plan.storm_title,
		"threat_level": snappedf(threat_level(), 0.001),
		"pressure": snappedf(_pressure.pressure, 0.001),
		"pressure_band": _pressure.band_label(),
		"reasons": _plan.breakdown.get("reasons", []),
	}
	if p >= 0:
		out["directions"] = _plan.direction_labels()
		out["direction_phrase"] = _plan.direction_phrase()
	if p >= 1:
		var vs: Array = []
		for v: ThreatVector in _plan.vectors:
			if v.share > 0.0001:
				vs.append(v.to_preview(p))
		out["vectors"] = vs
	if p >= 2:
		out["roles"] = _plan.role_phrase()
		out["shape"] = String(_plan.shape)
	if p >= 3:
		out["composition"] = _plan.counts_by_kind()
		out["units"] = _plan.unit_count()
		out["detail"] = _plan.detail_phrase()
	return out


## The night in progress, or an empty dictionary.
func current_wave_report() -> Dictionary:
	if _state != ThreatDefs.WaveState.ACTIVE or _plan == null:
		return {}
	return {
		"wave": _plan.wave,
		"budget": snappedf(_plan.budget, 0.01),
		"units": _plan.unit_count(),
		"live": _live_units(),
		"killed": _siege.killed,
		"structures_lost": _siege.structures_lost,
		"breached": _siege.breached,
		"closest_cells": _siege.closest_cells if _siege.closest_cells < (1 << 20) else -1,
		"resolver": "combat" if _combat_resolves() else "siege_model",
		"seconds_to_dawn": snappedf(_ticks_until_dawn() * SimClock.DT, 0.05),
	}


## The post-mortem of the last night that finished. This is the "legible in
## hindsight" contract: what came, from where, what it cost, how it went, and
## exactly what that did to the pressure multiplier.
func last_wave_report() -> Dictionary:
	return _last_report.duplicate(true)


## Live positions of everything on the map, when this system is resolving the
## night itself. Empty once [P07] combat owns the units.
func active_packs() -> Array[Dictionary]:
	if _plan == null or _combat_resolves():
		return []
	return _siege.view_packs(_plan)


## Every approach this world offers, with its current defence rating. The
## readability layer draws this straight onto the map.
func vectors() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for v: ThreatVector in _planner.candidates():
		out.append(v.to_dict())
	return out


## Seconds until the next attack begins. -1.0 while one is already on the map.
func seconds_until_wave() -> float:
	if _state == ThreatDefs.WaveState.ACTIVE:
		return -1.0
	return float(_ticks_until_night()) * SimClock.DT


## The wave number of the night being prepared or fought.
func wave() -> int:
	return _plan.wave if _plan != null else 0


func waves_cleared() -> int:
	return _waves_cleared


## Current adaptation multiplier, always inside the declared band.
func pressure() -> float:
	return _pressure.pressure


func pressure_band() -> String:
	return _pressure.band_label()


## The city's heat output as the plain perceives it, in units per second.
func heat_signature() -> float:
	return _heat_signature


## The campaign's set-piece calendar, and which storms it was synchronised to.
func schedule() -> Dictionary:
	return _schedule.to_dict()


func profile() -> ThreatProfile:
	return _profile


func plan() -> WavePlan:
	return _plan


# ==========================================================================
#  PLANNING
# ==========================================================================

## Composes the night belonging to `day`. Called once per day, at the moment the
## day rolls over, and never again — a plan that could be re-rolled would make
## every warning a lie.
func _plan_night(day: int) -> void:
	var night: int = maxi(1, day)
	var b: Dictionary = WaveBudget.compute(_profile, _schedule, night,
		_read_era_index(), _heat_signature, _pressure.pressure)

	var p := WavePlan.new()
	p.wave = night
	p.day = day
	p.budget = float(b["total"])
	p.breakdown = WaveBudget.to_dict(b)
	p.set_piece = _schedule.is_set_piece(night)
	p.storm_synced = _schedule.is_storm_synced(night)
	p.storm_title = _schedule.storm_title(night)
	p.storm_intensity = _schedule.storm_intensity(night)
	p.title = _schedule.title_for(night)

	var rng: RandomNumberGenerator = Rng.stream(RNG_STREAM)
	p.shape = WaveComposer.roll_shape(_profile, night, p.set_piece, rng)
	p.composition = WaveComposer.compose(_profile, night, p.budget, p.shape, _defs, rng)

	var errors: PackedStringArray = WaveComposer.legality_errors(
		_profile, night, p.budget, p.composition, _defs)
	if not errors.is_empty():
		# A composer that quietly breaks its own rules is the bug nobody finds
		# for a month. Say it out loud, in the run that produced it.
		Log.error(TAG, "illegal composition for wave %d: %s" % [night, ", ".join(errors)])

	p.vectors = _planner.select(night, p.set_piece, rng)
	_distribute(p)
	_plan = p
	_wave = night

	Log.info(TAG, "wave %d composed: %s budget %.1f (%s), %d unit(s) over %d vector(s)%s" % [
		night, ThreatDefs.shape_label(p.shape), p.budget, p.band_label(),
		p.unit_count(), p.vectors.size(),
		"" if not p.set_piece else " — SET PIECE '%s'%s" % [
			p.title, " synced to the storm" if p.storm_synced else ""]])

	if p.set_piece and _profile.set_piece_notice_ticks > 0:
		_maybe_notice(p)


## Splits the composition across the chosen vectors and stamps arrival times.
## Largest-remainder apportionment, so the counts always add back up and the
## split is identical on every machine.
func _distribute(p: WavePlan) -> void:
	p.groups.clear()
	p.spent = 0.0
	if p.vectors.is_empty() or p.composition.is_empty():
		return

	var rows: Array[Dictionary] = []
	for entry: Dictionary in p.composition:
		var total: int = int(entry.get("count", 0))
		if total <= 0:
			continue
		var def: EnemyDef = entry.get("def")
		var per_unit: float = float(entry.get("cost", 0.0)) / float(maxi(1, total))
		var counts: PackedInt32Array = _apportion(total, p.vectors)
		for i: int in p.vectors.size():
			if counts[i] <= 0:
				continue
			var g := WaveGroup.new()
			g.enemy = StringName(String(entry.get("enemy", "")))
			g.count = counts[i]
			g.cost = per_unit * float(counts[i])
			g.vector = i
			g.spawn_cell = p.vectors[i].entry_cell
			p.spent += g.cost
			rows.append({"g": g, "tier": def.tier if def != null else 1,
				"cost": def.cost if def != null else 0.0})

	# Arrival order: the small and the quick first, the heavy last. A night that
	# opens with its anchor is one decision; a night that ends with it is five.
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ga: WaveGroup = a["g"]
		var gb: WaveGroup = b["g"]
		if int(a["tier"]) != int(b["tier"]):
			return int(a["tier"]) < int(b["tier"])
		if absf(float(a["cost"]) - float(b["cost"])) > 0.0001:
			return float(a["cost"]) < float(b["cost"])
		if ga.vector != gb.vector:
			return ga.vector < gb.vector
		return String(ga.enemy) < String(gb.enemy))

	var n: int = rows.size()
	for i: int in n:
		var g2: WaveGroup = rows[i]["g"]
		g2.delay_ticks = 0 if n <= 1 else int(round(float(_profile.spawn_window_ticks) * float(i) / float(n - 1)))
		p.groups.append(g2)


## Largest-remainder split of `total` units over the vectors' shares. Every
## vector with a share gets at least one unit while units remain, so a
## telegraphed direction is never empty.
func _apportion(total: int, vs: Array[ThreatVector]) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var rema: Array[Dictionary] = []
	var used: int = 0
	for i: int in vs.size():
		var exact: float = float(total) * vs[i].share
		var whole: int = int(floor(exact))
		out.append(whole)
		used += whole
		rema.append({"i": i, "r": exact - float(whole)})
	rema.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["r"]) - float(b["r"])) > 0.000001:
			return float(a["r"]) > float(b["r"])
		return int(a["i"]) < int(b["i"]))
	var left: int = total - used
	var k: int = 0
	while left > 0 and not rema.is_empty():
		out[int(rema[k % rema.size()]["i"])] += 1
		left -= 1
		k += 1
	return out


## Re-reads the player's defences and commits to where the attack is coming
## from. Runs exactly once per night, at the first warning: late enough that it
## sees the walls that went up this morning, early enough that the player still
## has three minutes to answer it.
func _lock_vectors() -> void:
	if _plan == null or _plan.locked:
		return
	var before: PackedStringArray = _plan.direction_labels()
	_plan.vectors = _planner.select(_plan.wave, _plan.set_piece, Rng.stream(RNG_STREAM))
	_distribute(_plan)
	_plan.locked = true
	var after: PackedStringArray = _plan.direction_labels()
	if String(", ".join(before)) != String(", ".join(after)):
		Log.info(TAG, "wave %d re-aimed at %s (was %s)" % [
			_plan.wave, ", ".join(after), ", ".join(before)])


# ==========================================================================
#  TELEGRAPHING
# ==========================================================================

## Walks the warning ladder. Each rung fires once, in order, and raises the
## precision of everything the HUD is allowed to show.
func _telegraph() -> void:
	if _plan == null or _state == ThreatDefs.WaveState.ACTIVE:
		return
	var until: int = _ticks_until_night()
	var offsets: PackedInt32Array = _profile.warning_offsets_ticks
	while _plan.warnings_fired < offsets.size() and until <= offsets[_plan.warnings_fired]:
		var rung: int = _plan.warnings_fired
		_plan.warnings_fired += 1
		if rung == 0:
			_lock_vectors()
		var precision: int = _profile.warning_precision[rung] if rung < _profile.warning_precision.size() else rung
		_plan.precision = maxi(_plan.precision, precision)
		_state = ThreatDefs.WaveState.TELEGRAPHED
		_emit_warning(rung, precision, until)


func _emit_warning(rung: int, precision: int, until_ticks: int) -> void:
	var seconds: float = float(until_ticks) * SimClock.DT
	var line: String = _format(_profile.warning_lines[rung], precision, seconds)
	Bus.wave_incoming.emit(_plan.wave, seconds)
	Bus.alert_raised.emit(ThreatDefs.MAX_BUS_SEVERITY, ThreatDefs.KEY_WARNING, line, _focus())
	Bus.narrative_event.emit(ThreatDefs.KEY_WARNING, {
		"wave": _plan.wave,
		"rung": rung,
		"precision": precision,
		"seconds_until": snappedf(seconds, 0.05),
		"text": line,
		"strength": snappedf(_strength_norm(_plan.budget), 0.001),
		"strength_label": _plan.band_label(),
		"directions": _plan.direction_labels(),
		"set_piece": _plan.set_piece,
		"title": _plan.title,
		"preview": next_wave_preview(),
	})
	Log.info(TAG, "warning %d/%d: %s" % [rung + 1, _profile.warning_lines.size(), line])


## A set piece gets a full extra day of notice, fired the moment the plan for
## it exists. The player should be dreading it while they are still building.
func _maybe_notice(p: WavePlan) -> void:
	if p.notice_fired:
		return
	p.notice_fired = true
	var line: String = _profile.set_piece_notice_line \
		.replace("{title}", p.title if p.title != "" else "A muster") \
		.replace("{band}", p.band_label()) \
		.replace("{dirs}", p.direction_phrase()) \
		.replace("{wave}", str(p.wave))
	Bus.alert_raised.emit(ThreatDefs.MAX_BUS_SEVERITY, ThreatDefs.KEY_SET_PIECE, line, _focus())
	Bus.narrative_event.emit(ThreatDefs.KEY_SET_PIECE, {
		"wave": p.wave,
		"title": p.title,
		"storm_synced": p.storm_synced,
		"storm": p.storm_title,
		"text": line,
		"strength": snappedf(_strength_norm(p.budget), 0.001),
	})
	Log.info(TAG, "set piece announced: %s" % line)


# ==========================================================================
#  THE NIGHT
# ==========================================================================

func _begin_wave() -> void:
	if _plan == null or _state == ThreatDefs.WaveState.ACTIVE:
		return
	_lock_vectors()
	if _plan.precision < 0:
		# The night arrived before the ladder did (a commanded time jump). The
		# player still gets told, and still gets the full truth of it.
		_plan.precision = _profile.warning_precision[_profile.warning_precision.size() - 1]
	_state = ThreatDefs.WaveState.ACTIVE
	_night_start_tick = _tick
	_plan.night_start_tick = _tick
	_plan.dawn_tick = _tick + _ticks_until_dawn()
	_waves_started += 1
	_night_samples = 0
	_night_heat_ok = 0
	_buildings_at_dusk = _building_count()
	_siege.begin(_plan)

	var line: String = _format(_profile.wave_started_line, 3, 0.0)
	Bus.wave_started.emit(_plan.wave, _strength_norm(_plan.budget))
	Bus.alert_raised.emit(ThreatDefs.MAX_BUS_SEVERITY, ThreatDefs.KEY_WAVE_STARTED, line, _focus())
	Bus.narrative_event.emit(ThreatDefs.KEY_WAVE_STARTED, {
		"wave": _plan.wave,
		"text": line,
		"set_piece": _plan.set_piece,
		"title": _plan.title,
		"storm_synced": _plan.storm_synced,
		"units": _plan.unit_count(),
		"composition": _plan.counts_by_kind(),
		"vectors": _plan.to_dict()["vectors"],
		"budget": snappedf(_plan.budget, 0.01),
		"breakdown": _plan.breakdown,
	})
	Log.info(TAG, "NIGHT %d: %s (%d units, budget %.1f)" % [
		_plan.wave, line, _plan.unit_count(), _plan.budget])


func _run_wave(tick: int, night: bool) -> void:
	_dispatch_due(tick)

	if tick % RESCORE_TICKS == 0:
		_planner.refresh(_plan.vectors)
		if not _combat_resolves():
			_siege.rearm(_plan)

	if tick % _profile.siege_step_ticks == 0:
		if not _combat_resolves():
			_siege.step(_plan, _profile.siege_step_ticks)
		_sample_night_heat()
		_check_breach()

	if not night and _profile.withdraw_at_dawn:
		_resolve_wave(true)
		return
	if _all_dispatched() and _live_units() <= 0:
		_resolve_wave(false)


## Walks every group whose moment has come onto the map. Combat gets first
## refusal; the siege model only runs when there is nothing to hand them to.
func _dispatch_due(tick: int) -> void:
	var elapsed: int = tick - _night_start_tick
	for g: WaveGroup in _plan.groups:
		if g.dispatched or g.delay_ticks > elapsed:
			continue
		g.dispatched = true
		var v: ThreatVector = _plan.vector_of(g.vector)
		if v == null:
			continue
		if _combat_resolves():
			g.handle = _spawn_through_combat(g, v)
		else:
			_siege.dispatch(g, _plan)
		Bus.narrative_event.emit(ThreatDefs.KEY_CONTACT, {
			"wave": _plan.wave,
			"enemy": String(g.enemy),
			"count": g.count,
			"cell": [g.spawn_cell.x, g.spawn_cell.y],
			"compass": String(v.compass()),
		})


func _spawn_through_combat(g: WaveGroup, v: ThreatVector) -> int:
	if _combat.has_method("spawn_group"):
		var res: Variant = _combat.call("spawn_group", {
			"wave": _plan.wave,
			"enemy": g.enemy,
			"count": g.count,
			"cell": g.spawn_cell,
			"vector": g.vector,
			"compass": v.compass(),
			"path": v.path,
		})
		return int(res) if typeof(res) == TYPE_INT else -1
	if _combat.has_method("spawn_enemy"):
		for _i: int in g.count:
			_combat.call("spawn_enemy", g.enemy, g.spawn_cell, _plan.wave)
	return -1


func _check_breach() -> void:
	if _combat_resolves() or not _siege.breached:
		return
	if _breach_reported == _plan.wave:
		return
	_breach_reported = _plan.wave
	var line: String = _profile.wave_breached_line.replace("{dirs}", _plan.direction_phrase(1))
	Bus.alert_raised.emit(ThreatDefs.MAX_BUS_SEVERITY, ThreatDefs.KEY_BREACH, line, _focus())
	Bus.narrative_event.emit(ThreatDefs.KEY_BREACH, {"wave": _plan.wave, "text": line})
	Log.warn(TAG, "wave %d breached the city" % _plan.wave)


## Ends the night, measures it, and lets that measurement move the pressure
## multiplier inside its declared band.
func _resolve_wave(at_dawn: bool) -> void:
	var withdrew: int = 0
	if at_dawn and not _combat_resolves():
		withdrew = _siege.withdraw()
	var night_ticks: int = maxi(1, _tick - _night_start_tick)
	var heat_ok: int = night_ticks if _night_samples <= 0 else int(
		round(float(night_ticks) * float(_night_heat_ok) / float(_night_samples)))
	var outcome: Dictionary = _outcome(night_ticks, heat_ok, withdrew)
	var record: Dictionary = _pressure.record(outcome)

	_state = ThreatDefs.WaveState.RESOLVED
	_waves_survived += 1
	# "Cleared" means nothing of it was left standing. A night that ended
	# because the sun came up is survived, not cleared, and the difference is
	# exactly what the adaptation is reading.
	var wiped: bool = int(outcome.get("killed", 0)) >= int(outcome.get("spawned", 0)) \
		and withdrew == 0
	if wiped:
		_waves_cleared += 1
	var detail: String = "%d of %d put down%s" % [
		int(outcome.get("killed", 0)), maxi(1, int(outcome.get("spawned", 0))),
		"" if int(outcome.get("structures_lost", 0)) == 0
			else ", %d structure(s) lost" % int(outcome.get("structures_lost", 0))]
	var line: String = _profile.wave_cleared_line \
		.replace("{wave}", str(_plan.wave)).replace("{detail}", detail)

	_last_report = {
		"wave": _plan.wave,
		"day": _plan.day,
		"budget": snappedf(_plan.budget, 0.01),
		"breakdown": _plan.breakdown,
		"set_piece": _plan.set_piece,
		"title": _plan.title,
		"storm_synced": _plan.storm_synced,
		"shape": String(_plan.shape),
		"composition": _plan.counts_by_kind(),
		"vectors": _plan.to_dict()["vectors"],
		"outcome": outcome,
		"comfort": record.get("comfort", 0.0),
		"pressure_before": record.get("pressure_before", 1.0),
		"pressure_after": record.get("pressure_after", 1.0),
		"withdrew": withdrew,
		"cleared": wiped,
		"ended_at_dawn": at_dawn,
		"text": line,
	}

	Bus.wave_cleared.emit(_plan.wave)
	Bus.alert_raised.emit(0, ThreatDefs.KEY_WAVE_CLEARED, line, _focus())
	Bus.narrative_event.emit(ThreatDefs.KEY_WAVE_CLEARED, _last_report.duplicate(true))
	if withdrew > 0:
		Bus.narrative_event.emit(ThreatDefs.KEY_WITHDRAW, {
			"wave": _plan.wave, "survivors": withdrew,
			"text": "%d of them went back out onto the plain with the light." % withdrew})
	Log.info(TAG, "wave %d resolved: %s | comfort %.2f, pressure %.3f -> %.3f (band %s)" % [
		_plan.wave, detail, float(record.get("comfort", 0.0)),
		float(record.get("pressure_before", 1.0)), float(record.get("pressure_after", 1.0)),
		_pressure.band_label()])


## The night's numbers, from combat when it owns the field and from the siege
## model when it does not. Structures lost falls back to the change in the
## city's building count, which is the only universally available signal.
func _outcome(night_ticks: int, heat_ok: int, withdrew: int) -> Dictionary:
	if not _combat_resolves():
		var o: Dictionary = _siege.outcome(night_ticks, heat_ok)
		o["withdrew"] = withdrew
		return o
	var spawned: int = _plan.unit_count()
	var out: Dictionary = {
		"spawned": spawned,
		"killed": spawned,
		"structures_lost": maxi(0, _buildings_at_dusk - _building_count()),
		"closest_cells": _profile.breach_radius * 3,
		"night_ticks": night_ticks,
		"heat_ok_ticks": heat_ok,
		"breached": false,
		"withdrew": withdrew,
		"resolved_by": "combat",
	}
	if _combat.has_method("wave_status"):
		var raw: Variant = _combat.call("wave_status", _plan.wave)
		if typeof(raw) == TYPE_DICTIONARY:
			var st: Dictionary = raw
			for key: String in ["killed", "structures_lost", "closest_cells", "breached"]:
				if st.has(key):
					out[key] = st[key]
	return out


# ==========================================================================
#  CLOCK AND CROSS-SYSTEM READS
# ==========================================================================

func _roll_day(day: int) -> void:
	# A night that is somehow still running when the day rolls is closed out
	# first; the campaign never carries two waves at once.
	if _state == ThreatDefs.WaveState.ACTIVE:
		_resolve_wave(true)
	_day = day
	if _sig_n > 0:
		_heat_signature = _sig_sum / float(_sig_n)
	_sig_sum = 0.0
	_sig_n = 0
	_plan_night(day)


func _read_day() -> int:
	if _climate != null and _climate.has_method("day"):
		return maxi(1, int(_climate.call("day")))
	return 1 + _tick / _profile.fallback_day_ticks


func _read_is_night() -> bool:
	if _climate != null and _climate.has_method("is_night"):
		return bool(_climate.call("is_night"))
	return (_tick % _profile.fallback_day_ticks) >= _profile.fallback_night_start


func _ticks_until_night() -> int:
	if _climate != null and _climate.has_method("seconds_until_night"):
		return int(round(float(_climate.call("seconds_until_night")) / SimClock.DT))
	var into: int = _tick % _profile.fallback_day_ticks
	return maxi(0, _profile.fallback_night_start - into)


func _ticks_until_dawn() -> int:
	if _climate != null and _climate.has_method("seconds_until_dawn"):
		return int(round(float(_climate.call("seconds_until_dawn")) / SimClock.DT))
	var into: int = _tick % _profile.fallback_day_ticks
	if into < _profile.fallback_night_start:
		return _profile.fallback_day_ticks - into
	return _profile.fallback_day_ticks - into


func _read_era_index() -> int:
	if _climate != null and _climate.has_method("era_index"):
		return int(_climate.call("era_index"))
	return 0


## The Great Frost calendar, read once from [P09]'s own tuning table so the
## whole campaign is known up front rather than one forecast window at a time.
func _read_storm_calendar() -> Dictionary[int, Dictionary]:
	var out: Dictionary[int, Dictionary] = {}
	if _climate == null:
		return out
	if _climate.has_method("profile"):
		var raw: Variant = _climate.call("profile")
		if typeof(raw) == TYPE_OBJECT and (raw as Object) != null \
				and (raw as Object).has_method("frost_for_day"):
			var prof: Object = raw
			for d: int in range(1, WaveSchedule.HORIZON + 1):
				var f: Variant = prof.call("frost_for_day", d)
				if typeof(f) != TYPE_DICTIONARY or (f as Dictionary).is_empty():
					continue
				var fd: Dictionary = f
				out[d] = {
					"title": String(fd.get("title", "Great Frost")),
					"intensity": float(fd.get("intensity", 1.0)),
				}
			return out
	# Fall back to the public forecast when the profile is not reachable.
	if _has_forecast:
		var raw2: Variant = _climate.call("forecast", WaveSchedule.HORIZON)
		if typeof(raw2) == TYPE_ARRAY:
			for entry: Variant in (raw2 as Array):
				if typeof(entry) != TYPE_DICTIONARY:
					continue
				var e: Dictionary = entry
				if not bool(e.get("storm", false)):
					continue
				out[int(e.get("day", 0))] = {
					"title": String(e.get("storm_title", "Great Frost")),
					"intensity": float(e.get("storm_intensity", 1.0)),
				}
	return out


## The city's heat output as the plain perceives it: everything that actually
## left the generators, delivered or lost into the cold. Sampled, not read once,
## so panicking and shutting the grid down at dusk does not fool anybody.
func _sample_heat() -> void:
	if _heat == null or not _heat.has_method("totals"):
		return
	var raw: Variant = _heat.call("totals")
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var t: Dictionary = raw
	_sig_sum += maxf(0.0, float(t.get("delivered", 0.0))) + maxf(0.0, float(t.get("loss", 0.0)))
	_sig_n += 1
	if _heat_signature <= 0.0 and _sig_n >= 4:
		# Day one has no yesterday. Seed it so the first night is not sized as
		# though the city were dark.
		_heat_signature = _sig_sum / float(_sig_n)


func _sample_night_heat() -> void:
	_night_samples += 1
	if _heat == null or not _heat.has_method("totals"):
		_night_heat_ok += 1
		return
	var raw: Variant = _heat.call("totals")
	if typeof(raw) != TYPE_DICTIONARY:
		_night_heat_ok += 1
		return
	if float((raw as Dictionary).get("deficit", 0.0)) <= 0.01:
		_night_heat_ok += 1


func _building_count() -> int:
	if _build != null and _build.has_method("building_count"):
		return int(_build.call("building_count"))
	return 0


func _combat_resolves() -> bool:
	return _combat != null


func _live_units() -> int:
	if not _combat_resolves():
		return _siege.live_units()
	if _combat.has_method("wave_status"):
		var raw: Variant = _combat.call("wave_status", _plan.wave)
		if typeof(raw) == TYPE_DICTIONARY:
			return int((raw as Dictionary).get("live", 0))
	if _combat.has_method("live_enemy_count"):
		return int(_combat.call("live_enemy_count"))
	return 0


func _live_fraction() -> float:
	if _plan == null:
		return 0.0
	var total: int = maxi(1, _plan.unit_count())
	return clampf(float(_live_units()) / float(total), 0.0, 1.0)


func _all_dispatched() -> bool:
	for g: WaveGroup in _plan.groups:
		if not g.dispatched:
			return false
	return true


func _bind() -> void:
	_climate = Sim.get_system(&"climate")
	_grid = Sim.get_system(&"grid")
	_build = Sim.get_system(&"build")
	_heat = Sim.get_system(&"heat")
	_combat = Sim.get_system(&"combat")
	_has_forecast = _climate != null and _climate.has_method("forecast")


# ==========================================================================
#  PRESENTATION HELPERS
# ==========================================================================

## World-pixel focus point for an alert: the mouth of the heaviest approach, so
## the HUD can put an arrow on it and the camera can be flown there.
func _focus() -> Vector2:
	if _plan == null or _plan.vectors.is_empty():
		var c: Vector2i = _planner.core_cell()
		return Vector2(float(c.x) * 32.0 + 16.0, float(c.y) * 32.0 + 16.0)
	var best: ThreatVector = _plan.vectors[0]
	for v: ThreatVector in _plan.vectors:
		if v.share > best.share:
			best = v
	var cell: Vector2i = best.entry_cell
	return Vector2(float(cell.x) * 32.0 + 16.0, float(cell.y) * 32.0 + 16.0)


## Fills a warning template. `precision` decides how much of the truth goes in.
func _format(line: String, precision: int, seconds: float) -> String:
	var detail: String = _plan.band_label()
	if precision >= 3:
		detail = _plan.detail_phrase()
	elif precision >= 2:
		detail = _plan.role_phrase()
	var dirs: String = _plan.direction_phrase(1 if precision <= 0 else 3)
	return line \
		.replace("{band}", _plan.band_label()) \
		.replace("{dirs}", dirs) \
		.replace("{detail}", detail) \
		.replace("{clock}", ThreatDefs.format_clock(seconds)) \
		.replace("{title}", _plan.title) \
		.replace("{wave}", str(_plan.wave))


func _strength_norm(budget: float) -> float:
	return clampf(budget / _profile.level_reference_budget, 0.0, 1.0)


# ==========================================================================
#  COMMANDS
# ==========================================================================

## Scenario and debug hooks. The real API above is what other systems call.
##   {"system":"threat","op":"force_wave"}                  start tonight now
##   {"system":"threat","op":"force_wave","strength":2.0}   ...at 2x the budget
##   {"system":"threat","op":"set_pressure","value":0.9}    0..1 inside the band
##   {"system":"threat","op":"spawn","kind":"husk","count":6,"at":[x,y]}
##   {"system":"threat","op":"peace","on":true}             sandbox: no waves
##   {"system":"threat","op":"skip_wave"}                   resolve it now
##   {"system":"threat","op":"dump"}                        log the plan
func handle_command(cmd: Dictionary) -> void:
	var op: String = String(cmd.get("op", ""))
	match op:
		"force_wave":
			_op_force_wave(cmd)
		"set_pressure":
			_pressure.set_from_command(float(cmd.get("value", 1.0)))
			Log.info(TAG, "pressure set to %.3f (band %s)" % [_pressure.pressure, _pressure.band_label()])
		"spawn":
			_op_spawn(cmd)
		"peace":
			_peace = bool(cmd.get("on", true))
			Log.info(TAG, "peace mode %s" % ("on" if _peace else "off"))
		"skip_wave":
			if _state == ThreatDefs.WaveState.ACTIVE:
				_resolve_wave(true)
		"dump":
			_op_dump()
		_:
			Log.error(TAG, "unknown command op '%s'" % op)


func _op_force_wave(cmd: Dictionary) -> void:
	if _plan == null:
		_plan_night(_day)
	if _state == ThreatDefs.WaveState.ACTIVE:
		_resolve_wave(true)
	var strength: float = float(cmd.get("strength", 0.0))
	if strength > 0.0:
		_plan.budget *= strength
		_plan.breakdown["total"] = snappedf(_plan.budget, 0.01)
		_plan.composition = WaveComposer.compose(_profile, _plan.wave, _plan.budget,
			_plan.shape, _defs, Rng.stream(RNG_STREAM))
		_plan.locked = false
		_distribute(_plan)
	_begin_wave()


func _op_spawn(cmd: Dictionary) -> void:
	var kind: StringName = StringName(String(cmd.get("kind", "")))
	var def: EnemyDef = Registry.get_item(CATEGORY, kind) as EnemyDef
	if def == null:
		Log.error(TAG, "spawn: no enemy '%s' in game/content/enemies/" % kind)
		return
	if _plan == null:
		_plan_night(_day)
	if _plan.vectors.is_empty():
		Log.error(TAG, "spawn: this world has no approach vector to walk in on")
		return
	# The wave has to be live BEFORE the group is appended: starting one locks
	# the vectors and re-distributes the plan, which would throw the group away.
	if _state != ThreatDefs.WaveState.ACTIVE:
		_begin_wave()
	var count: int = maxi(1, int(cmd.get("count", 1)))
	var g := WaveGroup.new()
	g.enemy = kind
	g.count = count
	g.cost = def.cost * float(count)
	g.vector = 0
	g.spawn_cell = _plan.vectors[0].entry_cell
	var at: Variant = cmd.get("at", null)
	if typeof(at) == TYPE_ARRAY and (at as Array).size() >= 2:
		g.spawn_cell = Vector2i(int((at as Array)[0]), int((at as Array)[1]))
	g.delay_ticks = 0
	g.dispatched = true
	_plan.groups.append(g)
	if _combat_resolves():
		g.handle = _spawn_through_combat(g, _plan.vectors[0])
	else:
		_siege.dispatch(g, _plan)
	Log.info(TAG, "spawned %d %s at %s" % [count, kind, g.spawn_cell])


func _op_dump() -> void:
	if _plan == null:
		Log.info(TAG, "no plan")
		return
	Log.info(TAG, "plan: %s" % JSON.stringify(_plan.to_dict()))
	Log.info(TAG, "schedule: %s" % JSON.stringify(_schedule.to_dict()))


# ==========================================================================
#  STATE
# ==========================================================================

func serialize() -> Dictionary:
	return {
		"wave": _wave,
		"day": _day,
		"state": String(ThreatDefs.wave_state_name(_state)),
		"threat_level": snappedf(threat_level(), 0.001),
		"budget": snappedf(_plan.budget if _plan != null else 0.0, 0.01),
		"waves_cleared": _waves_cleared,
		"waves_survived": _waves_survived,
		"waves_started": _waves_started,
		"breach_reported": _breach_reported,
		"pressure": snappedf(_pressure.pressure, 0.0001),
		"pressure_band": _pressure.band_label(),
		"peace": _peace,
		"heat_signature": snappedf(_heat_signature, 0.01),
		"signature_accum": [snappedf(_sig_sum, 0.01), _sig_n],
		"night_start": _night_start_tick,
		"night_samples": [_night_samples, _night_heat_ok],
		"buildings_at_dusk": _buildings_at_dusk,
		"plan": _plan.to_dict() if _plan != null else {},
		"schedule": _schedule.to_dict(),
		"pressure_state": _pressure.to_dict(),
		"siege": _siege.to_dict(_plan),
		"last_report": _last_report,
		"profile": String(_profile.id),
	}


func deserialize(data: Dictionary) -> void:
	_wave = int(data.get("wave", 0))
	_day = maxi(1, int(data.get("day", 1)))
	_state = ThreatDefs.WAVE_STATE_NAMES.find(StringName(String(data.get("state", "idle"))))
	if _state < 0:
		_state = ThreatDefs.WaveState.IDLE
	_waves_cleared = int(data.get("waves_cleared", 0))
	_waves_survived = int(data.get("waves_survived", 0))
	_waves_started = int(data.get("waves_started", 0))
	_breach_reported = int(data.get("breach_reported", 0))
	_peace = bool(data.get("peace", false))
	_heat_signature = float(data.get("heat_signature", 0.0))
	var accum: Variant = data.get("signature_accum", [])
	if typeof(accum) == TYPE_ARRAY and (accum as Array).size() >= 2:
		_sig_sum = float((accum as Array)[0])
		_sig_n = int((accum as Array)[1])
	_night_start_tick = int(data.get("night_start", 0))
	var ns: Variant = data.get("night_samples", [])
	if typeof(ns) == TYPE_ARRAY and (ns as Array).size() >= 2:
		_night_samples = int((ns as Array)[0])
		_night_heat_ok = int((ns as Array)[1])
	_buildings_at_dusk = int(data.get("buildings_at_dusk", 0))

	var raw_plan: Variant = data.get("plan", {})
	_plan = null
	if typeof(raw_plan) == TYPE_DICTIONARY and not (raw_plan as Dictionary).is_empty():
		_plan = WavePlan.from_dict(raw_plan)
	var ps: Variant = data.get("pressure_state", {})
	if typeof(ps) == TYPE_DICTIONARY:
		_pressure.from_dict(ps)
	var sg: Variant = data.get("siege", {})
	if typeof(sg) == TYPE_DICTIONARY:
		_siege.from_dict(sg)
	var lr: Variant = data.get("last_report", {})
	_last_report = lr if typeof(lr) == TYPE_DICTIONARY else {}
	_was_night = _read_is_night()


func metrics() -> Dictionary:
	return {
		"wave": _wave,
		"threat_level": snappedf(threat_level(), 0.001),
		"budget": snappedf(_plan.budget if _plan != null else 0.0, 0.01),
		"waves_cleared": _waves_cleared,
		"waves_survived": _waves_survived,
		"pressure": snappedf(_pressure.pressure, 0.001),
		"pressure_band": _pressure.band_label(),
		"live": _live_units() if _state == ThreatDefs.WaveState.ACTIVE else 0,
		"heat_signature": snappedf(_heat_signature, 0.01),
		"state": String(ThreatDefs.wave_state_name(_state)),
	}


# ==========================================================================
#  CONTENT
# ==========================================================================

func _load_defs() -> void:
	_defs.clear()
	for res: Resource in Registry.all(CATEGORY):
		var d: EnemyDef = res as EnemyDef
		if d == null:
			Log.warn(TAG, "ignoring %s in game/content/enemies/: not an EnemyDef" % res.resource_path)
			continue
		var problems: PackedStringArray = d.validate()
		if not problems.is_empty():
			Log.error(TAG, "enemy '%s' is malformed: %s" % [d.id, ", ".join(problems)])
			continue
		_defs.append(d)
	_defs.sort_custom(func(a: EnemyDef, b: EnemyDef) -> bool: return String(a.id) < String(b.id))
	if _defs.is_empty():
		Log.warn(TAG, "no enemies in game/content/enemies/ — every night will be empty")


func _load_profile() -> ThreatProfile:
	var best: ThreatProfile = null
	for res: Resource in Registry.all(PROFILE_CATEGORY):
		var p: ThreatProfile = res as ThreatProfile
		if p == null:
			continue
		if best == null or p.priority > best.priority:
			best = p
	if best == null:
		return ThreatProfile.new()
	return best.duplicate(true) as ThreatProfile
