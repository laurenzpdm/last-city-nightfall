class_name LogiWorld
extends RefCounted
## [P03] The machine. Everything that moves an item lives here: the entity
## registry, the transport-line topology, and the per-tick movement of belts,
## splitters and arms.
##
## The records (LogiEntity, LogiSegment, LogiStore) are deliberately dumb data.
## Keeping the behaviour in one class means the tick order is readable in one
## place — belts, then splitters, then arms — and that there is exactly one
## answer to "who moved this item".
##
## TICK ORDER AND WHY
##   1. belts advance and hand off. A line pushes into whatever is in front of
##      it, except a splitter, which pulls.
##   2. splitters pull from the lines that end at them and push into the lines
##      that start after them. Pulling is what makes input priority possible:
##      the splitter, not the belt, decides whose turn it is.
##   3. arms swing. They act last so that an arm sees the belt as it is at the
##      end of the tick, which is what a player sees on screen.
##
## Nothing in here reads the frame, the clock or an input. Every dictionary that
## is iterated is iterated over a sorted key list.

const EPS: float = LogiTypes.EPS
## Items one lane may hand off in a single tick. mk3 needs 1.125, so anything
## above 2 is head-room; the cap only exists so a pathological graph cannot
## spin.
const MAX_HANDOFF: int = 8
## Ticks between the sweeps that check whether [P11] built over a belt.
const OVERBUILD_CHECK_EVERY: int = 20
## Ticks an arm must have been idle before it starts polling less often.
const IDLE_POLL_AFTER: int = 20
const IDLE_POLL_EVERY: int = 4

# --------------------------------------------------------------- registry ---

var entities: Dictionary[int, LogiEntity] = {}
var stores: Dictionary[int, LogiStore] = {}
var segments: Dictionary[int, LogiSegment] = {}

## Cell -> logistics entity id.
var occ: Dictionary[Vector2i, int] = {}
## Cell -> the id of whatever owns a store there (a chest, or a [P11] building).
var store_cells: Dictionary[Vector2i, int] = {}
## Cell -> [P11] building id of a burner that takes fuel, with the item it burns.
var fuel_cells: Dictionary[Vector2i, int] = {}
var fuel_item_of: Dictionary[int, StringName] = {}
## Cell -> transport line covering it.
var seg_at: Dictionary[Vector2i, int] = {}

var entity_ids: Array[int] = []
var splitter_ids: Array[int] = []
var inserter_ids: Array[int] = []
var segment_ids: Array[int] = []

## Bumped whenever the topology changes, so cached lookups can be invalidated.
var topo_version: int = 0
var topo_dirty: bool = false

# ------------------------------------------------------------ item kinds ---

var _kind_index: Dictionary[StringName, int] = {}
var _kind_names: Array[StringName] = []

# ------------------------------------------------------------ bookkeeping ---

var _next_seg: int = 1
var _heat: SimSystem = null
var _build: SimSystem = null
var _tick: int = 0

## Items that could not be poured back onto a line after the player edited it.
var spilled: int = 0
var delivered_to_stores: int = 0
var delivered_as_fuel: float = 0.0
var items_moved: int = 0


func bind(heat: SimSystem, build: SimSystem) -> void:
	_heat = heat
	_build = build


# =========================================================================
# item kinds — belts store ints, everyone else speaks StringNames
# =========================================================================

func intern(kind: StringName) -> int:
	var known: int = int(_kind_index.get(kind, -1))
	if known >= 0:
		return known
	var idx: int = _kind_names.size()
	_kind_names.append(kind)
	_kind_index[kind] = idx
	return idx


func kind_name(index: int) -> StringName:
	return _kind_names[index] if index >= 0 and index < _kind_names.size() else &""


func kind_index(kind: StringName) -> int:
	return int(_kind_index.get(kind, -1))


# =========================================================================
# placement
# =========================================================================

## True when every cell a placement needs is free of logistics entities.
func cells_free(cells: Array[Vector2i]) -> bool:
	for c: Vector2i in cells:
		if occ.has(c):
			return false
	return true


func entity_at(cell: Vector2i) -> LogiEntity:
	var id: int = int(occ.get(cell, -1))
	return entities.get(id) if id >= 0 else null


func add_entity(e: LogiEntity) -> void:
	entities[e.id] = e
	_insert_sorted(entity_ids, e.id)
	for c: Vector2i in e.cells:
		occ[c] = e.id
	match e.role():
		LogiTypes.Role.SPLITTER:
			_insert_sorted(splitter_ids, e.id)
		LogiTypes.Role.INSERTER:
			_insert_sorted(inserter_ids, e.id)
		LogiTypes.Role.CHEST:
			stores[e.id] = e.store
			for c: Vector2i in e.cells:
				store_cells[c] = e.id
	if e.is_underground():
		_pair_underground(e)
	if e.is_transport() or e.role() == LogiTypes.Role.SPLITTER:
		topo_dirty = true


func remove_entity(id: int) -> LogiEntity:
	var e: LogiEntity = entities.get(id)
	if e == null:
		return null
	for c: Vector2i in e.cells:
		if int(occ.get(c, -1)) == id:
			occ.erase(c)
		if int(store_cells.get(c, -1)) == id:
			store_cells.erase(c)
	entities.erase(id)
	entity_ids.erase(id)
	splitter_ids.erase(id)
	inserter_ids.erase(id)
	stores.erase(id)
	if e.pair_id >= 0:
		var other: LogiEntity = entities.get(e.pair_id)
		if other != null:
			other.pair_id = -1
			other.is_entrance = true
	if e.is_transport() or e.role() == LogiTypes.Role.SPLITTER:
		topo_dirty = true
	return e


## An underground looks back along its own direction for the nearest unpaired
## mouth of the same kind facing the same way. Finding one makes this end the
## exit, exactly the way a player expects a second click to complete a tunnel.
func _pair_underground(e: LogiEntity) -> void:
	var d: Vector2i = e.direction()
	var span: int = maxi(1, e.def.max_span)
	for step: int in range(1, span + 1):
		var c: Vector2i = e.cell - d * step
		var other: LogiEntity = entity_at(c)
		if other == null:
			continue
		if not other.is_underground() or other.kind != e.kind:
			# Anything else in the way is fine: a tunnel passes under it.
			continue
		if other.rot != e.rot or other.pair_id >= 0:
			continue
		if not other.is_entrance:
			continue
		other.pair_id = e.id
		e.pair_id = other.id
		e.is_entrance = false
		return
	e.is_entrance = true
	e.pair_id = -1


# =========================================================================
# topology
# =========================================================================

## Rebuilds every transport line, pouring the items that were in flight back
## onto the new ones. Called at most once per tick, and only after an edit.
func rebuild_topology() -> void:
	var carried: Array[Dictionary] = []
	for sid: int in segment_ids:
		carried.append_array(segments[sid].drain_items())

	segments.clear()
	segment_ids.clear()
	seg_at.clear()
	_next_seg = 1
	for id: int in entity_ids:
		entities[id].seg_id = -1

	for id: int in entity_ids:
		var e: LogiEntity = entities[id]
		if not e.is_transport() or e.seg_id >= 0:
			continue
		if e.is_underground():
			_build_tunnel(e)
		else:
			_build_line(e)

	for sid: int in segment_ids:
		_resolve_sink(segments[sid])

	for item: Dictionary in carried:
		if not _restore_item(item):
			spilled += 1

	topo_version += 1
	topo_dirty = false


## Walks back to the head of a straight run, then forward collecting it.
func _build_line(seed: LogiEntity) -> void:
	var d: Vector2i = seed.direction()
	var start: LogiEntity = seed
	var guard: int = 0
	while guard < LogiTypes.MAX_SEGMENT_TILES:
		guard += 1
		var prev: LogiEntity = entity_at(start.cell - d)
		if prev == null or not prev.is_belt() or prev.kind != seed.kind or prev.rot != seed.rot:
			break
		if prev.seg_id >= 0 or prev == seed:
			break
		start = prev

	var run: Array[Vector2i] = []
	var members: Array[LogiEntity] = []
	var cur: LogiEntity = start
	while cur != null and run.size() < LogiTypes.MAX_SEGMENT_TILES:
		if cur.seg_id >= 0 or not cur.is_belt() or cur.kind != seed.kind or cur.rot != seed.rot:
			break
		run.append(cur.cell)
		members.append(cur)
		cur.seg_id = 0  # claimed; the real id is assigned below
		cur = entity_at(cur.cell + d)

	var seg := LogiSegment.new(_mint_seg(), seed.kind, d, float(run.size()), seed.def.speed, false)
	seg.tiles = run
	seg.entry_cell = run[0]
	seg.exit_cell = run[run.size() - 1]
	segments[seg.id] = seg
	segment_ids.append(seg.id)
	for i: int in members.size():
		members[i].seg_id = seg.id
		members[i].seg_index = i
		seg_at[members[i].cell] = seg.id


## An underground pair is one line with a hole in the middle: items take exactly
## as long to cross as the tiles they skip, which is why a tunnel is a cost and
## not a free teleport.
func _build_tunnel(e: LogiEntity) -> void:
	var mouth: LogiEntity = e
	if not e.is_entrance and e.pair_id >= 0:
		var other: LogiEntity = entities.get(e.pair_id)
		if other != null and other.seg_id < 0:
			mouth = other
	var d: Vector2i = mouth.direction()
	var exit_e: LogiEntity = entities.get(mouth.pair_id) if mouth.pair_id >= 0 else null
	var tiles_long: float = 1.0
	var exit_cell: Vector2i = mouth.cell
	if exit_e != null:
		tiles_long = float(LogiTypes.chebyshev(mouth.cell, exit_e.cell) + 1)
		exit_cell = exit_e.cell

	var seg := LogiSegment.new(_mint_seg(), mouth.kind, d, tiles_long, mouth.def.speed, exit_e != null)
	seg.entry_cell = mouth.cell
	seg.exit_cell = exit_cell
	seg.tiles = [mouth.cell] if exit_e == null else [mouth.cell, exit_cell]
	segments[seg.id] = seg
	segment_ids.append(seg.id)
	mouth.seg_id = seg.id
	mouth.seg_index = 0
	seg_at[mouth.cell] = seg.id
	if exit_e != null:
		exit_e.seg_id = seg.id
		exit_e.seg_index = 1
		seg_at[exit_e.cell] = seg.id


## Works out what the end of a line feeds, once and for all, until the next edit.
func _resolve_sink(seg: LogiSegment) -> void:
	seg.sink = LogiTypes.Sink.NONE
	seg.sink_id = -1
	var next: Vector2i = seg.exit_cell + seg.dir
	var e: LogiEntity = entity_at(next)
	if e == null:
		return
	match e.role():
		LogiTypes.Role.SPLITTER:
			# Splitters pull, so the line only records who is waiting for it.
			seg.sink = LogiTypes.Sink.SPLITTER
			seg.sink_id = e.id
		LogiTypes.Role.CHEST:
			seg.sink = LogiTypes.Sink.STORE
			seg.sink_id = e.id
		LogiTypes.Role.BELT, LogiTypes.Role.UNDERGROUND:
			var target: LogiSegment = segments.get(e.seg_id)
			if target == null or target.id == seg.id:
				return
			var td: Vector2i = e.direction()
			if td == -seg.dir:
				return  # nose to nose: nothing moves, and that is legible
			if td == seg.dir:
				if target.entry_cell == next:
					seg.sink = LogiTypes.Sink.BELT
					seg.sink_id = target.id
				return  # feeding the middle of a line from behind is impossible
			var pos: float = _tile_pos_in(target, next)
			if pos < 0.0:
				return
			seg.sink = LogiTypes.Sink.SIDE
			seg.sink_id = target.id
			seg.sink_lane = LogiTypes.lane_for_side(td, seg.exit_cell - next)
			seg.sink_pos = pos


func _tile_pos_in(seg: LogiSegment, cell: Vector2i) -> float:
	if seg.is_tunnel:
		if cell == seg.entry_cell:
			return seg.length - 0.5
		return 0.5 if cell == seg.exit_cell else -1.0
	var idx: int = seg.tiles.find(cell)
	return seg.tile_center_pos(idx) if idx >= 0 else -1.0


## Puts one carried item back where it physically was, if the new layout still
## has a lane there. Items that have nowhere to go are counted, never hidden.
func _restore_item(item: Dictionary) -> bool:
	var cell: Vector2i = item["cell"]
	var sid: int = int(seg_at.get(cell, -1))
	if sid < 0:
		return false
	var seg: LogiSegment = segments[sid]
	var base: float = _tile_pos_in(seg, cell)
	if base < 0.0:
		return false
	var pos: float = clampf(base + 0.5 - float(item["frac"]), 0.0, seg.length)
	var lane: int = int(item["lane"])
	if seg.lanes[lane].insert_at(int(item["kind"]), pos):
		return true
	return seg.lanes[lane].insert_at(int(item["kind"]), clampf(pos + LogiTypes.SPACING, 0.0, seg.length))


func _mint_seg() -> int:
	var id: int = _next_seg
	_next_seg += 1
	return id


# =========================================================================
# the tick
# =========================================================================

func step(tick: int) -> void:
	_tick = tick
	items_moved = 0
	if topo_dirty:
		rebuild_topology()
	_move_belts()
	_run_splitters()
	_run_inserters()


# --- belts -----------------------------------------------------------------

func _move_belts() -> void:
	for sid: int in segment_ids:
		var seg: LogiSegment = segments[sid]
		if seg.lanes[0].is_empty() and seg.lanes[1].is_empty():
			if seg.blocked_ticks != 0:
				seg.blocked_ticks = 0
			seg.settle_rate()
			continue
		var slack: float = seg.slack()
		var blocked: bool = false
		for lane: int in LogiTypes.LANES:
			var l: LogiLane = seg.lanes[lane]
			l.advance(slack)
			if seg.sink == LogiTypes.Sink.SPLITTER:
				# The splitter takes it from the front; the line just waits.
				continue
			var handed: int = 0
			while l.front_ready() and handed < MAX_HANDOFF:
				if not _push_out(seg, lane, l.front_kind()):
					blocked = true
					break
				l.take_front()
				handed += 1
				seg.moved += 1
				items_moved += 1
		seg.blocked_ticks = seg.blocked_ticks + 1 if blocked else 0
		seg.settle_rate()


## Hands one item off the end of a line. False means the way is blocked, which
## is the only mechanism belts have for back-pressure — and it is enough.
func _push_out(seg: LogiSegment, lane: int, kind: int) -> bool:
	match seg.sink:
		LogiTypes.Sink.BELT:
			var target: LogiSegment = segments.get(seg.sink_id)
			if target == null:
				return false
			return target.lanes[lane].insert_back(kind, target.slack())
		LogiTypes.Sink.SIDE:
			var side_target: LogiSegment = segments.get(seg.sink_id)
			if side_target == null:
				return false
			return side_target.lanes[seg.sink_lane].insert_at(kind, seg.sink_pos)
		LogiTypes.Sink.STORE:
			var st: LogiStore = stores.get(seg.sink_id)
			if st == null:
				return false
			if st.insert(kind_name(kind), 1) <= 0:
				return false
			delivered_to_stores += 1
			return true
	return false


# --- splitters -------------------------------------------------------------

func _run_splitters() -> void:
	for id: int in splitter_ids:
		var sp: LogiSplitter = entities.get(id)
		if sp == null:
			continue
		if not sp.enabled:
			sp.settle_rate()
			continue
		var rate: float = sp.def.lane_rate()
		for side: int in LogiTypes.LANES:
			sp.credit[side] = minf(sp.credit[side] + rate * SimClock.DT, LogiSplitter.MAX_CREDIT)
			var guard: int = 0
			while sp.credit[side] >= 1.0 and guard < MAX_HANDOFF:
				guard += 1
				_splitter_fill(sp, side)
				if sp.buffers[side].is_empty():
					break
				if not _splitter_emit(sp, side):
					break
				sp.credit[side] -= 1.0
				sp.moved += 1
				items_moved += 1
		sp.settle_rate()


## Draws from the two lines feeding this splitter, honouring input priority.
func _splitter_fill(sp: LogiSplitter, side: int) -> void:
	while sp.buffers[side].size() < LogiSplitter.BUFFER:
		var order: Array[int] = _side_order(sp.input_priority, sp.next_in[side])
		var took: bool = false
		for which: int in order:
			var seg: LogiSegment = _splitter_input(sp, which)
			if seg == null:
				continue
			var l: LogiLane = seg.lanes[side]
			if not l.front_ready():
				continue
			sp.buffers[side].append(l.take_front())
			seg.moved += 1
			if sp.input_priority == LogiSplitter.Side.NONE:
				sp.next_in[side] = 1 - which
			took = true
			break
		if not took:
			return


## Pushes the front of the buffer out, honouring filters then output priority
## then the alternation that makes an even split even.
func _splitter_emit(sp: LogiSplitter, side: int) -> bool:
	var kind: int = sp.buffers[side][0]
	var forced: int = sp.forced_side(kind_name(kind))
	var order: Array[int] = [forced] if forced != LogiSplitter.Side.NONE \
		else _side_order(sp.output_priority, sp.next_out[side])
	for which: int in order:
		if not _splitter_push(sp, which, side, kind):
			continue
		sp.buffers[side].remove_at(0)
		if forced == LogiSplitter.Side.NONE and sp.output_priority == LogiSplitter.Side.NONE:
			sp.next_out[side] = 1 - which
		return true
	return false


func _side_order(priority: int, alternate: int) -> Array[int]:
	if priority == LogiSplitter.Side.LEFT or priority == LogiSplitter.Side.RIGHT:
		return [priority, 1 - priority]
	return [alternate, 1 - alternate]


## The line whose exit sits on one of this splitter's input tiles.
func _splitter_input(sp: LogiSplitter, which: int) -> LogiSegment:
	var cell: Vector2i = sp.input_cells()[which]
	var e: LogiEntity = entity_at(cell)
	if e == null or not e.is_transport() or e.direction() != sp.direction():
		return null
	var seg: LogiSegment = segments.get(e.seg_id)
	if seg == null or seg.exit_cell != cell:
		return null
	return seg


func _splitter_push(sp: LogiSplitter, which: int, lane: int, kind: int) -> bool:
	var cell: Vector2i = sp.output_cells()[which]
	var e: LogiEntity = entity_at(cell)
	if e == null:
		return false
	if e.role() == LogiTypes.Role.CHEST:
		var st: LogiStore = stores.get(e.id)
		if st == null or st.insert(kind_name(kind), 1) <= 0:
			return false
		delivered_to_stores += 1
		return true
	if not e.is_transport() or e.direction() != sp.direction():
		return false
	var seg: LogiSegment = segments.get(e.seg_id)
	if seg == null or seg.entry_cell != cell:
		return false
	return seg.lanes[lane].insert_back(kind, seg.slack())


# --- arms ------------------------------------------------------------------

func _run_inserters() -> void:
	for id: int in inserter_ids:
		var arm: LogiInserter = entities.get(id)
		if arm == null:
			continue
		if not arm.enabled:
			arm.settle_rate()
			continue
		if arm.timer > 0.0:
			arm.timer -= SimClock.DT
		match arm.phase:
			LogiInserter.Phase.WAITING:
				# A bored arm stops asking so often. Deterministic: the schedule
				# is a function of the tick and the id, never of the frame.
				if arm.idle_ticks >= IDLE_POLL_AFTER and (_tick + arm.id) % IDLE_POLL_EVERY != 0:
					arm.idle_ticks += 1
				elif _arm_grab(arm):
					arm.idle_ticks = 0
					arm.phase = LogiInserter.Phase.OUT
					arm.timer = arm.cycle_time() * 0.5
				else:
					arm.idle_ticks += 1
			LogiInserter.Phase.OUT:
				if arm.timer <= 0.0:
					if _arm_drop(arm):
						arm.phase = LogiInserter.Phase.BACK
						arm.timer = arm.cycle_time() * 0.5
						arm.idle_ticks = 0
					else:
						# Holding a full hand with nowhere to put it. Visible,
						# and exactly what the player needs to see.
						arm.idle_ticks += 1
			LogiInserter.Phase.BACK:
				if arm.timer <= 0.0:
					arm.phase = LogiInserter.Phase.WAITING
		arm.settle_rate()


func _arm_grab(arm: LogiInserter) -> bool:
	var cell: Vector2i = arm.source_cell()
	var want: int = arm.hand_size()
	var e: LogiEntity = entity_at(cell)
	if e != null and e.is_transport():
		return _grab_from_belt(arm, e, cell, want)
	var owner: int = int(store_cells.get(cell, -1))
	if owner < 0:
		return false
	var st: LogiStore = stores.get(owner)
	if st == null or st.is_empty():
		return false
	var kind: StringName = arm.filter_kind if String(arm.filter_kind) != "" else st.best_kind()
	if String(kind) == "":
		return false
	var got: int = st.take(kind, want)
	if got <= 0:
		return false
	arm.held_kind = kind
	arm.held = got
	return true


func _grab_from_belt(arm: LogiInserter, e: LogiEntity, cell: Vector2i, want: int) -> bool:
	var seg: LogiSegment = segments.get(e.seg_id)
	if seg == null:
		return false
	var centre: float = _tile_pos_in(seg, cell)
	if centre < 0.0:
		return false
	var lo: float = centre - 0.5
	var hi: float = centre + 0.5
	# The far lane first, the way every player already expects an arm to work.
	var near: int = LogiTypes.lane_for_side(seg.dir, arm.cell - cell)
	var order: Array[int] = [1 - near, near]
	var wanted: int = kind_index(arm.filter_kind) if String(arm.filter_kind) != "" else -1
	if String(arm.filter_kind) != "" and wanted < 0:
		return false
	for lane: int in order:
		var l: LogiLane = seg.lanes[lane]
		var idx: int = l.find_in_span(lo, hi, wanted)
		if idx < 0:
			continue
		var kind: int = l.kind_at(idx)
		l.remove_at(idx)
		arm.held_kind = kind_name(kind)
		arm.held = 1
		# A stack arm sweeps the tile for more of the same before it swings.
		while arm.held < want:
			var more: int = l.find_in_span(lo, hi, kind)
			if more < 0:
				break
			l.remove_at(more)
			arm.held += 1
		return true
	return false


func _arm_drop(arm: LogiInserter) -> bool:
	if arm.held <= 0:
		return true
	var moved: int = give_to_cell(arm.target_cell(), arm.held_kind, arm.held)
	if moved <= 0:
		return false
	arm.held -= moved
	arm.moved += moved
	items_moved += moved
	if arm.held > 0:
		return false
	arm.held_kind = &""
	return true


# =========================================================================
# delivery — the one place that knows how to put an item into anything
# =========================================================================

## Puts up to `amount` of `kind` into whatever stands on `cell`: a belt, a
## chest, a burner's bunker or a machine's buffer. Returns how many landed.
func give_to_cell(cell: Vector2i, kind: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	var e: LogiEntity = entity_at(cell)
	if e != null:
		if e.is_transport():
			return _give_to_belt(e, cell, kind, amount)
		if e.role() == LogiTypes.Role.CHEST:
			var st: LogiStore = stores.get(e.id)
			if st == null:
				return 0
			var n: int = st.insert(kind, amount)
			delivered_to_stores += n
			return n
	var burner: int = int(fuel_cells.get(cell, -1))
	if burner >= 0 and fuel_item_of.get(burner, &"") == kind:
		var took: int = give_fuel(burner, kind, amount)
		if took > 0:
			return took
	var owner: int = int(store_cells.get(cell, -1))
	if owner >= 0:
		var st2: LogiStore = stores.get(owner)
		if st2 != null:
			var n2: int = st2.insert(kind, amount)
			delivered_to_stores += n2
			return n2
	return 0


func _give_to_belt(e: LogiEntity, cell: Vector2i, kind: StringName, amount: int) -> int:
	var seg: LogiSegment = segments.get(e.seg_id)
	if seg == null:
		return 0
	var centre: float = _tile_pos_in(seg, cell)
	if centre < 0.0:
		return 0
	var near: int = LogiTypes.lane_for_side(seg.dir, Vector2i.ZERO)
	# Arms put things down on the far lane; without a side to be near, the left
	# lane is the far one by convention and the right lane is the fallback.
	var idx: int = intern(kind)
	var placed: int = 0
	for lane: int in [1 - near, near]:
		var l: LogiLane = seg.lanes[lane]
		for slot: int in LogiTypes.ITEMS_PER_TILE:
			if placed >= amount:
				return placed
			var pos: float = centre - 0.5 + (float(slot) + 0.5) * LogiTypes.SPACING
			if l.insert_at(idx, clampf(pos, 0.0, seg.length)):
				placed += 1
	return placed


## Feeds a burner's bunker through [P02]'s own contract. Returns whole items.
func give_fuel(building_id: int, kind: StringName, amount: int) -> int:
	if _heat == null or amount <= 0:
		return 0
	if not bool(_heat.call("has_building", building_id)):
		return 0
	var took: float = float(_heat.call("deliver_fuel", building_id, kind, float(amount)))
	var whole: int = int(floorf(took + EPS))
	if whole <= 0:
		return 0
	delivered_as_fuel += float(whole)
	return whole


## Takes up to `amount` of `kind` off whatever stands on `cell`.
func take_from_cell(cell: Vector2i, kind: StringName, amount: int) -> int:
	var owner: int = int(store_cells.get(cell, -1))
	if owner < 0:
		return 0
	var st: LogiStore = stores.get(owner)
	return 0 if st == null else st.take(kind, amount)


# =========================================================================
# queries — what [P19]'s lens and [P04]'s machines read
# =========================================================================

## Items per second crossing the belt on this tile, smoothed over a second.
func throughput_at(cell: Vector2i) -> float:
	var sid: int = int(seg_at.get(cell, -1))
	return 0.0 if sid < 0 else segments[sid].rate()


## 0..1 — how full the belt on this tile is. 1.0 is a compressed belt.
func saturation_at(cell: Vector2i) -> float:
	var sid: int = int(seg_at.get(cell, -1))
	return 0.0 if sid < 0 else segments[sid].saturation_at(cell)


func segment_at(cell: Vector2i) -> LogiSegment:
	var sid: int = int(seg_at.get(cell, -1))
	return segments.get(sid) if sid >= 0 else null


func items_on_belts() -> int:
	var n: int = 0
	for sid: int in segment_ids:
		n += segments[sid].item_count()
	return n


func backed_up_segments() -> int:
	var n: int = 0
	for sid: int in segment_ids:
		if segments[sid].is_backed_up():
			n += 1
	return n


func total_belt_rate() -> float:
	var r: float = 0.0
	for sid: int in segment_ids:
		r += segments[sid].rate()
	return r


func stored_units() -> int:
	var n: int = 0
	for id: int in _sorted_store_ids():
		n += stores[id].total()
	return n


func idle_arms() -> int:
	var n: int = 0
	for id: int in inserter_ids:
		var arm: LogiInserter = entities.get(id)
		if arm != null and arm.idle_ticks >= IDLE_POLL_AFTER:
			n += 1
	return n


func _sorted_store_ids() -> Array[int]:
	var keys: Array = stores.keys()
	keys.sort()
	var out: Array[int] = []
	for k: int in keys:
		out.append(k)
	return out


func store_ids() -> Array[int]:
	return _sorted_store_ids()


## Every item on every belt, in world pixels, for the renderer and the lens.
## O(items) — call it for what is on screen, not for the whole map.
func items_for_view(bounds: Rect2i = Rect2i()) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var all: bool = bounds.size.x <= 0 or bounds.size.y <= 0
	for sid: int in segment_ids:
		var seg: LogiSegment = segments[sid]
		if seg.is_tunnel or seg.item_count() == 0:
			continue
		if not all and not bounds.intersects(Rect2i(seg.entry_cell, Vector2i.ONE).merge(
				Rect2i(seg.exit_cell, Vector2i.ONE))):
			continue
		for lane: int in LogiTypes.LANES:
			for entry: Variant in seg.lanes[lane].snapshot():
				var e: Array = entry
				out.append({
					"pos": seg.world_pos_for(float(e[1]), lane),
					"kind": String(kind_name(int(e[0]))),
					"lane": lane,
				})
	return out


## Every belt tile with its direction, tier and how loaded it is. The logistics
## lens draws exactly this.
func belts_for_view() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: int in entity_ids:
		var e: LogiEntity = entities[id]
		if not e.is_transport():
			continue
		var seg: LogiSegment = segments.get(e.seg_id)
		out.append({
			"cell": LogiTypes.cell_to_json(e.cell),
			"kind": String(e.kind),
			"rot": e.rot,
			"tier": e.def.tier,
			"tunnel": e.is_underground(),
			"entrance": e.is_entrance,
			"saturation": snappedf(seg.saturation_at(e.cell) if seg != null else 0.0, 0.001),
			"rate": snappedf(seg.rate() if seg != null else 0.0, 0.01),
		})
	return out


static func _insert_sorted(arr: Array[int], value: int) -> void:
	var lo: int = 0
	var hi: int = arr.size()
	while lo < hi:
		var mid: int = (lo + hi) >> 1
		if arr[mid] < value:
			lo = mid + 1
		else:
			hi = mid
	arr.insert(lo, value)
