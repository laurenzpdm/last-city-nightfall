class_name ClimateForecast
extends RefCounted
## WHERE THE CLOCK WILL BE, computed before the run instead of discovered in a
## screenshot four waves later. [P09]
##
## ── WHY THIS EXISTS ───────────────────────────────────────────────────────────
##
## `tests/scenarios/first_night.json` names eleven photographic beats — `midday`,
## `dusk`, `deep_night`, `second_dusk`, `second_night` — and pins each one to a
## hand-written SIM TICK. Those ticks were written when a run began at tick 0 of
## day 1. It does not: `ClimateProfile.opening_tick` is 2016, added later and for
## an excellent reason (the first frame of a new game used to be 93% black under
## a HUD reading "Dawn"), and every beat in every scenario silently slid forward
## by most of a phase.
##
## Measured on the shipped build, `artifacts/G4_base/metrics.csv`, seed 7:
##
##     beat          asked at   photographed
##     midday          t3400    DUSK
##     dusk            t5500    NIGHT
##     assault         t7200    DEEP NIGHT, and the last enemy died at t6800
##     deep_night      t8800    MORNING, day 2
##     second_dusk    t15200    NIGHT
##     second_night   t17600    DAWN, day 3
##
## Six of eleven, and nothing anywhere said so. Every art and interface judgement
## this project has made from those frames for four waves was made about a moment
## the label denied. That is the defect this class closes, and it closes it by
## making the NAME the contract and the tick a hint: a rig asks "when is deep
## night" and is told, instead of asserting that it knows.
##
## ── WHY IT IS A PREDICTION AND NOT A MEASUREMENT ──────────────────────────────
##
## A screenshot has to be taken AT a tick; you cannot go back for it. So a rig
## either knows the schedule up front or it photographs whatever it finds and
## hopes. Everything the day clock does is a pure function of the profile plus
## the scenario's own scripted `skip_to_phase` / `set_day` commands, both of
## which are on disk before the run starts — so the schedule is knowable, and
## this walks it.
##
## `tests/gate/test_shot_beats.gd` holds this prediction against a REAL
## `ClimateSystem` stepped tick by tick and fails on the first tick they
## disagree. A forecast nobody checks against the weather is a horoscope.
##
##     var f := ClimateForecast.of(climate.profile(), script_by_tick, 24000)
##     var t: int = f.nearest(3400, ClimateDefs.Phase.AFTERNOON, -1)

## Sim tick -> phase index, 1-based (index 0 is unused; the sim's first tick is 1).
var _phase: PackedByteArray = PackedByteArray()
## Sim tick -> 1-based campaign day.
var _day: PackedInt32Array = PackedInt32Array()
var _ticks: int = 0


## Walks the day clock the way `ClimateSystem` walks it, applying the scenario's
## clock commands at the ticks they are scripted for.
##
## `script_by_tick` is the harness's own map of tick -> Array[Dictionary]; a
## caller with no script passes `{}`. Commands are applied BEFORE the tick they
## are scripted on, because `Sim._advance` drains the command queue before any
## system steps — so a `skip_to_phase` at t=100 is in force for tick 100 itself.
static func of(profile: ClimateProfile, script_by_tick: Dictionary, ticks: int) -> ClimateForecast:
	var f := ClimateForecast.new()
	if profile == null or ticks <= 0:
		return f
	var day_ticks: int = maxi(1, profile.day_ticks)
	f._ticks = ticks
	f._phase.resize(ticks + 1)
	f._day.resize(ticks + 1)
	var offset: int = clampi(profile.opening_tick, 0, maxi(0, day_ticks - 1))
	# Seeded from `ClimateSystem.setup()`, which is where a run's clock actually
	# starts. Seeding from midnight would put every prediction a third of a day
	# out — which is the exact bug this file exists to stop.
	var tick_in_day: int = offset
	var day: int = 1
	f._phase[0] = phase_index_at(profile, tick_in_day)
	f._day[0] = day
	for t: int in range(1, ticks + 1):
		for cmd: Variant in script_by_tick.get(t, []):
			offset += _clock_jump(profile, cmd as Dictionary, tick_in_day, day)
		var clock: int = maxi(0, t + offset)
		@warning_ignore("integer_division")
		day = clock / day_ticks + 1
		tick_in_day = clock % day_ticks
		f._phase[t] = phase_index_at(profile, tick_in_day)
		f._day[t] = day
	return f


## What one scripted command does to the climate's tick offset. Zero for every
## command that is not a clock jump, which is all of them except two.
static func _clock_jump(profile: ClimateProfile, cmd: Dictionary,
		tick_in_day: int, day: int) -> int:
	if String(cmd.get("system", "")) != "climate":
		return 0
	var day_ticks: int = maxi(1, profile.day_ticks)
	match String(cmd.get("op", "")):
		"skip_to_phase":
			var idx: int = ClimateDefs.PHASE_NAMES.find(
				StringName(String(cmd.get("phase", "night"))))
			if idx < 0:
				return 0
			var delta: int = profile.phase_starts[idx] - tick_in_day
			if delta <= 0:
				delta += day_ticks
			return delta
		"set_day":
			return (maxi(1, int(cmd.get("day", 1))) - day) * day_ticks
	return 0


## The phase in force at a tick INSIDE a day. Mirrors `ClimateSystem`'s own
## lookup; kept static and profile-driven so a tool can ask without a world.
static func phase_index_at(profile: ClimateProfile, tick_in_day: int) -> int:
	var idx: int = 0
	for i: int in ClimateDefs.PHASE_COUNT:
		if tick_in_day >= profile.phase_starts[i]:
			idx = i
		else:
			break
	return idx


# ------------------------------------------------------------------ asking --

func ticks() -> int:
	return _ticks


## Phase index at a sim tick, or -1 outside the forecast window.
func phase_at(sim_tick: int) -> int:
	if sim_tick < 0 or sim_tick > _ticks or _phase.is_empty():
		return -1
	return int(_phase[sim_tick])


## 1-based campaign day at a sim tick, or -1 outside the forecast window.
func day_at(sim_tick: int) -> int:
	if sim_tick < 0 or sim_tick > _ticks or _day.is_empty():
		return -1
	return _day[sim_tick]


func holds(sim_tick: int, phase: int, day: int) -> bool:
	if sim_tick < 1 or sim_tick > _ticks:
		return false
	if phase >= 0 and phase_at(sim_tick) != phase:
		return false
	if day >= 0 and day_at(sim_tick) != day:
		return false
	return true


## Contiguous runs of ticks where (phase, day) holds. `-1` means "don't care".
## Rows are {from, to} inclusive, in tick order.
func windows(phase: int, day: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var start: int = -1
	for t: int in range(1, _ticks + 1):
		if holds(t, phase, day):
			if start < 0:
				start = t
		elif start >= 0:
			out.append(Vector2i(start, t - 1))
			start = -1
	if start >= 0:
		out.append(Vector2i(start, _ticks))
	return out


## THE ONE THE RIGS CALL. The tick this beat should actually be photographed at,
## or -1 when the scenario never reaches the moment its beat is named for.
##
## Two rules, and the second one is the interesting one:
##
##   * a beat already standing in the phase it names DOES NOT MOVE. Re-aiming a
##     shot that was right disturbs a picture somebody chose, and a scenario
##     author's tick carries intent this class does not have.
##   * otherwise it moves to the MIDDLE of the nearest window where the claim
##     holds. The middle, not the near edge: a beat clamped to the edge of its
##     phase lands within a few seconds of the neighbouring beat, and two
##     photographs taken five seconds apart are one photograph taken twice —
##     which the DIFF guard would then, correctly, call a failure.
func nearest(requested: int, phase: int, day: int) -> int:
	if phase < 0 and day < 0:
		return clampi(requested, 1, maxi(1, _ticks))
	if holds(requested, phase, day):
		return requested
	var best: int = -1
	var best_gap: int = 0x7FFFFFFF
	for w: Vector2i in windows(phase, day):
		var gap: int = 0
		if requested < w.x:
			gap = w.x - requested
		elif requested > w.y:
			gap = requested - w.y
		if gap < best_gap:
			best_gap = gap
			@warning_ignore("integer_division")
			best = (w.x + w.y) / 2
	return best
