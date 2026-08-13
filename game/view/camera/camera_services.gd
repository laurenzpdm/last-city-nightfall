class_name CameraServices
extends RefCounted
## Late-bound access to the core autoloads (Log, Bus, Settings, Sim, SimClock).
##
## Why not just write `Log.info(...)`: the autoload global identifiers only exist once
## the SceneTree has installed them, so any script that names one cannot be compiled by
## a headless runner started with `--script`. Resolving the node by name at call time
## costs a dictionary lookup and keeps every file in game/view/camera/ loadable from a
## bare test process, which is exactly where camera maths wants to be tested.
##
## This is a lookup shim, not a second contract: it forwards to the real autoloads and
## degrades to a no-op when they are absent.

static var _cache: Dictionary[StringName, Node] = {}


## The autoload node, or null when running without a SceneTree.
static func node(autoload_name: StringName) -> Node:
	var cached: Node = _cache.get(autoload_name)
	if cached != null and is_instance_valid(cached):
		return cached
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var found: Node = tree.root.get_node_or_null(NodePath(autoload_name))
	if found != null:
		_cache[autoload_name] = found
	return found


## Tests swap autoloads in and out; drop the memoised nodes when they do.
static func reset_cache() -> void:
	_cache.clear()


# --- Log ----------------------------------------------------------------------

static func log_info(tag: String, msg: String) -> void:
	_log(&"info", tag, msg)


static func log_warn(tag: String, msg: String) -> void:
	_log(&"warn", tag, msg)


static func log_error(tag: String, msg: String) -> void:
	_log(&"error", tag, msg)


static func log_debug(tag: String, msg: String) -> void:
	_log(&"debug", tag, msg)


static func _log(level: StringName, tag: String, msg: String) -> void:
	var n: Node = node(&"Log")
	if n == null:
		return
	n.call(level, tag, msg)


# --- Settings -----------------------------------------------------------------

static func setting(section: String, key: String, fallback: Variant) -> Variant:
	var n: Node = node(&"Settings")
	if n == null:
		return fallback
	return n.call(&"get_value", section, key, fallback)


static func setting_float(section: String, key: String, fallback: float) -> float:
	var v: Variant = setting(section, key, fallback)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return fallback


static func setting_bool(section: String, key: String, fallback: bool) -> bool:
	var v: Variant = setting(section, key, fallback)
	if typeof(v) == TYPE_BOOL:
		return bool(v)
	return fallback


static func settings_node() -> Node:
	return node(&"Settings")


# --- Bus ----------------------------------------------------------------------

static func connect_bus(sig: StringName, target: Callable) -> void:
	var b: Node = node(&"Bus")
	if b == null or not b.has_signal(sig):
		return
	if not b.is_connected(sig, target):
		b.connect(sig, target)


static func disconnect_bus(sig: StringName, target: Callable) -> void:
	var b: Node = node(&"Bus")
	if b == null or not b.has_signal(sig):
		return
	if b.is_connected(sig, target):
		b.disconnect(sig, target)


static func emit_bus(sig: StringName, args: Array) -> void:
	var b: Node = node(&"Bus")
	if b == null or not b.has_signal(sig):
		return
	var call_args: Array = [sig]
	call_args.append_array(args)
	b.callv(&"emit_signal", call_args)


# --- Sim / SimClock -----------------------------------------------------------

## The only channel from view to sim. View never writes sim state directly.
static func submit_command(cmd: Dictionary) -> void:
	var n: Node = node(&"Sim")
	if n == null:
		log_warn("camera", "no Sim autoload; command dropped: %s" % str(cmd.get("system", "?")))
		return
	n.call(&"submit_command", cmd)


static func sim_system(system_name: StringName) -> Object:
	var n: Node = node(&"Sim")
	if n == null:
		return null
	var v: Variant = n.call(&"get_system", system_name)
	return v as Object


static func set_sim_speed(speed: float) -> void:
	var n: Node = node(&"SimClock")
	if n == null:
		return
	n.set(&"speed", speed)
	if speed <= 0.0:
		n.call(&"pause")
	else:
		n.call(&"start")


static func sim_speed() -> float:
	var n: Node = node(&"SimClock")
	if n == null:
		return 1.0
	return float(n.get(&"speed"))


static func sim_running() -> bool:
	var n: Node = node(&"SimClock")
	if n == null:
		return false
	return bool(n.get(&"running"))


static func set_sim_running(on: bool) -> void:
	var n: Node = node(&"SimClock")
	if n == null:
		return
	n.call(&"start" if on else &"pause")
