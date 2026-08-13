class_name ThreatVector
extends RefCounted
## One approach the dark can use tonight: a road in off the plain, the narrow
## place on it, how well the player has fortified it, and what share of the
## night's budget is coming down it.
##
## Vectors are derived from [P01]'s approach lanes, which are carved by the map
## generator out of the terrain itself. That is why a defence line pays off
## exactly where the ground says it should — the director is reading the same
## chokepoints the player can see.

## Role this vector plays tonight.
const ROLE_MAIN: StringName = &"main"       ## the obvious road, always telegraphed first
const ROLE_PROBE: StringName = &"probe"     ## aimed at the weakest side on purpose
const ROLE_FLANK: StringName = &"flank"     ## everything else

## Position in the plan's vector array. Stable for the life of the plan.
var index: int = 0
## Index into GridSystem.approach_lanes(), or -1 for a synthesised vector.
var lane: int = -1
var role: StringName = ROLE_FLANK

## Where they come onto the map.
var entry_cell: Vector2i = Vector2i.ZERO
## The narrow place on the way in. Equals entry_cell when the lane has none.
var choke_cell: Vector2i = Vector2i.ZERO
## 0..7, see ThreatDefs.compass_sector. Measured core -> entry, so it is the
## direction the player looks in, not the direction the enemy walks.
var sector: int = 0

## Flat cell indices from near the core (0) out to the entry (size - 1).
## The siege model walks this backwards; combat can hand it straight to a unit.
var path: PackedInt32Array = PackedInt32Array()
## Index into `path` at which the defended envelope begins, walking inward.
var envelope_from: int = 0
var envelope_to: int = 0

## Fraction of tonight's budget arriving here. Shares over a plan sum to 1.
var share: float = 0.0
## 0..1 reading of how fortified this approach is. 0 is an open road.
var defence: float = 0.0
## Raw numbers behind that reading, and what the siege model needs.
var defence_dps: float = 0.0
var barrier_hp: float = 0.0
var turrets: int = 0
var walls: int = 0
## Building ids sitting in the corridor, ascending. The siege model chews these.
var structures: PackedInt32Array = PackedInt32Array()

## Travel cost from the entry to the core, in the flow field's tenths of a tile.
## Lower means a faster road in — that is what makes one lane "the main road".
var travel: int = 0


func compass() -> StringName:
	return ThreatDefs.compass_name(sector)


func label() -> String:
	return ThreatDefs.compass_label(sector)


func short_label() -> String:
	return ThreatDefs.compass_short(sector)


## Cells from the entry to the core along the lane. What the warning quotes.
func length_cells() -> int:
	return path.size()


## JSON-safe. Used by the preview, the save and the harness dump.
func to_dict() -> Dictionary:
	return {
		"index": index,
		"lane": lane,
		"role": String(role),
		"sector": sector,
		"compass": String(compass()),
		"entry": [entry_cell.x, entry_cell.y],
		"choke": [choke_cell.x, choke_cell.y],
		"share": snappedf(share, 0.001),
		"defence": snappedf(defence, 0.001),
		"defence_dps": snappedf(defence_dps, 0.01),
		"barrier_hp": snappedf(barrier_hp, 0.1),
		"turrets": turrets,
		"walls": walls,
		"travel": travel,
		"cells": path.size(),
	}


## What the player is allowed to see at a given telegraph precision. At
## precision 0 the direction is deliberately vague; the exact gate is only
## named once there is barely time left to move anything.
func to_preview(precision: int) -> Dictionary:
	var out: Dictionary = {
		"index": index,
		"compass": String(compass()),
		"label": label(),
		"role": String(role),
	}
	if precision >= 1:
		out["entry"] = [entry_cell.x, entry_cell.y]
		out["share"] = snappedf(share, 0.01)
	if precision >= 2:
		out["choke"] = [choke_cell.x, choke_cell.y]
		out["defence"] = snappedf(defence, 0.01)
		out["turrets"] = turrets
	return out


static func from_dict(d: Dictionary) -> ThreatVector:
	var v := ThreatVector.new()
	v.index = int(d.get("index", 0))
	v.lane = int(d.get("lane", -1))
	v.role = StringName(String(d.get("role", ROLE_FLANK)))
	v.entry_cell = _cell(d.get("entry", []))
	v.choke_cell = _cell(d.get("choke", []))
	v.sector = int(d.get("sector", 0))
	v.share = float(d.get("share", 0.0))
	v.defence = float(d.get("defence", 0.0))
	v.defence_dps = float(d.get("defence_dps", 0.0))
	v.barrier_hp = float(d.get("barrier_hp", 0.0))
	v.turrets = int(d.get("turrets", 0))
	v.walls = int(d.get("walls", 0))
	v.travel = int(d.get("travel", 0))
	return v


static func _cell(v: Variant) -> Vector2i:
	if typeof(v) == TYPE_ARRAY:
		var a: Array = v
		if a.size() >= 2:
			return Vector2i(int(a[0]), int(a[1]))
	return Vector2i.ZERO
