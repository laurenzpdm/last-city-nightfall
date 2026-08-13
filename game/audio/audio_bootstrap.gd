class_name LcnAudioBootstrap
extends Resource
## [P23] Self-installing hook for the soundtrack.
##
## `game/boot.gd` and `project.godot` are integrator-owned and shared by twenty
## parts, so this part installs itself the way [P13] and [P19] do: a `.tres` in
## `game/content/audio/`, which Registry scans at boot, whose `_init` arms a
## deferred install.
##
## **IT DOES NOT USE `call_deferred`, AND THAT IS THE WHOLE POINT.** Registry's
## scan runs inside an autoload's `_ready`, while the scene tree root is still
## setting up its children, and `root.add_child()` in that window is REFUSED by
## Godot with "Parent node is busy setting up children" — it prints one engine
## error, returns an orphan, and every self-check downstream still passes because
## the object exists and merely is not in the tree. That is exactly how this
## build spent a phase with a build menu nobody could open while the log said
## "view installed". A deferred call is flushed at the engine's convenience and
## can land inside the same window; `SceneTree.process_frame` cannot, because it
## is emitted from the main loop's idle step with nothing under construction.
##
## So: arm on `process_frame`, install once, and then VERIFY `is_inside_tree()`
## and say so in the log either way. An install that cannot prove it landed is
## reported as an error, not assumed.
##
## Timid, in this order:
##   * headless runs install nothing — `tools/check.sh` and the deterministic
##     harness never pay for audio and can never be perturbed by it;
##   * `--no-view`, `--no-audio` and `--mute` each disable it;
##   * something already in the group wins and this stands down.
##
## To replace it, instantiate [LcnAudio] from a real view root and delete
## `game/content/audio/audio_bootstrap.tres`.

@export var id: StringName = &"audio_bootstrap"

static var _installed: bool = false
static var _armed: bool = false
static var _last_failure: String = ""


func _init() -> void:
	if Engine.is_editor_hint():
		return
	arm()


## Waits for a frame in which the tree is idle, then installs exactly once.
static func arm() -> void:
	if _armed or _installed:
		return
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_armed = true
	tree.process_frame.connect(_on_first_frame, CONNECT_ONE_SHOT)


static func _on_first_frame() -> void:
	install()


## Idempotent. Returns the audio root if one is in the tree afterwards, and null
## with a logged reason otherwise. Never returns an orphan.
static func install() -> LcnAudio:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var existing: LcnAudio = tree.get_first_node_in_group(LcnAudio.GROUP) as LcnAudio
	if existing != null:
		_installed = true
		return existing
	if _installed:
		return null
	if not wanted():
		_installed = true
		return null

	var node := LcnAudio.new()
	# Root, not `current_scene`: audio outlives a scene change, and by the time
	# process_frame fires the root has long finished setting up its children.
	var parent: Node = tree.root
	parent.add_child(node)
	if not node.is_inside_tree():
		# Never "probably fine, it will arrive". An orphan that MIGHT land later
		# is the exact state this comment block exists to prevent.
		_last_failure = "add_child was refused by %s" % parent.name
		Log.error("audio", "the soundtrack did NOT install: %s — the game is silent" % _last_failure)
		node.queue_free()
		return null
	_installed = true
	return node


## Should this run have sound at all?
static func wanted() -> bool:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has("--no-audio") or args.has("--mute"):
		Log.info("audio", "disabled by command line")
		return false
	# The same switch [P13], [P17], [P18] and [P19] consult, so `--force-ui`
	# brings up the whole session including its sound and a headless gate run
	# brings up none of it.
	return LcnLayers.view_wanted()


static func installed() -> bool:
	return _installed


static func last_failure() -> String:
	return _last_failure


## Tests install and uninstall repeatedly inside one process.
static func reset() -> void:
	_installed = false
	_armed = false
	_last_failure = ""
