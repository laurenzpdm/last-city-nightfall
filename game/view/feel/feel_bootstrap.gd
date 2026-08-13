class_name LcnFeelBootstrap
extends Resource
## Self-installing hook for the feel layer. [P15]
##
## `game/boot.gd` and `project.godot` are integrator-owned and shared by every
## part, so [P15] cannot add itself there without racing twenty other agents for
## the same two lines. This resource lives in `game/content/feel/`, which
## Registry scans at boot, and installs the layer from inside its own folder —
## the same pattern [P13], [P18] and [P19] use.
##
## It is deliberately timid, and every guard below is a bug this build has
## already had:
##
##   * it installs DEFERRED and parents to a node that is already in the tree.
##     `tree.root.add_child()` from inside a `_ready` is refused by Godot with
##     "parent node is busy setting up children" and leaves an orphan — that one
##     line cost this build its entire build menu for a phase;
##   * it VERIFIES `is_inside_tree()` afterwards and logs an ERROR naming itself
##     if the node did not land, rather than reporting success and drawing
##     nothing;
##   * headless runs skip it, so `tools/check.sh` and the deterministic harness
##     pay no rendering cost and cannot be perturbed. `--force-ui` (LcnLayers)
##     overrides that for the reachability and gallery suites;
##   * if a feel layer is already in the tree it stands down, so the day boot
##     installs [P15] explicitly this becomes a no-op instead of a second copy.

@export var id: StringName = &"feel_bootstrap"

static var _installed: bool = false


func _init() -> void:
	if Engine.is_editor_hint():
		return
	_install_deferred.call_deferred()


func _install_deferred() -> void:
	install()


## Idempotent. Returns the feel layer if one is in the tree afterwards.
static func install() -> LcnFeel:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var existing: Node = tree.get_first_node_in_group(LcnFeel.GROUP)
	if existing != null:
		_installed = true
		return existing as LcnFeel
	if _installed:
		return null
	if not LcnLayers.view_wanted():
		return null
	var parent: Node = tree.current_scene
	if parent == null or not parent.is_inside_tree():
		parent = tree.root
	if parent == null:
		return null
	var feel := LcnFeel.new()
	parent.add_child(feel)
	if not feel.is_inside_tree():
		Log.error("feel", "the feel layer failed to enter the tree — no juice, no shake, no nightfall")
		feel.free()
		return null
	_installed = true
	return feel


## Test seam: forget that anything was installed. Never call this from the game.
static func reset_for_tests() -> void:
	_installed = false
