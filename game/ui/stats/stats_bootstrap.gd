class_name LcnStatsBootstrap
extends Resource
## [P20] Self-installing hook for the statistics screen.
##
## `game/boot.gd` and `project.godot` are integrator-owned and shared by every
## part, so this one installs itself the way [P13], [P18] and [P19] do: a `.tres`
## in `game/content/ui_stats/`, which `Registry` scans at boot, whose `_init`
## defers an install into the scene tree.
##
## THE FAILURE THIS FILE IS WRITTEN AGAINST. [P18]'s bootstrap called
## `tree.root.add_child()` from inside `boot._ready()`, where the root is still
## propagating NOTIFICATION_READY and Godot refuses the call outright. It printed
## one engine error into a log nobody parsed, set its own `_installed` flag, and
## the entire build UI spent a phase as an orphan while 768 tests stayed green.
##
## So this install does three things that one did not:
##   1. it parents through `add_child.call_deferred` whenever the host would
##      refuse the call, which `is_node_ready()` answers exactly;
##   2. it VERIFIES with `is_inside_tree()` afterwards and logs an error naming
##      the consequence — "P and G will do nothing" — if the node is an orphan;
##   3. it does not latch `_installed` on a failed parent, so a later caller
##      gets a real second attempt instead of a silent null.
##
## Timid in the ways that matter: headless runs install nothing, `--no-view`,
## `--no-ui` and `--no-stats` all disable it, and it stands down if something
## already put a statistics screen in the tree.

@export var id: StringName = &"stats_bootstrap"

static var _installed: bool = false


func _init() -> void:
	if Engine.is_editor_hint():
		return
	_install_deferred.call_deferred()


func _install_deferred() -> void:
	install()


## Idempotent. Returns the screen if one is in the tree afterwards, null if not.
static func install() -> LcnStats:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var existing: Node = tree.get_first_node_in_group(LcnStats.GROUP)
	if existing == null:
		existing = tree.root.get_node_or_null(NodePath("LcnStats"))
	if existing != null:
		_installed = true
		return existing as LcnStats
	if _installed:
		return null
	if not LcnLayers.view_wanted():
		return null
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--no-ui") or args.has("--no-stats"):
		Log.info("ui.stats", "disabled by command line")
		_installed = true
		return null

	var stats := LcnStats.new()
	_parent(tree.root, stats)
	# Deferred parenting has not landed yet at this point, so an orphan here is
	# expected rather than a failure; the verify pass runs a frame later.
	if stats.is_inside_tree():
		_installed = true
		return stats
	_verify_later.call_deferred(stats)
	return null


## Parents WITHOUT tripping "Parent node is busy setting up children".
## `is_node_ready()` is false for exactly the window in which `add_child` would
## be refused, so it is the precise, public test for "would this error now".
static func _parent(host: Node, node: Node) -> void:
	if host.is_node_ready():
		host.add_child(node)
		return
	host.add_child.call_deferred(node)


## One frame after a deferred parent, the node is either in the tree or it is a
## bug. Saying so out loud is the whole lesson of the orphaned build menu.
static func _verify_later(stats: LcnStats) -> void:
	if stats == null or not is_instance_valid(stats):
		return
	if stats.is_inside_tree():
		_installed = true
		return
	Log.error("ui.stats", "the statistics screen could not be parented — "
		+ "P and G will do nothing and no history is being recorded")
	stats.free()


## Tests install and uninstall repeatedly in one process.
static func reset() -> void:
	_installed = false
