class_name LawBook
extends RefCounted
## The Book of Laws: the graph, the seal, and the record of who you turned out
## to be.
##
## Three rules give the book its shape.
##
##   PREREQUISITES make the book a tree instead of a menu. You cannot conscript
##   labour before you have men willing to do the conscripting.
##
##   EXCLUSIONS make it a record. Signing The Pits closes Named Graves forever;
##   the page stays in the book, greyed, with your handwriting nowhere on it.
##   Exclusion is symmetric and LawBook enforces that, so content only ever
##   declares it once.
##
##   THE SEAL makes it scarce. One law is argued at a time, it takes hours to
##   come into force, and the seal has to dry for eighteen hours after that.
##   Roughly one law a day. You will not sign your way out of a crisis.
##
## Everything here is pure bookkeeping. LawBook never touches a meter; it hands
## the law that just came into force back to SocietySystem and lets the
## consequences happen there.

const CATEGORY: String = SocietyDefs.LAW_CATEGORY

## id -> LawDef
var _defs: Dictionary[StringName, LawDef] = {}
## Sorted by (branch, tier, sort_order, id) so every listing is stable.
var _ordered: Array[LawDef] = []
## Symmetric closure of every declared exclusion.
var _excludes: Dictionary[StringName, Array] = {}

## Signing order matters: the book is read top to bottom at the end of a run.
var _signed_order: Array[StringName] = []
var _signed: Dictionary[StringName, int] = {}   ## id -> tick it came into force

var _pending: StringName = &""
var _pending_from: int = 0
var _pending_until: int = 0
var _cooldown_until: int = 0

## Resolved on every change so the hot path is a dictionary read, not a scan.
var _policy: Dictionary[StringName, float] = {}
var _flags: Dictionary[StringName, bool] = {}
var _dirty: bool = true


# =========================================================================
#  loading
# =========================================================================

## Reads every law out of Registry and validates the whole graph. Returns the
## problems it found; SocietySystem turns those into Log.error at boot, because
## a broken law tree discovered mid run is a run nobody can judge.
func load_from_registry() -> PackedStringArray:
	_defs.clear()
	_ordered.clear()
	_excludes.clear()
	var problems: PackedStringArray = PackedStringArray()

	for id: StringName in Registry.ids(CATEGORY):
		var res: Resource = Registry.get_item(CATEGORY, id)
		var law: LawDef = res as LawDef
		if law == null:
			problems.append("'%s' in game/content/laws is not a LawDef" % String(id))
			continue
		if law.id == &"":
			law.id = id
		for p: String in law.validate():
			problems.append("law '%s' %s" % [String(law.id), p])
		_defs[law.id] = law

	for law: LawDef in _sorted_defs():
		_ordered.append(law)

	problems.append_array(_build_graph())
	return problems


func _sorted_defs() -> Array[LawDef]:
	var ids: Array = _defs.keys()
	ids.sort()
	var out: Array[LawDef] = []
	for id: StringName in ids:
		out.append(_defs[id])
	out.sort_custom(func(a: LawDef, b: LawDef) -> bool:
		if a.branch != b.branch:
			return String(a.branch) < String(b.branch)
		if a.tier != b.tier:
			return a.tier < b.tier
		if a.sort_order != b.sort_order:
			return a.sort_order < b.sort_order
		return String(a.id) < String(b.id))
	return out


## Symmetric exclusion closure plus every referential check the graph needs.
func _build_graph() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	for law: LawDef in _ordered:
		for r: StringName in law.requires:
			if not _defs.has(r):
				problems.append("law '%s' requires '%s', which does not exist" % [
					String(law.id), String(r)])
		for r: StringName in law.requires_any:
			if not _defs.has(r):
				problems.append("law '%s' requires_any '%s', which does not exist" % [
					String(law.id), String(r)])
		for x: StringName in law.excludes:
			if not _defs.has(x):
				problems.append("law '%s' excludes '%s', which does not exist" % [
					String(law.id), String(x)])
				continue
			_link_exclusion(law.id, x)
			_link_exclusion(x, law.id)

	# A law that requires two laws which exclude each other can never be signed.
	# That is not a design decision, it is a typo, and it should be loud.
	for law: LawDef in _ordered:
		var reqs: Array[StringName] = law.requires.duplicate()
		for i: int in reqs.size():
			for j: int in range(i + 1, reqs.size()):
				if _blocks(reqs[i], reqs[j]):
					problems.append("law '%s' requires both '%s' and '%s', which exclude each other" % [
						String(law.id), String(reqs[i]), String(reqs[j])])
		for r: StringName in reqs:
			if _blocks(law.id, r):
				problems.append("law '%s' requires '%s' but also excludes it" % [
					String(law.id), String(r)])

	problems.append_array(_check_cycles())
	return problems


func _link_exclusion(a: StringName, b: StringName) -> void:
	var arr: Array = _excludes.get(a, [])
	if not arr.has(b):
		arr.append(b)
		arr.sort()
		_excludes[a] = arr


func _blocks(a: StringName, b: StringName) -> bool:
	return (_excludes.get(a, []) as Array).has(b)


## Depth first search over requires + requires_any. A cycle means a branch of
## the book is unreachable no matter what the player does.
func _check_cycles() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var state: Dictionary[StringName, int] = {}   ## 0 unseen, 1 open, 2 closed
	for law: LawDef in _ordered:
		var found: PackedStringArray = _visit(law.id, state, PackedStringArray())
		if not found.is_empty():
			out.append_array(found)
	return out


func _visit(id: StringName, state: Dictionary[StringName, int],
		path: PackedStringArray) -> PackedStringArray:
	var s: int = int(state.get(id, 0))
	if s == 2:
		return PackedStringArray()
	if s == 1:
		return PackedStringArray(["law prerequisite cycle: %s -> %s" % [
			" -> ".join(path), String(id)]])
	state[id] = 1
	var out: PackedStringArray = PackedStringArray()
	var law: LawDef = _defs.get(id)
	if law != null:
		var next: PackedStringArray = path.duplicate()
		next.append(String(id))
		var deps: Array[StringName] = []
		deps.append_array(law.requires)
		deps.append_array(law.requires_any)
		deps.sort()
		for d: StringName in deps:
			if _defs.has(d):
				out.append_array(_visit(d, state, next))
	state[id] = 2
	return out


# =========================================================================
#  reading the book
# =========================================================================

func count() -> int:
	return _defs.size()


func has(id: StringName) -> bool:
	return _defs.has(id)


func get_law(id: StringName) -> LawDef:
	return _defs.get(id)


## Every law in the book, in book order.
func all() -> Array[LawDef]:
	return _ordered.duplicate()


func laws_in_branch(branch: StringName) -> Array[LawDef]:
	var out: Array[LawDef] = []
	for law: LawDef in _ordered:
		if law.branch == branch:
			out.append(law)
	return out


func is_signed(id: StringName) -> bool:
	return _signed.has(id)


func signed_at(id: StringName) -> int:
	return int(_signed.get(id, -1))


## In signing order. This array IS the record of the run.
func signed_ids() -> Array[StringName]:
	return _signed_order.duplicate()


func signed_count() -> int:
	return _signed_order.size()


## Laws this run can never sign now, because something in force excludes them.
func foreclosed_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for law: LawDef in _ordered:
		if _signed.has(law.id):
			continue
		if _foreclosed_by(law.id) != &"":
			out.append(law.id)
	return out


func _foreclosed_by(id: StringName) -> StringName:
	for other: StringName in (_excludes.get(id, []) as Array):
		if _signed.has(other):
			return other
	return &""


## The branch the player has committed to, or &"" while both doors are open.
func committed_branch() -> StringName:
	var order_n: int = 0
	var faith_n: int = 0
	for id: StringName in _signed_order:
		var law: LawDef = _defs[id]
		if law.branch == SocietyDefs.BRANCH_ORDER:
			order_n += 1
		elif law.branch == SocietyDefs.BRANCH_FAITH:
			faith_n += 1
	if order_n > 0 and faith_n == 0:
		return SocietyDefs.BRANCH_ORDER
	if faith_n > 0 and order_n == 0:
		return SocietyDefs.BRANCH_FAITH
	return &""


# =========================================================================
#  the seal
# =========================================================================

func pending_id() -> StringName:
	return _pending


func pending_ticks_left(tick: int) -> int:
	return 0 if _pending == &"" else maxi(0, _pending_until - tick)


func cooldown_ticks_left(tick: int) -> int:
	return maxi(0, _cooldown_until - tick)


## {ok: bool, reason: String, blocked_by: String}. `reason` is written for a
## human, because this string is what a UI puts under a greyed out page.
func availability(id: StringName, day: int, tick: int) -> Dictionary:
	var law: LawDef = _defs.get(id)
	if law == null:
		return {"ok": false, "reason": "There is no such law.", "blocked_by": ""}
	if _signed.has(id):
		return {"ok": false, "reason": "Already in force.", "blocked_by": ""}
	if _pending == id:
		return {"ok": false, "reason": "Being argued now.", "blocked_by": ""}
	var closed_by: StringName = _foreclosed_by(id)
	if closed_by != &"":
		return {
			"ok": false,
			"reason": "Foreclosed by %s. That door is shut." % _defs[closed_by].title,
			"blocked_by": String(closed_by),
		}
	if _pending != &"":
		return {
			"ok": false,
			"reason": "%s is still being argued." % _defs[_pending].title,
			"blocked_by": String(_pending),
		}
	if tick < _cooldown_until:
		return {
			"ok": false,
			"reason": "The seal is not dry.",
			"blocked_by": "",
		}
	if day < law.min_day:
		return {
			"ok": false,
			"reason": "Nobody would sign this on day %d." % day,
			"blocked_by": "",
		}
	for r: StringName in _sorted(law.requires):
		if not _signed.has(r):
			var need: LawDef = _defs.get(r)
			return {
				"ok": false,
				"reason": "Requires %s." % (need.title if need != null else String(r)),
				"blocked_by": String(r),
			}
	if not law.requires_any.is_empty():
		var any_ok: bool = false
		for r: StringName in law.requires_any:
			if _signed.has(r):
				any_ok = true
				break
		if not any_ok:
			var names: PackedStringArray = PackedStringArray()
			for r: StringName in _sorted(law.requires_any):
				var d: LawDef = _defs.get(r)
				names.append(d.title if d != null else String(r))
			return {
				"ok": false,
				"reason": "Requires one of: %s." % ", ".join(names),
				"blocked_by": String(law.requires_any[0]),
			}
	return {"ok": true, "reason": "", "blocked_by": ""}


func can_sign(id: StringName, day: int, tick: int) -> bool:
	return bool(availability(id, day, tick).get("ok", false))


## Every law that could be put to the room right now, in book order.
func available(day: int, tick: int) -> Array[LawDef]:
	var out: Array[LawDef] = []
	for law: LawDef in _ordered:
		if can_sign(law.id, day, tick):
			out.append(law)
	return out


## Puts a law to the room. Returns {ok, reason, until_tick}.
func propose(id: StringName, day: int, tick: int, hour_ticks: int) -> Dictionary:
	var av: Dictionary = availability(id, day, tick)
	if not bool(av.get("ok", false)):
		return {"ok": false, "reason": String(av.get("reason", "")), "until_tick": 0}
	var law: LawDef = _defs[id]
	_pending = id
	_pending_from = tick
	_pending_until = tick + int(round(law.effective_debate_hours() * float(hour_ticks)))
	_dirty = true
	return {"ok": true, "reason": "", "until_tick": _pending_until}


## Withdraws the law under debate. Costs nothing here; SocietySystem charges for
## it, because taking a proposal back off the table is its own kind of statement.
func withdraw() -> StringName:
	var was: StringName = _pending
	_pending = &""
	_pending_from = 0
	_pending_until = 0
	return was


## Advances the seal. Returns the law that came into force this tick, or null.
func advance(tick: int, hour_ticks: int) -> LawDef:
	if _pending == &"" or tick < _pending_until:
		return null
	var law: LawDef = _defs.get(_pending)
	_pending = &""
	_pending_from = 0
	_pending_until = 0
	if law == null:
		return null
	_signed[law.id] = tick
	_signed_order.append(law.id)
	_cooldown_until = tick + int(round(SocietyDefs.SIGN_COOLDOWN_HOURS * float(hour_ticks)))
	_dirty = true
	return law


# =========================================================================
#  the policy vector — what the book does to the world
# =========================================================================

## Base value plus every signed law's offset. Other parts read this to find out
## what the city has agreed to do to itself.
func policy_value(key: StringName) -> float:
	_resolve()
	return float(_policy.get(key, SocietyDefs.policy_default(key)))


func policy_flag(f: StringName) -> bool:
	_resolve()
	return bool(_flags.get(f, false))


## The whole vector, for serialize() and for a UI that wants to show the diff.
func policy_snapshot() -> Dictionary:
	_resolve()
	var out: Dictionary = {}
	for key: StringName in SocietyDefs.POLICY_KEYS:
		out[String(key)] = snappedf(policy_value(key), 0.001)
	var flags: Array = _flags.keys()
	flags.sort()
	var on: Array = []
	for f: StringName in flags:
		if bool(_flags[f]):
			on.append(String(f))
	out["flags"] = on
	return out


func _resolve() -> void:
	if not _dirty:
		return
	_policy.clear()
	_flags.clear()
	for key: StringName in SocietyDefs.POLICY_KEYS:
		_policy[key] = SocietyDefs.policy_default(key)
	for id: StringName in _signed_order:
		var law: LawDef = _defs.get(id)
		if law == null:
			continue
		var keys: Array = law.policy.keys()
		keys.sort()
		for key: StringName in keys:
			_policy[key] = float(_policy.get(key, SocietyDefs.policy_default(key))) \
				+ float(law.policy[key])
		for f: StringName in law.flags:
			_flags[f] = true
	_dirty = false


## Grievance kinds every law in force answers, sorted.
func relieved_grievances() -> Array[StringName]:
	var seen: Dictionary[StringName, bool] = {}
	for id: StringName in _signed_order:
		var law: LawDef = _defs.get(id)
		if law == null:
			continue
		for g: StringName in law.relieves:
			seen[g] = true
	return _sorted_keys(seen)


## Grievance kinds the book itself is causing, sorted.
func provoked_grievances() -> Array[StringName]:
	var seen: Dictionary[StringName, bool] = {}
	for id: StringName in _signed_order:
		var law: LawDef = _defs.get(id)
		if law == null:
			continue
		for g: StringName in law.provokes:
			seen[g] = true
	return _sorted_keys(seen)


## Sum of every signed law's continuous contribution to one meter, per hour.
func standing_rate(meter: StringName) -> float:
	var total: float = 0.0
	for id: StringName in _signed_order:
		var law: LawDef = _defs.get(id)
		if law == null:
			continue
		total += law.hope_rate if meter == SocietyDefs.METER_HOPE else law.discontent_rate
	return total


# =========================================================================
#  persistence
# =========================================================================

func serialize() -> Dictionary:
	var signed: Array = []
	for id: StringName in _signed_order:
		var law: LawDef = _defs.get(id)
		signed.append({
			"id": String(id),
			"title": law.title if law != null else String(id),
			"branch": String(law.branch) if law != null else "trunk",
			"tick": int(_signed[id]),
		})
	var foreclosed: Array = []
	for id: StringName in foreclosed_ids():
		foreclosed.append({"id": String(id), "by": String(_foreclosed_by(id))})
	return {
		"signed": signed,
		"foreclosed": foreclosed,
		"pending": String(_pending),
		"pending_from": _pending_from,
		"pending_until": _pending_until,
		"cooldown_until": _cooldown_until,
		"branch": String(committed_branch()),
		"policy": policy_snapshot(),
		"in_book": _defs.size(),
	}


func deserialize(data: Dictionary) -> void:
	_signed.clear()
	_signed_order.clear()
	for raw: Variant in data.get("signed", []):
		var d: Dictionary = raw
		var id: StringName = StringName(String(d.get("id", "")))
		if not _defs.has(id) or _signed.has(id):
			continue
		_signed[id] = int(d.get("tick", 0))
		_signed_order.append(id)
	_pending = StringName(String(data.get("pending", "")))
	if not _defs.has(_pending):
		_pending = &""
	_pending_from = int(data.get("pending_from", 0))
	_pending_until = int(data.get("pending_until", 0))
	_cooldown_until = int(data.get("cooldown_until", 0))
	_dirty = true


# --- small helpers -----------------------------------------------------------

func _sorted(arr: Array[StringName]) -> Array[StringName]:
	var copy: Array[StringName] = arr.duplicate()
	copy.sort()
	return copy


func _sorted_keys(d: Dictionary[StringName, bool]) -> Array[StringName]:
	var raw: Array = d.keys()
	raw.sort()
	var out: Array[StringName] = []
	for k: StringName in raw:
		out.append(k)
	return out
