class_name LcnSaveDiff
extends RefCounted
## Structural comparison of two `Sim.serialize()`-shaped trees, by PATH.
##
## `tests/framework/json_canon.gd` already diffs two states for a test to print.
## This is the same idea for the *simulation* side of the fence: the save layer
## has to know which fields a load failed to bring back while it is still able
## to do something about it, and nothing under `game/` may depend on `tests/`.
##
## A path is an `Array` of segments — a `String` for a dictionary key, an `int`
## for an array index — so a caller can walk back to the value rather than parse
## a printed string. `render()` turns one into the `$.systems.heat.totals.ambient`
## form the round-trip suite prints.
##
## Floats are compared EXACTLY. This layer exists to make a reload byte-identical
## to the save it came from; a tolerance here is the negotiation the architecture
## says is not on offer.

const MAX_DEPTH: int = 48


## Every leaf path where `want` and `have` disagree, in sorted path order.
## A key present in one side and missing from the other is a difference at that
## key, not at its children.
static func differing(want: Variant, have: Variant, limit: int = 4096) -> Array:
	var out: Array = []
	_walk(want, have, [], out, limit, 0)
	out.sort_custom(func(a: Array, b: Array) -> bool: return render(a) < render(b))
	return out


## "$.systems.threat.plan.vectors[2].cells"
static func render(path: Array) -> String:
	var s: String = "$"
	for seg: Variant in path:
		if seg is int:
			s += "[%d]" % int(seg)
		else:
			s += "." + String(seg)
	return s


## The same rendering the round-trip suite groups on: array indices collapsed, so
## a list is one FIELD rather than one field per element.
static func render_field(path: Array) -> String:
	var s: String = "$"
	for seg: Variant in path:
		if seg is int:
			s += "[]"
		else:
			s += "." + String(seg)
	return s


## Value at `path`, or null when the path does not exist.
static func at(root: Variant, path: Array) -> Variant:
	var cur: Variant = root
	for seg: Variant in path:
		if seg is int:
			if not (cur is Array) or int(seg) >= (cur as Array).size():
				return null
			cur = (cur as Array)[int(seg)]
		else:
			if not (cur is Dictionary) or not (cur as Dictionary).has(seg):
				return null
			cur = (cur as Dictionary)[seg]
	return cur


## Deep, exact equality. Ints and floats are DIFFERENT types here on purpose:
## `var_to_bytes` round-trips both, so a save that comes back with 3 where it
## stored 3.0 has lost something, even though `==` would shrug.
static func same(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	match typeof(a):
		TYPE_DICTIONARY:
			var da: Dictionary = a
			var db: Dictionary = b
			if da.size() != db.size():
				return false
			for k: Variant in da:
				if not db.has(k):
					return false
				if not same(da[k], db[k]):
					return false
			return true
		TYPE_ARRAY:
			var aa: Array = a
			var ab: Array = b
			if aa.size() != ab.size():
				return false
			for i: int in aa.size():
				if not same(aa[i], ab[i]):
					return false
			return true
	return a == b


static func _walk(want: Variant, have: Variant, path: Array, out: Array, limit: int, depth: int) -> void:
	if out.size() >= limit or depth > MAX_DEPTH:
		return
	if typeof(want) != typeof(have):
		out.append(path.duplicate())
		return
	if want is Dictionary:
		var dw: Dictionary = want
		var dh: Dictionary = have
		# Sorted so two runs of the same comparison report in the same order.
		var keys: Array = dw.keys()
		keys.sort()
		for k: Variant in keys:
			if not dh.has(k):
				out.append(path + [k])
				continue
			_walk(dw[k], dh[k], path + [k], out, limit, depth + 1)
		var extra: Array = dh.keys()
		extra.sort()
		for k2: Variant in extra:
			if not dw.has(k2):
				out.append(path + [k2])
		return
	if want is Array:
		var aw: Array = want
		var ah: Array = have
		if aw.size() != ah.size():
			out.append(path.duplicate())
			return
		for i: int in aw.size():
			_walk(aw[i], ah[i], path + [i], out, limit, depth + 1)
		return
	if not same(want, have):
		out.append(path.duplicate())
