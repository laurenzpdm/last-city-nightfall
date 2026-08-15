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
## Ticks between the profiling lines this system writes at DEBUG level. Short
## enough that a 3000-tick perf scenario still reports what this part cost.
const LOG_PERF_EVERY: int = 1000

# --- tuning and content ------------------------------------------------------
var _profile: ThreatProfile = null
## The roster, adapted from whatever schema game/content/enemies/ is authored in.
var _defs: Array[ThreatUnit] = []
var _by_id: Dictionary[StringName, ThreatUnit] = {}

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
## This is NOT what `waves_cleared()` reports — see the accessor for why.
var _waves_wiped: int = 0
## Nights that ended at all, cleanly or otherwise. One per `Bus.wave_cleared`.
var _waves_survived: int = 0
var _waves_started: int = 0
var _night_start_tick: int = 0
## A wave forced by a command in broad daylight must not be ended by the "dawn
## closes the night" rule on the very tick it started. It ends when it is dead,
## at the next real dawn, or at the safety valve below — never instantly.
var _wave_saw_night: bool = false
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
## Snapshots of [P07]'s monotonic counters taken at nightfall. Every number in
## the post-mortem is a delta against these rather than a reading of combat's
## own per-wave record, so a bookkeeping bug in another part can slow the
## director down but can never end a night early or invent a clean sweep.
var _alive_at_dusk: int = 0
var _kills_at_dusk: int = 0
var _lost_at_dusk: int = 0
var _breaches_at_dusk: int = 0
var _damage_at_dusk: float = 0.0
var _shots_at_dusk: int = 0
var _heat_at_dusk: float = 0.0
var _engaged_at_dusk: int = 0
var _ready_at_dusk: int = 0
var _gun_ticks_at_dusk: int = 0
## One row per night that has ended: what came, what it cost, what the wall did.
## This is the campaign's own record — the table a critic reads instead of
## being told the fight is escalating.
var _nights: Array[Dictionary] = []
## [P02]'s balance sheet, cached for the tick it was read on.
var _totals: Dictionary = {}
var _totals_tick: int = -1

# --- profiling. Never reaches serialize() or metrics(); see step(). ----------
## Total wall time inside step(), and the part of it spent inside OTHER parts'
## code that this system called synchronously — handing a group to [P07] runs
## [P07]'s spawn, and on first contact that includes a one-off 80 ms flood of
## its siege surface. Both numbers are logged, because charging another part's
## one-time build to this system's per-tick budget would be a lie in either
## direction.
var _perf_us: int = 0
var _perf_max_us: int = 0
var _perf_own_max_us: int = 0
var _perf_extern_us: int = 0
var _perf_steps: int = 0
var _extern_us: int = 0


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
	_waves_wiped = 0
	_waves_survived = 0
	_waves_started = 0
	_state = ThreatDefs.WaveState.IDLE
	_plan = null
	_wave_saw_night = false
	_last_report = {}
	_breach_reported = 0
	_peace = false
	_heat_signature = 0.0
	_sig_sum = 0.0
	_sig_n = 0
	_nights.clear()
	_perf_us = 0
	_perf_max_us = 0
	_perf_steps = 0


func post_setup() -> void:
	_bind()
	_schedule.build(_profile, _read_storm_calendar())
	_planner.bind(_profile, _grid, _build, _heat)
	_planner.build_vectors()
	_siege.bind(_profile, _planner, _build, _grid, _by_id)
	_day = _read_day()
	_was_night = _read_is_night()
	_plan_night(_day)
	var pieces: Array[int] = _schedule.set_piece_nights()
	Log.info(TAG, "director ready: %d enemy kind(s), set pieces on %s, band %s" % [
		_defs.size(), str(pieces.slice(0, 8)), _pressure.band_label()])


func step(tick: int) -> void:
	var t0: int = Time.get_ticks_usec()  # lint:allow profiling only; never serialized
	_extern_us = 0
	_tick = tick

	var day: int = _read_day()
	if day != _day:
		_roll_day(day)

	if tick % _profile.heat_sample_interval == 0:
		_sample_heat()
		if _state == ThreatDefs.WaveState.ACTIVE:
			_sample_night_heat()

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
	_perf_extern_us += _extern_us
	_perf_max_us = maxi(_perf_max_us, us)
	_perf_own_max_us = maxi(_perf_own_max_us, us - _extern_us)
	_perf_steps += 1
	if _perf_steps >= LOG_PERF_EVERY:
		Log.debug(TAG, "step avg %.1f us (own %.1f), max %d us (own %d) over %d ticks; %d lane scan(s), worst %d us" % [
			float(_perf_us) / float(_perf_steps),
			float(_perf_us - _perf_extern_us) / float(_perf_steps),
			_perf_max_us, _perf_own_max_us, _perf_steps,
			_planner.scans, _planner.worst_us])
		_perf_us = 0
		_perf_extern_us = 0
		_perf_max_us = 0
		_perf_own_max_us = 0
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
	var size: float = _strength_norm(_plan.budget, _plan.wave)
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
		"strength": snappedf(_strength_norm(_plan.budget, _plan.wave), 0.001),
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


## Nights that are over — one per `Bus.wave_cleared`, and the number every panel
## that says "Nights cleared" is quoting.
##
## It used to report only the nights that were WIPED, which made it a second,
## stricter counter of an event the bus already announces: a night the city held
## at dawn with one survivor walking away fired `Bus.wave_cleared`, toasted
## "Wave 1 is over", played the relief cue — and left this at zero. Downstream
## that was not cosmetic: [P22] draws its one morning line per fought night off
## this number, and [P06]'s "the line held" hope impulse off its delta, so both
## simply skipped any night that was not a clean sweep. The wiped count is still
## kept, under the name that says what it is.
func waves_cleared() -> int:
	return _waves_survived


## Nights that ended with nothing of the wave left standing. A subset of
## `waves_cleared()`, and the harder thing to do.
func waves_wiped() -> int:
	return _waves_wiped


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
	p.units = _by_id
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
	var total_units: int = 0
	for entry: Dictionary in p.composition:
		var total: int = int(entry.get("count", 0))
		if total <= 0:
			continue
		var def: ThreatUnit = entry.get("def")
		var per_unit: float = float(entry.get("cost", 0.0)) / float(maxi(1, total))
		var counts: PackedInt32Array = _apportion(total, p.vectors)
		for i: int in p.vectors.size():
			if counts[i] <= 0:
				continue
			rows.append({
				"enemy": StringName(String(entry.get("enemy", ""))),
				"count": counts[i],
				"per_unit": per_unit,
				"vector": i,
				"tier": def.tier if def != null else 1,
				"unit_cost": def.cost if def != null else 0.0,
			})
			total_units += counts[i]

	# Arrival order: the small and the quick first, the heavy last. A night that
	# opens with its anchor is one decision; a night that ends with it is five.
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["tier"]) != int(b["tier"]):
			return int(a["tier"]) < int(b["tier"])
		if absf(float(a["unit_cost"]) - float(b["unit_cost"])) > 0.0001:
			return float(a["unit_cost"]) < float(b["unit_cost"])
		if int(a["vector"]) != int(b["vector"]):
			return int(a["vector"]) < int(b["vector"])
		if int(a["count"]) != int(b["count"]):
			return int(a["count"]) > int(b["count"])
		return String(a["enemy"]) < String(b["enemy"]))

	# THE ECHELONS — why a night is a night and not a metronome.
	#
	# The old rule cut every kind on every vector into packets of four and spread
	# the packets evenly, so a 28-unit night arrived as eight lots of four with
	# 340 empty ticks between them and `combat.enemies_alive` never once passed 4.
	# Now the night is cut into a handful of ARRIVAL MOMENTS instead, sized
	# against the wave's own budget, and every group belonging to a moment lands
	# on the same tick — a column of hounds with its breakers behind it, not four
	# hounds, silence, four hounds.
	var echelons: int = _profile.echelon_count(p.wave, total_units, p.budget)
	var per_echelon: int = maxi(1, (total_units + echelons - 1) / echelons)
	var e: int = 0
	var room: int = per_echelon
	for row: Dictionary in rows:
		var left: int = int(row["count"])
		while left > 0:
			if room <= 0 and e < echelons - 1:
				e += 1
				room = per_echelon
			# The last echelon has no ceiling: whatever the packing has not placed
			# by then arrives with it. Dropping the remainder would break the one
			# promise the telegraph makes — that exactly what was named turns up.
			var take: int = left if e >= echelons - 1 else mini(left, room)
			var g := WaveGroup.new()
			g.enemy = row["enemy"]
			g.count = take
			g.cost = float(row["per_unit"]) * float(take)
			g.vector = int(row["vector"])
			g.spawn_cell = p.vectors[g.vector].entry_cell
			g.echelon = e
			g.delay_frac = 0.0 if echelons <= 1 else float(e) / float(echelons - 1)
			g.delay_ticks = int(round(float(_profile.spawn_window_ticks) * g.delay_frac))
			p.spent += g.cost
			p.groups.append(g)
			room -= take
			left -= take
	_stamp_arrivals(p)


## Turns each packet's place in the arrival window into a tick, against the
## length of the night it will actually be fought in. Called again at nightfall,
## when dawn_tick is known — before that it uses the profile's floor.
func _stamp_arrivals(p: WavePlan) -> void:
	var window: int = _profile.spawn_window_ticks
	var night: int = p.dawn_tick - p.night_start_tick
	if night > 0:
		# The last packet still arrives with a real slice of the night left to
		# fight it in, so a wave is never decided by the sunrise.
		window = clampi(int(round(float(night) * _profile.spawn_window_share)),
			mini(_profile.spawn_window_ticks, night / 2),
			maxi(1, night - _profile.wave_settle_ticks * 2))
	for g: WaveGroup in p.groups:
		g.delay_ticks = int(round(float(window) * g.delay_frac))


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



## Signal emission runs every listener synchronously, so the audio mix, the HUD
## and the narrative layer reacting to a wave are all charged to whoever emitted
## it. These two wrappers move that time out of this part's OWN budget and into
## the external one. It is not hidden — it stays in the total — it is simply not
## counted as the director's work, because it is not.
func _extern_begin() -> int:
	return Time.get_ticks_usec()  # lint:allow profiling only; never serialized


func _extern_end(t0: int) -> void:
	_extern_us += Time.get_ticks_usec() - t0  # lint:allow profiling only


func _emit_warning(rung: int, precision: int, until_ticks: int) -> void:
	var seconds: float = float(until_ticks) * SimClock.DT
	var line: String = _format(_profile.warning_lines[rung], precision, seconds)
	var t0: int = _extern_begin()
	Bus.wave_incoming.emit(_plan.wave, seconds)
	Bus.alert_raised.emit(ThreatDefs.MAX_BUS_SEVERITY, ThreatDefs.KEY_WARNING, line, _focus())
	Bus.narrative_event.emit(ThreatDefs.KEY_WARNING, {
		"wave": _plan.wave,
		"rung": rung,
		"precision": precision,
		"seconds_until": snappedf(seconds, 0.05),
		"text": line,
		"strength": snappedf(_strength_norm(_plan.budget, _plan.wave), 0.001),
		"strength_label": _plan.band_label(),
		"directions": _plan.direction_labels(),
		"set_piece": _plan.set_piece,
		"title": _plan.title,
		"preview": next_wave_preview(),
	})
	_extern_end(t0)
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
	var t0: int = _extern_begin()
	Bus.alert_raised.emit(ThreatDefs.MAX_BUS_SEVERITY, ThreatDefs.KEY_SET_PIECE, line, _focus())
	Bus.narrative_event.emit(ThreatDefs.KEY_SET_PIECE, {
		"wave": p.wave,
		"title": p.title,
		"storm_synced": p.storm_synced,
		"storm": p.storm_title,
		"text": line,
		"strength": snappedf(_strength_norm(p.budget, p.wave), 0.001),
	})
	_extern_end(t0)
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
	_wave_saw_night = _read_is_night()
	_plan.night_start_tick = _tick
	_plan.dawn_tick = _tick + _ticks_until_dawn()
	# The length of the night is only knowable now. Re-stamp the arrivals against
	# it so the attack is spread over THIS night rather than over a constant.
	_stamp_arrivals(_plan)
	_waves_started += 1
	_night_samples = 0
	_night_heat_ok = 0
	_buildings_at_dusk = _building_count()
	_alive_at_dusk = _enemies_alive()
	_kills_at_dusk = _combat_counter("kills")
	_lost_at_dusk = _combat_counter("structures_lost")
	_breaches_at_dusk = _combat_counter("breaches")
	var d0: Dictionary = _defence_now()
	_damage_at_dusk = float(d0.get("damage_taken", 0.0))
	_shots_at_dusk = int(d0.get("shots", 0))
	_heat_at_dusk = float(d0.get("heat_spent", 0.0))
	_engaged_at_dusk = int(d0.get("engaged_ticks", 0))
	_ready_at_dusk = int(d0.get("ready_ticks", 0))
	_gun_ticks_at_dusk = int(d0.get("live_ticks", 0))
	_siege.begin(_plan)

	var line: String = _format(_profile.wave_started_line, 3, 0.0)
	var t0: int = _extern_begin()
	Bus.wave_started.emit(_plan.wave, _strength_norm(_plan.budget, _plan.wave))
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
	_extern_end(t0)
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
		_check_breach()

	if night:
		_wave_saw_night = true
	elif _wave_saw_night and _profile.withdraw_at_dawn:
		_resolve_wave(true)
		return
	elif tick - _night_start_tick > _profile.fallback_day_ticks:
		# Safety valve: a wave that somehow never sees a night still ends.
		_resolve_wave(true)
		return

	# THE WATCHDOG. Everything above depends on somebody else's clock — [P09]'s
	# day, [P09]'s dawn, [P07]'s idea of what is still alive. This depends on
	# nothing: a night that has run this long is a bug, it is said out loud as
	# one, and the campaign carries on instead of freezing on wave two for ever.
	if tick - _night_start_tick > _profile.wave_hard_timeout_ticks:
		Log.error(TAG, ("wave %d has been live for %d ticks (limit %d) with %d unit(s) "
			+ "still reported alive — resolving it by watchdog") % [
			_plan.wave, tick - _night_start_tick, _profile.wave_hard_timeout_ticks,
			_live_units()])
		_resolve_wave(true)
		return
	# "Nothing is alive" only means the night is over once everything has been
	# handed over AND whoever owns the bodies has had time to put them on the
	# map. Polling on the dispatch tick itself would end every wave at dusk.
	#
	# Polled twice a second rather than every tick: asking [P07] how a wave is
	# going costs a scan of the whole swarm, and half a second of latency on the
	# end of a night is invisible.
	if tick % _profile.poll_interval_ticks == 0 and _settled(tick) and _live_units() <= 0:
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
		var t0: int = _extern_begin()
		Bus.narrative_event.emit(ThreatDefs.KEY_CONTACT, {
			"wave": _plan.wave,
			"enemy": String(g.enemy),
			"count": g.count,
			"cell": [g.spawn_cell.x, g.spawn_cell.y],
			"compass": String(v.compass()),
		})
		_extern_end(t0)


func _spawn_through_combat(g: WaveGroup, v: ThreatVector) -> int:
	var t0: int = Time.get_ticks_usec()  # lint:allow profiling only; never serialized
	var out: int = _spawn_through_combat_inner(g, v)
	_extern_us += Time.get_ticks_usec() - t0  # lint:allow profiling only
	return out


func _spawn_through_combat_inner(g: WaveGroup, v: ThreatVector) -> int:
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
	var through: bool = _siege.breached if not _combat_resolves() \
		else _combat_counter("breaches") > _breaches_at_dusk
	if not through or _breach_reported == _plan.wave:
		return
	_breach_reported = _plan.wave
	var line: String = _profile.wave_breached_line.replace("{dirs}", _plan.direction_phrase(1))
	var t0: int = _extern_begin()
	Bus.alert_raised.emit(ThreatDefs.MAX_BUS_SEVERITY, ThreatDefs.KEY_BREACH, line, _focus())
	Bus.narrative_event.emit(ThreatDefs.KEY_BREACH, {"wave": _plan.wave, "text": line})
	_extern_end(t0)
	Log.warn(TAG, "wave %d breached the city" % _plan.wave)


## Ends the night, measures it, and lets that measurement move the pressure
## multiplier inside its declared band.
func _resolve_wave(at_dawn: bool) -> void:
	var withdrew: int = 0
	if at_dawn:
		# Survivors go back onto the plain, because a wave has to END. Leaving
		# [P07]'s bodies standing where they were and calling them "the day's
		# problem" is what produced a keener that outlived its own night by six
		# thousand ticks, ate a storage yard and a heat main at four damage a
		# second, and kept `live` above zero so no later night could ever finish.
		# A survivor is now ordered to break off and walk back out, visibly.
		withdrew = _withdraw_survivors()
	var night_ticks: int = maxi(1, _tick - _night_start_tick)
	var heat_ok: int = night_ticks if _night_samples <= 0 else int(
		round(float(night_ticks) * float(_night_heat_ok) / float(_night_samples)))
	var outcome: Dictionary = _outcome(night_ticks, heat_ok, withdrew)
	var record: Dictionary = _pressure.record(outcome)

	_state = ThreatDefs.WaveState.RESOLVED
	_waves_survived += 1
	# Whether the wave was WIPED — nothing of it left standing — is what the
	# verdict and the night's record are graded on. It is deliberately not the
	# number `waves_cleared()` publishes: see that accessor.
	var wiped: bool = int(outcome.get("killed", 0)) >= int(outcome.get("spawned", 0)) \
		and withdrew == 0
	if wiped:
		_waves_wiped += 1
	var detail: String = "%d of %d put down%s" % [
		int(outcome.get("killed", 0)), maxi(1, int(outcome.get("spawned", 0))),
		"" if int(outcome.get("structures_lost", 0)) == 0
			else ", %d structure%s lost" % [int(outcome.get("structures_lost", 0)),
				"" if int(outcome.get("structures_lost", 0)) == 1 else "s"]]
	# The verdict comes FIRST, in words, because that is the thing a player needs
	# before any of the numbers: was that a good night or a bad one.
	var verdict: int = ThreatDefs.verdict_of(outcome, wiped, withdrew)
	var line: String = "%s %s" % [ThreatDefs.verdict_label(verdict),
		_profile.wave_cleared_line.replace("{wave}", str(_plan.wave)).replace("{detail}", detail)]
	# WHAT THE NIGHT TOOK. A night that costs nothing is a night the player has no
	# reason to have prepared for, and this build ran three of them with
	# structures_lost flat at zero. The bill is read at dawn, in words, before any
	# number: which buildings are missing and who was in them.
	var toll_rows: Array[Dictionary] = _night_toll()
	var toll_line: String = _night_toll_line()
	if toll_line != "":
		line = "%s %s" % [line, toll_line]
	var toll_dead: int = 0
	var toll_hurt: int = 0
	for row: Dictionary in toll_rows:
		toll_dead += (row.get("dead", []) as Array).size()
		toll_hurt += int(row.get("hurt", 0))

	var defence: Dictionary = _defence_delta()
	_nights.append({
		"night": _plan.wave,
		"day": _plan.day,
		"budget": snappedf(_plan.budget, 0.01),
		"band": _plan.band_label(),
		"set_piece": _plan.set_piece,
		"vectors": _plan.direction_labels(),
		"spawned": int(outcome.get("spawned", 0)),
		"killed": int(outcome.get("killed", 0)),
		"withdrew": withdrew,
		"wiped": wiped,
		"verdict": String(ThreatDefs.verdict_key(verdict)),
		"structures_lost": int(outcome.get("structures_lost", 0)),
		"breached": bool(outcome.get("breached", false)),
		"dead": toll_dead,
		"hurt": toll_hurt,
		"toll": toll_rows,
		"toll_text": toll_line,
		"damage_taken": defence.get("damage_taken", 0.0),
		"shots_fired": defence.get("shots", 0),
		"heat_spent": defence.get("heat_spent", 0.0),
		"turrets": defence.get("turrets", 0),
		"cold_turrets": defence.get("cold", 0),
		"engaged": defence.get("engaged", 0.0),
		"night_ticks": int(outcome.get("night_ticks", 0)),
		"comfort": record.get("comfort", 0.0),
	})

	_last_report = {
		"wave": _plan.wave,
		"day": _plan.day,
		"defence": defence,
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
		"wiped": wiped,
		"dead": toll_dead,
		"hurt": toll_hurt,
		"toll": toll_rows,
		"toll_text": toll_line,
		"verdict": String(ThreatDefs.verdict_key(verdict)),
		"verdict_text": ThreatDefs.verdict_label(verdict),
		"ended_at_dawn": at_dawn,
		"text": line,
	}

	var t0: int = _extern_begin()
	Bus.wave_cleared.emit(_plan.wave)
	Bus.alert_raised.emit(0, ThreatDefs.KEY_WAVE_CLEARED, line, _focus())
	Bus.narrative_event.emit(ThreatDefs.KEY_WAVE_CLEARED, _last_report.duplicate(true))
	if withdrew > 0:
		Bus.narrative_event.emit(ThreatDefs.KEY_WITHDRAW, {
			"wave": _plan.wave, "survivors": withdrew,
			"text": ("%d of them are still on the ground when the sun comes up." % withdrew)
				if _combat_resolves()
				else ("%d of them went back out onto the plain with the light." % withdrew)})
	_extern_end(t0)
	Log.info(TAG, "wave %d resolved: %s | comfort %.2f, pressure %.3f -> %.3f (band %s)" % [
		_plan.wave, detail, float(record.get("comfort", 0.0)),
		float(record.get("pressure_before", 1.0)), float(record.get("pressure_after", 1.0)),
		_pressure.band_label()])
	# The night in the six numbers a player can feel, in one line, every night.
	Log.info(TAG, ("night %d: %d spawned, %d killed, %d walked away | %d shot(s), %.1f heat "
		+ "on the guns, %d of %d cold | %.0f structural damage, %d lost%s") % [
		_plan.wave, int(outcome.get("spawned", 0)), int(outcome.get("killed", 0)), withdrew,
		int(defence.get("shots", 0)), float(defence.get("heat_spent", 0.0)),
		int(defence.get("cold", 0)), int(defence.get("turrets", 0)),
		float(defence.get("damage_taken", 0.0)), int(outcome.get("structures_lost", 0)),
		" | THEY GOT THROUGH" if bool(outcome.get("breached", false)) else ""])
	if toll_line != "":
		Log.info(TAG, "night %d took: %s" % [_plan.wave, toll_line])


## Sends whatever is left of the night home. Combat turns them around and walks
## them off the map; the siege model melts them back into the dark. Either way
## the field is empty afterwards and nothing survives into tomorrow.
func _withdraw_survivors() -> int:
	if not _combat_resolves():
		return _siege.withdraw()
	var live: int = maxi(0, _live_units())
	if _combat.has_method("withdraw_wave"):
		var t0: int = _extern_begin()
		var n: int = int(_combat.call("withdraw_wave", -1))
		_extern_end(t0)
		return maxi(n, live)
	# No withdrawal contract in this build of [P07]: say so rather than quietly
	# leaving bodies standing on the map for the rest of the campaign.
	if live > 0:
		Log.warn(TAG, ("[P07] has no withdraw_wave(); %d survivor(s) of wave %d are being "
			+ "left on the map") % [live, _plan.wave])
	return live


## The night's numbers, from combat when it owns the field and from the siege
## model when it does not. Structures lost falls back to the change in the
## city's building count, which is the only universally available signal.
func _outcome(night_ticks: int, heat_ok: int, withdrew: int) -> Dictionary:
	if not _combat_resolves():
		var o: Dictionary = _siege.outcome(night_ticks, heat_ok)
		o["withdrew"] = withdrew
		return o
	var spawned: int = _plan.unit_count()
	var breaches: int = maxi(0, _combat_counter("breaches") - _breaches_at_dusk)
	var lost: int = maxi(0, _combat_counter("structures_lost") - _lost_at_dusk)
	if lost == 0:
		# Nothing published a count, so fall back to the only universally
		# available signal: the city is smaller than it was at dusk.
		lost = maxi(0, _buildings_at_dusk - _building_count())
	# Of what was put on the field, whatever is not still standing is down. This
	# is deliberately computed from survivors rather than read from combat's
	# `killed`, which is derived from the same broken per-wave record as `live`
	# and would report a clean sweep for a night that was never fought.
	var killed: int = clampi(spawned - maxi(0, withdrew), 0, spawned)
	killed = maxi(killed, mini(_derived_killed(), spawned))
	# Combat does not publish how close anything got, only whether the line was
	# broken. A breach is treated as contact at the breach radius, no breach as
	# a wave that never reached it — coarse, but never a flattering guess.
	var closest: int = _profile.breach_radius if breaches > 0 else _profile.breach_radius * 3
	return {
		"spawned": spawned,
		"killed": clampi(killed, 0, spawned),
		"structures_lost": lost,
		"closest_cells": closest,
		"night_ticks": night_ticks,
		"heat_ok_ticks": heat_ok,
		"breached": breaches > 0,
		"breaches": breaches,
		"withdrew": withdrew,
		"resolved_by": "combat",
	}


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


## [P02]'s city-wide balance sheet, fetched AT MOST ONCE PER TICK and charged to
## the external budget. It is not a cheap call — it walks the whole warmth field
## to produce an average this system does not even use — so everything here goes
## through this one accessor and everything here is sampled, never polled.
func _heat_totals() -> Dictionary:
	if _totals_tick == _tick:
		return _totals
	_totals_tick = _tick
	_totals = {}
	if _heat == null or not _heat.has_method("totals"):
		return _totals
	var t0: int = Time.get_ticks_usec()  # lint:allow profiling only; never serialized
	var raw: Variant = _heat.call("totals")
	_extern_us += Time.get_ticks_usec() - t0  # lint:allow profiling only
	if typeof(raw) == TYPE_DICTIONARY:
		_totals = raw
	return _totals


## The city's heat output as the plain perceives it: everything that actually
## left the generators, delivered or lost into the cold. Sampled, not read once,
## so panicking and shutting the grid down at dusk does not fool anybody.
func _sample_heat() -> void:
	var t: Dictionary = _heat_totals()
	if t.is_empty():
		return
	_sig_sum += maxf(0.0, float(t.get("delivered", 0.0))) + maxf(0.0, float(t.get("loss", 0.0)))
	_sig_n += 1
	if _heat_signature <= 0.0 and _sig_n >= 4:
		# Day one has no yesterday. Seed it so the first night is not sized as
		# though the city were dark.
		_heat_signature = _sig_sum / float(_sig_n)


func _sample_night_heat() -> void:
	_night_samples += 1
	var t: Dictionary = _heat_totals()
	if t.is_empty() or float(t.get("deficit", 0.0)) <= 0.01:
		_night_heat_ok += 1


## What the wall is doing right now, read off [P07]. Empty when combat is absent.
func _defence_now() -> Dictionary:
	if _combat == null or not _combat.has_method("defence_report"):
		return {}
	var t0: int = _extern_begin()
	var raw: Variant = _combat.call("defence_report")
	_extern_end(t0)
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var r: Dictionary = raw
	r["damage_taken"] = float(_combat.get("damage_taken")) if "damage_taken" in _combat else 0.0
	return r


## What the wall did between dusk and now: shots, heat, and the damage the city
## absorbed. Monotonic counters differenced against the dusk snapshot, so a
## bookkeeping bug in [P07] can understate a night but can never invent one.
func _defence_delta() -> Dictionary:
	var now: Dictionary = _defence_now()
	if now.is_empty():
		return {"turrets": 0, "cold": 0, "shots": 0, "heat_spent": 0.0,
			"damage_taken": 0.0, "engaged": 0.0, "uptime": 0.0}
	# Gun-ticks THIS NIGHT, not since world creation. A wall that fought
	# perfectly for three minutes reads as 1% engaged once fifteen thousand ticks
	# of daylight are in the denominator, which is how a defence that never fires
	# and a defence that never stops look like the same number.
	var gun_ticks: int = maxi(1, int(now.get("live_ticks", 0)) - _gun_ticks_at_dusk)
	return {
		"turrets": int(now.get("turrets", 0)),
		"cold": int(now.get("cold", 0)) + int(now.get("offline", 0)),
		"dry": int(now.get("dry", 0)),
		"shots": maxi(0, int(now.get("shots", 0)) - _shots_at_dusk),
		"heat_spent": snappedf(maxf(0.0, float(now.get("heat_spent", 0.0)) - _heat_at_dusk), 0.1),
		"damage_taken": snappedf(maxf(0.0,
			float(now.get("damage_taken", 0.0)) - _damage_at_dusk), 0.1),
		"engaged": snappedf(float(maxi(0,
			int(now.get("engaged_ticks", 0)) - _engaged_at_dusk)) / float(gun_ticks), 0.001),
		"uptime": snappedf(float(maxi(0,
			int(now.get("ready_ticks", 0)) - _ready_at_dusk)) / float(gun_ticks), 0.001),
		"gun_ticks": gun_ticks,
	}


## The campaign so far, one row per night that ended. Tests, the harness dump and
## the post-run report read this instead of trusting a summary.
func nights() -> Array[Dictionary]:
	return _nights.duplicate(true)


## What [P07] says this night cost, one row per structure with the names of
## whoever was inside it. Empty in a build with no combat system — the siege
## model is an abstraction and has nobody to lose.
func _night_toll() -> Array[Dictionary]:
	if _combat == null or not _combat.has_method("night_toll"):
		return []
	var raw: Variant = _combat.call("night_toll", _night_start_tick)
	var out: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for row: Variant in (raw as Array):
		if typeof(row) == TYPE_DICTIONARY:
			out.append(row)
	return out


func _night_toll_line() -> String:
	if _combat == null or not _combat.has_method("night_toll_line"):
		return ""
	return String(_combat.call("night_toll_line", _night_start_tick))


## Bodies the current plan puts on the map at its busiest single moment.
func _peak_arrival() -> int:
	if _plan == null:
		return 0
	var by_tick: Dictionary[int, int] = {}
	for g: WaveGroup in _plan.groups:
		by_tick[g.delay_ticks] = int(by_tick.get(g.delay_ticks, 0)) + g.count
	var peak: int = 0
	for k: int in by_tick.keys():
		peak = maxi(peak, by_tick[k])
	return peak


func _building_count() -> int:
	if _build != null and _build.has_method("building_count"):
		return int(_build.call("building_count"))
	return 0


func _combat_resolves() -> bool:
	return _combat != null


## Bodies on the field right now, whoever owns them.
func _enemies_alive() -> int:
	if _combat == null:
		return 0
	if _combat.has_method("live_enemy_count"):
		return int(_combat.call("live_enemy_count"))
	if _combat.has_method("enemies_alive"):
		return int(_combat.call("enemies_alive"))
	return 0


## A monotonic counter [P07] publishes, or 0.
func _combat_counter(name: String) -> int:
	if _combat == null or not (name in _combat):
		return 0
	return int(_combat.get(name))


## How much of TONIGHT'S wave is still standing.
##
## Two sources, and the larger wins. [P07] keeps a per-wave record and answers
## wave_status(); when that record is healthy it is the better number, because
## it can tell this wave's bodies from anything left over from last night. When
## it is not — and at the time of writing it reports zero live for a wave that
## demonstrably has six hounds walking down the road — the derived count below
## carries the night instead. Taking the maximum means a bookkeeping bug in
## either direction delays the end of a night rather than faking one.
func _live_units() -> int:
	if not _combat_resolves():
		return _siege.live_units()
	var reported: int = 0
	if _combat.has_method("wave_status") and _plan != null:
		var raw: Variant = _combat.call("wave_status", _plan.wave)
		if typeof(raw) == TYPE_DICTIONARY:
			reported = int((raw as Dictionary).get("live", 0))
	return maxi(reported, _derived_live())


## Bodies on the field minus whatever was already there at dusk. Leftovers can
## only shrink, and kills are attributed to them first, which bounds the error
## in both directions.
func _derived_live() -> int:
	var killed_since: int = maxi(0, _combat_counter("kills") - _kills_at_dusk)
	var leftovers: int = maxi(0, _alive_at_dusk - killed_since)
	return maxi(0, _enemies_alive() - leftovers)


## Of tonight's wave, how many are down.
func _derived_killed() -> int:
	var killed_since: int = maxi(0, _combat_counter("kills") - _kills_at_dusk)
	var leftovers_killed: int = mini(killed_since, _alive_at_dusk)
	var spawned: int = _plan.unit_count() if _plan != null else 0
	return clampi(killed_since - leftovers_killed, 0, spawned)


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


## True once every group is on the map and the settle window has passed.
func _settled(tick: int) -> bool:
	if not _all_dispatched():
		return false
	var last: int = 0
	for g: WaveGroup in _plan.groups:
		last = maxi(last, g.delay_ticks)
	return (tick - _night_start_tick) >= last + _profile.wave_settle_ticks


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


## How hard a night should LAND on the player, 0..1. The profile owns the rule;
## this system only remembers which night it is asking about, which is the whole
## bug that shipped: a constant divisor made the first nightfall in a game named
## after nightfall arrive at 0.01.
func _strength_norm(budget: float, wave: int) -> float:
	return _profile.strength_of(budget, wave)


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
	var def: ThreatUnit = _by_id.get(kind)
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
		# THE TWO NUMBERS THIS PART WAS FAILING, IN THE ARTIFACT A CRITIC READS.
		# `strength` is what the shake, the edge pulse and the mix multiply by —
		# it used to read 0.01 on night one because it was divided by a day-45
		# army. `peak_arrival` is the largest number of bodies that walk in on one
		# tick of the current plan — it used to be 4 on every night of the
		# campaign, for ever. Neither was in metrics.csv, which is why both
		# survived a whole phase.
		"strength": snappedf(_strength_norm(
			_plan.budget if _plan != null else 0.0,
			_plan.wave if _plan != null else 1), 0.001),
		"peak_arrival": _peak_arrival(),
		"waves_cleared": waves_cleared(),
		"waves_wiped": _waves_wiped,
		"waves_survived": _waves_survived,
		"waves_started": _waves_started,
		"breach_reported": _breach_reported,
		"pressure": snappedf(_pressure.pressure, 0.0001),
		"pressure_band": _pressure.band_label(),
		"peace": _peace,
		"heat_signature": snappedf(_heat_signature, 0.01),
		"signature_accum": [snappedf(_sig_sum, 0.01), _sig_n],
		"night_start": _night_start_tick,
		"saw_night": _wave_saw_night,
		"night_samples": [_night_samples, _night_heat_ok],
		"buildings_at_dusk": _buildings_at_dusk,
		"plan": _plan.to_dict() if _plan != null else {},
		"approaches": _planner.to_dict(),
		"schedule": _schedule.to_dict(),
		"pressure_state": _pressure.to_dict(),
		"siege": _siege.to_dict(_plan),
		"last_report": _last_report,
		"nights": _nights,
		"profile": String(_profile.id),
	}


func deserialize(data: Dictionary) -> void:
	_wave = int(data.get("wave", 0))
	_day = maxi(1, int(data.get("day", 1)))
	_state = ThreatDefs.WAVE_STATE_NAMES.find(StringName(String(data.get("state", "idle"))))
	if _state < 0:
		_state = ThreatDefs.WaveState.IDLE
	# A save written before the split stored the wiped count under the old name.
	_waves_wiped = int(data.get("waves_wiped", data.get("waves_cleared", 0)))
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
	_wave_saw_night = bool(data.get("saw_night", false))
	var ns: Variant = data.get("night_samples", [])
	if typeof(ns) == TYPE_ARRAY and (ns as Array).size() >= 2:
		_night_samples = int((ns as Array)[0])
		_night_heat_ok = int((ns as Array)[1])
	_buildings_at_dusk = int(data.get("buildings_at_dusk", 0))

	var raw_plan: Variant = data.get("plan", {})
	_plan = null
	if typeof(raw_plan) == TYPE_DICTIONARY and not (raw_plan as Dictionary).is_empty():
		_plan = WavePlan.from_dict(raw_plan)
		_plan.bind_units(_by_id)
	var ps: Variant = data.get("pressure_state", {})
	if typeof(ps) == TYPE_DICTIONARY:
		_pressure.from_dict(ps)
	var sg: Variant = data.get("siege", {})
	if typeof(sg) == TYPE_DICTIONARY:
		_siege.from_dict(sg)
	var lr: Variant = data.get("last_report", {})
	_last_report = lr if typeof(lr) == TYPE_DICTIONARY else {}
	_nights = []
	for raw_night: Variant in data.get("nights", []):
		if typeof(raw_night) == TYPE_DICTIONARY:
			_nights.append(raw_night)
	_was_night = _read_is_night()


func metrics() -> Dictionary:
	return {
		"wave": _wave,
		"threat_level": snappedf(threat_level(), 0.001),
		"budget": snappedf(_plan.budget if _plan != null else 0.0, 0.01),
		# THE TWO NUMBERS THIS PART WAS FAILING, IN THE ARTIFACT A CRITIC READS.
		# `strength` is what the shake, the edge pulse and the mix multiply by —
		# it used to read 0.01 on night one because it was divided by a day-45
		# army. `peak_arrival` is the largest number of bodies that walk in on one
		# tick of the current plan — it used to be 4 on every night of the
		# campaign, for ever. Neither was in metrics.csv, which is why both
		# survived a whole phase.
		"strength": snappedf(_strength_norm(
			_plan.budget if _plan != null else 0.0,
			_plan.wave if _plan != null else 1), 0.001),
		"peak_arrival": _peak_arrival(),
		"waves_cleared": waves_cleared(),
		"waves_wiped": _waves_wiped,
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

## Adapts every resource in game/content/enemies/ into the director's own view
## of it. The folder is SHARED with [P07], which authors the creatures against a
## much richer combat schema; ThreatUnit reads whichever fields are there and
## derives the rest, so neither part has to own the other's classes and the game
## ships one roster instead of two.
func _load_defs() -> void:
	_defs.clear()
	_by_id.clear()
	for res: Resource in Registry.all(CATEGORY):
		var d: ThreatUnit = ThreatUnit.from_resource(res, _profile)
		if d == null:
			Log.warn(TAG, "ignoring %s in game/content/enemies/: no id to compose it by"
				% res.resource_path)
			continue
		var problems: PackedStringArray = d.validate()
		if not problems.is_empty():
			Log.error(TAG, "enemy '%s' is malformed: %s" % [d.id, ", ".join(problems)])
			continue
		_defs.append(d)
		_by_id[d.id] = d
	_defs.sort_custom(func(a: ThreatUnit, b: ThreatUnit) -> bool: return String(a.id) < String(b.id))
	if _defs.is_empty():
		Log.warn(TAG, "no enemies in game/content/enemies/ — every night will be empty")
	else:
		var names: PackedStringArray = PackedStringArray()
		for d2: ThreatUnit in _defs:
			names.append("%s(%s t%d, %s pts, day %d%s)" % [d2.id, d2.role, d2.tier,
				String.num(d2.cost, 1), d2.min_wave, ", placed only" if d2.weight <= 0.0 else ""])
		Log.info(TAG, "roster: %s" % ", ".join(names))


## The roster, as the director understands it. Tests and the bestiary read this.
func roster() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d: ThreatUnit in _defs:
		out.append(d.to_dict())
	return out


func units() -> Array[ThreatUnit]:
	return _defs


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
