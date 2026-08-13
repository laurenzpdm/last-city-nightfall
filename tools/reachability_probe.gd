extends Node
## Boots the real game and writes down what is ACTUALLY in the scene tree.
##
##   Godot --path . tools/reachability_scene.tscn -- --out=artifacts/gate/reach [--frames=60]
##
## Run as a SCENE, never with --script, and it adds game/boot.tscn as its own
## child from inside its own _ready(). Both details are load-bearing:
##
##   * as a scene it is the main scene, so the autoloads exist and the window
##     root propagates NOTIFICATION_READY exactly the way it does in a real
##     launch;
##   * adding Boot from _ready() means Boot's own _ready() runs while the root
##     is still busy setting up children — `tree.root.data.blocked == 1`. That
##     is the precise window in which `tree.root.add_child()` is refused, and
##     it is how [P18]'s build menu became an orphan while the log claimed
##     "view installed: ... build menu ..." and tools/check.sh reported green.
##     A probe that instantiated Boot from _process() would find root unblocked,
##     every add_child would succeed, and the probe would certify a bug it was
##     written to catch.
##
## It asserts nothing. It writes reachability.json — what is in the tree, what
## Boot is still holding that never made it into the tree, how many orphan nodes
## the engine is tracking, and every line the boot sequence logged. The
## assertions live in tools/check_reachability.py against tests/gate/reachability.json,
## so the contract can change without touching the probe and vice versa.

const BOOT_SCENE: String = "res://game/boot.tscn"
const MAX_NODES: int = 30000

var _frames_to_wait: int = 60
var _out_dir: String = "artifacts/gate/reach"
var _frame: int = 0
var _boot: Node = null
var _done: bool = false


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out_dir = a.substr(6)
		elif a.begins_with("--frames="):
			_frames_to_wait = maxi(2, int(a.substr(9)))
	Log.capture = true
	Log.min_level = Log.Level.DEBUG
	if not ResourceLoader.exists(BOOT_SCENE):
		push_error("reachability: no %s" % BOOT_SCENE)
		get_tree().quit(2)
		return
	var packed: PackedScene = load(BOOT_SCENE) as PackedScene
	_boot = packed.instantiate()
	# Boot hangs one level below the root here, where a real launch has it AS the
	# root's scene. That is the single fidelity gap and it is the strict
	# direction: `tree.current_scene` is this probe rather than Boot, so an
	# installer that reaches for the current scene lands beside Boot instead of
	# under it — still in the tree, still reachable, which is the only question
	# this probe answers. (Assigning `current_scene` to close the gap is not an
	# option: the engine refuses a current_scene whose parent is not the root,
	# and a probe that prints its own engine error has no business grading one.)
	# Deliberately NOT call_deferred: the whole point is to run Boot's _ready
	# inside the root's ready propagation, which is the condition under test.
	add_child(_boot)


func _process(_delta: float) -> void:
	if _done:
		return
	_frame += 1
	if _frame < _frames_to_wait:
		return
	_done = true
	_write(_collect())
	get_tree().quit(0)


func _collect() -> Dictionary:
	var nodes: Array[Dictionary] = []
	var layers: Array[Dictionary] = []
	_walk(get_tree().root, nodes, layers)
	return {
		"display": DisplayServer.get_name(),
		"frames": _frame,
		"headless": DisplayServer.get_name() == "headless",
		"node_count": nodes.size(),
		"orphan_nodes": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"nodes": nodes,
		"canvas_layers": layers,
		"held": _held_by(_boot),
		"log": Log.drain(),
		"log_errors": Log.errors,
		"log_warnings": Log.warnings,
		"sim_alive": bool(Sim.alive),
		"sim_systems": _system_names(),
	}


func _walk(node: Node, nodes: Array[Dictionary], layers: Array[Dictionary]) -> void:
	if nodes.size() >= MAX_NODES:
		return
	var scr: Script = node.get_script() as Script
	var groups: Array[String] = []
	for g: StringName in node.get_groups():
		groups.append(String(g))
	groups.sort()
	var entry: Dictionary = {
		"path": String(node.get_path()),
		"name": node.name,
		"class": node.get_class(),
		"script": scr.resource_path if scr != null else "",
		"groups": groups,
	}
	var ci := node as CanvasItem
	if ci != null:
		entry["visible"] = ci.visible
	var cl := node as CanvasLayer
	if cl != null:
		entry["layer"] = cl.layer
		layers.append({
			"path": String(node.get_path()),
			"name": node.name,
			"layer": cl.layer,
			"script": scr.resource_path if scr != null else "",
			"visible": cl.visible,
		})
	nodes.append(entry)
	for child: Node in node.get_children():
		_walk(child, nodes, layers)


## Every Node-valued property the Boot node still holds, and whether it ever
## reached the tree. A non-null reference that is not inside the tree is the
## definition of the failure this part exists to catch: the object was built,
## the log said so, and the player can never touch it.
func _held_by(owner_node: Node) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if owner_node == null:
		return out
	for prop: Dictionary in owner_node.get_property_list():
		if int(prop.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var name: String = String(prop.get("name", ""))
		var value: Variant = owner_node.get(name)
		# `value as Node` on an int is a hard SCRIPT ERROR in 4.7, not a null, so
		# the type is checked first. A probe that raises the class of error it
		# reports on is worthless.
		if typeof(value) != TYPE_OBJECT:
			if value == null:
				out.append({"field": name, "state": "null", "class": "", "path": ""})
			continue
		var as_node: Node = value as Node
		if as_node == null:
			continue
		out.append({
			"field": name,
			"state": "in_tree" if as_node.is_inside_tree() else "ORPHAN",
			"class": as_node.get_class(),
			"script": (as_node.get_script() as Script).resource_path if as_node.get_script() != null else "",
			"path": String(as_node.get_path()) if as_node.is_inside_tree() else "",
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["field"]) < String(b["field"]))
	return out


func _system_names() -> Array[String]:
	var out: Array[String] = []
	for s: SimSystem in Sim.systems:
		out.append(String(s.system_name()))
	out.sort()
	return out


func _write(payload: Dictionary) -> void:
	var dir: String = _out_dir if _out_dir.begins_with("res://") else "res://" + _out_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path: String = dir + "/reachability.json"
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("reachability: cannot write %s" % path)
		return
	f.store_string(JSON.stringify(payload, "  ", true, true))
	f.close()
	print("reachability: wrote %s (%d nodes, %d orphans)" % [
		path, int(payload["node_count"]), int(payload["orphan_nodes"])])
