class_name WaveBudget
extends RefCounted
## Turns a night number into a number of budget points, and — just as
## importantly — into the sentences that explain why it is that number.
##
## Five terms, no hidden sixth:
##
##     budget = curve(night) x drama x era x heat x pressure
##
##   curve     the authored ramp in ThreatProfile.budget_table
##   drama     set piece (up to 2.0x) or false lull (down to 0.62x)
##   era       [P09]'s escalation beat; a colder world sends more
##   heat      the city's own heat signature — they are drawn to warmth
##   pressure  adaptation, hard-clamped to the declared band
##
## Every one of those lands in `reasons` as a plain sentence, and every one of
## them reaches the HUD through next_wave_preview(). A player who loses a night
## can read exactly what made it that size. There is nothing else in here.

## Multiplier per era step from [P09]. Small on purpose: the curve already
## climbs, and stacking two exponentials is how a campaign becomes unplayable.
const ERA_STEP: float = 0.06
const ERA_MAX: float = 1.40


## Full computation. `heat_signature` is the city's average heat output in
## units per second over the day just ended; `pressure` is already clamped to
## the band by PressureTracker.
static func compute(profile: ThreatProfile, schedule: WaveSchedule, night: int,
		era_index: int, heat_signature: float, pressure: float) -> Dictionary:
	var base: float = profile.base_budget(night)

	var set_piece: bool = schedule.is_set_piece(night)
	var intensity: float = schedule.storm_intensity(night)
	var drama: float = 1.0
	if set_piece:
		drama = profile.set_piece_multiplier + profile.set_piece_storm_bonus * intensity
	else:
		drama = schedule.lull_factor(night)

	var era: float = minf(ERA_MAX, 1.0 + ERA_STEP * float(maxi(0, era_index)))
	var heat: float = heat_factor(profile, heat_signature)
	var adapt: float = clampf(pressure, profile.adapt_min, profile.adapt_max)

	var total: float = minf(profile.budget_ceiling * 2.0, base * drama * era * heat * adapt)

	var reasons: Array[String] = []
	reasons.append("Night %d sits at %s on the curve." % [night, _n(base)])
	if set_piece:
		var title: String = schedule.title_for(night)
		if schedule.is_storm_synced(night):
			reasons.append("%s blows tonight. They came for the same reason you are afraid of it: %sx."
					% [title, _n(drama)])
		else:
			reasons.append("%s. A set piece: %sx." % [title, _n(drama)])
	elif drama < 0.999:
		reasons.append("The plain is still spent from the last assault: %sx." % _n(drama))
	if era > 1.001:
		reasons.append("The world has gotten colder since you started: %sx." % _n(era))
	if heat > 1.001:
		reasons.append("Your city burned %s units of heat a second last night. They can see that from the plain: %sx."
				% [_n(heat_signature), _n(heat)])
	if absf(adapt - 1.0) > 0.005:
		if adapt > 1.0:
			reasons.append("You have been holding comfortably, so more of them came: %sx (band %s-%s)."
					% [_n(adapt), _n(profile.adapt_min), _n(profile.adapt_max)])
		else:
			reasons.append("You are barely holding, so fewer came: %sx (band %s-%s)."
					% [_n(adapt), _n(profile.adapt_min), _n(profile.adapt_max)])

	return {
		"total": total,
		"base": base,
		"drama": drama,
		"era": era,
		"heat": heat,
		"pressure": adapt,
		"set_piece": set_piece,
		"storm_intensity": intensity,
		"heat_signature": heat_signature,
		"reasons": reasons,
	}


## Saturating draw curve. Doubling the grid must never double the horde: at the
## reference output it is halfway to the ceiling, and it never passes it.
static func heat_factor(profile: ThreatProfile, signature: float) -> float:
	var s: float = maxf(0.0, signature)
	return 1.0 + (profile.heat_draw_max - 1.0) * (s / (s + profile.heat_reference))


## JSON-safe shape of the breakdown, rounded so a save diff stays readable.
static func to_dict(b: Dictionary) -> Dictionary:
	return {
		"total": snappedf(float(b.get("total", 0.0)), 0.01),
		"base": snappedf(float(b.get("base", 0.0)), 0.01),
		"drama": snappedf(float(b.get("drama", 1.0)), 0.001),
		"era": snappedf(float(b.get("era", 1.0)), 0.001),
		"heat": snappedf(float(b.get("heat", 1.0)), 0.001),
		"pressure": snappedf(float(b.get("pressure", 1.0)), 0.001),
		"heat_signature": snappedf(float(b.get("heat_signature", 0.0)), 0.01),
		"storm_intensity": snappedf(float(b.get("storm_intensity", 0.0)), 0.001),
		"set_piece": bool(b.get("set_piece", false)),
		"reasons": b.get("reasons", []),
	}


static func _n(v: float) -> String:
	if absf(v - roundf(v)) < 0.005:
		return "%d" % int(roundf(v))
	return "%.2f" % v
