class_name LcnAutosave
extends Node
## [P24] The autosave, at dawn.
##
## Not on a wall-clock timer. A timer saves at a moment that means nothing —
## halfway through a wave, mid-placement, with three buildings on fire — and the
## save a player reaches for after a bad night is the one taken BEFORE it. Dawn
## is the beat this game already has: the night is over, the count is in, and
## the next decision has not been made yet. `Bus.day_started` is emitted by
## [P09]'s climate system at exactly that point.
##
## Three files rotate (`autosave_1..3`), so a dawn that arrives after the city
## is already lost cannot overwrite the last morning it was not.
##
## It never runs during a harness run: the deterministic replay must not touch
## the disk, and a 3 MB write every in-world day would show up in the tick
## budget as a mystery.

const MIN_TICKS_BETWEEN: int = 200

var enabled: bool = true
var saves_written: int = 0
var last_slot: String = ""

var _last_tick: int = -100000


func _ready() -> void:
	name = "LcnAutosave"
	if Harness.active:
		enabled = false
		return
	Bus.day_started.connect(_on_day_started)


func _on_day_started(day: int) -> void:
	if not enabled or not Sim.alive:
		return
	# Day 1 fires while the climate system is still in setup(), before the world
	# has a city in it. Saving there writes an empty morning over a real one.
	if day <= 1 or SimClock.tick <= 1:
		return
	if SimClock.tick - _last_tick < MIN_TICKS_BETWEEN:
		return
	_last_tick = SimClock.tick
	write_now(day)


## Exposed so a test can drive it without waiting an in-world day.
func write_now(day: int) -> bool:
	var slot: String = LcnSaveManager.autosave_slot(day)
	var head: Dictionary = LcnSaveManager.save(slot, "Dawn of day %d" % day)
	if head.is_empty():
		Log.error("meta", "autosave at dawn of day %d failed" % day)
		return false
	saves_written += 1
	last_slot = slot
	Bus.toast.emit("saved — dawn of day %d" % day)
	return true
