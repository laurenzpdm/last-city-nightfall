class_name LcnMetaBootstrap
extends Resource
## [P24] Self-installing hook for the meta layer.
##
## `game/boot.gd` and `project.godot` are integrator-owned, so this part installs
## itself the way [P13], [P19], [P15] and [P23] already do: a `.tres` under
## `game/content/meta/` that `Registry` scans at boot, whose `_init` defers an
## install into the scene tree. There is nothing to merge and no shared list to
## edit.
##
## Timid, in this order:
##   * a headless run is skipped entirely, so the deterministic harness and
##     `tools/check.sh` never pay for a menu and can never be perturbed by one;
##   * `--no-view` and `--no-meta` on the command line disable it;
##   * if a root is already in the group it stands down, so a second install is
##     a no-op rather than a duplicate menu nobody can close.
##
## The install is VERIFIED: a node that was created and not parented is reported
## as an error naming this part, because "created but orphaned" is the exact
## state that once left a whole build menu unreachable while boot announced
## success.

@export var id: StringName = &"meta_bootstrap"

static var _installed: bool = false


func _init() -> void:
	if Engine.is_editor_hint():
		return
	_install_deferred.call_deferred()


func _install_deferred() -> void:
	var _root: LcnMetaRoot = install()


## Idempotent. Returns the root if one is in the tree afterwards.
static func install() -> LcnMetaRoot:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var existing: Node = tree.get_first_node_in_group(LcnMetaRoot.GROUP)
	if existing != null:
		_installed = true
		return existing as LcnMetaRoot
	if _installed:
		return null
	if not LcnLayers.view_wanted():
		return null
	if OS.get_cmdline_user_args().has("--no-meta"):
		Log.info("meta", "disabled by command line")
		_installed = true
		return null
	var root := LcnMetaRoot.new()
	# Reached only from a deferred call, where the root is not mid-propagation.
	tree.root.add_child(root)
	_installed = true
	if not root.is_inside_tree():
		Log.error("meta", "the meta root could not be parented — there is no pause menu, no settings and no way to save")
		return null
	return root


## Tests tear the tree down and rebuild it; without this the second install
## silently declines and the suite tests nothing.
static func forget() -> void:
	_installed = false
