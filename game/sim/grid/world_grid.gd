class_name WorldGrid
extends RefCounted
## The authoritative tile store: a chunked, flat-array world of any size.
##
## Chunks ([GridChunk]) hold the tile fields. On top of them this class keeps ONE
## derived cache — a flat `cost` byte array covering the whole map — because the
## flow field must sweep hundreds of thousands of cells without paying for a
## chunk lookup per cell. Every mutation that can change movement cost funnels
## through [method _touch] so the cache has exactly one write path and can never
## drift from the tiles it mirrors.
##
## Invariant the pathfinder relies on: the outermost `border` ring of the map is
## always impassable. That means any walkable cell has all eight neighbours in
## range, so the inner loop of the flow field needs no bounds checks at all.

const SERIAL_VERSION: int = 1

var width: int = 0
var height: int = 0
var chunks_x: int = 0
var chunks_y: int = 0
var chunks: Array[GridChunk] = []

## Flat width*height movement cost. Grid.IMPASSABLE (255) is a wall.
var cost: PackedByteArray = PackedByteArray()

## Cumulative count of cost changes since world creation. Metrics only.
var cost_changes_total: int = 0
## Live count of passable tiles, maintained by the single cost write path.
var walkable_cells: int = 0
## Cumulative tiles whose snow depth moved. Metrics only.
var snow_changes_total: int = 0

var _dirty: PackedInt32Array = PackedInt32Array()
var _dirty_mark: PackedByteArray = PackedByteArray()

## building id -> footprint rect
var _occ_rect: Dictionary[int, Rect2i] = {}
## building id -> blocks ground movement
var _occ_blocks: Dictionary[int, bool] = {}


func _init(w: int = 0, h: int = 0) -> void:
	if w > 0 and h > 0:
		resize(w, h)


func resize(w: int, h: int) -> void:
	width = w
	height = h
	chunks_x = (w + Grid.CHUNK_MASK) >> Grid.CHUNK_SHIFT
	chunks_y = (h + Grid.CHUNK_MASK) >> Grid.CHUNK_SHIFT
	chunks.clear()
	chunks.resize(chunks_x * chunks_y)
	for cy: int in range(chunks_y):
		for cx: int in range(chunks_x):
			chunks[cy * chunks_x + cx] = GridChunk.new(cx, cy)
	cost = PackedByteArray()
	cost.resize(w * h)
	cost.fill(Grid.IMPASSABLE)
	_dirty = PackedInt32Array()
	_dirty_mark = PackedByteArray()
	_dirty_mark.resize(w * h)
	_occ_rect.clear()
	_occ_blocks.clear()
	cost_changes_total = 0


# ---------------------------------------------------------------- addressing

func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height


func index_of(cell: Vector2i) -> int:
	return cell.y * width + cell.x


func cell_of(idx: int) -> Vector2i:
	return Vector2i(idx % width, idx / width)


func chunk_count() -> int:
	return chunks.size()


func chunk_at(cell: Vector2i) -> GridChunk:
	return chunks[(cell.y >> Grid.CHUNK_SHIFT) * chunks_x + (cell.x >> Grid.CHUNK_SHIFT)]


func chunk_by_coord(cx: int, cy: int) -> GridChunk:
	return chunks[cy * chunks_x + cx]


func _local(cell: Vector2i) -> int:
	return ((cell.y & Grid.CHUNK_MASK) << Grid.CHUNK_SHIFT) | (cell.x & Grid.CHUNK_MASK)


# ---------------------------------------------------------------- tile reads

func terrain_at(cell: Vector2i) -> int:
	if not in_bounds(cell):
		return Grid.Terrain.RIDGE
	return chunk_at(cell).terrain[_local(cell)]


func elevation_at(cell: Vector2i) -> int:
	if not in_bounds(cell):
		return 255
	return chunk_at(cell).elevation[_local(cell)]


func snow_at(cell: Vector2i) -> int:
	if not in_bounds(cell):
		return 0
	return chunk_at(cell).snow[_local(cell)]


func resource_kind_at(cell: Vector2i) -> int:
	if not in_bounds(cell):
		return Grid.Res.NONE
	return chunk_at(cell).res_kind[_local(cell)]


func resource_amount_at(cell: Vector2i) -> int:
	if not in_bounds(cell):
		return 0
	return chunk_at(cell).res_amount[_local(cell)]


func occupancy_at(cell: Vector2i) -> int:
	if not in_bounds(cell):
		return 0
	return chunk_at(cell).occupancy[_local(cell)]


func flags_at(cell: Vector2i) -> int:
	if not in_bounds(cell):
		return 0
	return Grid.TERRAIN_FLAGS[chunk_at(cell).terrain[_local(cell)]]


func is_walkable(cell: Vector2i) -> bool:
	return in_bounds(cell) and cost[cell.y * width + cell.x] != Grid.IMPASSABLE


func is_buildable_terrain(cell: Vector2i) -> bool:
	return in_bounds(cell) and (flags_at(cell) & Grid.F_BUILD) != 0


func blocks_sight(cell: Vector2i) -> bool:
	if not in_bounds(cell):
		return true
	if (Grid.TERRAIN_FLAGS[chunk_at(cell).terrain[_local(cell)]] & Grid.F_BLOCK_SIGHT) != 0:
		return true
	var id: int = chunk_at(cell).occupancy[_local(cell)]
	return id != 0 and _occ_blocks.get(id, false)


func cost_at(cell: Vector2i) -> int:
	if not in_bounds(cell):
		return Grid.IMPASSABLE
	return cost[cell.y * width + cell.x]


# ---------------------------------------------------------------- tile writes

func set_terrain(cell: Vector2i, t: int) -> void:
	if not in_bounds(cell):
		return
	chunk_at(cell).set_terrain(_local(cell), t)
	_touch(cell.y * width + cell.x)


func set_elevation(cell: Vector2i, e: int) -> void:
	if not in_bounds(cell):
		return
	chunk_at(cell).set_elevation(_local(cell), clampi(e, 0, 255))


func set_snow(cell: Vector2i, depth: int) -> void:
	if not in_bounds(cell):
		return
	var c: GridChunk = chunk_at(cell)
	var li: int = _local(cell)
	var v: int = clampi(depth, 0, 255)
	if c.snow[li] == v:
		return
	c.set_snow(li, v)
	snow_changes_total += 1


func set_resource(cell: Vector2i, kind: int, amount: int) -> void:
	if not in_bounds(cell):
		return
	chunk_at(cell).set_resource(_local(cell), kind, maxi(amount, 0))


## Removes up to `amount` from the deposit here. Returns what was actually taken.
## Exhausting a wreck leaves rubble behind — the world keeps a memory of it.
func harvest(cell: Vector2i, amount: int) -> int:
	if not in_bounds(cell) or amount <= 0:
		return 0
	var c: GridChunk = chunk_at(cell)
	var li: int = _local(cell)
	var have: int = c.res_amount[li]
	if have <= 0:
		return 0
	var taken: int = mini(have, amount)
	var left: int = have - taken
	c.set_resource(li, c.res_kind[li] if left > 0 else Grid.Res.NONE, left)
	if left == 0 and c.terrain[li] == Grid.Terrain.WRECK:
		c.set_terrain(li, Grid.Terrain.RUBBLE)
		_touch(cell.y * width + cell.x)
	return taken


# ---------------------------------------------------------------- occupancy

## True when every tile of the footprint is in bounds, buildable and unclaimed.
func is_free(cell: Vector2i, size: Vector2i) -> bool:
	var sx: int = maxi(size.x, 1)
	var sy: int = maxi(size.y, 1)
	if cell.x < 0 or cell.y < 0 or cell.x + sx > width or cell.y + sy > height:
		return false
	for y: int in range(cell.y, cell.y + sy):
		for x: int in range(cell.x, cell.x + sx):
			var c: GridChunk = chunk_at(Vector2i(x, y))
			var li: int = ((y & Grid.CHUNK_MASK) << Grid.CHUNK_SHIFT) | (x & Grid.CHUNK_MASK)
			if c.occupancy[li] != 0:
				return false
			if (Grid.TERRAIN_FLAGS[c.terrain[li]] & Grid.F_BUILD) == 0:
				return false
	return true


## Claims a footprint for `id`. Fails (and changes nothing) if it is not free.
func occupy(cell: Vector2i, size: Vector2i, id: int, blocks_movement: bool = true) -> bool:
	if id == 0 or _occ_rect.has(id):
		return false
	if not is_free(cell, size):
		return false
	var sx: int = maxi(size.x, 1)
	var sy: int = maxi(size.y, 1)
	_occ_rect[id] = Rect2i(cell, Vector2i(sx, sy))
	_occ_blocks[id] = blocks_movement
	for y: int in range(cell.y, cell.y + sy):
		for x: int in range(cell.x, cell.x + sx):
			var cc: Vector2i = Vector2i(x, y)
			chunk_at(cc).set_occupancy(_local(cc), id)
			_touch(y * width + x)
	return true


## Frees everything `id` claimed. Returns false if the id was not placed.
func release(id: int) -> bool:
	if not _occ_rect.has(id):
		return false
	var r: Rect2i = _occ_rect[id]
	_occ_rect.erase(id)
	_occ_blocks.erase(id)
	for y: int in range(r.position.y, r.position.y + r.size.y):
		for x: int in range(r.position.x, r.position.x + r.size.x):
			var cc: Vector2i = Vector2i(x, y)
			var c: GridChunk = chunk_at(cc)
			var li: int = _local(cc)
			if c.occupancy[li] == id:
				c.set_occupancy(li, 0)
				_touch(y * width + x)
	return true


## Building id occupying this tile, or 0.
func building_at(cell: Vector2i) -> int:
	return occupancy_at(cell)


func building_rect(id: int) -> Rect2i:
	return _occ_rect.get(id, Rect2i())


func building_count() -> int:
	return _occ_rect.size()


func building_ids() -> PackedInt32Array:
	var keys: Array = _occ_rect.keys()
	keys.sort()
	var out: PackedInt32Array = PackedInt32Array()
	for k: int in keys:
		out.append(k)
	return out


# ---------------------------------------------------------------- cost cache

## Recomputes one cell's movement cost and queues it if it changed.
func _touch(idx: int) -> void:
	var x: int = idx % width
	var y: int = idx / width
	var c: int = _compute_cost(x, y)
	var was: int = cost[idx]
	if was == c:
		return
	if was == Grid.IMPASSABLE:
		walkable_cells += 1
	elif c == Grid.IMPASSABLE:
		walkable_cells -= 1
	cost[idx] = c
	cost_changes_total += 1
	if _dirty_mark[idx] == 0:
		_dirty_mark[idx] = 1
		_dirty.append(idx)


func _compute_cost(x: int, y: int) -> int:
	if x <= 0 or y <= 0 or x >= width - 1 or y >= height - 1:
		return Grid.IMPASSABLE
	var c: GridChunk = chunks[(y >> Grid.CHUNK_SHIFT) * chunks_x + (x >> Grid.CHUNK_SHIFT)]
	var li: int = ((y & Grid.CHUNK_MASK) << Grid.CHUNK_SHIFT) | (x & Grid.CHUNK_MASK)
	var t: int = c.terrain[li]
	if (Grid.TERRAIN_FLAGS[t] & Grid.F_WALK) == 0:
		return Grid.IMPASSABLE
	var id: int = c.occupancy[li]
	if id != 0 and _occ_blocks.get(id, false):
		return Grid.IMPASSABLE
	return Grid.TERRAIN_COST[t]


## How fast a ground unit crosses this tile, 0.35 .. 1.0. Snow depth lives HERE
## and deliberately not in the pathfinding cost: drifting snow would otherwise
## re-dirty tens of thousands of tiles an hour and drag the flow field through a
## repair it cannot see the point of. Terrain decides the route, snow decides the
## pace, and clearing snow with heat is a speed buff you can actually watch.
func speed_scale(cell: Vector2i) -> float:
	if not in_bounds(cell):
		return 1.0
	var c: GridChunk = chunk_at(cell)
	var li: int = _local(cell)
	var t: int = c.terrain[li]
	var base: float = 10.0 / float(maxi(Grid.TERRAIN_COST[t], 1)) if (Grid.TERRAIN_FLAGS[t] & Grid.F_WALK) != 0 else 0.0
	return clampf(base * (1.0 - float(c.snow[li]) * 0.0022), 0.28, 1.6)


## Full recompute. Only for world creation and load — O(width*height).
func rebuild_all_costs() -> void:
	var n: int = 0
	for y: int in range(height):
		var row: int = y * width
		for x: int in range(width):
			var c: int = _compute_cost(x, y)
			cost[row + x] = c
			if c != Grid.IMPASSABLE:
				n += 1
	walkable_cells = n
	_dirty = PackedInt32Array()
	_dirty_mark.fill(0)


## Adds `delta` snow across one whole chunk. Costs one linear pass over 1024
## bytes and never touches the pathfinding cost (see [method speed_scale]), so a
## blizzard is cheap no matter how much of the map it covers.
func accumulate_snow(chunk_index: int, delta: int, cap: int) -> int:
	if chunk_index < 0 or chunk_index >= chunks.size() or delta == 0:
		return 0
	var c: GridChunk = chunks[chunk_index]
	var s: PackedByteArray = c.snow
	var n: int = 0
	for i: int in range(Grid.CHUNK_AREA):
		if (Grid.TERRAIN_FLAGS[c.terrain[i]] & Grid.F_WARM) != 0:
			if s[i] != 0:
				s[i] = 0
				n += 1
			continue
		var old: int = s[i]
		var v: int = clampi(old + delta, 0, cap)
		if v == old:
			continue
		s[i] = v
		n += 1
	c.snow = s
	c.version += 1
	snow_changes_total += n
	return n


## Forces every cell in the region back into the dirty queue.
func mark_region_dirty(region: Rect2i) -> int:
	var x0: int = maxi(region.position.x, 0)
	var y0: int = maxi(region.position.y, 0)
	var x1: int = mini(region.position.x + region.size.x, width)
	var y1: int = mini(region.position.y + region.size.y, height)
	var n: int = 0
	for y: int in range(y0, y1):
		var row: int = y * width
		for x: int in range(x0, x1):
			var idx: int = row + x
			var c: int = _compute_cost(x, y)
			cost[idx] = c
			if _dirty_mark[idx] == 0:
				_dirty_mark[idx] = 1
				_dirty.append(idx)
				n += 1
	return n


func dirty_count() -> int:
	return _dirty.size()


## Pops at most `budget` queued cells. The rest stay queued for the next tick,
## which is what keeps a storm or a mass demolition from stalling a frame.
func take_dirty(budget: int) -> PackedInt32Array:
	if _dirty.is_empty():
		return PackedInt32Array()
	var out: PackedInt32Array
	if _dirty.size() <= budget:
		out = _dirty
		_dirty = PackedInt32Array()
	else:
		out = _dirty.slice(0, budget)
		_dirty = _dirty.slice(budget)
	for i: int in out:
		_dirty_mark[i] = 0
	return out


# ---------------------------------------------------------------- queries

## Ground line of sight between two tiles. A diagonal squeeze counts as blocked
## only when both flanking tiles block, so units can see through a gap.
func line_of_sight(a: Vector2i, b: Vector2i) -> bool:
	if a == b:
		return true
	var x: int = a.x
	var y: int = a.y
	var dx: int = absi(b.x - a.x)
	var dy: int = absi(b.y - a.y)
	var sx: int = 1 if b.x > a.x else -1
	var sy: int = 1 if b.y > a.y else -1
	var err: int = dx - dy
	var guard: int = dx + dy + 2
	while guard > 0:
		guard -= 1
		var e2: int = err * 2
		var moved_x: bool = false
		var moved_y: bool = false
		if e2 > -dy:
			err -= dy
			x += sx
			moved_x = true
		if e2 < dx:
			err += dx
			y += sy
			moved_y = true
		if x == b.x and y == b.y:
			return true
		if moved_x and moved_y:
			if blocks_sight(Vector2i(x - sx, y)) and blocks_sight(Vector2i(x, y - sy)):
				return false
		if blocks_sight(Vector2i(x, y)):
			return false
	return false


## Walkable component containing `start`, as a flat 0/1 mask. O(width*height).
func reachable_mask(start: Vector2i) -> PackedByteArray:
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(width * height)
	if not in_bounds(start) or cost[index_of(start)] == Grid.IMPASSABLE:
		return mask
	var queue: PackedInt32Array = PackedInt32Array()
	queue.append(index_of(start))
	mask[index_of(start)] = 1
	var head: int = 0
	var offs: PackedInt32Array = PackedInt32Array([1, -1, width, -width])
	while head < queue.size():
		var c: int = queue[head]
		head += 1
		for o: int in offs:
			var n: int = c + o
			if n < 0 or n >= mask.size():
				continue
			if mask[n] == 1 or cost[n] == Grid.IMPASSABLE:
				continue
			mask[n] = 1
			queue.append(n)
	return mask


## Nearest tile carrying `kind` with amount left, searched ring by ring.
## Returns Vector2i(-1,-1) when nothing is in range.
func find_nearest_resource(from: Vector2i, kind: int, max_radius: int) -> Vector2i:
	for r: int in range(0, max_radius + 1):
		for c: Vector2i in Grid.ring(from, r):
			if not in_bounds(c):
				continue
			var ch: GridChunk = chunk_at(c)
			var li: int = _local(c)
			if ch.res_amount[li] > 0 and ch.res_kind[li] == kind:
				return c
	return Vector2i(-1, -1)


## Every deposit tile of `kind` inside a radius, nearest first.
func resources_in_radius(from: Vector2i, kind: int, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for r: int in range(0, radius + 1):
		for c: Vector2i in Grid.ring(from, r):
			if not in_bounds(c):
				continue
			var ch: GridChunk = chunk_at(c)
			var li: int = _local(c)
			if ch.res_amount[li] > 0 and (kind == Grid.Res.NONE or ch.res_kind[li] == kind):
				out.append(c)
	return out


## Nearest walkable tile to `from`, or from itself. Used to unstick spawns.
func nearest_walkable(from: Vector2i, max_radius: int = 32) -> Vector2i:
	if is_walkable(from):
		return from
	for r: int in range(1, max_radius + 1):
		for c: Vector2i in Grid.ring(from, r):
			if is_walkable(c):
				return c
	return from


## Totals per resource kind across the whole map. Index by Grid.Res.
func resource_totals() -> PackedInt64Array:
	var out: PackedInt64Array = PackedInt64Array()
	out.resize(Grid.RES_COUNT)
	for c: GridChunk in chunks:
		if c.deposits == 0:
			continue
		for i: int in range(Grid.CHUNK_AREA):
			var a: int = c.res_amount[i]
			if a > 0:
				out[c.res_kind[i]] += a
	return out


func terrain_histogram() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(Grid.TERRAIN_COUNT)
	for c: GridChunk in chunks:
		for i: int in range(Grid.CHUNK_AREA):
			out[c.terrain[i]] += 1
	return out


func walkable_count() -> int:
	var n: int = 0
	for v: int in cost:
		if v != Grid.IMPASSABLE:
			n += 1
	return n


# ---------------------------------------------------------------- persistence

## Content hash of every tile field. Two runs of the same seed must match.
func content_hash() -> int:
	var h: int = Rng.hash_combine(width, height)
	for c: GridChunk in chunks:
		h = Rng.hash_combine(h, hash(c.terrain))
		h = Rng.hash_combine(h, hash(c.elevation))
		h = Rng.hash_combine(h, hash(c.res_kind))
		h = Rng.hash_combine(h, hash(c.res_amount))
		h = Rng.hash_combine(h, hash(c.occupancy))
		h = Rng.hash_combine(h, hash(c.snow))
	return h


func serialize() -> Dictionary:
	var terrain: PackedByteArray = PackedByteArray()
	var elevation: PackedByteArray = PackedByteArray()
	var res_kind: PackedByteArray = PackedByteArray()
	var snow: PackedByteArray = PackedByteArray()
	var res_amount: PackedInt32Array = PackedInt32Array()
	var occupancy: PackedInt32Array = PackedInt32Array()
	for c: GridChunk in chunks:
		terrain.append_array(c.terrain)
		elevation.append_array(c.elevation)
		res_kind.append_array(c.res_kind)
		snow.append_array(c.snow)
		res_amount.append_array(c.res_amount)
		occupancy.append_array(c.occupancy)

	var occ: PackedInt32Array = PackedInt32Array()
	for id: int in building_ids():
		var r: Rect2i = _occ_rect[id]
		occ.append(id)
		occ.append(r.position.x)
		occ.append(r.position.y)
		occ.append(r.size.x)
		occ.append(r.size.y)
		occ.append(1 if _occ_blocks.get(id, false) else 0)

	return {
		"v": SERIAL_VERSION,
		"w": width,
		"h": height,
		"hash": content_hash(),
		"terrain": _pack_bytes(terrain),
		"elevation": _pack_bytes(elevation),
		"res_kind": _pack_bytes(res_kind),
		"snow": _pack_bytes(snow),
		"res_amount": _pack_bytes(res_amount.to_byte_array()),
		"occupancy": _pack_bytes(occupancy.to_byte_array()),
		"buildings": _pack_bytes(occ.to_byte_array()),
	}


func deserialize(data: Dictionary) -> bool:
	var w: int = int(data.get("w", 0))
	var h: int = int(data.get("h", 0))
	if w <= 0 or h <= 0:
		return false
	resize(w, h)
	var terrain: PackedByteArray = _unpack_bytes(data.get("terrain", {}))
	var elevation: PackedByteArray = _unpack_bytes(data.get("elevation", {}))
	var res_kind: PackedByteArray = _unpack_bytes(data.get("res_kind", {}))
	var snow: PackedByteArray = _unpack_bytes(data.get("snow", {}))
	var res_amount: PackedInt32Array = _unpack_bytes(data.get("res_amount", {})).to_int32_array()
	var occupancy: PackedInt32Array = _unpack_bytes(data.get("occupancy", {})).to_int32_array()
	var n: int = chunks.size()
	if terrain.size() < n * Grid.CHUNK_AREA:
		Log.error("grid", "save payload truncated (terrain %d of %d)" % [terrain.size(), n * Grid.CHUNK_AREA])
		return false
	for ci: int in range(n):
		var lo: int = ci * Grid.CHUNK_AREA
		var hi: int = lo + Grid.CHUNK_AREA
		var c: GridChunk = chunks[ci]
		c.terrain = terrain.slice(lo, hi)
		c.elevation = elevation.slice(lo, hi)
		c.res_kind = res_kind.slice(lo, hi)
		c.snow = snow.slice(lo, hi)
		c.res_amount = res_amount.slice(lo, hi)
		c.occupancy = occupancy.slice(lo, hi)
		c.recount_deposits()
		c.version += 1

	var occ: PackedInt32Array = _unpack_bytes(data.get("buildings", {})).to_int32_array()
	var i: int = 0
	while i + 5 < occ.size():
		var id: int = occ[i]
		_occ_rect[id] = Rect2i(occ[i + 1], occ[i + 2], occ[i + 3], occ[i + 4])
		_occ_blocks[id] = occ[i + 5] != 0
		i += 6
	rebuild_all_costs()
	return true


static func _pack_bytes(raw: PackedByteArray) -> Dictionary:
	if raw.is_empty():
		return {"n": 0, "b": ""}
	return {
		"n": raw.size(),
		"b": Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_ZSTD)),
	}


static func _unpack_bytes(d: Variant) -> PackedByteArray:
	if typeof(d) != TYPE_DICTIONARY:
		return PackedByteArray()
	var dict: Dictionary = d
	var n: int = int(dict.get("n", 0))
	if n <= 0:
		return PackedByteArray()
	var comp: PackedByteArray = Marshalls.base64_to_raw(String(dict.get("b", "")))
	return comp.decompress(n, FileAccess.COMPRESSION_ZSTD)
