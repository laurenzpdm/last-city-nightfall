class_name LcnNarrativeBootstrap
extends Resource
## [P22] How the narrative system gets into the tick without editing a file it
## does not own.
##
## `game/core/sim.gd` holds the one shared list of simulation systems and is
## INTEGRATOR-ONLY, and `game/narrative/` is deliberately not under `game/sim/`.
## So this part registers the way every other part registers: a `.tres` in
## `game/content/events/`, which `Registry` scans at boot, whose `_init` defers
## a hook onto `Bus.world_ready`. When a world is created, the system is built,
## `setup()` and `post_setup()` are called, and it is inserted into
## `Sim.systems` at its declared order.
##
## THE ONE RULE THIS FILE OBEYS: it never calls `add_child` and it never touches
## the scene tree. The build menu spent a whole phase as an orphan because an
## install ran inside `_ready`, where the root refuses to take children, and
## nothing checked afterwards. There is nothing to parent here, so there is
## nothing to get wrong; the check that matters is `Sim.get_system(&"narrative")`
## and `ensure()` performs it every time.
##
## Idempotent from every direction: the deferred hook, a second world, a test
## fixture that creates and destroys ten worlds in one process, and a direct
## `ensure()` from `Narrative.system()`.

@export var id: StringName = &"narrative_bootstrap"

static var _hooked: bool = false


func _init() -> void:
	if Engine.is_editor_hint():
		return
	# Deferred because Registry is an autoload that readies BEFORE Bus and Sim
	# do: at this instant neither of them exists yet.
	_hook_deferred.call_deferred()


func _hook_deferred() -> void:
	hook()


## Connects to world creation. Safe to call any number of times.
static func hook() -> void:
	if Engine.get_main_loop() == null:
		return
	if not _hooked:
		var cb: Callable = Callable(LcnNarrativeBootstrap, "_on_world_ready")
		if not Bus.world_ready.is_connected(cb):
			Bus.world_ready.connect(cb)
		_hooked = true
	# A world may already exist: `boot.gd` creates one inside its own `_ready`,
	# which is earlier than any deferred call can possibly run.
	ensure()


static func _on_world_ready() -> void:
	ensure()


## Builds and attaches the system if this world does not have one. Returns it
## either way, or null when there is no world to attach to.
static func ensure() -> NarrativeSystem:
	if not Sim.alive:
		return null
	var existing: SimSystem = Sim.get_system(&"narrative")
	if existing != null:
		return existing as NarrativeSystem

	var system := NarrativeSystem.new()
	system.setup()
	system.post_setup()
	Sim.by_name[system.system_name()] = system
	Sim.systems.insert(_slot_for(system), system)
	# Sim's per-system profile arrays are indexed positionally, so an insert in
	# the middle would attribute one tick of cost to the wrong part. Clearing
	# them is public, cheap and happens once per world.
	Sim.profile_reset()
	Log.info(NarrativeDefs.TAG, "attached to the world at order %d (%d systems now)" % [
		system.order, Sim.systems.size()])
	return system


## The index that keeps `Sim.systems` in the order `Sim._sort_by_order()` would
## produce: ascending `order`, ties broken on `system_name()`.
static func _slot_for(system: SimSystem) -> int:
	var name: String = String(system.system_name())
	for i: int in Sim.systems.size():
		var other: SimSystem = Sim.systems[i]
		if other.order > system.order:
			return i
		if other.order == system.order and String(other.system_name()) > name:
			return i
	return Sim.systems.size()


## Tests create and tear down worlds repeatedly in one process.
static func reset() -> void:
	_hooked = false
