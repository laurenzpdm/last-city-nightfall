class_name LogiSegment
extends RefCounted
## One transport line: a straight run of same-tier belt tiles, or one
## underground pair, carrying two independent lanes.
##
## Lines are split at every turn, every tier change and every splitter, so a
## segment always has ONE direction, ONE speed and exactly two lanes. That is
## what keeps the movement maths honest: an item on a curve would travel a
## different distance on the inside lane than on the outside, and pretending
## otherwise is how belt throughput quietly stops matching its own tooltip.
##
## Tile 0 is where items enter, tile n-1 is where they leave. Lane positions run
## the other way — 0.0 is the exit — so the centre of tile i is at
## `length - i - 0.5`.

var id: int = -1
var kind: StringName = &""
var dir: Vector2i = Vector2i.RIGHT
var speed: float = 1.875
## Tiles the run covers, entry first. Empty for an underground: a tunnel has
## only two real tiles and a hole in between.
var tiles: Array[Vector2i] = []
var entry_cell: Vector2i = Vector2i.ZERO
var exit_cell: Vector2i = Vector2i.ZERO
var length: float = 1.0
var is_tunnel: bool = false

var lanes: Array[LogiLane] = []

## What the end of the line feeds. See LogiTypes.Sink.
var sink: int = LogiTypes.Sink.NONE
var sink_id: int = -1
## Which lane of the target a side-load lands in, and where along it.
var sink_lane: int = 0
var sink_pos: float = 0.0

## Items handed off this tick, and a smoothed items-per-second for the lens.
var moved: int = 0
var rate_ema: float = 0.0
## Consecutive ticks the front of a lane sat at the exit unable to leave.
var blocked_ticks: int = 0


func _init(segment_id: int = -1, segment_kind: StringName = &"", direction: Vector2i = Vector2i.RIGHT,
		tiles_long: float = 1.0, belt_speed: float = 1.875, tunnel: bool = false) -> void:
	id = segment_id
	kind = segment_kind
	dir = direction
	length = maxf(1.0, tiles_long)
	speed = maxf(0.01, belt_speed)
	is_tunnel = tunnel
	lanes = [LogiLane.new(length), LogiLane.new(length)]


## Tiles the line moves in one tick.
func slack() -> float:
	return speed * SimClock.DT


func tile_count() -> int:
	return int(round(length))


## Distance from the exit of the middle of tile `index`.
func tile_center_pos(index: int) -> float:
	return length - float(index) - 0.5


## The tile a lane position falls on, clamped into the run.
func tile_index_for_pos(pos: float) -> int:
	return clampi(int(floorf(length - pos)), 0, maxi(0, tile_count() - 1))


## Cell a lane position sits on. A tunnel reports its two ends.
func cell_for_pos(pos: float) -> Vector2i:
	if is_tunnel:
		return exit_cell if pos <= 0.5 else entry_cell
	var i: int = tile_index_for_pos(pos)
	return tiles[clampi(i, 0, tiles.size() - 1)] if not tiles.is_empty() else entry_cell


## World position of an item, including which side of the belt its lane is on.
func world_pos_for(pos: float, lane: int) -> Vector2:
	var travelled: float = clampf(length - pos, 0.0, length)
	var base: Vector2 = LogiTypes.cell_center(entry_cell)
	var along: Vector2 = Vector2(float(dir.x), float(dir.y)) * ((travelled - 0.5) * LogiTypes.TILE)
	return base + along + LogiTypes.lane_offset(dir, lane)


func item_count() -> int:
	return lanes[0].size() + lanes[1].size()


func capacity_items() -> int:
	return lanes[0].capacity() + lanes[1].capacity()


## 0..1 over the whole line.
func saturation() -> float:
	var c: int = capacity_items()
	return 0.0 if c <= 0 else clampf(float(item_count()) / float(c), 0.0, 1.0)


## 0..1 on one tile of the line — what the logistics lens colours a belt with.
func saturation_at(cell: Vector2i) -> float:
	var idx: int = tiles.find(cell)
	if idx < 0:
		if is_tunnel:
			return saturation()
		return 0.0
	var hi: float = length - float(idx)
	var lo: float = hi - 1.0
	var n: int = lanes[0].count_in_span(lo, hi) + lanes[1].count_in_span(lo, hi)
	return clampf(float(n) / float(2 * LogiTypes.ITEMS_PER_TILE), 0.0, 1.0)


## Items per second crossing this line, smoothed over about a second.
func rate() -> float:
	return rate_ema


## Items per second this line could carry with both lanes compressed.
func max_rate() -> float:
	return LogiTypes.lane_rate(speed) * float(LogiTypes.LANES)


func is_backed_up() -> bool:
	return blocked_ticks >= 20 and saturation() > 0.6


## Folds this tick's hand-off count into the smoothed rate. Called once per tick
## by the network, after movement.
func settle_rate() -> void:
	var per_second: float = float(moved) / SimClock.DT
	rate_ema += (per_second - rate_ema) * 0.05
	if rate_ema < 0.0005:
		rate_ema = 0.0
	moved = 0


func clear_items() -> void:
	lanes[0].clear()
	lanes[1].clear()


## Everything on the line as {cell, lane, frac, kind}, used when the topology
## changes and the items have to be poured into the new lines.
func drain_items() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for lane: int in LogiTypes.LANES:
		for entry: Variant in lanes[lane].snapshot():
			var e: Array = entry
			var pos: float = float(e[1])
			out.append({
				"cell": cell_for_pos(pos),
				"lane": lane,
				"kind": int(e[0]),
				"frac": clampf(length - pos - floorf(length - pos), 0.0, 0.999),
			})
	clear_items()
	return out


func to_json(kind_name: Callable) -> Dictionary:
	var lane_dump: Array = []
	for lane: int in LogiTypes.LANES:
		var flat: Array = []
		for entry: Variant in lanes[lane].snapshot():
			var e: Array = entry
			flat.append(String(kind_name.call(int(e[0]))))
			flat.append(e[1])
		lane_dump.append(flat)
	return {
		"id": id,
		"kind": String(kind),
		"entry": LogiTypes.cell_to_json(entry_cell),
		"exit": LogiTypes.cell_to_json(exit_cell),
		"dir": LogiTypes.rot_of(dir),
		"len": snappedf(length, 0.01),
		"tunnel": is_tunnel,
		"sink": sink,
		"sink_id": sink_id,
		"items": item_count(),
		"saturation": snappedf(saturation(), 0.001),
		"rate": snappedf(rate_ema, 0.01),
		"blocked": blocked_ticks,
		"lanes": lane_dump,
	}
