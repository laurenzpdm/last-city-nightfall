class_name BlueprintEntry
extends Resource
## One building inside a Blueprint, stored relative to the stamp's top-left corner.
##
## `span` is cached deliberately: a blueprint must be rotatable and mirrorable
## without looking a definition up, so it survives a content change that removes
## the building kind — the stamp then reports a missing kind instead of crashing.

## BuildingDef.id to stamp.
@export var kind: StringName = &""
## Minimum corner of this building's footprint, relative to the blueprint origin.
@export var offset: Vector2i = Vector2i.ZERO
## Quarter-turns clockwise this building carries inside the stamp.
@export var rot: int = 0
## Footprint size at that rotation. Cached so transforms stay Registry-free.
@export var span: Vector2i = Vector2i.ONE
## True when the definition cannot be turned. Cached at CAPTURE time, when the
## Registry is still available, because a transform must never look a definition
## up. Rotating a stamp used to swap the span of these entries anyway and the
## paste then forced rot back to 0, so a 4x3 workshop landed 4x3 inside a slot
## the stamp had reserved as 3x4 — silently overlapping its neighbours.
@export var fixed: bool = false
## Per-instance settings the stamp preserves: recipe choice, filters, priorities.
@export var meta: Dictionary = {}


## Deep copy — transforms never mutate the source blueprint.
func copy() -> BlueprintEntry:
	var e := BlueprintEntry.new()
	e.kind = kind
	e.offset = offset
	e.rot = rot
	e.span = span
	e.fixed = fixed
	e.meta = meta.duplicate(true)
	return e


## Rectangle this entry covers inside the stamp.
func rect() -> Rect2i:
	return Rect2i(offset, span)


func to_dict() -> Dictionary:
	return {
		"kind": String(kind),
		"offset": BuildTypes.cell_to_json(offset),
		"rot": rot,
		"span": BuildTypes.cell_to_json(span),
		"fixed": fixed,
		"meta": meta.duplicate(true),
	}


static func from_dict(data: Dictionary) -> BlueprintEntry:
	var e := BlueprintEntry.new()
	e.kind = StringName(String(data.get("kind", "")))
	e.offset = BuildTypes.to_cell(data.get("offset", [0, 0]))
	e.rot = int(data.get("rot", 0))
	e.span = BuildTypes.to_cell(data.get("span", [1, 1]))
	e.fixed = bool(data.get("fixed", false))
	var m: Variant = data.get("meta", {})
	e.meta = (m as Dictionary).duplicate(true) if typeof(m) == TYPE_DICTIONARY else {}
	return e
