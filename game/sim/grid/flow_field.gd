class_name FlowField
extends RefCounted
## Integration + flow field over the whole map. One field serves any number of
## agents: an agent asks for the direction of the tile it stands on and moves.
## That is O(1) per agent, which is the only way 1000+ units stay affordable.
##
## Two things make this implementation fast enough to rebuild while the game runs:
##
## 1. **Dial's algorithm** instead of a binary heap. Movement costs are small
##    integers, so the priority queue is 512 intrusive linked lists indexed by
##    `cost & 511` — O(1) push, O(1) decrease-key, no allocation, no log factor.
##    Seeds outside the 512-wide window wait in a sorted list and are admitted as
##    the wavefront reaches them, so the window invariant always holds.
##
## 2. **Raise / lower repair** instead of a full rebuild. When a wall goes up we
##    invalidate only the cells whose path actually ran through it (found by
##    following the stored direction backwards), then re-flood from the border of
##    that shadow. Placing a turret costs a few hundred cells, not 65 000.
##
## The map's outer ring is impassable by contract (see [WorldGrid]), so the inner
## loop never needs a bounds check.

const UNREACHABLE: int = 0x3FFFFFFF
const DIR_NONE: int = 8
const BUCKETS: int = 512
const BUCKET_MASK: int = 511
const IDX_BITS: int = 24
const IDX_MASK: int = (1 << 24) - 1
const MAX_CELLS: int = 1 << 24
const W_ORTHO: int = 10
const W_DIAG: int = 14
const IMP: int = 255
## Cells the raise/lower repair may invalidate before it gives up and re-floods
## from scratch instead. Raising costs about what flooding costs per cell, and a
## repair that raises most of the map has already spent a full rebuild without
## having produced one. Measured: repairs beyond this were the 20-42 ms ticks in
## a stress run, all of them during heavy construction.
const RAISE_LIMIT: int = 3000

var field_name: StringName = &"default"
var width: int = 0
var height: int = 0

## Accumulated movement cost from each cell to the nearest goal.
var integration: PackedInt32Array = PackedInt32Array()
## Index into Grid.DIRS8 pointing one step toward the goal, or DIR_NONE.
var direction: PackedByteArray = PackedByteArray()
## Flat indices the field flows toward.
var goals: PackedInt32Array = PackedInt32Array()

# --- last-run stats, for metrics only ---
var last_visited: int = 0
var last_was_full: bool = false
var rebuilds_full: int = 0
var rebuilds_partial: int = 0

var _size: int = 0
var _off: PackedInt32Array = PackedInt32Array()
var _head: PackedInt32Array = PackedInt32Array()
var _next: PackedInt32Array = PackedInt32Array()
var _prev: PackedInt32Array = PackedInt32Array()
var _qkey: PackedInt32Array = PackedInt32Array()
var _pending: int = 0
var _cur: int = 0
var _seeds: PackedInt64Array = PackedInt64Array()
## How far into _seeds lazy admission got. Non-zero only while a budgeted flood
## is suspended between ticks.
var _seed_at: int = 0
var _resuming: bool = false

## True when the last flood hit its cell budget and left a wavefront on the
## queue. The field is USABLE in this state: correct everywhere the wave has
## already passed, stale behind it, and it converges to the exact unbudgeted
## answer once resume() finishes. That is what lets a 75 ms reflood be paid over
## several ticks instead of as one dropped frame.
var unfinished: bool = false

## While a BUDGETED full rebuild is in flight the live arrays are being wiped and
## re-flooded from nothing, so every query would see DIR_NONE and every agent on
## the map would stop walking for a third of a second. These hold the previous,
## complete field and every query reads them instead until the new one lands.
## Costs 320 KB and buys "the pathing never blinks".
var _shadow_integration: PackedInt32Array = PackedInt32Array()
var _shadow_direction: PackedByteArray = PackedByteArray()
var _shadowed: bool = false


func setup(w: int, h: int, name: StringName = &"default") -> bool:
	field_name = name
	width = w
	height = h
	_size = w * h
	if _size <= 0 or _size >= MAX_CELLS:
		Log.error("grid", "flow field '%s' size %d out of range" % [name, _size])
		return false
	integration = PackedInt32Array()
	integration.resize(_size)
	integration.fill(UNREACHABLE)
	direction = PackedByteArray()
	direction.resize(_size)
	direction.fill(DIR_NONE)
	# E, SE, S, SW, W, NW, N, NE in flat-index space.
	_off = PackedInt32Array([1, 1 + w, w, -1 + w, -1, -1 - w, -w, 1 - w])
	_head = PackedInt32Array()
	_head.resize(BUCKETS)
	_head.fill(-1)
	_next = PackedInt32Array()
	_next.resize(_size)
	_prev = PackedInt32Array()
	_prev.resize(_size)
	_qkey = PackedInt32Array()
	_qkey.resize(_size)
	_qkey.fill(-1)
	_pending = 0
	return true


## Replaces the goal set. Caller must follow with rebuild().
func set_goals(g: PackedInt32Array) -> void:
	goals = g


# ---------------------------------------------------------------- queries

## The field a query should read: the shadow while a budgeted full rebuild is
## still filling the live one in.
func _read_direction() -> PackedByteArray:
	return _shadow_direction if _shadowed else direction


func _read_integration() -> PackedInt32Array:
	return _shadow_integration if _shadowed else integration


func direction_at(idx: int) -> int:
	return _read_direction()[idx] if idx >= 0 and idx < _size else DIR_NONE


## One step toward the goal from a flat index; ZERO at the goal or in dead space.
func step_at(idx: int) -> Vector2i:
	if idx < 0 or idx >= _size:
		return Grid.ZERO
	var d: int = _read_direction()[idx]
	return Grid.ZERO if d >= 8 else Grid.DIRS8[d]


func integration_at(idx: int) -> int:
	return _read_integration()[idx] if idx >= 0 and idx < _size else UNREACHABLE


func reachable(idx: int) -> bool:
	return idx >= 0 and idx < _size and _read_integration()[idx] != UNREACHABLE


## Smoothly blended flow at a world position: bilinear over the four nearest
## tile directions, so 1000 agents on one field do not walk in lockstep along
## eight fixed angles.
func steer(world_pos: Vector2) -> Vector2:
	var fx: float = world_pos.x / Grid.TILE_SIZE_F - 0.5
	var fy: float = world_pos.y / Grid.TILE_SIZE_F - 0.5
	var x0: int = floori(fx)
	var y0: int = floori(fy)
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	var acc: Vector2 = Vector2.ZERO
	var dirs: PackedByteArray = _read_direction()
	for j: int in range(2):
		for i: int in range(2):
			var x: int = x0 + i
			var y: int = y0 + j
			if x < 0 or y < 0 or x >= width or y >= height:
				continue
			var d: int = dirs[y * width + x]
			if d >= 8:
				continue
			var wgt: float = (tx if i == 1 else 1.0 - tx) * (ty if j == 1 else 1.0 - ty)
			var v: Vector2i = Grid.DIRS8[d]
			acc += Vector2(float(v.x), float(v.y)).normalized() * wgt
	return acc if acc.length_squared() < 0.000001 else acc.normalized()


# ---------------------------------------------------------------- building

## Full flood from the goals. O(width*height) — world creation, load, goal change.
## `budget` caps the cells settled in this call; 0 means "finish it now". When a
## budget is hit the call returns with `unfinished` true and the caller resumes
## it on a later tick.
func rebuild(cost: PackedByteArray, budget: int = 0) -> void:
	if _size == 0:
		return
	if budget > 0 and rebuilds_full > 0 and not _shadowed:
		# About to wipe a field agents are standing on. Keep the old one to
		# answer queries from until the new flood has covered the map.
		_shadow_integration = integration.duplicate()
		_shadow_direction = direction.duplicate()
		_shadowed = true
	integration.fill(UNREACHABLE)
	direction.fill(DIR_NONE)
	_reset_queue()
	_seeds = PackedInt64Array()
	for g: int in goals:
		if g < 0 or g >= _size or cost[g] == IMP:
			continue
		integration[g] = 0
		_seeds.append(g)
	last_was_full = true
	rebuilds_full += 1
	_run(cost, budget)


## Repairs the field after `changed` cells took a new cost. Touches only the
## affected shadow, so a building placement is orders of magnitude cheaper than
## a full rebuild.
func update(cost: PackedByteArray, changed: PackedInt32Array, budget: int = 0) -> void:
	if _size == 0 or changed.is_empty():
		return
	var lower: PackedInt32Array = PackedInt32Array()
	var raise_q: PackedInt32Array = PackedInt32Array()

	for idx: int in changed:
		if _on_border(idx):
			continue
		if integration[idx] != UNREACHABLE:
			raise_q.append(idx)
		else:
			# Cell may have just opened up: let its valued neighbours flood in.
			for d: int in range(8):
				var n: int = idx + _off[d]
				if n >= 0 and n < _size and integration[n] != UNREACHABLE:
					lower.append(n)
		if cost[idx] != IMP:
			continue
		# A new wall also invalidates every DIAGONAL step that used to squeeze past
		# the corner it now occupies. Those cells still point at a perfectly valid
		# neighbour, so the back-pointer test below never sees them — without this
		# the repaired field keeps a step the full rebuild forbids (and understates
		# the cost of everything behind it).
		for d2: int in range(8):
			var m: int = idx + _off[d2]
			if m < 0 or m >= _size or integration[m] == UNREACHABLE:
				continue
			var dm: int = direction[m]
			if dm >= 8 or (dm & 1) == 0:
				continue
			if m + _off[(dm + 1) & 7] == idx or m + _off[(dm + 7) & 7] == idx:
				raise_q.append(m)

	var head: int = 0
	while head < raise_q.size():
		if budget > 0 and head > RAISE_LIMIT:
			# The shadow this change casts is bigger than a whole fresh flood.
			# Invalidating it is NOT budgetable — a half-invalidated field keeps
			# stale-low integrations the following flood will refuse to improve,
			# which is silently wrong rather than merely slow. So stop, throw the
			# repair away and start a full flood, which IS budgetable and which
			# the shadow buffer keeps invisible to anything walking on it.
			rebuild(cost, budget)
			return
		var c: int = raise_q[head]
		head += 1
		if integration[c] == UNREACHABLE:
			continue
		integration[c] = UNREACHABLE
		direction[c] = DIR_NONE
		for d: int in range(8):
			var n: int = c + _off[d]
			if n < 0 or n >= _size or integration[n] == UNREACHABLE:
				continue
			# n's path ran through c exactly when its stored step points back at c.
			if direction[n] == ((d + 4) & 7):
				raise_q.append(n)
			else:
				lower.append(n)

	_seeds = PackedInt64Array()
	for idx: int in lower:
		if integration[idx] != UNREACHABLE and cost[idx] != IMP:
			_seeds.append((integration[idx] << IDX_BITS) | idx)
	for g: int in goals:
		if g < 0 or g >= _size or cost[g] == IMP:
			continue
		if integration[g] != 0:
			integration[g] = 0
			direction[g] = DIR_NONE
		_seeds.append(g)

	last_was_full = false
	rebuilds_partial += 1
	_run(cost, budget)


## Continues a flood that ran out of budget. Returns true while there is still
## work left, so a caller can keep asking once a tick until it is done.
func resume(cost: PackedByteArray, budget: int = 0) -> bool:
	if not unfinished:
		return false
	_resuming = true
	_run(cost, budget)
	return unfinished


# ---------------------------------------------------------------- internals

func _on_border(idx: int) -> bool:
	if idx < width or idx >= _size - width:
		return true
	var x: int = idx % width
	return x == 0 or x == width - 1


func _reset_queue() -> void:
	_head.fill(-1)
	_qkey.fill(-1)
	_pending = 0
	_cur = 0
	_seed_at = 0
	_resuming = false
	unfinished = false


## Dijkstra over the bucket queue. Seeds are admitted lazily in cost order so the
## 512-bucket window is never violated, no matter how far apart the seeds are.
func _run(cost: PackedByteArray, budget: int = 0) -> void:
	if _pending != 0 and not _resuming:
		# A previous run was cut short and nobody resumed it; the intrusive lists
		# describe a wavefront that is not going to be finished.
		_reset_queue()
	var resuming: bool = _resuming
	_resuming = false
	var n_seeds: int = _seeds.size()
	if n_seeds == 0 and _pending == 0:
		last_visited = 0
		unfinished = false
		return
	if n_seeds > 1 and not resuming:
		_seeds.sort()
	var sp: int = _seed_at if resuming else 0
	if not resuming:
		_cur = _seeds[0] >> IDX_BITS if n_seeds > 0 else 0
	var visited: int = 0
	unfinished = false

	while true:
		while sp < n_seeds:
			var enc: int = _seeds[sp]
			var k: int = enc >> IDX_BITS
			if k >= _cur + BUCKETS:
				break
			sp += 1
			var si: int = enc & IDX_MASK
			if integration[si] == k and cost[si] != IMP:
				_push(si, k)
		if _pending <= 0:
			if sp >= n_seeds:
				break
			_cur = _seeds[sp] >> IDX_BITS
			continue
		var scanned: int = 0
		while _head[_cur & BUCKET_MASK] == -1 and scanned < BUCKETS:
			_cur += 1
			scanned += 1
		if _head[_cur & BUCKET_MASK] == -1:
			Log.error("grid", "flow field '%s' queue desync at %d" % [field_name, _cur])
			_reset_queue()
			break
		visited += _drain(cost)
		if budget > 0 and visited >= budget:
			unfinished = true
			break

	_seed_at = sp
	if not unfinished:
		_seeds = PackedInt64Array()
		_seed_at = 0
		if _shadowed:
			_shadowed = false
			_shadow_integration = PackedInt32Array()
			_shadow_direction = PackedByteArray()
	last_visited = visited


func _push(idx: int, key: int) -> void:
	if _qkey[idx] >= 0:
		var ob: int = _qkey[idx] & BUCKET_MASK
		var p: int = _prev[idx]
		var q: int = _next[idx]
		if p != -1:
			_next[p] = q
		else:
			_head[ob] = q
		if q != -1:
			_prev[q] = p
		_pending -= 1
	var b: int = key & BUCKET_MASK
	var h: int = _head[b]
	_next[idx] = h
	_prev[idx] = -1
	if h != -1:
		_prev[h] = idx
	_head[b] = idx
	_qkey[idx] = key
	_pending += 1


## Empties the bucket at _cur, relaxing every cell in it. This is THE hot loop of
## the whole part: pushes and neighbour walks are hand-inlined on purpose, since
## a GDScript call per relaxation costs more than the relaxation itself.
func _drain(cost: PackedByteArray) -> int:
	var b: int = _cur & BUCKET_MASK
	var key: int = _cur
	var visited: int = 0
	var c: int = _head[b]
	while c != -1:
		var nx: int = _next[c]
		_head[b] = nx
		if nx != -1:
			_prev[nx] = -1
		_qkey[c] = -1
		_pending -= 1
		if integration[c] != key:
			c = _head[b]
			continue
		visited += 1
		for d: int in range(8):
			var nidx: int = c + _off[d]
			var cn: int = cost[nidx]
			if cn == IMP:
				continue
			var diag: bool = (d & 1) == 1
			if diag:
				# no cutting the corner of a wall
				if cost[c + _off[(d + 1) & 7]] == IMP:
					continue
				if cost[c + _off[(d - 1) & 7]] == IMP:
					continue
			var nk: int = key + cn * (W_DIAG if diag else W_ORTHO)
			if nk >= integration[nidx]:
				continue
			integration[nidx] = nk
			direction[nidx] = (d + 4) & 7
			# --- inlined _push(nidx, nk) ---
			var qk: int = _qkey[nidx]
			if qk >= 0:
				var ob: int = qk & BUCKET_MASK
				var p: int = _prev[nidx]
				var q: int = _next[nidx]
				if p != -1:
					_next[p] = q
				else:
					_head[ob] = q
				if q != -1:
					_prev[q] = p
				_pending -= 1
			var nb: int = nk & BUCKET_MASK
			var nh: int = _head[nb]
			_next[nidx] = nh
			_prev[nidx] = -1
			if nh != -1:
				_prev[nh] = nidx
			_head[nb] = nidx
			_qkey[nidx] = nk
			_pending += 1
		c = _head[b]
	return visited
