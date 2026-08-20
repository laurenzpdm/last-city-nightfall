class_name LcnItemsBootstrap
extends Resource
## [D2] Self-installing hook for the belt-item view.
##
## `game/boot.gd` and `project.godot` are integrator-owned and shared by every
## part, so this one installs itself the way [P13], [P15], [P18] and [P19] do: a
## `.tres` in `game/content/items_view/`, which `Registry` scans at boot, whose
## `_init` defers an install into the scene tree.
##
## Every guard below is a bug this build has already shipped once
## (docs/HANDOFF.md, rule 3):
##
##   * it installs DEFERRED and parents to a node that is ALREADY in the tree.
##     `add_child()` from inside another node's `_ready` is refused with "parent
##     node is busy setting up children" and leaves an orphan — that is how the
##     build menu spent a phase existing and drawing nothing;
##   * it VERIFIES `is_inside_tree()` afterwards and logs an ERROR naming itself
##     if the node did not land, instead of returning a node it never parented.
##     The harness counts orphan nodes at the end of every run, so a silent
##     failure here fails the run rather than producing empty screenshots;
##   * headless runs are skipped, so `tools/check.sh` and the deterministic
##     harness pay nothing and cannot be perturbed. `--force-ui` overrides that
##     for the reachability and frame suites — `LcnLayers.view_wanted()` is the
##     one switch and this part does not invent a second one;
##   * `--no-items` disables it on its own, which is the bisect switch that
##     separates "the script loaded" from "the node is in the tree";
##   * if a root is already in the group it stands down, so the day boot installs
##     this explicitly it becomes a no-op instead of a second copy drawing every
##     item twice.

@export var id: StringName = &"items_bootstrap"

static var _installed: bool = false


func _init() -> void:
	if Engine.is_editor_hint():
		return
	_install_deferred.call_deferred()


func _install_deferred() -> void:
	install()


## Idempotent. Returns the item-flow root if one is in the tree afterwards.
static func install() -> LcnItemFlowRoot:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var existing: Node = tree.get_first_node_in_group(LcnItemFlowRoot.GROUP)
	if existing != null:
		_installed = true
		return existing as LcnItemFlowRoot
	if _installed:
		return null
	if not LcnLayers.view_wanted():
		return null
	if OS.get_cmdline_user_args().has("--no-items"):
		Log.info("items", "disabled by command line — belts will carry nothing visible")
		_installed = true
		return null

	# Parented to a node that is already settled, never to one mid-_ready.
	var parent: Node = tree.current_scene
	if parent == null or not parent.is_inside_tree():
		parent = tree.root
	if parent == null:
		return null
	var root := LcnItemFlowRoot.new()
	parent.add_child(root)
	_installed = true
	if not root.is_inside_tree():
		Log.error("items", "the item layer could not be parented — every belt in the city will look empty")
		root.free()
		return null
	Log.info("items", "installed on the world canvas (layer %d), z %d/%d/%d — belts, items, arms" % [
		LcnLayers.WORLD, LcnItemFlowRoot.Z_BELTS, LcnItemFlowRoot.Z_ITEMS,
		LcnItemFlowRoot.Z_MACHINES])
	return root


## Test seam: forget that anything was installed. Never call this from the game.
static func reset_for_tests() -> void:
	_installed = false
