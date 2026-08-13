class_name LogiInserter
extends LogiEntity
## A swing arm. It reaches behind itself, takes what it finds, swings over its
## own tile and puts it down in front.
##
## The cycle is deliberately visible, because an inserter is the part of a
## factory a player watches to understand why a machine is idle:
##
##   WAITING   nothing to pick up, or nowhere to put it
##   OUT       carrying a hand of items across
##   BACK      returning empty
##
## Throughput is `swings_per_second * stack_size` items per second, and a full
## cycle costs `1 / swings_per_second` seconds — half of it outbound, half of it
## coming back. That is why a stack arm is worth six ordinary ones and why tier
## choice is a real decision instead of a number that goes up.
##
## An arm that has grabbed a hand keeps it until there is somewhere to put it.
## Standing there holding four plates is exactly the tell a player needs.

enum Phase { WAITING, OUT, BACK }

var phase: int = Phase.WAITING
## Seconds left in the current swing.
var timer: float = 0.0
## What the arm is carrying.
var held_kind: StringName = &""
var held: int = 0
## Only pick this item up. Empty means whatever is there.
var filter_kind: StringName = &""

## Items delivered this tick and the smoothed rate for the lens.
var moved: int = 0
var rate_ema: float = 0.0
## Consecutive ticks it had nothing to do. Drives is_starved() and the lens.
var idle_ticks: int = 0


func source_cell() -> Vector2i:
	var reach: int = 1 if def == null else maxi(1, def.reach)
	return cell - direction() * reach


func target_cell() -> Vector2i:
	var reach: int = 1 if def == null else maxi(1, def.reach)
	return cell + direction() * reach


## Seconds one grab-swing-drop-return cycle takes.
func cycle_time() -> float:
	var rate: float = 0.83 if def == null else maxf(0.01, def.swings_per_second)
	return 1.0 / rate


func hand_size() -> int:
	return 1 if def == null else maxi(1, def.stack_size)


## Items per second when it never has to wait.
func max_rate() -> float:
	return 0.0 if def == null else def.inserter_rate()


func is_holding() -> bool:
	return held > 0


func settle_rate() -> void:
	var per_second: float = float(moved) / SimClock.DT
	rate_ema += (per_second - rate_ema) * 0.05
	if rate_ema < 0.0005:
		rate_ema = 0.0
	moved = 0


func to_json() -> Dictionary:
	var d: Dictionary = super.to_json()
	d["phase"] = phase
	d["timer"] = snappedf(timer, 0.0001)
	d["held"] = held
	d["held_kind"] = String(held_kind)
	d["filter"] = String(filter_kind)
	d["rate"] = snappedf(rate_ema, 0.01)
	d["idle"] = idle_ticks
	return d
