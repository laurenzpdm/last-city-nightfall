class_name LogiBuildLink
extends RefCounted
## [P03] The seam that makes transport buildable by a human.
##
## Belts, undergrounds, splitters, arms and chests exist twice on purpose:
##
##   game/content/logistics/<id>.tres   a LogiDef — speed, span, swing rate,
##                                      capacity. What the thing DOES.
##   game/content/buildings/<id>.tres   a BuildingDef — footprint, cost, build
##                                      time, category, tooltip. What it costs
##                                      to PUT DOWN.
##
## Same id in both folders, and that is the whole handshake: [P11] owns the
## ground, the ghost, the material cost and the construction site, so a belt is
## placed by exactly the command a player's click produces
## (`{"system": "build", "op": "place", "kind": "belt_mk1", ...}`) and appears in
## [P18]'s palette without anybody registering it anywhere. LogisticsSystem then
## adopts the finished building and gives it a transport entity.
##
## THE DRAG. This class also owns the one interaction the genre is built on.
## [P11]'s `place_line` lays an L-shaped run of belts and gives every one of them
## the SAME rotation, because a wall does not care which way it faces and a belt
## is the only thing in the build system that does. So facing is decided here,
## from the run itself, exactly the way Factorio decides it:
##
##     every belt in a dragged run faces the next belt in the run,
##     and the last one keeps going the way the drag was going.
##
## A run is the set of TRANSPORT pieces of one kind placed on one tick whose
## cells form an unbroken orthogonal chain — which is precisely what one drag
## produces, and which splits itself correctly when the drag stepped over
## something already standing there. A single click is a run of one and keeps the
## rotation the player chose with R, and so is every arm and every splitter: a
## row of dragged inserters must all face the machine they are feeding, not each
## other.
##
## Deterministic: the decision reads placement tick, kind, building id and cell
## and nothing else. No wall clock, no frame, no dictionary iteration order.

## Build id -> the facing the run decided. Survives until the building is gone,
## so a belt adopted three ticks after it was placed still faces the right way.
var facing: Dictionary[int, int] = {}

## Pieces recorded since the last resolve(), {id, kind, cell, rot, tick, transport}.
var _fresh: Array[Dictionary] = []
## Build ids already recorded, so a sweep never re-decides a settled belt.
var _noted: Dictionary[int, bool] = {}

var runs_resolved: int = 0
var pieces_oriented: int = 0
var corners_turned: int = 0


## Records a freshly placed piece. `transport` is true for belts and tunnels —
## the only things a drag re-aims. A row of inserters laid with one drag all face
## the way the player was holding R, exactly as they do in Factorio: chaining
## them along the drag would point every arm at the next arm.
func note(id: int, kind: StringName, cell: Vector2i, rot: int, tick: int,
		transport: bool = true) -> bool:
	if _noted.has(id):
		return false
	_noted[id] = true
	_fresh.append({"id": id, "kind": kind, "cell": cell, "rot": rot, "tick": tick,
		"transport": transport})
	return true


func has_pending() -> bool:
	return not _fresh.is_empty()


## Decides the facing of everything recorded since the last call and returns one
## row per piece, `[{id, rot}]`, ascending by id. Caller writes the rotation back
## onto [P11]'s instance so the build system, the renderer and the belt all agree.
func resolve() -> Array[Dictionary]:
	if _fresh.is_empty():
		return []
	# Tick first, then kind, then id: the id order inside one command is the
	# order [P11] walked the path, which is the order the cursor drew it.
	_fresh.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["tick"]) != int(b["tick"]):
			return int(a["tick"]) < int(b["tick"])
		if String(a["kind"]) != String(b["kind"]):
			return String(a["kind"]) < String(b["kind"])
		return int(a["id"]) < int(b["id"]))

	var out: Array[Dictionary] = []
	var n: int = _fresh.size()
	var i: int = 0
	while i < n:
		var j: int = i + 1
		while j < n and _continues(_fresh[j - 1], _fresh[j]):
			j += 1
		_orient_run(i, j, out)
		runs_resolved += 1
		i = j
	_fresh.clear()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["id"]) < int(b["id"]))
	return out


## True when `b` is the next tile of the same drag as `a`.
func _continues(a: Dictionary, b: Dictionary) -> bool:
	if not bool(a.get("transport", true)) or not bool(b.get("transport", true)):
		return false
	if int(a["tick"]) != int(b["tick"]) or StringName(a["kind"]) != StringName(b["kind"]):
		return false
	var step: Vector2i = (b["cell"] as Vector2i) - (a["cell"] as Vector2i)
	return LogiTypes.rot_of(step) >= 0


func _orient_run(from: int, to: int, out: Array[Dictionary]) -> void:
	var count: int = to - from
	if count <= 1:
		var solo: Dictionary = _fresh[from]
		facing[int(solo["id"])] = posmod(int(solo["rot"]), 4)
		out.append({"id": int(solo["id"]), "rot": posmod(int(solo["rot"]), 4)})
		pieces_oriented += 1
		return
	var previous: int = -1
	for k: int in range(from, to):
		var here: Dictionary = _fresh[k]
		var step: Vector2i = (_fresh[k + 1]["cell"] as Vector2i) - (here["cell"] as Vector2i) \
			if k + 1 < to else (here["cell"] as Vector2i) - (_fresh[k - 1]["cell"] as Vector2i)
		var rot: int = LogiTypes.rot_of(step)
		if rot < 0:
			rot = posmod(int(here["rot"]), 4)
		facing[int(here["id"])] = rot
		out.append({"id": int(here["id"]), "rot": rot})
		pieces_oriented += 1
		if previous >= 0 and rot != previous:
			corners_turned += 1
		previous = rot


## The facing decided for this building, or `fallback` when it was never in a run.
func facing_of(id: int, fallback: int) -> int:
	return int(facing.get(id, posmod(fallback, 4)))


## Overrides the stored facing — a player rotating a belt that is already down.
func set_facing(id: int, rot: int) -> void:
	facing[id] = posmod(rot, 4)
	_noted[id] = true


func forget(id: int) -> void:
	facing.erase(id)
	_noted.erase(id)


## Drops everything [P11] no longer has. A belt cancelled while it was still a
## ghost is never adopted and never released, so without this the two tables
## would grow by one entry per piece ever placed for the length of a session.
func prune(alive: Dictionary[int, bool]) -> int:
	var dropped: int = 0
	var known: Array = _noted.keys()
	known.sort()
	for id: int in known:
		if not alive.has(id):
			facing.erase(id)
			_noted.erase(id)
			dropped += 1
	return dropped


func clear() -> void:
	facing.clear()
	_noted.clear()
	_fresh.clear()
	runs_resolved = 0
	pieces_oriented = 0
	corners_turned = 0


## The tile a splitter's LEFT half stands on. [P11] anchors a footprint at its
## minimum corner; a splitter is anchored at the tile whose right-hand neighbour
## is the other half, and for two of the four rotations those are not the same
## cell. Getting this wrong silently mirrors every splitter facing south.
static func splitter_origin(cells: Array[Vector2i], rot: int) -> Vector2i:
	if cells.is_empty():
		return Vector2i.ZERO
	var right: Vector2i = LogiTypes.right_of(LogiTypes.dir_vec(rot))
	for c: Vector2i in cells:
		if cells.has(c + right):
			return c
	return cells[0]
