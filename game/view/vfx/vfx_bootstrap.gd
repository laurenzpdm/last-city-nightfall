class_name LcnVfxBootstrap
extends Resource
## Self-installing hook for the effects layer. [P14]
##
## `game/boot.gd` is integrator-owned and twenty parts cannot queue for the same
## two lines in it, so this resource lives in `game/content/vfx/`, which
## [Registry] scans at boot, and installs the layer from inside its own folder.
##
## IT DOES NOT ADD ITSELF TO THE SCENE ROOT. That is the whole design of this
## file, and it is a direct answer to the defect a critic found in this build:
##
##     ERROR: Parent node is busy setting up children, `add_child()` failed.
##
## `tree.root` is still assembling its children while the main scene's `_ready`
## runs, and an `add_child()` on it in that window fails — silently, as far as
## the gate was concerned, because the harness counts `Log.errors` and an engine
## error is not one of those. So this parents itself to the [WorldRenderer]
## instead, which is where world-space effects belong anyway, and it will not
## touch the tree at all until that node reports `is_inside_tree()`. If the
## renderer is not there yet it waits on a timer and tries again, up to
## MAX_ATTEMPTS, and then says so in the log rather than failing quietly.
##
## It is otherwise as timid as [LcnViewBootstrap]:
##   * a headless run installs nothing, so the deterministic harness and
##     tools/check.sh never pay for particles and can never be perturbed;
##   * `--no-view` and `--no-vfx` both disable it;
##   * if something already put an [LcnVfx] in the tree it stands down.

## Retries before giving up on finding a renderer to hang off.
const MAX_ATTEMPTS: int = 40
## Seconds between retries.
const RETRY_SECONDS: float = 0.1

@export var id: StringName = &"vfx_bootstrap"

static var _installed: bool = false
static var _attempts: int = 0
static var _gave_up: bool = false


func _init() -> void:
	if Engine.is_editor_hint():
		return
	_try.call_deferred()


func _try() -> void:
	if install() != null or _gave_up:
		return
	_attempts += 1
	if _attempts >= MAX_ATTEMPTS:
		_gave_up = true
		# ERROR, not warn. An effects layer that never installed is exactly the
		# class of failure this build has already shipped once: a whole part
		# built, tested and invisible, with a green gate over it.
		Log.error("vfx", "no WorldRenderer appeared after %d attempts — the effects layer is NOT in the scene"
			% MAX_ATTEMPTS)
		return
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var t: SceneTreeTimer = tree.create_timer(RETRY_SECONDS)
	t.timeout.connect(_try)


## Idempotent. Returns the effects layer if one is in the tree afterwards, and
## null if this build should not have one (headless, opted out) or if the
## renderer is not ready to parent it yet.
static func install() -> LcnVfx:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var existing: Node = tree.get_first_node_in_group(LcnVfx.GROUP)
	if existing != null:
		_installed = true
		return existing as LcnVfx
	if _installed:
		return null
	if DisplayServer.get_name() == "headless":
		_installed = true
		return null
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--no-view") or args.has("--no-vfx"):
		Log.info("vfx", "--no-vfx: effects layer not installed")
		_installed = true
		return null

	var renderer: WorldRenderer = tree.get_first_node_in_group(WorldRenderer.GROUP) as WorldRenderer
	if renderer == null or not renderer.is_inside_tree():
		return null
	# The renderer is in the tree and its own _ready has run, so this add_child
	# lands on a settled parent. Nothing here ever touches tree.root.
	var node: LcnVfx = LcnVfx.new()
	renderer.add_child(node)
	_installed = true
	return node


## Test hook. Lets a suite install a second layer into a fresh scene without the
## static latch from a previous world blocking it.
static func reset() -> void:
	_installed = false
	_attempts = 0
	_gave_up = false
