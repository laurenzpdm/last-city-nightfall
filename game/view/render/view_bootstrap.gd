class_name LcnViewBootstrap
extends Resource
## Self-installing hook for the world renderer. [P13]
##
## The renderer has to be in the scene tree for anything to be visible, but
## game/boot.gd and project.godot are integrator-owned and shared by every part,
## so [P13] cannot add itself there without racing twenty other agents for the
## same two lines. Instead this resource lives in game/content/view/, which
## Registry scans at boot, and installs the renderer from inside its own folder.
##
## It is deliberately timid:
##   * headless runs are skipped entirely, so the deterministic sim harness and
##     tools/check.sh never pay a rendering cost and can never be perturbed;
##   * `--no-view` on the command line disables it;
##   * if anything already put a WorldRenderer in the tree it stands down, so
##     the day a real view root exists this becomes a no-op instead of a
##     duplicate.
##
## Replace it by instantiating res://game/view/render/world_renderer.tscn from a
## proper view root and deleting game/content/view/render_bootstrap.tres.

const SCENE: String = "res://game/view/render/world_renderer.tscn"

@export var id: StringName = &"render_bootstrap"

static var _installed: bool = false


func _init() -> void:
	if Engine.is_editor_hint():
		return
	_install_deferred.call_deferred()


func _install_deferred() -> void:
	install()


## Idempotent. Returns the renderer if one is in the tree afterwards.
static func install() -> WorldRenderer:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var existing: Node = tree.get_first_node_in_group(WorldRenderer.GROUP)
	if existing != null:
		_installed = true
		return existing as WorldRenderer
	if _installed:
		return null
	if not LcnLayers.view_wanted():
		return null
	if not ResourceLoader.exists(SCENE):
		Log.error("render", "world_renderer.tscn missing at %s" % SCENE)
		return null
	var packed: PackedScene = load(SCENE)
	var node: Node = packed.instantiate()
	tree.root.add_child(node)
	_installed = true
	if not node.is_inside_tree():
		Log.error("render", "the world renderer could not be parented — nothing is visible")
		return null
	return node as WorldRenderer
