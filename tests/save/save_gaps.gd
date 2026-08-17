class_name LcnSaveGapProbe
extends RefCounted
## The state a save still loses, lifted out of the live world by hand and put
## back by hand after the load — so that "these two fields do not come back" is a
## MEASUREMENT with a proof attached, instead of a line of prose in a gap list.
##
## `Sim.deserialize()` plus `LcnStateReconciler` bring back every field of
## `Sim.serialize()` except two, and both are state the save file never carried
## in the first place:
##
##   $.systems.society.forces          [P06] game/sim/society/
##   $.systems.threat.plan.vectors[]   [P08] game/sim/threat/threat_vector.gd
##
## Nothing downstream can restore what was never written, and neither folder
## belongs to the save layer. What this class does instead is settle the
## question a gap list always leaves open: *is that really all of it?* A test
## captures these values from the running world before the save, loads the save
## into a fresh world, puts exactly these values back, and then demands the two
## states be byte-identical — at rest AND two hundred ticks later. If any other
## field were quietly lost, that comparison would still fail and name it.
##
## So this is the shape of the fix the two parts owe, run as an experiment:
##   * [P06] `SocietyPressures` needs `serialize()`'s inverse — the five parallel
##     arrays below plus the ceiling — and `SocietySystem.deserialize()` needs to
##     call it instead of recomputing the forces from an already-advanced council;
##   * [P08] `ThreatVector.to_dict()` writes `path.size()` and never `path`, so
##     the approach corridor a night was planned around is gone on reload.
##
## Test-only, and it says so by living in `tests/`. Nothing in `game/` may use it.

## THE WHOLE LIST, and the single place it is written down. Fields of
## `Sim.serialize()` that a `Sim.deserialize()` of the same payload does not
## bring back, with the part that owns each, the file, and the reason. Both
## round-trip suites assert against this and print everything they saw, so it can
## only shrink by being fixed. None of these is in a folder the save layer may
## write in.
const GAPS: Dictionary[String, String] = {
	"$.systems.society.forces":
		"[P06] game/sim/society/society_system.gd — deserialize() rebuilds the "
		+ "standing forces from the restored world instead of reading them back, "
		+ "and _sample() polls the council AFTER rebuilding them. So a recompute "
		+ "at load time sees one sample more of council state than the save did, "
		+ "and four grievance forces stand that were not standing. Fix: give "
		+ "SocietyPressures the inverse of its serialize() (the five parallel "
		+ "arrays plus the ceiling) and call it.",
	"$.systems.threat.plan.vectors[].cells":
		"[P08] game/sim/threat/threat_vector.gd — to_dict() writes `path.size()` "
		+ "and never `path`, so the approach corridor the night was planned "
		+ "around is not in the file at all and the siege model resumes down a "
		+ "lane of length zero. Fix: write `path` in to_dict(), read it in "
		+ "from_dict().",
	"$.systems.narrative.pending":
		"[P22] game/narrative/narrative_system.gd:950 — deserialize() rebuilds a "
		+ "waiting card only when `by_id` knows its id, and chapter beats are "
		+ "raised from the chapter table rather than from game/content/events/**. "
		+ "Measured: `the_column_stopped` is in the save, is not among by_id's 26 "
		+ "ids, and is dropped. Every chapter beat waiting on the player dies in "
		+ "a load.",
	"$.systems.research.pacing.*":
		"[P10] game/sim/research/ — the pacing window is a rolling measurement "
		+ "over recent ticks and deserialize() does not carry it, so the reloaded "
		+ "director re-derives it from the single instant it woke up in.",
	# Cascade, and only ever downstream of the above: the citizens' average
	# morale follows society's meters, which follow the forces.
	"$.systems.citizens.totals.avg_morale": "[P05] cascade of the society gap above",
}

## Script variables of `SocietyPressures` that `serialize()` reports (directly or
## through `hope_ceiling()`) and that no `deserialize()` reads back.
const PRESSURE_VARS: Array[String] = [
	"keys", "labels", "texts", "rates", "meters",
	"grievance_pressure", "grievance_detail", "metric_values",
	"_ceiling", "_headroom",
]

## Fields of `ThreatVector` that `to_dict()` does not write. `path` is the one
## the round-trip suite can see (as `cells`); the other three are what the siege
## model walks, so a night resumed from a save would fight down a corridor of
## length zero without them.
const VECTOR_VARS: Array[String] = [
	"path", "structures", "envelope_from", "envelope_to",
]


## Lifts the unsaved state out of the live world. Call it with the world in the
## exact condition it is about to be saved in.
static func capture() -> Dictionary:
	return {"society": _capture_society(), "threat": _capture_threat()}


## Puts a [method capture] back into the live world after a load. Returns the
## paths it wrote, so a test can assert the experiment actually ran rather than
## silently doing nothing on a build where the systems are absent.
static func reinject(snap: Dictionary) -> PackedStringArray:
	var done: PackedStringArray = PackedStringArray()
	done.append_array(_restore_society(snap.get("society", {})))
	done.append_array(_restore_threat(snap.get("threat", {})))
	return done


# ------------------------------------------------------------------ society ---

static func _pressures() -> Object:
	var sys: SimSystem = Sim.get_system(&"society")
	if sys == null:
		return null
	var p: Variant = sys.get("_pressures")
	return p as Object if p is Object else null


static func _capture_society() -> Dictionary:
	var p: Object = _pressures()
	if p == null:
		return {}
	var out: Dictionary = {}
	for name: String in PRESSURE_VARS:
		var v: Variant = p.get(name)
		# duplicate(), because these are the live arrays the system keeps
		# writing to: a reference here would "restore" whatever the world
		# happened to end up with, which is a probe that always agrees.
		out[name] = v.duplicate() if (v is Array or v is Dictionary or v is PackedStringArray
			or v is PackedFloat32Array or v is PackedByteArray) else v
	return out


static func _restore_society(snap: Variant) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if typeof(snap) != TYPE_DICTIONARY or (snap as Dictionary).is_empty():
		return out
	var p: Object = _pressures()
	if p == null:
		return out
	var d: Dictionary = snap
	var names: Array = d.keys()
	names.sort()
	for name: String in names:
		var v: Variant = d[name]
		p.set(name, v.duplicate() if (v is Array or v is Dictionary or v is PackedStringArray
			or v is PackedFloat32Array or v is PackedByteArray) else v)
		out.append("$.systems.society._pressures.%s" % name)
	return out


# ------------------------------------------------------------------- threat ---

static func _vectors() -> Array:
	var sys: SimSystem = Sim.get_system(&"threat")
	if sys == null:
		return []
	var plan: Variant = sys.get("_plan")
	if not (plan is Object):
		return []
	var vs: Variant = (plan as Object).get("vectors")
	return vs as Array if vs is Array else []


static func _capture_threat() -> Dictionary:
	var out: Dictionary = {}
	for v: Object in _vectors():
		var row: Dictionary = {}
		for name: String in VECTOR_VARS:
			var val: Variant = v.get(name)
			row[name] = val.duplicate() if (val is Array or val is PackedInt32Array) else val
		out[str(int(v.get("index")))] = row
	return out


static func _restore_threat(snap: Variant) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if typeof(snap) != TYPE_DICTIONARY or (snap as Dictionary).is_empty():
		return out
	var d: Dictionary = snap
	for v: Object in _vectors():
		var key: String = str(int(v.get("index")))
		if not d.has(key):
			continue
		var row: Dictionary = d[key]
		var names: Array = row.keys()
		names.sort()
		for name: String in names:
			var val: Variant = row[name]
			v.set(name, val.duplicate() if (val is Array or val is PackedInt32Array) else val)
		out.append("$.systems.threat.plan.vectors[%s].path" % key)
	return out
