class_name TestEnv
extends RefCounted
## Runtime access to the core autoloads.
##
## `godot --script foo.gd` compiles foo.gd BEFORE the autoloads are registered,
## so a bootstrap script cannot name `Log` or `Sim` at compile time. Everything
## in the framework goes through here instead, which also means a tool can run
## in a stripped environment and degrade gracefully instead of crashing.

## Mirrors Log.Level. Kept as plain ints because Log is fetched by node path.
const LOG_TRACE: int = 0
const LOG_DEBUG: int = 1
const LOG_INFO: int = 2
const LOG_WARN: int = 3
const LOG_ERROR: int = 4

const REQUIRED: Array[String] = [
	"Log", "Rng", "Registry", "Bus", "Sim", "SimClock", "Settings", "Harness",
]


static func tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## The autoload node, or null if this process was started without autoloads.
static func autoload(n: String) -> Node:
	var t: SceneTree = tree()
	if t == null or t.root == null:
		return null
	return t.root.get_node_or_null(NodePath("/root/" + n))


static func sim() -> Node:
	return autoload("Sim")


static func clock() -> Node:
	return autoload("SimClock")


static func rng() -> Node:
	return autoload("Rng")


static func bus() -> Node:
	return autoload("Bus")


static func registry() -> Node:
	return autoload("Registry")


static func logger() -> Node:
	return autoload("Log")


## Names of the autoloads that are missing. Empty means the environment is sane.
static func missing() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for n: String in REQUIRED:
		if autoload(n) == null:
			out.append(n)
	return out


static func set_log_level(level: int) -> void:
	var lg: Node = logger()
	if lg != null:
		lg.set("min_level", level)


## Runs `action` with the log captured and returns every line it produced.
## Log.drain() is destructive and has no push-back, so anything already buffered
## when this is called is discarded — the runner keeps capture off between tests
## precisely so that never costs anyone a log line.
static func capture_log(action: Callable, level: int = LOG_TRACE) -> PackedStringArray:
	var lg: Node = logger()
	if lg == null:
		action.call()
		return PackedStringArray()
	var prev_capture: bool = bool(lg.get("capture"))
	var prev_level: int = int(lg.get("min_level"))
	lg.call("drain")
	lg.set("capture", true)
	lg.set("min_level", level)
	action.call()
	var produced: PackedStringArray = lg.call("drain")
	lg.set("capture", prev_capture)
	lg.set("min_level", prev_level)
	return produced


## Systems this build actually contains, probed once by TestRunner against a
## throwaway world. A suite must be able to ask "is [P02] built yet?" without a
## world of its own, which is exactly when has_system() would lie.
static var built_systems: PackedStringArray = PackedStringArray()


## True when the world currently in memory has a system under this name.
static func has_system(n: StringName) -> bool:
	var s: Node = sim()
	if s == null:
		return false
	return s.call("get_system", n) != null


## True when this build contains the part at all, world or no world.
static func system_is_built(n: StringName) -> bool:
	return built_systems.has(String(n)) or has_system(n)


## System names present in the currently-created world, sorted.
static func system_names() -> PackedStringArray:
	var s: Node = sim()
	var out: PackedStringArray = PackedStringArray()
	if s == null:
		return out
	var by_name: Dictionary = s.get("by_name")
	var keys: Array = by_name.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return String(a) < String(b))
	for k: Variant in keys:
		out.append(String(k))
	return out
