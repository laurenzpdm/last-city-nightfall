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
## It also installs `LcnNarrativeCard`, which is how the events reach a human.
## That install happens ONLY from a deferred call, never from inside anybody's
## `_ready`, and the node is checked with `is_inside_tree()` afterwards: an
## `add_child` that Godot refuses returns an orphan, prints one engine error
## into a log nobody parses, and leaves the part unreachable while every gate
## stays green. That is not a hypothetical; it is what happened to the build
## menu. If the parenting fails here it is freed and logged as an ERROR, which
## fails the harness run.
##
## Idempotent from every direction: the deferred hook, a second world, a test
## fixture that creates and destroys ten worlds in one process, and a direct
## `ensure()` from `Narrative.system()`.

@export var id: StringName = &"narrative_bootstrap"

static var _hooked: bool = false
static var _card_done: bool = false


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
	install_card()


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


# =========================================================================
#  the card
# =========================================================================

## Puts the event card in the tree, unless somebody better already draws events.
## Returns the presenter that is in the tree afterwards, or null.
static func install_card() -> LcnNarrativeCard:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var existing: Node = tree.get_first_node_in_group(LcnNarrativeCard.GROUP)
	if existing != null:
		# [P17] or [P18] taking the group over is the intended end state, not a
		# failure. The log names whoever is drawing, so a run always says which
		# one a screenshot came from.
		if not _card_done:
			Log.info(NarrativeDefs.TAG, "events are drawn by %s" % existing.name)
		_card_done = true
		return existing as LcnNarrativeCard
	if _card_done:
		return null
	if not LcnLayers.view_wanted():
		return null
	if OS.get_cmdline_user_args().has("--no-narrative-card"):
		Log.info(NarrativeDefs.TAG, "the event card is disabled by command line")
		_card_done = true
		return null
	var card := LcnNarrativeCard.new()
	# `is_node_ready()` is false for exactly the window in which `add_child` is
	# refused, so it is the precise public test for "would this be an orphan".
	if tree.root.is_node_ready():
		tree.root.add_child(card)
	else:
		tree.root.add_child.call_deferred(card)
		_card_done = true
		return card
	_card_done = true
	if not card.is_inside_tree():
		Log.error(NarrativeDefs.TAG,
			"the event card could not be parented — dilemmas would decide themselves")
		card.free()
		return null
	Log.info(NarrativeDefs.TAG, "event card installed on layer %d" % LcnNarrativeCard.LAYER)
	return card


## Tests create and tear down worlds repeatedly in one process.
static func reset() -> void:
	_hooked = false
	_card_done = false
