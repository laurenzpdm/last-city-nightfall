class_name LcnBuildMenuBootstrap
extends Resource
## [P18] Self-installing hook for the build UI.
##
## `game/boot.gd` and `project.godot` are integrator-owned and shared by every
## part, so [P18] cannot add itself there without racing eleven other agents for
## the same two lines. This resource lives in `game/content/ui_build_menu/`,
## which Registry scans at boot, and installs the UI from inside its own folder —
## the same pattern [P13] uses for the renderer.
##
## Timid on purpose:
##   * headless runs (tools/check.sh, the deterministic harness) install nothing,
##     so the sim gate never pays a UI cost and can never be perturbed by one;
##   * `--no-view` and `--no-ui` both disable it;
##   * if something already put a build menu in the tree it stands down.
##
## To replace it, instantiate `LcnBuildMenu` from a real UI root and delete
## `game/content/ui_build_menu/build_menu.tres`.

@export var id: StringName = &"build_menu_bootstrap"

static var _installed: bool = false


func _init() -> void:
	if Engine.is_editor_hint():
		return
	_install_deferred.call_deferred()


func _install_deferred() -> void:
	install()


## Idempotent. Returns the menu if one is in the tree afterwards.
static func install() -> LcnBuildMenu:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var existing: Node = tree.root.get_node_or_null(NodePath("LcnBuildMenu"))
	if existing == null:
		existing = tree.get_first_node_in_group(LcnBuildMenu.GROUP)
	if existing != null:
		_installed = true
		return existing as LcnBuildMenu
	if _installed:
		return null
	if DisplayServer.get_name() == "headless":
		return null
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--no-view") or args.has("--no-ui"):
		Log.info("ui.build_menu", "disabled by command line")
		_installed = true
		return null
	var menu := LcnBuildMenu.new()
	tree.root.add_child(menu)
	_installed = true
	return menu


## Tests install and uninstall repeatedly in one process.
static func reset() -> void:
	_installed = false
