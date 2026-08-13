class_name SimSystem
extends RefCounted
## Base class for every simulation system. Deterministic, headless-safe.
##
## A system owns its slice of world state, advances it once per tick, and can
## serialize that slice. It must never read input, touch view/ or ui/, use
## delta time, or call randf() outside Rng.stream().

## Lower runs first. See docs/ARCHITECTURE.md §3 for the canonical order.
var order: int = 50

## Set false to skip ticking (e.g. system not unlocked yet).
var enabled: bool = true


## Called once when the world is created, before any tick. Build state here.
func setup() -> void:
	pass


## Called after every system has run setup(). Wire cross-system references here.
func post_setup() -> void:
	pass


## Advance exactly one tick. `tick` is the absolute tick index.
## Use SimClock.DT for integration. Never use frame delta.
func step(_tick: int) -> void:
	pass


## Full state of this system as plain JSON-safe data. Used by saves,
## by the harness state dump, and by determinism replay checks.
func serialize() -> Dictionary:
	return {}


func deserialize(_data: Dictionary) -> void:
	pass


## Scalar series the harness writes to metrics.csv each sample.
## Keep keys stable — critics diff these across builds.
func metrics() -> Dictionary:
	return {}


## Stable name used in logs, saves and metric prefixes.
func system_name() -> StringName:
	return &"unnamed"
