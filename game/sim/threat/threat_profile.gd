class_name ThreatProfile
extends Resource
## Every number the wave director uses. **The campaign's dramaturgy lives here**,
## not in the code: the shape of the pressure curve, where the false lulls fall,
## how hard a set-piece night hits, how far adaptation is allowed to move, and
## exactly what the player is told and when.
##
## Defaults below are the shipping tuning. Drop a .tres of this type into
## `game/content/threat/` to override it; the highest `priority` wins, so a
## scenario can ship a crueller world without touching a line of code.

@export var id: StringName = &"default"
@export var display_name: String = "The Long Dark"
## Highest priority profile in the registry wins.
@export var priority: int = 0

# ==========================================================================
#  THE PRESSURE CURVE
# ==========================================================================
# One wave per night, so wave number == campaign day. This table is the BASE
# curve only: a smooth, honest ramp. The drama — set pieces and false lulls —
# is applied on top of it by rule, so that moving a Great Frost automatically
# moves the night that was built to land on it.

## Budget points for nights 1..N. Past the end the curve continues geometrically.
##
## Night one is a handful on purpose and stays one — it is the teaching night.
## Everything after it was measured against a real run and found empty. Four
## burner cannons sustain about 139 damage a second all night; a hundred and
## sixty seconds of night is therefore a wall capable of killing some seven
## hundred drift hounds, and night two used to send fourteen. The whole "43 shots
## and 19 kills across three days" finding is that one ratio: the waves were two
## orders of magnitude smaller than the defence they exist to test.
##
## So the curve keeps night one at a handful and then climbs to meet the wall
## instead of ambling toward it: night three is a real fight, night seven is a
## siege, and the top of the table is roughly double what it was.
@export var budget_table: PackedFloat32Array = PackedFloat32Array([
	8.0, 30.0, 54.0, 84.0, 120.0, 162.0, 210.0, 266.0, 330.0, 402.0, 484.0, 576.0,
])
## Growth per night once the authored table runs out.
@export var budget_growth: float = 1.18
## Nothing past this, ever. A number a designer can reason about is worth more
## than an exponential that eventually asks for forty thousand units.
@export var budget_ceiling: float = 12000.0

## Nights the director WANTS to be set pieces, before storm synchronisation.
## These get snapped onto a Great Frost inside `set_piece_snap_days`.
@export var set_piece_nights: PackedInt32Array = PackedInt32Array([3, 7, 12, 18, 25, 33])
## After the authored list, a set piece every N nights forever. 0 disables.
@export var set_piece_repeat_every: int = 6
## How far a set piece may be dragged to land on a Great Frost. The best moment
## this game can produce is the worst attack arriving on the coldest night, so
## the director bends its own schedule to make that happen.
@export var set_piece_snap_days: int = 2
## Budget multiplier on a set-piece night...
@export var set_piece_multiplier: float = 1.55
## ...plus this much more at full storm intensity.
@export var set_piece_storm_bonus: float = 0.45
## A set piece also gets one extra approach vector.
@export var set_piece_extra_vectors: int = 1

## The night AFTER a set piece is deliberately soft. The lull is not mercy, it
## is contrast: it is what makes the next escalation legible as an escalation.
@export var lull_factor: float = 0.62
## ...and it decays back to normal over this many nights.
@export var lull_recovery_nights: int = 2

# ==========================================================================
#  THE HEAT HUNGER — why they come at all
# ==========================================================================
# They are drawn to warmth. The better the city holds its heat, the more of
# them the plain sends. The player's own success is what summons them, and the
# preview says so in words, so nobody can call it arbitrary.

## Heat units per second that count as "an ordinary city".
@export var heat_reference: float = 55.0
## Budget multiplier ceiling from the heat signature. Saturating, never linear:
## doubling your grid must not double the horde.
@export var heat_draw_max: float = 1.60
## Nights before the plain notices a change in the city's output. The signature
## is averaged over the day, so one panicked shutdown at dusk does not fool it.
@export var heat_sample_interval: int = 20

# ==========================================================================
#  ADAPTIVE PRESSURE — declared, bounded, and shown to the player
# ==========================================================================
# THE BAND IS 0.80 .. 1.25. That is the whole authority the director has over
# the authored curve. A player who is dismantling every wave gets at most 25%
# more than the curve says; a player who is being taken apart gets at worst 20%
# less. Both numbers are in metrics() and in next_wave_preview() every tick.
# Hidden rubber banding that players can feel is worse than none, so this is
# neither hidden nor larger than it needs to be.

@export var adapt_min: float = 0.80
@export var adapt_max: float = 1.25
## How much of the gap between measured comfort and `adapt_target` is closed
## per night. 0.07 means it takes five comfortable nights to reach the ceiling.
@export var adapt_rate: float = 0.07
## Comfort the director aims for: cleared, but not cleanly.
@export var adapt_target: float = 0.60
## Weight of each comfort component. They sum to 1.
@export var comfort_w_kills: float = 0.40
@export var comfort_w_depth: float = 0.25
@export var comfort_w_losses: float = 0.22
@export var comfort_w_heat: float = 0.13
## Structures lost that counts as a total failure of the losses component.
@export var comfort_loss_scale: float = 4.0

# ==========================================================================
#  APPROACH VECTORS
# ==========================================================================

## Vectors on night 1.
@export var vectors_base: int = 1
## One more vector every N nights...
@export var vectors_every_nights: int = 2
## ...up to this many, terrain permitting.
@export var vectors_max: int = 4
## Share of the budget sent at the player's WEAKEST side. Ramps in from night
## `probe_from_night` so the opening nights stay legible, then punishes anyone
## who fortified one road and called it a defence.
@export var probe_share_max: float = 0.42
@export var probe_from_night: int = 3
@export var probe_ramp_nights: int = 6
## No single vector may carry more than this once there is more than one, so a
## flank is a real threat and never an instant loss.
@export var vector_share_cap: float = 0.72
## Tiles either side of a lane that count as "defending that lane".
@export var lane_corridor_radius: int = 5
## Path cells PAST the chokepoint (outward) that the defence envelope covers.
## Everything between the chokepoint and the core counts too — players build
## their line where their city ends, not where the terrain is prettiest, and a
## director that only looked at the chokepoint would read a fortified city as
## an empty one.
@export var lane_envelope_cells: int = 6
## ...but not the core itself. The corridor starts this many cells out, so the
## hearth district is not counted as defending every lane at once.
@export var lane_core_clear: int = 10
## Defence rating that reads as 0.5 on the 0..1 scale. Saturating, so the
## twentieth turret on one road still counts, just not as much as the second.
@export var defence_reference: float = 55.0
## Weight of barrier hit points against turret damage in that rating.
@export var defence_hp_weight: float = 0.02

# ==========================================================================
#  TELEGRAPHING — the whole feeling of the game
# ==========================================================================
# The player must know roughly what is coming and from where, with enough time
# to act and never enough to fully prepare. Four rungs, each more precise than
# the last, plus a full extra day of notice before a set piece.

## Ticks before nightfall at which each warning fires. Descending.
@export var warning_offsets_ticks: PackedInt32Array = PackedInt32Array([3600, 1800, 900, 300])
## Precision unlocked by each rung: 0 direction only, 1 named vectors,
## 2 composition by role, 3 unit counts.
@export var warning_precision: PackedInt32Array = PackedInt32Array([0, 1, 2, 3])
## Extra rung fired a full day ahead of a set piece.
@export var set_piece_notice_ticks: int = 9600
## {band} {dirs} {detail} {clock} {title} are substituted before display.
@export var warning_lines: PackedStringArray = PackedStringArray([
	"Watchers report movement on the plain: {band}, somewhere out of {dirs}.",
	"They have found the old road: {band} coming out of {dirs}. {clock} to nightfall.",
	"{detail}, out of {dirs}. {clock} to nightfall.",
	"{detail} coming in from {dirs}. {clock}. Everyone behind the line.",
])
@export var set_piece_notice_line: String = "{title}. They are massing for it — {band} at least, and the cold is coming with them."
@export var wave_started_line: String = "Night {wave}: {band} out of {dirs}."
@export var wave_cleared_line: String = "Night {wave} held. {detail}"
@export var wave_breached_line: String = "They are through the line out of {dirs}."

# ==========================================================================
#  NIGHT COMPOSITION
# ==========================================================================

## Role multipliers per shape, row-major: SHAPES x ROLES
## (swarm, line, breaker, stalker, siege).
@export var shape_role_weights: PackedFloat32Array = PackedFloat32Array([
	# probe   — fast and thin, meant to find the hole
	1.20, 0.60, 0.10, 2.40, 0.00,
	# swarm   — everything cheap, all at once
	3.00, 1.00, 0.25, 0.50, 0.00,
	# column  — the ordinary night
	1.00, 2.20, 0.80, 0.60, 0.10,
	# hammer  — armour up the main road
	0.40, 1.20, 2.60, 0.40, 0.60,
	# siege   — the set piece
	0.80, 1.60, 1.80, 0.70, 2.20,
])
## Base weight of each shape, and how that weight moves as the campaign runs
## from night 1 to `shape_full_night`. Probes fade, sieges arrive.
@export var shape_weight_base: PackedFloat32Array = PackedFloat32Array([0.34, 0.30, 0.28, 0.08, 0.00])
@export var shape_weight_slope: PackedFloat32Array = PackedFloat32Array([-0.28, -0.10, 0.10, 0.22, 0.06])
@export var shape_full_night: int = 24
## A set-piece night is always a siege, whatever the roll said.
@export var set_piece_shape: StringName = &"siege"
## Hard cap on distinct enemy kinds in one night. A night the player cannot
## read at a glance is not a night, it is noise.
@export var max_kinds_per_wave: int = 4
## Ceiling on the share of one night's budget a single kind may eat, when the
## content does not state one of its own. Swarm things are allowed to dominate
## a night; a boss is placed once and is never most of the budget.
@export var share_swarm: float = 0.60
@export var share_line: float = 0.55
@export var share_breaker: float = 0.45
@export var share_stalker: float = 0.45
@export var share_siege: float = 0.40
@export var share_boss: float = 0.35
## Composition loop safety valve. Never reached in practice; bounds the tick.
@export var max_compose_steps: int = 96

# ==========================================================================
#  SPAWNING AND THE NIGHT ITSELF
# ==========================================================================

## Floor on the arrival window, in ticks, used when the length of the night is
## not known (no [P09] in the build).
@export var spawn_window_ticks: int = 1100
## Share of the ACTUAL night that arrivals are spread over.
##
## This used to be the fixed 1100 ticks above, against a night of 3264: the
## whole attack landed in the first third and the other hundred seconds were
## empty. A tower-defence night is a night under pressure, not a blob at dusk
## followed by silence — so the window is measured against dusk-to-dawn, and the
## last packet still arrives with a quarter of the night left to fight it in.
@export var spawn_window_share: float = 0.72
## SIMULTANEITY — the number that decided the whole build was a metronome.
##
## This used to be a flat `pulse_max_units = 4`, at every difficulty, for ever.
## A packet bigger than four was split into pulses of four and the pulses were
## spread evenly across the night, so `combat.enemies_alive` measured over 24000
## ticks peaked at **4** on every night of the campaign. Night two announced "a
## column out of the south-east, 28 units" and delivered four bodies, dead in
## 120 ticks, four more 340 ticks later, eight times over. The doc comment two
## lines below warned against producing "a drip rather than a wave" and the
## constant above it produced exactly that.
##
## An arrival packet is now sized against the night it belongs to: a handful on
## the teaching night, a shield wall on night seven. `pulse_units()` is the
## whole rule, and `ThreatSystem._distribute` packs the night's groups into
## ECHELONS of that size so several kinds land together instead of taking turns.
##
## Floor: what arrives at once on night one, when the budget is a rounding error.
@export var pulse_units_min: int = 4
## Ceiling: no single moment ever puts more than this on the map, whatever the
## budget says. A hundred bodies on one tick is a frame spike, not a siege.
@export var pulse_units_max: int = 40
## Budget points that buy one more body in a simultaneous arrival. This IS the
## peak-simultaneity curve, because the echelon count is derived from it: a
## night is cut into as many arrival moments as it takes for each one to be
## about this big. Measured against the shipped budget table it gives a peak of
## roughly 3 bodies on night one, 7 on night two, 16 on the first set piece and
## 33 on night seven — against a flat 4 for ever, which is what shipped.
@export var pulse_budget_per_unit: float = 12.0
## Arrival moments a night has AT LEAST, before size forces more. Two, so even
## the teaching night has a second beat and the player learns that a night comes
## in stages. Grows with the campaign so a big night keeps a rhythm instead of
## being two blobs.
@export var echelons_min: int = 2
## One more guaranteed arrival moment every N nights...
@export var echelons_every_nights: int = 4
## ...up to this many. Past here, extra bodies make echelons bigger, not more
## numerous — which is the difference between a longer night and a harder one.
@export var echelons_max: int = 6
## ...but never more arrival moments than this in one night, or the player is
## fighting a drip rather than a wave.
@export var pulses_max: int = 16
## Ticks between combat polls while a wave is live.
@export var poll_interval_ticks: int = 10
## Ticks after the last group is handed over before "nothing is alive" is
## allowed to mean "the night is over". [P07] runs at order 80, one place behind
## this system, and queues its spawns — so on the tick a group is dispatched the
## field is legitimately still empty. Without this window every wave would
## resolve itself the instant it began.
@export var wave_settle_ticks: int = 80
## Survivors melt back into the dark at dawn. A wave always ends.
@export var withdraw_at_dawn: bool = true
## Hard ceiling on how long one night may stay ACTIVE, whatever the clock, the
## climate system or [P07]'s bookkeeping thinks.
##
## THE WATCHDOG. A night that outlives this has a bug in it, so it is resolved
## and the fact is written into the log as an error rather than left to freeze
## the campaign: a build where wave two never ends and wave three never arrives
## reported itself green for a whole phase. 12000 ticks is ten minutes of world
## time against a night of under three.
@export var wave_hard_timeout_ticks: int = 12000

# ==========================================================================
#  THE SIEGE MODEL — only used when [P07] combat is absent
# ==========================================================================
# See SiegeResolver. These numbers are a stand-in for real weapons, and every
# one of them is ignored the moment a combat system exists in the build.

## Damage per second a finished, powered turret contributes to its lane.
@export var turret_dps: float = 16.0
## ...and a watchtower, or anything else tagged defense without a weapon.
@export var support_dps: float = 3.0
## Hit points a wall adds to the barrier a pack has to chew through.
@export var wall_barrier_scale: float = 1.0
## Damage per shot the abstract defence deals, for armour arithmetic.
@export var defence_shot: float = 12.0
## Ticks between siege resolution steps. 5 = four times a second.
@export var siege_step_ticks: int = 5
## Cells from the core at which a pack counts as having breached the city.
@export var breach_radius: int = 14
## How much of a pack's dps actually lands on structures while it is being shot
## at. Below 1 because a thing under fire is not calmly demolishing a wall.
@export var siege_damage_efficiency: float = 0.55

# ==========================================================================
#  HUD NORMALISATION
# ==========================================================================

# A night is FELT against the night it was supposed to be, not against a day-45
# army. `level_reference_budget = 620.0` used to be the divisor for the number
# that drives every screen shake, edge pulse and audio beat, so night one — 8.0
# budget — landed on the player at 0.01. The log said so in as many words:
# `[feel] wave 1 felt at strength 0.01`. Night two 0.069, night three 0.23. The
# entire opening week of a game called Nightfall was calibrated against an army
# it will not meet for a month and a half, and arrived as nothing.
#
# `strength_of(budget, wave)` reads instead:
#     an ORDINARY night on the authored curve      -> level_ordinary
#     a night the director made heavier than that  -> more, saturating
#     the same relative night later in the campaign-> more again, up to the gain
# so night one is a real nightfall, a set piece on a Great Frost is near the
# top, and a lull is visibly a lull.

## What a night that lands exactly on the authored curve feels like, 0..1.
@export var level_ordinary: float = 0.55
## How the reading answers a night heavier or lighter than the curve. Below 1 so
## a 1.55x set piece reads well above an ordinary night without pinning the
## meter, and a 0.62 lull is legibly softer without reading as nothing.
@export var level_rel_exponent: float = 0.60
## Extra reading a night carries purely for being late in the campaign...
@export var level_campaign_gain: float = 0.30
## ...approached over this many nights.
@export var level_campaign_nights: int = 14
## Seconds out at which an incoming wave starts registering on the meter.
@export var level_horizon_seconds: float = 260.0

# ==========================================================================
#  FALLBACK CLOCK — used only when [P09] climate is absent
# ==========================================================================

@export var fallback_day_ticks: int = 9600
@export var fallback_night_start: int = 6336


## Clamps everything into a workable range and reports whether it had to.
## Content is data written by hand; a profile that silently divides by zero is
## a balance bug nobody can find.
func validate() -> bool:
	var ok: bool = true
	if budget_table.is_empty():
		budget_table = PackedFloat32Array([8.0])
		ok = false
	for i: int in budget_table.size():
		if budget_table[i] <= 0.0:
			budget_table[i] = 1.0
			ok = false
	budget_growth = clampf(budget_growth, 1.0, 3.0)
	budget_ceiling = maxf(budget_ceiling, budget_table[budget_table.size() - 1])
	set_piece_repeat_every = maxi(0, set_piece_repeat_every)
	set_piece_snap_days = clampi(set_piece_snap_days, 0, 6)
	set_piece_multiplier = maxf(1.0, set_piece_multiplier)
	set_piece_storm_bonus = maxf(0.0, set_piece_storm_bonus)
	lull_factor = clampf(lull_factor, 0.1, 1.0)
	lull_recovery_nights = clampi(lull_recovery_nights, 0, 8)

	heat_reference = maxf(1.0, heat_reference)
	heat_draw_max = maxf(1.0, heat_draw_max)
	heat_sample_interval = maxi(1, heat_sample_interval)

	adapt_min = clampf(adapt_min, 0.25, 1.0)
	adapt_max = clampf(adapt_max, adapt_min, 4.0)
	adapt_rate = clampf(adapt_rate, 0.0, 1.0)
	adapt_target = clampf(adapt_target, 0.0, 1.0)
	var w: float = comfort_w_kills + comfort_w_depth + comfort_w_losses + comfort_w_heat
	if w <= 0.0:
		comfort_w_kills = 1.0
		comfort_w_depth = 0.0
		comfort_w_losses = 0.0
		comfort_w_heat = 0.0
		ok = false
	elif absf(w - 1.0) > 0.001:
		comfort_w_kills /= w
		comfort_w_depth /= w
		comfort_w_losses /= w
		comfort_w_heat /= w
	comfort_loss_scale = maxf(1.0, comfort_loss_scale)

	vectors_base = maxi(1, vectors_base)
	vectors_every_nights = maxi(1, vectors_every_nights)
	vectors_max = maxi(vectors_base, vectors_max)
	probe_share_max = clampf(probe_share_max, 0.0, 0.6)
	probe_from_night = maxi(1, probe_from_night)
	probe_ramp_nights = maxi(1, probe_ramp_nights)
	vector_share_cap = clampf(vector_share_cap, 0.4, 1.0)
	lane_corridor_radius = clampi(lane_corridor_radius, 1, 24)
	lane_envelope_cells = clampi(lane_envelope_cells, 0, 200)
	lane_core_clear = clampi(lane_core_clear, 0, 64)
	defence_reference = maxf(1.0, defence_reference)
	defence_hp_weight = maxf(0.0, defence_hp_weight)

	if warning_offsets_ticks.is_empty():
		warning_offsets_ticks = PackedInt32Array([1800, 600])
		ok = false
	# Descending, strictly. A ladder that goes back up would fire twice.
	var sorted: Array[int] = []
	for v: int in warning_offsets_ticks:
		sorted.append(maxi(1, v))
	sorted.sort()
	sorted.reverse()
	warning_offsets_ticks = PackedInt32Array(sorted)
	while warning_precision.size() < warning_offsets_ticks.size():
		warning_precision.append(warning_precision.size())
	while warning_lines.size() < warning_offsets_ticks.size():
		warning_lines.append("{band} out of {dirs}. {clock}.")
	set_piece_notice_ticks = maxi(0, set_piece_notice_ticks)

	var cells: int = ThreatDefs.SHAPES.size() * ThreatDefs.ROLES.size()
	if shape_role_weights.size() != cells:
		shape_role_weights.resize(cells)
		ok = false
	if shape_weight_base.size() != ThreatDefs.SHAPES.size():
		shape_weight_base.resize(ThreatDefs.SHAPES.size())
		ok = false
	if shape_weight_slope.size() != ThreatDefs.SHAPES.size():
		shape_weight_slope.resize(ThreatDefs.SHAPES.size())
		ok = false
	shape_full_night = maxi(2, shape_full_night)
	max_kinds_per_wave = maxi(1, max_kinds_per_wave)
	share_swarm = clampf(share_swarm, 0.05, 1.0)
	share_line = clampf(share_line, 0.05, 1.0)
	share_breaker = clampf(share_breaker, 0.05, 1.0)
	share_stalker = clampf(share_stalker, 0.05, 1.0)
	share_siege = clampf(share_siege, 0.05, 1.0)
	share_boss = clampf(share_boss, 0.05, 1.0)
	max_compose_steps = maxi(4, max_compose_steps)

	spawn_window_ticks = maxi(1, spawn_window_ticks)
	spawn_window_share = clampf(spawn_window_share, 0.0, 0.9)
	pulse_units_min = maxi(1, pulse_units_min)
	pulse_units_max = maxi(pulse_units_min, pulse_units_max)
	pulse_budget_per_unit = maxf(0.01, pulse_budget_per_unit)
	echelons_min = maxi(1, echelons_min)
	echelons_every_nights = maxi(1, echelons_every_nights)
	echelons_max = maxi(echelons_min, echelons_max)
	pulses_max = maxi(echelons_max, pulses_max)
	wave_hard_timeout_ticks = maxi(600, wave_hard_timeout_ticks)
	poll_interval_ticks = maxi(1, poll_interval_ticks)
	wave_settle_ticks = maxi(1, wave_settle_ticks)
	siege_step_ticks = maxi(1, siege_step_ticks)
	defence_shot = maxf(1.0, defence_shot)
	breach_radius = maxi(1, breach_radius)
	siege_damage_efficiency = clampf(siege_damage_efficiency, 0.0, 1.0)

	level_ordinary = clampf(level_ordinary, 0.05, 1.0)
	level_rel_exponent = clampf(level_rel_exponent, 0.05, 3.0)
	level_campaign_gain = clampf(level_campaign_gain, 0.0, 1.0 - level_ordinary)
	level_campaign_nights = maxi(1, level_campaign_nights)
	level_horizon_seconds = maxf(1.0, level_horizon_seconds)
	fallback_day_ticks = maxi(120, fallback_day_ticks)
	fallback_night_start = clampi(fallback_night_start, 1, fallback_day_ticks - 1)
	return ok


## Authored base budget for a night, before drama, heat and adaptation.
func base_budget(wave: int) -> float:
	var w: int = maxi(1, wave)
	var n: int = budget_table.size()
	if w <= n:
		return budget_table[w - 1]
	return minf(budget_ceiling, budget_table[n - 1] * pow(budget_growth, float(w - n)))


## Role weight for a shape. Missing combinations weigh nothing.
func shape_role_weight(shape: StringName, role: StringName) -> float:
	var si: int = ThreatDefs.shape_index(shape)
	var ri: int = ThreatDefs.role_index(role)
	if si < 0 or ri < 0:
		return 0.0
	var idx: int = si * ThreatDefs.ROLES.size() + ri
	if idx < 0 or idx >= shape_role_weights.size():
		return 0.0
	return maxf(0.0, shape_role_weights[idx])


## Selection weight of each shape on a given night, already normalised.
func shape_weights(wave: int) -> PackedFloat32Array:
	var t: float = clampf(float(wave - 1) / float(maxi(1, shape_full_night - 1)), 0.0, 1.0)
	var out: PackedFloat32Array = PackedFloat32Array()
	var total: float = 0.0
	for i: int in ThreatDefs.SHAPES.size():
		var base: float = shape_weight_base[i] if i < shape_weight_base.size() else 0.0
		var slope: float = shape_weight_slope[i] if i < shape_weight_slope.size() else 0.0
		var v: float = maxf(0.0, base + slope * t)
		out.append(v)
		total += v
	if total <= 0.0:
		out[ThreatDefs.shape_index(ThreatDefs.SHAPE_COLUMN)] = 1.0
		return out
	for i: int in out.size():
		out[i] = out[i] / total
	return out


## Default budget ceiling for one kind, when the content does not state one.
func share_for_role(role: StringName, boss: bool) -> float:
	if boss:
		return share_boss
	match role:
		ThreatDefs.ROLE_SWARM:
			return share_swarm
		ThreatDefs.ROLE_BREAKER:
			return share_breaker
		ThreatDefs.ROLE_STALKER:
			return share_stalker
		ThreatDefs.ROLE_SIEGE:
			return share_siege
	return share_line


## Vectors the director may open on a given night, terrain permitting.
func vector_count(wave: int, set_piece: bool) -> int:
	var n: int = vectors_base + int((maxi(1, wave) - 1) / vectors_every_nights)
	if set_piece:
		n += set_piece_extra_vectors
	return clampi(n, 1, vectors_max + set_piece_extra_vectors)


## Bodies that may walk in on one tick, given what the night is worth. THE fix
## for `enemies_alive max 4 across every night`: an arrival is sized against the
## wave it belongs to, so night eight cannot look like night one.
func pulse_units(budget: float) -> int:
	var n: float = float(pulse_units_min) + maxf(0.0, budget) / pulse_budget_per_unit
	return clampi(int(round(n)), pulse_units_min, pulse_units_max)


## Arrival moments a night is cut into. At least `echelons_min` (growing slowly
## with the campaign) so a night always has a rhythm, and more than that only
## when the wave is too big to land in that many pieces.
func echelon_count(wave: int, units: int, budget: float) -> int:
	if units <= 1:
		return 1
	var rhythm: int = clampi(
		echelons_min + int((maxi(1, wave) - 1) / echelons_every_nights),
		echelons_min, echelons_max)
	return clampi(mini(units, maxi(rhythm, _echelons_for_size(units, budget))), 1, pulses_max)


func _echelons_for_size(units: int, budget: float) -> int:
	var per: int = maxi(1, pulse_units(budget))
	return (units + per - 1) / per


## How hard a night of `budget` on night `wave` should LAND, 0..1. Everything
## the player feels — the shake, the edge pulse, the mix — is scaled by this, so
## it is measured against what an ordinary night `wave` is worth and not against
## a late-campaign constant. See the block comment above `level_ordinary`.
func strength_of(budget: float, wave: int) -> float:
	var w: int = maxi(1, wave)
	var expected: float = maxf(0.001, base_budget(w))
	var rel: float = maxf(0.0, budget) / expected
	var shaped: float = pow(rel, level_rel_exponent) if rel > 0.0 else 0.0
	var t: float = clampf(float(w - 1) / float(maxi(1, level_campaign_nights - 1)), 0.0, 1.0)
	return clampf(level_ordinary * shaped + level_campaign_gain * t, 0.0, 1.0)


## Share of the budget aimed at the weakest side on a given night.
func probe_share(wave: int) -> float:
	if wave < probe_from_night:
		return 0.0
	var t: float = clampf(float(wave - probe_from_night) / float(probe_ramp_nights), 0.0, 1.0)
	return probe_share_max * t
