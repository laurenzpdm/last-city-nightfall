extends Node
## Structured, level-filtered logging. Harness-capturable.
## The only logging any part should use. print() is banned in game/sim/**.

enum Level { TRACE, DEBUG, INFO, WARN, ERROR }

var min_level: Level = Level.INFO
var capture: bool = false
## Monotonic counts since process start. The harness gates a run on `errors`:
## a Log.error inside a sim system has to be able to turn a run red, otherwise
## the max_errors contract in every scenario is decoration.
var errors: int = 0
var warnings: int = 0
var _lines: PackedStringArray = PackedStringArray()

const _NAMES: Array[String] = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"]


func trace(tag: String, msg: String) -> void:
	_emit(Level.TRACE, tag, msg)


func debug(tag: String, msg: String) -> void:
	_emit(Level.DEBUG, tag, msg)


func info(tag: String, msg: String) -> void:
	_emit(Level.INFO, tag, msg)


func warn(tag: String, msg: String) -> void:
	_emit(Level.WARN, tag, msg)


func error(tag: String, msg: String) -> void:
	_emit(Level.ERROR, tag, msg)


## Returns everything captured since capture was enabled.
func drain() -> PackedStringArray:
	var out: PackedStringArray = _lines.duplicate()
	_lines = PackedStringArray()
	return out


func _emit(lvl: Level, tag: String, msg: String) -> void:
	if lvl < min_level:
		return
	if lvl == Level.ERROR:
		errors += 1
	elif lvl == Level.WARN:
		warnings += 1
	var tick: int = SimClock.tick if is_instance_valid(SimClock) else -1
	var line: String = "[%s][t%06d][%s] %s" % [_NAMES[lvl], tick, tag, msg]
	if capture:
		_lines.append(line)
	if lvl >= Level.WARN:
		printerr(line)
	else:
		print(line)
