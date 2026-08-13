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

func direction_at(idx: int) -> int:
	return direction[idx] if idx >= 0 and idx < _size else DIR_NONE


## One step toward the goal from a flat index; ZERO at the goal or in dead space.
func step_at(idx: int) -> Vector2i:
	if idx < 0 or idx >= _size:
		return Grid.ZERO
	var d: int = direction[idx]
	return Grid.ZERO if d >= 8 else Grid.DIRS8[d]


func integration_at(idx: int) -> int:
	return integration[idx] if idx >= 0 and idx < _size else UNREACHABLE


func reachable(idx: int) -> bool:
	return idx >= 0 and idx < _size and integration[idx] != UNREACHABLE


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
	for j: int in range(2):
		for i: int in range(2):
			var x: int = x0 + i
			var y: int = y0 + j
			if x < 0 or y < 0 or x >= width or y >= height:
				continue
			var d: int = direction[y * width + x]
			if d >= 8:
				continue
			var wgt: float = (tx if i == 1 else 1.0 - tx) * (ty if j == 1 else 1.0 - ty)
			var v: Vector2i = Grid.DIRS8[d]
			acc += Vector2(float(v.x), float(v.y)).normalized() * wgt
	return acc if acc.length_squared() < 0.000001 else acc.normalized()


# ---------------------------------------------------------------- building

## Full flood from the goals. O(width*height) — world creation, load, goal change.
func rebuild(cost: PackedByteArray) -> void:
	if _size == 0:
		return
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
	_run(cost)


## Repairs the field after `changed` cells took a new cost. Touches only the
## affected shadow, so a building placement is orders of magnitude cheaper than
## a full rebuild.
func update(cost: PackedByteArray, changed: PackedInt32Array) -> void:
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
	_run(cost)


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


## Dijkstra over the bucket queue. Seeds are admitted lazily in cost order so the
## 512-bucket window is never violated, no matter how far apart the seeds are.
func _run(cost: PackedByteArray) -> void:
	if _pending != 0:
		# A previous run was cut short; the intrusive lists are unusable.
		_reset_queue()
	var n_seeds: int = _seeds.size()
	if n_seeds == 0:
		last_visited = 0
		return
	if n_seeds > 1:
		_seeds.sort()
	var sp: int = 0
	_cur = _seeds[0] >> IDX_BITS
	var visited: int = 0

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
