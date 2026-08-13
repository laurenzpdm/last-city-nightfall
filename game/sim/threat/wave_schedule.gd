class_name WaveSchedule
extends RefCounted
## The campaign's dramaturgy as a lookup table: which nights are set pieces,
## which are false lulls, and which ones the director deliberately dragged onto
## a Great Frost.
##
## **This is where the two halves of the game meet.** [P09] publishes a fixed,
## never-random storm calendar; this class reads it and rewrites its own peaks
## to land on top of it. The worst attack of the campaign arriving on the
## coldest night is not a coincidence and it is not scripted per-scenario — it
## is a rule, so it survives a modded climate profile, a different biome and a
## different seed.
##
## Rules, in order:
##   1. Every day a Great Frost blows is a set-piece night. No exceptions.
##   2. Every authored set-piece night is dragged onto the nearest Great Frost
##      within `set_piece_snap_days`, if one is free.
##   3. Two set pieces never land on consecutive nights; the later one slides.
##   4. The night after a set piece is a false lull, recovering over
##      `lull_recovery_nights`.

const HORIZON: int = 180

var _profile: ThreatProfile = null
## day -> {"title": String, "intensity": float}
var _storms: Dictionary[int, Dictionary] = {}
## night -> true
var _set_pieces: Dictionary[int, bool] = {}
## night -> the storm it was synchronised with, if any
var _synced: Dictionary[int, bool] = {}
## Ascending set-piece nights, for lull lookups.
var _ordered: Array[int] = []


## `storms` maps campaign day -> {"title", "intensity"}. Pass an empty
## dictionary when [P09] is absent; the authored calendar then stands alone.
func build(profile: ThreatProfile, storms: Dictionary[int, Dictionary]) -> void:
	_profile = profile
	_storms = storms
	_set_pieces.clear()
	_synced.clear()
	_ordered.clear()

	# 1. every storm night is a set piece, by rule and not by hand.
	var storm_days: Array[int] = []
	for d: int in _storms.keys():
		storm_days.append(d)
	storm_days.sort()
	for d: int in storm_days:
		if d >= 1 and d <= HORIZON:
			_set_pieces[d] = true
			_synced[d] = true

	# 2. authored peaks are dragged onto the nearest free storm.
	for night: int in _authored_nights():
		if _set_pieces.has(night):
			continue
		var target: int = _nearest_storm(night)
		if target > 0 and not _set_pieces.has(target):
			_set_pieces[target] = true
			_synced[target] = true
			continue
		# 3. never two big nights in a row — slide forward until there is air.
		var slot: int = night
		var guard: int = 0
		while guard < 8 and (_set_pieces.has(slot - 1) or _set_pieces.has(slot + 1) or _set_pieces.has(slot)):
			slot += 1
			guard += 1
		if slot <= HORIZON:
			_set_pieces[slot] = true

	var keys: Array = _set_pieces.keys()
	keys.sort()
	for k: int in keys:
		_ordered.append(k)


func is_set_piece(night: int) -> bool:
	return _set_pieces.has(night)


func is_storm_synced(night: int) -> bool:
	return _synced.has(night)


func storm_intensity(night: int) -> float:
	return float((_storms.get(night, {}) as Dictionary).get("intensity", 0.0))


func storm_title(night: int) -> String:
	return String((_storms.get(night, {}) as Dictionary).get("title", ""))


## Nights since the last set piece, or -1 when there has not been one yet.
func nights_since_set_piece(night: int) -> int:
	var last: int = -1
	for n: int in _ordered:
		if n < night:
			last = n
		else:
			break
	return -1 if last < 0 else night - last


## The multiplier the false lull applies to a night's base budget.
func lull_factor(night: int) -> float:
	if is_set_piece(night):
		return 1.0
	var since: int = nights_since_set_piece(night)
	if since < 1 or since > _profile.lull_recovery_nights:
		return 1.0
	var t: float = float(since - 1) / float(maxi(1, _profile.lull_recovery_nights))
	return lerpf(_profile.lull_factor, 1.0, t)


## The next set-piece night at or after `from_night`, or 0.
func next_set_piece(from_night: int) -> int:
	for n: int in _ordered:
		if n >= from_night:
			return n
	return 0


func set_piece_nights() -> Array[int]:
	return _ordered.duplicate()


## Names the night. A set piece borrows the storm's name when it has one,
## because the player already knows that name and dreads it.
func title_for(night: int) -> String:
	if not is_set_piece(night):
		return ""
	var st: String = storm_title(night)
	if st != "":
		return st
	return "The %s Night" % _ordinal(_ordered.find(night) + 1)


func to_dict() -> Dictionary:
	var pieces: Array = []
	for n: int in _ordered:
		pieces.append({
			"night": n,
			"storm_synced": _synced.has(n),
			"storm": storm_title(n),
			"intensity": snappedf(storm_intensity(n), 0.001),
		})
	return {"set_pieces": pieces}


func _authored_nights() -> Array[int]:
	var out: Array[int] = []
	for n: int in _profile.set_piece_nights:
		if n >= 1 and n <= HORIZON:
			out.append(n)
	if _profile.set_piece_repeat_every > 0 and not out.is_empty():
		var last: int = out[out.size() - 1]
		var n2: int = last + _profile.set_piece_repeat_every
		while n2 <= HORIZON:
			out.append(n2)
			n2 += _profile.set_piece_repeat_every
	out.sort()
	return out


## Nearest storm day to `night` within the snap window. Ties go to the earlier
## day so the answer never depends on iteration order.
func _nearest_storm(night: int) -> int:
	var best: int = 0
	var best_d: int = 1 << 30
	var days: Array[int] = []
	for d: int in _storms.keys():
		days.append(d)
	days.sort()
	for d: int in days:
		var dist: int = absi(d - night)
		if dist <= _profile.set_piece_snap_days and dist < best_d:
			best_d = dist
			best = d
	return best


static func _ordinal(n: int) -> String:
	match n:
		1: return "First"
		2: return "Second"
		3: return "Third"
		4: return "Fourth"
		5: return "Fifth"
		6: return "Sixth"
		7: return "Seventh"
		8: return "Eighth"
	return "%dth" % n
