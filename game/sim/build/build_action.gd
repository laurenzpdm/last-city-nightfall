class_name BuildAction
extends RefCounted
## One reversible construction action.
##
## The action stores everything needed to undo AND redo itself, including the
## materials that changed hands, so undo is exact rather than approximate.
## A blueprint stamp is a single GROUP holding one child per building, which is
## why pasting fifty pipes costs the player exactly one press of undo.

enum Kind {
	PLACE = 0,   ## a building was created (payload: id, kind, cell, rot)
	REMOVE = 1,  ## a building was demolished or cancelled (payload: snapshot)
	ROTATE = 2,  ## orientation changed (payload: id, from, to)
	TOGGLE = 3,  ## enabled flag changed (payload: id, from, to)
	GROUP = 4,   ## several actions the player thinks of as one
}

## Kind
var kind: int = Kind.PLACE
## Short phrase for the undo tooltip: "Place Coal Generator".
var label: String = ""
## Tick the action happened on.
var tick: int = 0
## Kind-specific data. Mutated once more when a deferred effect lands, e.g. the
## refund of a demolition that took time to finish.
var payload: Dictionary = {}
## Sub-actions, GROUP only. Undone in reverse order.
var children: Array[BuildAction] = []


static func make(action_kind: int, label_text: String, tick_value: int, data: Dictionary) -> BuildAction:
	var a := BuildAction.new()
	a.kind = action_kind
	a.label = label_text
	a.tick = tick_value
	a.payload = data
	return a


static func group(label_text: String, tick_value: int) -> BuildAction:
	var a := BuildAction.new()
	a.kind = Kind.GROUP
	a.label = label_text
	a.tick = tick_value
	return a


## Buildings this action touches, for tooltips and tests.
func affected_count() -> int:
	if kind == Kind.GROUP:
		var n: int = 0
		for c: BuildAction in children:
			n += c.affected_count()
		return n
	return 1


func to_dict() -> Dictionary:
	var kids: Array = []
	for c: BuildAction in children:
		kids.append(c.to_dict())
	return {"kind": kind, "label": label, "tick": tick, "payload": payload.duplicate(true), "children": kids}


static func from_dict(data: Dictionary) -> BuildAction:
	var a := BuildAction.new()
	a.kind = int(data.get("kind", Kind.PLACE))
	a.label = String(data.get("label", ""))
	a.tick = int(data.get("tick", 0))
	var p: Variant = data.get("payload", {})
	a.payload = _normalize((p as Dictionary).duplicate(true)) if typeof(p) == TYPE_DICTIONARY else {}
	for raw: Variant in data.get("children", []):
		if typeof(raw) == TYPE_DICTIONARY:
			a.children.append(BuildAction.from_dict(raw))
	return a


## JSON has one number type, so a loaded payload arrives with 1.0 where an int
## was written. Coercing the known fields back keeps save -> load -> save
## byte-identical, which is what the determinism replay actually compares.
static func _normalize(p: Dictionary) -> Dictionary:
	for key: String in ["id", "rot"]:
		if p.has(key):
			p[key] = int(p[key])
	for key: String in ["from", "to"]:
		if p.has(key) and typeof(p[key]) != TYPE_BOOL:
			p[key] = int(p[key])
	if p.has("cell"):
		p["cell"] = BuildTypes.cell_to_json(BuildTypes.to_cell(p["cell"]))
	if p.has("refunded"):
		p["refunded"] = BuildTypes.items_to_json(BuildTypes.to_items(p["refunded"]))
	if p.has("snapshot") and typeof(p["snapshot"]) == TYPE_DICTIONARY:
		p["snapshot"] = _normalize_snapshot(p["snapshot"])
	return p


static func _normalize_snapshot(s: Dictionary) -> Dictionary:
	for key: String in ["id", "rot", "state", "placed_tick", "completed_tick", "workers"]:
		if s.has(key):
			s[key] = int(s[key])
	for key: String in ["hp", "max_hp", "progress", "deconstruct_progress", "heat_stored"]:
		if s.has(key):
			s[key] = float(s[key])
	if s.has("cell"):
		s["cell"] = BuildTypes.cell_to_json(BuildTypes.to_cell(s["cell"]))
	if s.has("delivered"):
		s["delivered"] = BuildTypes.items_to_json(BuildTypes.to_items(s["delivered"]))
	return s
