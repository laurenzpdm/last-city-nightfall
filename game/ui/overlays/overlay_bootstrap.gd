class_name LcnOverlayBootstrap
extends Resource
## [P19] Self-installing hook for the readability lenses.
##
## game/boot.gd and project.godot are integrator-owned and shared by twenty
## parts, so this system installs itself the same way [P13]'s renderer does: a
## .tres in game/content/overlays/ that Registry scans at boot, whose _init
## defers an install into the scene tree.
##
## Deliberately timid, in this order:
##   * headless runs are skipped entirely — the deterministic harness and
##     tools/check.sh never pay for an overlay and can never be perturbed by one;
##   * `--no-view` and `--no-overlays` on the command line disable it;
##   * if a root is already in the group it stands down, so the day [P17] owns a
##     real UI root this becomes a no-op instead of a duplicate.
##
## Replace it by instantiating LcnOverlayRoot from a proper UI root and deleting
## game/content/overlays/overlay_bootstrap.tres.

@export var id: StringName = &"overlay_bootstrap"

static var _installed: bool = false


func _init() -> void:
	if Engine.is_editor_hint():
		return
	_install_deferred.call_deferred()


func _install_deferred() -> void:
	install()


## Idempotent. Returns the root if one is in the tree afterwards.
static func install() -> LcnOverlayRoot:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var existing: Node = tree.get_first_node_in_group(LcnOverlayRoot.GROUP)
	if existing != null:
		_installed = true
		return existing as LcnOverlayRoot
	if _installed:
		return null
	if DisplayServer.get_name() == "headless":
		return null
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--no-view") or args.has("--no-overlays"):
		Log.info("overlay", "disabled by command line")
		_installed = true
		return null
	var root := LcnOverlayRoot.new()
	tree.root.add_child(root)
	_installed = true
	return root
