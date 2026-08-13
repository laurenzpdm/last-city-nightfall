class_name LogiLane
extends RefCounted
## One lane of one transport line. This is the data structure the whole
## automation half of the game stands on, so it is worth stating what it is.
##
## AN ITEM IS NOT AN OBJECT. A lane stores two things:
##
##   * `_kinds` — the item kinds in order, front (nearest the exit) first. One
##     int per item, in a flat PackedInt32Array with a moving head index, so
##     ten thousand items cost forty kilobytes and no allocations.
##   * `_g_head` / `_g_cnt` — the GROUPS. A group is a maximal run of items that
##     are compressed against each other, described by the position of its
##     leading item and how many items follow it at exactly SPACING intervals.
##
## Positions are implicit: item k of group g sits at `_g_head[g] + k * SPACING`
## tiles from the exit. That is what makes the per-tick cost O(groups) rather
## than O(items) — a saturated belt is ONE group no matter how many items are on
## it, and moving it is a single subtraction. This is Factorio's transport-line
## trick and it is the difference between a factory and a slideshow.
##
## Invariants, maintained by every mutator and checked by `debug_invariants()`:
##   1. groups are ordered by position, `_g_head[i] > _g_head[i-1]`
##   2. consecutive groups are strictly more than SPACING apart, or they would
##      be one group — `_g_head[i] - tail(i-1) > SPACING`
##   3. every position lies in [0, length]
##   4. `sum(_g_cnt) == size()`

const EPS: float = LogiTypes.EPS

## Tiles the lane spans. Position 0 is the exit, `length` is the entrance.
var length: float = 1.0
## Tiles between the centres of two compressed items.
var spacing: float = LogiTypes.SPACING

## Item kinds, front first. Valid entries are [_head, _kinds.size()).
var _kinds: PackedInt32Array = PackedInt32Array()
var _head: int = 0
## Leading item position of each group, ascending (front group first).
var _g_head: PackedFloat32Array = PackedFloat32Array()
## Items in each group.
var _g_cnt: PackedInt32Array = PackedInt32Array()
## Movement budget the front group has left this tick, so a lane can hand over
## more than one item per tick without cheating on distance.
var _slack_left: float = 0.0


func _init(lane_length: float = 1.0, item_spacing: float = LogiTypes.SPACING) -> void:
	length = maxf(item_spacing, lane_length)
	spacing = item_spacing


# =========================================================================
# reading
# =========================================================================

func size() -> int:
	return _kinds.size() - _head


func is_empty() -> bool:
	return _kinds.size() == _head


## Most items this lane can hold when fully compressed.
func capacity() -> int:
	return int(floorf(length / spacing + EPS)) + 1


## 0..1 — how full the lane is against its compressed capacity.
func saturation() -> float:
	var c: int = capacity()
	return 0.0 if c <= 0 else clampf(float(size()) / float(c), 0.0, 1.0)


## Kind of the item closest to the exit, or -1.
func front_kind() -> int:
	return -1 if is_empty() else _kinds[_head]


## Distance from the exit of the item closest to it. INF when the lane is empty.
func front_pos() -> float:
	return INF if _g_head.is_empty() else _g_head[0]


## True when the front item has reached the exit and may be handed on.
func front_ready() -> bool:
	return not _g_head.is_empty() and _g_head[0] <= EPS


func group_count() -> int:
	return _g_cnt.size()


## Items whose centres fall inside [lo, hi] tiles from the exit. O(groups).
func count_in_span(lo: float, hi: float) -> int:
	var n: int = 0
	for g: int in _g_head.size():
		var head: float = _g_head[g]
		var cnt: int = _g_cnt[g]
		var tail: float = head + float(cnt - 1) * spacing
		if tail < lo - EPS or head > hi + EPS:
			continue
		var first: int = maxi(0, int(ceilf((lo - head) / spacing - EPS)))
		var last: int = mini(cnt - 1, int(floorf((hi - head) / spacing + EPS)))
		if last >= first:
			n += last - first + 1
	return n


## Index of the first item inside [lo, hi] whose kind passes `wanted`
## (-1 for any), searching from the front. -1 when there is none.
func find_in_span(lo: float, hi: float, wanted: int = -1) -> int:
	var idx: int = 0
	for g: int in _g_head.size():
		var head: float = _g_head[g]
		var cnt: int = _g_cnt[g]
		for k: int in cnt:
			var p: float = head + float(k) * spacing
			if p >= lo - EPS and p <= hi + EPS:
				if wanted < 0 or _kinds[_head + idx + k] == wanted:
					return idx + k
			elif p > hi + EPS:
				return -1
		idx += cnt
	return -1


## Kind of the item at `index` counted from the front, or -1.
func kind_at(index: int) -> int:
	if index < 0 or index >= size():
		return -1
	return _kinds[_head + index]


## Position of the item at `index` counted from the front, or -1.
func pos_at(index: int) -> float:
	if index < 0 or index >= size():
		return -1.0
	var seen: int = 0
	for g: int in _g_head.size():
		var cnt: int = _g_cnt[g]
		if index < seen + cnt:
			return _g_head[g] + float(index - seen) * spacing
		seen += cnt
	return -1.0


## Every item as [kind, position]. Only for the view layer and for saves —
## this is the one call that is O(items) on purpose.
func snapshot() -> Array:
	var out: Array = []
	var idx: int = 0
	for g: int in _g_head.size():
		var head: float = _g_head[g]
		for k: int in _g_cnt[g]:
			out.append([_kinds[_head + idx + k], snappedf(head + float(k) * spacing, 0.0001)])
		idx += _g_cnt[g]
	return out


## Total of each kind on the lane, as kind index -> count.
func tally(into: Dictionary[int, int]) -> void:
	var idx: int = 0
	for g: int in _g_head.size():
		for k: int in _g_cnt[g]:
			var kind: int = _kinds[_head + idx + k]
			into[kind] = int(into.get(kind, 0)) + 1
		idx += _g_cnt[g]


# =========================================================================
# movement
# =========================================================================

## Advances everything by at most `slack` tiles and merges whatever caught up.
## O(groups): a compressed belt is one subtraction regardless of item count.
func advance(slack: float) -> void:
	if _g_head.is_empty():
		_slack_left = 0.0
		return
	var m0: float = minf(slack, _g_head[0])
	_g_head[0] = _g_head[0] - m0
	# What the front group did not use is kept: if it hands items off this tick
	# the ones behind it may still travel the rest of their budget.
	_slack_left = slack - m0

	var i: int = 1
	while i < _g_head.size():
		var prev_tail: float = _g_head[i - 1] + float(_g_cnt[i - 1] - 1) * spacing
		var gap: float = _g_head[i] - prev_tail - spacing
		if gap > 0.0:
			_g_head[i] = _g_head[i] - minf(slack, gap)
		if _g_head[i] - prev_tail <= spacing + EPS:
			_g_head[i] = prev_tail + spacing
			_g_cnt[i - 1] = _g_cnt[i - 1] + _g_cnt[i]
			_g_head.remove_at(i)
			_g_cnt.remove_at(i)
		else:
			i += 1


## Removes the item at the exit and lets the rest of its group spend whatever
## movement budget is left, so a fast belt can pass several items in one tick.
## Only call it when front_ready() is true.
func take_front() -> int:
	if is_empty():
		return -1
	var kind: int = _kinds[_head]
	_head += 1
	_g_cnt[0] = _g_cnt[0] - 1
	if _g_cnt[0] <= 0:
		_g_head.remove_at(0)
		_g_cnt.remove_at(0)
	else:
		_g_head[0] = _g_head[0] + spacing
	_compact()
	if not _g_head.is_empty():
		var m: float = minf(_slack_left, _g_head[0])
		_g_head[0] = _g_head[0] - m
		_slack_left -= m
	return kind


# =========================================================================
# insertion
# =========================================================================

## Puts an item on the back of the lane. `slack` is how far the lane moved this
## tick: an item can only enter through the stretch of belt that actually passed
## the entrance, which is what stops an empty belt from swallowing a burst and
## what lets a saturated belt accept 1.125 items per tick at mk3.
## Returns false when there is no room.
func insert_back(kind: int, slack: float) -> bool:
	var pos: float = length
	if not _g_head.is_empty():
		var last: int = _g_head.size() - 1
		var tail: float = _g_head[last] + float(_g_cnt[last] - 1) * spacing
		pos = maxf(tail + spacing, length - maxf(slack, 0.0))
		if pos > length + EPS:
			return false
		if pos < tail + spacing - EPS:
			return false
	_kinds.append(kind)
	if not _g_head.is_empty():
		var last2: int = _g_head.size() - 1
		var tail2: float = _g_head[last2] + float(_g_cnt[last2] - 1) * spacing
		if pos - tail2 <= spacing + EPS:
			_g_cnt[last2] = _g_cnt[last2] + 1
			return true
	_g_head.append(pos)
	_g_cnt.append(1)
	return true


## Drops an item onto the lane at `pos` tiles from the exit — a side-load from
## another belt, or an arm putting something down mid-line. Refuses when it
## would land within SPACING of an item that is already there.
func insert_at(kind: int, pos: float) -> bool:
	var p: float = clampf(pos, 0.0, length)
	var idx: int = 0
	var slot: int = _g_head.size()
	for g: int in _g_head.size():
		var head: float = _g_head[g]
		var cnt: int = _g_cnt[g]
		var tail: float = head + float(cnt - 1) * spacing
		if tail <= p - spacing + EPS:
			idx += cnt
			continue
		if head >= p + spacing - EPS:
			slot = g
			break
		return false
	_kinds.insert(_head + idx, kind)
	_g_head.insert(slot, p)
	_g_cnt.insert(slot, 1)
	_coalesce(maxi(0, slot - 1))
	return true


## Lifts the item at `index` (counted from the front) off the lane.
## Returns its kind, or -1. Splits its group when it came out of the middle.
func remove_at(index: int) -> int:
	if index < 0 or index >= size():
		return -1
	var seen: int = 0
	for g: int in _g_head.size():
		var cnt: int = _g_cnt[g]
		if index < seen + cnt:
			var off: int = index - seen
			var kind: int = _kinds[_head + index]
			_kinds.remove_at(_head + index)
			if cnt == 1:
				_g_head.remove_at(g)
				_g_cnt.remove_at(g)
			elif off == 0:
				_g_head[g] = _g_head[g] + spacing
				_g_cnt[g] = cnt - 1
			elif off == cnt - 1:
				_g_cnt[g] = cnt - 1
			else:
				var head: float = _g_head[g]
				_g_cnt[g] = off
				_g_head.insert(g + 1, head + float(off + 1) * spacing)
				_g_cnt.insert(g + 1, cnt - off - 1)
			return kind
		seen += cnt
	return -1


func clear() -> void:
	_kinds = PackedInt32Array()
	_head = 0
	_g_head = PackedFloat32Array()
	_g_cnt = PackedInt32Array()
	_slack_left = 0.0


# =========================================================================
# internals
# =========================================================================

## Merges groups from `from` onward that ended up compressed against each other.
func _coalesce(from: int) -> void:
	var i: int = maxi(1, from + 1)
	while i < _g_head.size():
		var prev_tail: float = _g_head[i - 1] + float(_g_cnt[i - 1] - 1) * spacing
		if _g_head[i] - prev_tail <= spacing + EPS:
			_g_head[i] = prev_tail + spacing
			_g_cnt[i - 1] = _g_cnt[i - 1] + _g_cnt[i]
			_g_head.remove_at(i)
			_g_cnt.remove_at(i)
		else:
			i += 1


## Amortised O(1): the head index only walks forward, and the array is rebuilt
## once the dead prefix is as long as the live part.
func _compact() -> void:
	if _head < 32 or _head < _kinds.size() - _head:
		return
	_kinds = _kinds.slice(_head)
	_head = 0


## Every invariant this class promises, as human-readable violations.
## Tests call it; nothing in the tick loop does.
func debug_invariants() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var total: int = 0
	for g: int in _g_head.size():
		if _g_cnt[g] <= 0:
			out.append("group %d is empty" % g)
		total += _g_cnt[g]
		var head: float = _g_head[g]
		var tail: float = head + float(_g_cnt[g] - 1) * spacing
		if head < -EPS or tail > length + EPS:
			out.append("group %d spans %.4f..%.4f outside 0..%.4f" % [g, head, tail, length])
		if g > 0:
			var prev_tail: float = _g_head[g - 1] + float(_g_cnt[g - 1] - 1) * spacing
			if head - prev_tail <= spacing + EPS:
				out.append("groups %d and %d are touching and should be one" % [g - 1, g])
	if total != size():
		out.append("group counts total %d but the lane holds %d" % [total, size()])
	return out
