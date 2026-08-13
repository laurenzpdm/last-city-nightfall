class_name ResearchProgress
extends RefCounted
## Work done and materials already paid on one node.
##
## A record survives being set aside: park a half-finished project because the
## copper ran out, come back on day six, and the insight and the plate you
## already spent are still there. Nothing in this game punishes a player for
## reacting to the night in front of them.

## Node this belongs to.
var id: StringName = &""
## Insight points accumulated, 0 .. node.work.
var points: float = 0.0
## Materials already handed over, item id -> amount.
var paid: Dictionary[StringName, int] = {}
## Instalments settled so far, 0 .. ResearchProgress.STAGES.
var stage: int = 0
## Absolute tick the node was first started. -1 while untouched.
var started_tick: int = -1
## Consecutive ticks the node has been unable to buy its next instalment.
var stalled_ticks: int = 0
## What it is short of while stalled, item id -> amount. Empty when running.
var missing: Dictionary[StringName, int] = {}
## How often the player (or the auto-picker) has come back to it.
var resumes: int = 0

## Instalments a node is paid in. Four is enough that a shortage is felt part
## way through instead of only at the start, and few enough that the ledger is
## not touched every tick.
const STAGES: int = 4


func _init(node_id: StringName = &"") -> void:
	id = node_id


## Fraction of the work done, 0..1.
func fraction(work: int) -> float:
	if work <= 0:
		return 1.0
	return clampf(points / float(work), 0.0, 1.0)


## The instalment boundary `stage` corresponds to. Stage 0 is due immediately —
## committing to a project costs something before it produces anything.
static func stage_fraction(s: int) -> float:
	return clampf(float(s) / float(STAGES), 0.0, 1.0)


func is_stalled() -> bool:
	return not missing.is_empty()


func clear_stall() -> void:
	if not missing.is_empty():
		missing.clear()
	stalled_ticks = 0


## Everything paid so far, as a plain JSON-safe dictionary.
func paid_json() -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = paid.keys()
	keys.sort()
	for k: StringName in keys:
		out[String(k)] = int(paid[k])
	return out


func missing_json() -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = missing.keys()
	keys.sort()
	for k: StringName in keys:
		out[String(k)] = int(missing[k])
	return out


func to_dict() -> Dictionary:
	return {
		"id": String(id),
		"points": snappedf(points, 0.001),
		"paid": paid_json(),
		"stage": stage,
		"started_tick": started_tick,
		"stalled_ticks": stalled_ticks,
		"missing": missing_json(),
		"resumes": resumes,
	}


static func from_dict(data: Dictionary) -> ResearchProgress:
	var p := ResearchProgress.new(StringName(String(data.get("id", ""))))
	p.points = float(data.get("points", 0.0))
	p.stage = int(data.get("stage", 0))
	p.started_tick = int(data.get("started_tick", -1))
	p.stalled_ticks = int(data.get("stalled_ticks", 0))
	p.resumes = int(data.get("resumes", 0))
	var raw: Dictionary = data.get("paid", {})
	var keys: Array = raw.keys()
	keys.sort()
	for k: Variant in keys:
		p.paid[StringName(String(k))] = int(raw[k])
	var raw_missing: Dictionary = data.get("missing", {})
	var mkeys: Array = raw_missing.keys()
	mkeys.sort()
	for k2: Variant in mkeys:
		p.missing[StringName(String(k2))] = int(raw_missing[k2])
	return p
