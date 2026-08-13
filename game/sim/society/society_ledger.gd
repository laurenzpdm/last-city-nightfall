class_name SocietyLedger
extends RefCounted
## The reason ledger. Nothing moves a meter in [P06] without going through here,
## which is the whole point: a player must always be able to ask "why is
## discontent 71" and get an answer with numbers in it.
##
## Every entry records four different views of the same contribution, because a
## UI needs all four:
##
##   rate     what this reason is doing to the meter RIGHT NOW, points per hour.
##            This is what a live tooltip shows: "Cold homes, -4.1/h".
##   recent   an exponentially decayed sum with a one hour half life. Ranking by
##            this is what makes "the three things hurting you most" honest:
##            a death an hour ago still counts, a death yesterday does not.
##   today    everything this reason contributed since the last dawn, so the
##            morning report can say "the night cost you 14 hope".
##   total    the whole run, for the end screen and for tests.
##
## `text` is rewritten every time a reason fires, so it always carries the
## current numbers rather than a generic label.

const RECENT_HALF_LIFE_HOURS: float = 1.0
const EPS: float = 0.0000005

## key -> record. Never iterated without sorting the keys first.
var _entries: Dictionary[StringName, Dictionary] = {}
var _keys: Array[StringName] = []
var _keys_dirty: bool = false


func clear() -> void:
	_entries.clear()
	_keys.clear()
	_keys_dirty = false


## Records a contribution. `delta` is meter points already scaled to the tick;
## `rate` is the same reason expressed as points per hour, or 0.0 for a one-off
## impulse. Returns nothing: the caller has already applied the delta.
func add(meter: StringName, key: StringName, label: String, text: String,
		delta: float, rate: float, tick: int) -> void:
	var rec: Dictionary = _entries.get(key, {})
	if rec.is_empty():
		rec = {
			"meter": String(meter),
			"label": label,
			"text": text,
			"rate": 0.0,
			"recent": 0.0,
			"today": 0.0,
			"total": 0.0,
			"first_tick": tick,
			"last_tick": tick,
			"count": 0,
		}
		_entries[key] = rec
		_keys_dirty = true
	rec["label"] = label
	if text != "":
		rec["text"] = text
	rec["rate"] = rate
	rec["recent"] = float(rec["recent"]) + delta
	rec["today"] = float(rec["today"]) + delta
	rec["total"] = float(rec["total"]) + delta
	rec["last_tick"] = tick
	rec["count"] = int(rec["count"]) + 1


## Marks a reason as no longer acting without touching its history, so a UI can
## grey it out instead of having it vanish mid-frame.
func silence(key: StringName) -> void:
	var rec: Dictionary = _entries.get(key, {})
	if not rec.is_empty():
		rec["rate"] = 0.0


func has(key: StringName) -> bool:
	return _entries.has(key)


func rate_of(key: StringName) -> float:
	var rec: Dictionary = _entries.get(key, {})
	return float(rec.get("rate", 0.0))


func total_of(key: StringName) -> float:
	var rec: Dictionary = _entries.get(key, {})
	return float(rec.get("total", 0.0))


func today_of(key: StringName) -> float:
	var rec: Dictionary = _entries.get(key, {})
	return float(rec.get("today", 0.0))


## Everything one meter has been moved by, over the whole run. This must equal
## the distance the meter has actually travelled, and a test holds it to that:
## a ledger whose numbers do not add up to the number on the bar is a lie with
## extra detail.
func meter_total(meter: StringName) -> float:
	var sum: float = 0.0
	var want: String = String(meter)
	for key: StringName in _sorted_keys():
		var rec: Dictionary = _entries[key]
		if String(rec["meter"]) == want:
			sum += float(rec["total"])
	return sum


## The same, since the last dawn.
func meter_today(meter: StringName) -> float:
	var sum: float = 0.0
	var want: String = String(meter)
	for key: StringName in _sorted_keys():
		var rec: Dictionary = _entries[key]
		if String(rec["meter"]) == want:
			sum += float(rec["today"])
	return sum


## Ages every `recent` window. Called once per sample with the hours elapsed.
func decay(hours: float) -> void:
	if hours <= 0.0:
		return
	var f: float = pow(0.5, hours / RECENT_HALF_LIFE_HOURS)
	for key: StringName in _sorted_keys():
		var rec: Dictionary = _entries[key]
		var r: float = float(rec["recent"]) * f
		rec["recent"] = 0.0 if absf(r) < EPS else r


## Dawn. `today` resets, everything else survives.
func roll_day() -> void:
	for key: StringName in _sorted_keys():
		(_entries[key] as Dictionary)["today"] = 0.0


## Every reason acting on one meter, strongest first. `limit` <= 0 means all.
## Ranking is by |recent| with the key as the tie break, so two reasons of
## identical weight always come out in the same order in every replay.
func top(meter: StringName, limit: int = 0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var want: String = String(meter)
	for key: StringName in _sorted_keys():
		var rec: Dictionary = _entries[key]
		if want != "" and String(rec["meter"]) != want:
			continue
		out.append(_view(key, rec))
	out.sort_custom(_rank)
	if limit > 0 and out.size() > limit:
		out.resize(limit)
	return out


## Everything, both meters, strongest first.
func all(limit: int = 0) -> Array[Dictionary]:
	return top(&"", limit)


## Compact, JSON-safe form for serialize(). Sorted by key, not by weight, so a
## state diff between two runs lines up.
func serialize() -> Array:
	var out: Array = []
	for key: StringName in _sorted_keys():
		var rec: Dictionary = _entries[key]
		if absf(float(rec["total"])) < EPS and int(rec["count"]) == 0:
			continue
		out.append({
			"key": String(key),
			"meter": String(rec["meter"]),
			"label": String(rec["label"]),
			"text": String(rec["text"]),
			"rate": snappedf(float(rec["rate"]), 0.001),
			"recent": snappedf(float(rec["recent"]), 0.001),
			"today": snappedf(float(rec["today"]), 0.001),
			"total": snappedf(float(rec["total"]), 0.001),
			"since": int(rec["first_tick"]),
			"last": int(rec["last_tick"]),
			"count": int(rec["count"]),
		})
	return out


func deserialize(data: Array) -> void:
	clear()
	for raw: Variant in data:
		var d: Dictionary = raw
		var key: StringName = StringName(String(d.get("key", "")))
		if key == &"":
			continue
		_entries[key] = {
			"meter": String(d.get("meter", "hope")),
			"label": String(d.get("label", "")),
			"text": String(d.get("text", "")),
			"rate": float(d.get("rate", 0.0)),
			"recent": float(d.get("recent", 0.0)),
			"today": float(d.get("today", 0.0)),
			"total": float(d.get("total", 0.0)),
			"first_tick": int(d.get("since", 0)),
			"last_tick": int(d.get("last", 0)),
			"count": int(d.get("count", 0)),
		}
	_keys_dirty = true


func size() -> int:
	return _entries.size()


# --- internals ---------------------------------------------------------------

func _view(key: StringName, rec: Dictionary) -> Dictionary:
	var total: float = float(rec["total"])
	return {
		"key": String(key),
		"meter": String(rec["meter"]),
		"label": String(rec["label"]),
		"text": String(rec["text"]),
		"rate": snappedf(float(rec["rate"]), 0.001),
		"recent": snappedf(float(rec["recent"]), 0.001),
		"today": snappedf(float(rec["today"]), 0.001),
		"total": snappedf(total, 0.001),
		"sign": 0 if absf(total) < EPS else (1 if total > 0.0 else -1),
		"since": int(rec["first_tick"]),
		"last": int(rec["last_tick"]),
		"count": int(rec["count"]),
	}


func _rank(a: Dictionary, b: Dictionary) -> bool:
	var ra: float = absf(float(a["recent"]))
	var rb: float = absf(float(b["recent"]))
	if absf(ra - rb) > EPS:
		return ra > rb
	var ta: float = absf(float(a["total"]))
	var tb: float = absf(float(b["total"]))
	if absf(ta - tb) > EPS:
		return ta > tb
	return String(a["key"]) < String(b["key"])


func _sorted_keys() -> Array[StringName]:
	if _keys_dirty or _keys.size() != _entries.size():
		_keys.clear()
		var raw: Array = _entries.keys()
		raw.sort()
		for k: StringName in raw:
			_keys.append(k)
		_keys_dirty = false
	return _keys
