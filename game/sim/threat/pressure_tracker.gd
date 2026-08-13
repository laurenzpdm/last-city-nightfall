class_name PressureTracker
extends RefCounted
## Adaptive pressure, declared out loud.
##
## THE BAND IS ThreatProfile.adapt_min .. adapt_max — 0.80 to 1.25 as shipped.
## That is the entire authority this class has over the authored curve, and it
## is reported in metrics(), in serialize() and in next_wave_preview() on every
## single tick. Nothing about it is hidden, because rubber banding a player can
## feel but not see is worse than no rubber banding at all.
##
## After every night the director measures four things it can actually observe:
##
##   kills   what fraction of what came was destroyed
##   depth   how close the nearest attacker got to the core
##   losses  how many structures were taken apart
##   heat    how much of the night the grid stayed out of deficit
##
## They combine into one comfort number in 0..1. Comfort above the target moves
## pressure up, below it moves pressure down, at `adapt_rate` per night — five
## comfortable nights to cross the band. Relief is faster than punishment
## (`RELIEF_BIAS`): a player being taken apart gets help sooner than a player
## coasting gets punished. That asymmetry is deliberate and it is the only
## asymmetry in here.

## How much faster pressure falls than it rises. 1.0 would be symmetric.
const RELIEF_BIAS: float = 1.6
## Outcomes kept for the HUD's "how have I been doing" readout.
const HISTORY: int = 8

var pressure: float = 1.0
var last_comfort: float = -1.0
var waves_measured: int = 0
## Newest last. Each entry is one night's post-mortem.
var history: Array[Dictionary] = []

var _profile: ThreatProfile = null


func _init(profile: ThreatProfile = null) -> void:
	_profile = profile


func bind(profile: ThreatProfile) -> void:
	_profile = profile
	pressure = clampf(pressure, profile.adapt_min, profile.adapt_max)


## 0..1 reading of how comfortably a night was cleared. Pure function of the
## outcome record, so a test can pin it exactly.
func comfort_of(outcome: Dictionary) -> float:
	var p: ThreatProfile = _profile
	var spawned: int = maxi(0, int(outcome.get("spawned", 0)))
	var killed: int = clampi(int(outcome.get("killed", 0)), 0, maxi(spawned, 0))
	var kills: float = 1.0 if spawned <= 0 else float(killed) / float(spawned)

	# Distance in cells of the closest approach to the core. Anything at or
	# inside the breach radius scores zero; three breach radii out is untouched.
	var breach: float = float(maxi(1, p.breach_radius))
	var closest: float = float(int(outcome.get("closest_cells", int(breach * 3.0))))
	var depth: float = clampf((closest - breach) / (breach * 2.0), 0.0, 1.0)

	var lost: float = float(maxi(0, int(outcome.get("structures_lost", 0))))
	var losses: float = clampf(1.0 - lost / p.comfort_loss_scale, 0.0, 1.0)

	var night_ticks: int = maxi(1, int(outcome.get("night_ticks", 1)))
	var heat_ok: int = clampi(int(outcome.get("heat_ok_ticks", night_ticks)), 0, night_ticks)
	var heat: float = float(heat_ok) / float(night_ticks)

	return clampf(
		p.comfort_w_kills * kills
		+ p.comfort_w_depth * depth
		+ p.comfort_w_losses * losses
		+ p.comfort_w_heat * heat, 0.0, 1.0)


## Folds one night's outcome into the pressure multiplier. Returns the record
## that was appended to history, comfort included.
func record(outcome: Dictionary) -> Dictionary:
	var comfort: float = comfort_of(outcome)
	var delta: float = comfort - _profile.adapt_target
	var rate: float = _profile.adapt_rate
	if delta < 0.0:
		rate *= RELIEF_BIAS
	var before: float = pressure
	pressure = clampf(pressure + rate * delta, _profile.adapt_min, _profile.adapt_max)
	last_comfort = comfort
	waves_measured += 1

	var record: Dictionary = outcome.duplicate(true)
	record["comfort"] = snappedf(comfort, 0.001)
	record["pressure_before"] = snappedf(before, 0.001)
	record["pressure_after"] = snappedf(pressure, 0.001)
	history.append(record)
	while history.size() > HISTORY:
		history.pop_front()
	return record


## Rolling comfort over the nights measured so far, or -1 before the first one.
func average_comfort() -> float:
	if history.is_empty():
		return -1.0
	var sum: float = 0.0
	for h: Dictionary in history:
		sum += float(h.get("comfort", 0.0))
	return sum / float(history.size())


## "0.80..1.25". The string the HUD shows next to the pressure readout.
func band_label() -> String:
	return "%.2f..%.2f" % [_profile.adapt_min, _profile.adapt_max]


## 0..1 position inside the band. 0.5 means the director is not intervening.
func band_position() -> float:
	var span: float = maxf(0.0001, _profile.adapt_max - _profile.adapt_min)
	return clampf((pressure - _profile.adapt_min) / span, 0.0, 1.0)


## Command hook. `value` in 0..1 is read as a position inside the band; anything
## larger is read as an absolute multiplier. Both are clamped to the band, so
## no command can move the director outside what it publicly declares.
func set_from_command(value: float) -> void:
	if value >= 0.0 and value <= 1.0:
		pressure = lerpf(_profile.adapt_min, _profile.adapt_max, value)
	else:
		pressure = value
	pressure = clampf(pressure, _profile.adapt_min, _profile.adapt_max)


func to_dict() -> Dictionary:
	return {
		"pressure": snappedf(pressure, 0.0001),
		"band": band_label(),
		"band_min": _profile.adapt_min,
		"band_max": _profile.adapt_max,
		"last_comfort": snappedf(last_comfort, 0.001),
		"waves_measured": waves_measured,
		"history": history.duplicate(true),
	}


func from_dict(d: Dictionary) -> void:
	pressure = clampf(float(d.get("pressure", 1.0)), _profile.adapt_min, _profile.adapt_max)
	last_comfort = float(d.get("last_comfort", -1.0))
	waves_measured = int(d.get("waves_measured", 0))
	history.clear()
	for raw: Variant in d.get("history", []):
		if typeof(raw) == TYPE_DICTIONARY:
			history.append(raw)
