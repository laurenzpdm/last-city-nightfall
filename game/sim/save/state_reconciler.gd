class_name LcnStateReconciler
extends RefCounted
## Finishes a restore that a system's own `deserialize()` left half done — and
## proves each repair instead of assuming it.
##
## THE PROBLEM. `SimSystem.serialize()` reports everything a system knows.
## `SimSystem.deserialize()` reads back only what its author remembered to read
## back. Eleven parts wrote those two methods independently, so a save that is
## complete on the way out comes back missing forty fields — a cached ambient
## temperature here, a per-tick crew budget there, a queued narrative event, the
## approach path a wave had already chosen. The round-trip suite listed all of
## them under `KNOWN_GAPS` with an owner beside each, and a gap list is how a
## rule the architecture calls non-negotiable becomes negotiable one line at a
## time.
##
## Fixing it inside each of the eleven systems is the obvious answer and it is
## not available to this part: `game/sim/<part>/` belongs to that part. It is
## also the answer that rots, because the next field a part adds to `serialize()`
## and forgets in `deserialize()` re-opens the hole silently.
##
## THE MECHANISM. After a system has deserialized, ask it to serialize again and
## compare that against the payload it was handed. Every field that still
## disagrees is a field the load lost. For each one, look through the system's
## own script variables — and those of the plain helper objects it holds — for
## the variable that field came out of, put the saved value in it, and then
## SERIALIZE AGAIN to find out whether that actually worked. A repair is kept
## only when the field it targeted now matches and no field that already matched
## has stopped matching. Anything else is rolled back to the value it had.
##
## So the search is allowed to be wrong. It guesses by name (`wind` → `_wind`,
## `hope_rate` → `_rate_hope`, `totals.ambient` → `_ambient_c`) and the guess is
## worth nothing until the system's own `serialize()` agrees. That is the whole
## reason this is not a hand-written table of forty field-to-variable mappings:
## a table is a claim, and this is a measurement. What it CANNOT repair it
## reports by name and by owner, so the residue is visible rather than excused.
##
## WHAT IT WILL NOT TOUCH. It never walks into another `SimSystem` (a neighbour
## reference is not this system's state), never into a `Resource` (Registry owns
## those and they outlive the world), and never into a `Node`. It never assigns
## a value of a different type than the variable already holds, it never puts
## objects into a typed container, and — see `_congruent` — it never writes a
## container that would cost the live object a key it depends on, because
## `serialize()` is very often a PROJECTION and a repair verified only by
## re-serializing cannot otherwise tell a value from its own shadow.
## Determinism: every walk and every key iteration is sorted, and nothing here
## reads a clock or a random number.

## How deep into a system's helper objects to look. `LogisticsSystem.haul.porters`
## and `SocietySystem._pressures.<field>` are depth 2; past that the search costs
## more than it finds.
const MAX_HOLDER_DEPTH: int = 2

## How many times `Sim.deserialize()` walks the systems handing each its payload
## before this class runs. Two, because a system that samples a neighbour on the
## way in sampled a half-restored world on the first pass. See sim.gd.
const RESTORE_PASSES: int = 2

## How many times the repair sweep may run. It stops as soon as a round mends
## nothing new; the cap is only there so a pathological system cannot loop.
const RECONCILE_ROUNDS: int = 4

## Ceilings, so a badly-behaved system cannot turn a load into a minute of
## re-serialization. A system with more residue than this reports the residue.
const MAX_CANDIDATES: int = 3000
const MAX_TRIES_PER_FIELD: int = 6
const MAX_VERIFY_CALLS: int = 400


## Puts back what `sys.deserialize()` did not. Returns
## `{fixed: PackedStringArray, left: PackedStringArray, map: Dictionary, tries: int}`
## where `map` records field → the variable it was recovered from, so the log can
## show a human the mapping the search found.
static func finish(sys: SimSystem, want: Dictionary) -> Dictionary:
	var report: Dictionary = {
		"fixed": PackedStringArray(), "left": PackedStringArray(),
		"map": {}, "tries": 0,
	}
	var have: Dictionary = sys.serialize()
	var missing: Array = LcnSaveDiff.differing(want, have)
	if missing.is_empty():
		return report

	var candidates: Array[Dictionary] = _candidates(sys)
	var verify_calls: int = 0

	# Broadest first. `narrative.facts` is one dictionary that was lost whole, and
	# putting it back in one assignment beats twenty-two leaf assignments; but
	# `research.pacing.signals.cold` only becomes reachable at the *middle*
	# prefix, because `cold` is a key inside a dictionary and `signals` is the
	# variable. So every prefix of every missing path is a target, shortest
	# first, and a prefix that succeeds removes the deeper ones from the list.
	var attempted: Dictionary[String, bool] = {}
	for prefix: Array in _prefixes(missing):
		if verify_calls >= MAX_VERIFY_CALLS:
			break
		var key: String = LcnSaveDiff.render(prefix)
		if attempted.has(key):
			continue
		attempted[key] = true
		if LcnSaveDiff.same(LcnSaveDiff.at(want, prefix), LcnSaveDiff.at(have, prefix)):
			continue                  # an earlier, broader repair already covered it
		var res: Dictionary = _try_path(sys, want, have, prefix, candidates,
			MAX_VERIFY_CALLS - verify_calls)
		verify_calls += int(res["calls"])
		if bool(res["ok"]):
			have = res["have"]
			report["map"][LcnSaveDiff.render_field(prefix)] = String(res["via"])

	report["tries"] = verify_calls
	var left: Dictionary[String, bool] = {}
	for path2: Array in LcnSaveDiff.differing(want, sys.serialize()):
		left[LcnSaveDiff.render_field(path2)] = true
	# PackedStringArray is a VALUE in GDScript: `report["fixed"].append(x)` appends
	# to a copy and throws it away. Build the arrays locally, assign them once.
	var fixed_keys: Array = (report["map"] as Dictionary).keys()
	fixed_keys.sort()
	var fixed_out: PackedStringArray = PackedStringArray()
	for k2: String in fixed_keys:
		fixed_out.append(k2)
	var left_keys: Array = left.keys()
	left_keys.sort()
	var left_out: PackedStringArray = PackedStringArray()
	for k3: String in left_keys:
		left_out.append(k3)
	report["fixed"] = fixed_out
	report["left"] = left_out
	return report


# ------------------------------------------------------------ the attempt ---

## One field (or one subtree). Tries the best-named variables in turn, keeps the
## first assignment the system's own `serialize()` ratifies, rolls back the rest.
static func _try_path(sys: SimSystem, want: Dictionary, have: Dictionary,
		path: Array, candidates: Array[Dictionary], budget: int) -> Dictionary:
	var target: Variant = LcnSaveDiff.at(want, path)
	var ranked: Array[Dictionary] = _rank(path, candidates)
	var calls: int = 0
	for i: int in mini(ranked.size(), MAX_TRIES_PER_FIELD):
		if calls >= budget:
			break
		var cand: Dictionary = ranked[i]
		var holder: Object = cand["holder"]
		if holder == null or not is_instance_valid(holder):
			continue
		var prop: String = cand["prop"]
		var old: Variant = holder.get(prop)

		var applied: bool = false
		if old is Object:
			# A helper that knows its own format is always better than poking at
			# its fields: `_pressures.deserialize(saved)` over guessing which of
			# its nine variables produced `forces.hope_ceiling`.
			applied = _apply_via_method(old as Object, target)
		else:
			var conv: Variant = _convert(old, target)
			if conv == null and target != null:
				continue
			holder.set(prop, conv)
			applied = true
		if not applied:
			continue

		calls += 1
		var after: Dictionary = sys.serialize()
		if _is_improvement(want, have, after, path):
			return {"ok": true, "have": after, "calls": calls,
				"via": "%s.%s" % [_type_name(holder), prop]}
		# Not an improvement: put it back exactly as it was. An object handed to
		# its own deserialize() cannot be rolled back this way, which is why that
		# route is only taken when the object HAS that method — a part that ships
		# `deserialize()` on a helper has already accepted that call.
		if not (old is Object):
			holder.set(prop, old)
	return {"ok": false, "have": have, "calls": calls, "via": ""}


## The rule that makes a guess safe: the field we aimed at must now match, and
## nothing that already matched may have stopped matching.
static func _is_improvement(want: Dictionary, before: Dictionary, after: Dictionary,
		path: Array) -> bool:
	if not LcnSaveDiff.same(LcnSaveDiff.at(want, path), LcnSaveDiff.at(after, path)):
		return false
	var was: Dictionary[String, bool] = {}
	for p: Array in LcnSaveDiff.differing(want, before):
		was[LcnSaveDiff.render(p)] = true
	for p2: Array in LcnSaveDiff.differing(want, after):
		if not was.has(LcnSaveDiff.render(p2)):
			return false
	return true


static func _apply_via_method(obj: Object, value: Variant) -> bool:
	if typeof(value) != TYPE_DICTIONARY and typeof(value) != TYPE_ARRAY:
		return false
	for m: String in ["deserialize", "from_json", "from_dict", "restore"]:
		if obj.has_method(m):
			obj.call(m, value)
			return true
	return false


# ---------------------------------------------------------- the candidates ---

## Every script variable on the system and on the plain helper objects it holds.
## Sorted, so the search is the same search on every machine.
static func _candidates(root: SimSystem) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary[int, bool] = {root.get_instance_id(): true}
	var frontier: Array[Dictionary] = [{"obj": root, "via": "", "depth": 0}]
	while not frontier.is_empty() and out.size() < MAX_CANDIDATES:
		var node: Dictionary = frontier.pop_front()
		var obj: Object = node["obj"]
		var depth: int = node["depth"]
		var names: Array[String] = _script_vars(obj)
		for prop: String in names:
			out.append({
				"holder": obj, "prop": prop, "via": String(node["via"]),
				"tokens": _tokens(prop), "holder_tokens": _tokens(String(node["via"])),
				"depth": depth,
			})
			if depth >= MAX_HOLDER_DEPTH:
				continue
			var v: Variant = obj.get(prop)
			if not (v is Object):
				continue
			var child: Object = v
			if not _walkable(child) or seen.has(child.get_instance_id()):
				continue
			seen[child.get_instance_id()] = true
			frontier.append({"obj": child, "via": prop, "depth": depth + 1})
	return out


## A part's own helper. NOT a neighbouring system (that is somebody else's
## state), NOT a Resource (Registry owns it and it outlives the world), NOT a
## Node (somebody else's tree).
static func _walkable(o: Object) -> bool:
	if o is SimSystem or o is Resource or o is Node:
		return false
	return o is RefCounted


static func _script_vars(o: Object) -> Array[String]:
	var names: Array[String] = []
	for p: Dictionary in o.get_property_list():
		if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		names.append(String(p.get("name", "")))
	names.sort()
	return names


# ------------------------------------------------------------- the ranking ---

## Best-named variables first. Names are a hint and only a hint — `_is_improvement`
## is what decides — but a good hint keeps the number of re-serializations small.
static func _rank(path: Array, candidates: Array[Dictionary]) -> Array[Dictionary]:
	var leaf: PackedStringArray = _tokens(_last_name(path))
	var parent: PackedStringArray = _tokens(_parent_name(path))
	var scored: Array[Dictionary] = []
	for c: Dictionary in candidates:
		var s: int = _affinity(leaf, c["tokens"])
		if s <= 0:
			continue
		# `haul.porters` reached through the variable `haul` outranks a `porters`
		# that happens to live somewhere else.
		if parent.size() > 0 and _affinity(parent, c["holder_tokens"]) > 0:
			s += 40
		# A variable on the system itself is likelier than one three objects in.
		s += (MAX_HOLDER_DEPTH - int(c["depth"])) * 3
		scored.append({"score": s, "cand": c})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["score"]) != int(b["score"]):
			return int(a["score"]) > int(b["score"])
		var ca: Dictionary = a["cand"]
		var cb: Dictionary = b["cand"]
		return "%s.%s" % [ca["via"], ca["prop"]] < "%s.%s" % [cb["via"], cb["prop"]])
	var out: Array[Dictionary] = []
	for row: Dictionary in scored:
		out.append(row["cand"])
	return out


static func _last_name(path: Array) -> String:
	for i: int in range(path.size() - 1, -1, -1):
		if not (path[i] is int):
			return String(path[i])
	return ""


static func _parent_name(path: Array) -> String:
	var found: int = 0
	for i: int in range(path.size() - 1, -1, -1):
		if path[i] is int:
			continue
		found += 1
		if found == 2:
			return String(path[i])
	return ""


static func _tokens(name: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for part: String in name.to_lower().lstrip("_").split("_"):
		if part != "":
			out.append(part)
	return out


## 0 means "do not bother". Anything above is a rank, not a decision.
static func _affinity(want: PackedStringArray, have: PackedStringArray) -> int:
	if want.is_empty() or have.is_empty():
		return 0
	var wj: String = "".join(want)
	var hj: String = "".join(have)
	if wj == hj:
		return 100
	var shared: int = 0
	for t: String in want:
		if have.has(t):
			shared += 1
	if shared == want.size():
		return 70                     # every word we wanted is in the name
	if shared == have.size():
		return 60                     # the name is a prefix-set of what we wanted
	if shared > 0:
		return 20 + shared * 5
	if hj.begins_with(wj) or wj.begins_with(hj):
		return 30                     # ambient → _ambient_c
	return 0


# ---------------------------------------------------------- the assignment ---

## The saved value, in the type the variable already holds — or null when there
## is no safe conversion, which means this candidate is skipped rather than
## coerced. A wrong-typed `set()` is an engine error and the gate counts those.
static func _convert(old: Variant, want: Variant) -> Variant:
	match typeof(old):
		TYPE_FLOAT:
			if want is float:
				return float(want)
			if want is int:
				return float(want)
		TYPE_INT:
			if want is int:
				return int(want)
			if want is bool:
				return int(want)
		TYPE_BOOL:
			if want is bool:
				return bool(want)
		TYPE_STRING:
			if want is String or want is StringName:
				return String(want)
		TYPE_STRING_NAME:
			if want is String or want is StringName:
				return StringName(String(want))
		TYPE_DICTIONARY:
			if want is Dictionary and _congruent(old, want):
				return _convert_dict(old as Dictionary, want as Dictionary)
		TYPE_ARRAY:
			if want is Array and _congruent(old, want):
				return _convert_array(old as Array, want as Array)
	return null


## THE RULE THAT STOPS A REPAIR BEING A LIE, and it was written the day one was.
##
## `serialize()` is very often a PROJECTION of a variable rather than the
## variable: `NarrativeSystem.serialize()` writes six keys of a pending card and
## the live card has eleven. Assigning the projection back makes the system's own
## `serialize()` agree — `_is_improvement` said yes and the field went green —
## and the next `_push()` after the load died on
## `Invalid access to property or key 'priority'`, because the queue now held
## card-shaped things that were not cards. A repair verified only by
## re-serializing cannot tell a value from its own shadow.
##
## So a write may ADD information and may never silently DROP a key the live
## object depends on:
##
##   * dictionary → dictionary: every key already there must still be there
##     afterwards. A card with eleven keys will not accept a card with six. A
##     dictionary the load left EMPTY has no keys to lose, so a rebuilt-every-tick
##     signal table still comes back.
##   * list → list of the same length: checked element by element, same rule.
##   * list → list of a DIFFERENT length: allowed only when nothing inside is a
##     record, because a list of numbers cannot be a projection of itself and a
##     list of records cannot be checked against elements that are not there.
##
## When the check refuses, the field stays in the residue with its name on it,
## which is the outcome this class exists to make honest.
static func _congruent(old: Variant, want: Variant) -> bool:
	if old is Dictionary and want is Dictionary:
		var od: Dictionary = old
		var wd: Dictionary = want
		for k: Variant in od:
			# A `Dictionary[StringName, float]` in the world meets plain String
			# keys out of the file, and `has()` does not bridge the two. Without
			# this, seven perfectly restorable research pacing signals were
			# refused as "a key the live object would lose".
			var wk: Variant = _matching_key(wd, k)
			if wk == null and k != null:
				return false
			if not _congruent(od[k], wd[wk]):
				return false
		return true
	if old is Array and want is Array:
		var oa: Array = old
		var wa: Array = want
		if oa.size() != wa.size():
			return _no_records(wa)
		for i: int in oa.size():
			if not _congruent(oa[i], wa[i]):
				return false
		return true
	# A container on one side and a leaf on the other is a shape change too.
	if old is Dictionary or old is Array or want is Dictionary or want is Array:
		return false
	return true


## `k` as it appears in `d`, bridging String and StringName, or null when `d`
## does not carry that key at all.
static func _matching_key(d: Dictionary, k: Variant) -> Variant:
	if d.has(k):
		return k
	if k is StringName and d.has(String(k)):
		return String(k)
	if k is String and d.has(StringName(k)):
		return StringName(k)
	return null


## True when nothing anywhere inside `v` is a dictionary — the only shape whose
## keys a `serialize()` can quietly leave out.
static func _no_records(v: Variant) -> bool:
	if v is Dictionary:
		return false
	if v is Array:
		for e: Variant in (v as Array):
			if not _no_records(e):
				return false
	return true


static func _convert_array(old: Array, want: Array) -> Variant:
	if not old.is_typed():
		return want.duplicate(true)
	if old.get_typed_script() != null:
		return null                   # an array of objects cannot take raw data
	var builtin: int = old.get_typed_builtin()
	var out: Array = old.duplicate()
	out.clear()
	for v: Variant in want:
		var c: Variant = _as_builtin(builtin, v)
		if c == null and v != null:
			return null
		out.append(c)
	return out


static func _convert_dict(old: Dictionary, want: Dictionary) -> Variant:
	if not old.is_typed_key() and not old.is_typed_value():
		return want.duplicate(true)
	if old.get_typed_key_script() != null or old.get_typed_value_script() != null:
		return null
	var out: Dictionary = old.duplicate()
	out.clear()
	var keys: Array = want.keys()
	keys.sort()
	for k: Variant in keys:
		var ck: Variant = _as_builtin(old.get_typed_key_builtin(), k) if old.is_typed_key() else k
		var cv: Variant = _as_builtin(old.get_typed_value_builtin(), want[k]) if old.is_typed_value() else want[k]
		if (ck == null and k != null) or (cv == null and want[k] != null):
			return null
		out[ck] = cv
	return out


static func _as_builtin(builtin: int, v: Variant) -> Variant:
	match builtin:
		TYPE_NIL:
			return v
		TYPE_FLOAT:
			return float(v) if (v is float or v is int) else null
		TYPE_INT:
			return int(v) if (v is int or v is bool) else null
		TYPE_BOOL:
			return bool(v) if v is bool else null
		TYPE_STRING:
			return String(v) if (v is String or v is StringName) else null
		TYPE_STRING_NAME:
			return StringName(String(v)) if (v is String or v is StringName) else null
		TYPE_DICTIONARY:
			return (v as Dictionary).duplicate(true) if v is Dictionary else null
		TYPE_ARRAY:
			return (v as Array).duplicate(true) if v is Array else null
	return null


# ------------------------------------------------------------------ detail ---

## Every distinct prefix of every missing path, shortest first — the list of
## places a repair could be aimed at, from "the whole subtree" down to "this one
## number". A prefix ending in an array index is dropped: an element of a list is
## never a variable of its own, and the list itself is already in this set.
static func _prefixes(missing: Array) -> Array[Array]:
	var seen: Dictionary[String, bool] = {}
	var out: Array[Array] = []
	var longest: int = 0
	for path: Array in missing:
		longest = maxi(longest, path.size())
	for depth: int in range(1, longest + 1):
		for path2: Array in missing:
			if path2.size() < depth:
				continue
			var prefix: Array = path2.slice(0, depth)
			if prefix[depth - 1] is int:
				continue
			var key: String = LcnSaveDiff.render(prefix)
			if seen.has(key):
				continue
			seen[key] = true
			out.append(prefix)
	return out


static func _type_name(o: Object) -> String:
	var scr: Script = o.get_script() as Script
	if scr != null and scr.get_global_name() != &"":
		return String(scr.get_global_name())
	return o.get_class()
