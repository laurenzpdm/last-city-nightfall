class_name LogiSplitter
extends LogiEntity
## A two-tile splitter: two belts in, two belts out, and the three behaviours
## players actually expect from one.
##
##   EVEN SPLIT     alternate outputs, so a full input feeds two half belts and
##                  two full inputs feed two full outputs
##   PRIORITY       take from (or feed) one side first and only spill to the
##                  other when it backs up — this is how you make a bus
##   FILTER         send one named item to one side and everything else to the
##                  other, which is how you pull a single product off a mixed
##                  line without a chest
##
## Lanes are preserved. The left lane of either input can only ever reach the
## left lane of an output, exactly like the real thing, so a splitter never
## quietly mixes a sorted belt back together.
##
## The internal buffer is two items per lane side. It exists so a splitter can
## hold an item while one output is briefly blocked; it is not storage.

const BUFFER: int = 2
## Ceiling on saved-up throughput, in items. Without it a splitter that sat idle
## for a minute would fire a burst that no belt could have delivered.
const MAX_CREDIT: float = 3.0

enum Side { NONE = -1, LEFT = 0, RIGHT = 1 }

## Which input to drain first: Side.NONE means alternate.
var input_priority: int = Side.NONE
## Which output to fill first: Side.NONE means alternate.
var output_priority: int = Side.NONE
## Item forced to `filter_side`. Everything else then takes the other side.
var filter_kind: StringName = &""
var filter_side: int = Side.LEFT

## Per lane side: the items waiting inside, front first.
var buffers: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array()]
## Whose turn it is next when nothing has priority, per lane side.
var next_in: PackedInt32Array = PackedInt32Array([0, 0])
var next_out: PackedInt32Array = PackedInt32Array([0, 0])
## Fractional item budget carried between ticks, per lane side.
var credit: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])

## Items passed this tick, and the smoothed rate for the lens.
var moved: int = 0
var rate_ema: float = 0.0


## The two cells this splitter stands on: origin first, then the tile to its right.
func footprint() -> Array[Vector2i]:
	var d: Vector2i = direction()
	return [cell, cell + LogiTypes.right_of(d)]


## Cells items arrive from, left side first.
func input_cells() -> Array[Vector2i]:
	var d: Vector2i = direction()
	return [cell - d, cell + LogiTypes.right_of(d) - d]


## Cells items leave into, left side first.
func output_cells() -> Array[Vector2i]:
	var d: Vector2i = direction()
	return [cell + d, cell + LogiTypes.right_of(d) + d]


## Side an item of `kind` is allowed to leave by, or Side.NONE for either.
func forced_side(kind: StringName) -> int:
	if String(filter_kind) == "":
		return Side.NONE
	return filter_side if kind == filter_kind else (1 - filter_side)


func buffered() -> int:
	return buffers[0].size() + buffers[1].size()


func settle_rate() -> void:
	var per_second: float = float(moved) / SimClock.DT
	rate_ema += (per_second - rate_ema) * 0.05
	if rate_ema < 0.0005:
		rate_ema = 0.0
	moved = 0


func to_json() -> Dictionary:
	var d: Dictionary = super.to_json()
	d["input_priority"] = input_priority
	d["output_priority"] = output_priority
	d["filter"] = String(filter_kind)
	d["filter_side"] = filter_side
	d["buffered"] = buffered()
	d["rate"] = snappedf(rate_ema, 0.01)
	return d
