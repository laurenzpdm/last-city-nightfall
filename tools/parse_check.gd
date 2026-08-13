extends SceneTree
## Compiles every .gd in the project in one engine start and reports the ones
## that fail. Per-file `--check-only` would need one process per script; at
## twenty parts that is a minute of gate time nobody will wait for.
##
##   Godot --headless --path . --script tools/parse_check.gd -- [--roots=game,tests,tools]
##
## Exit codes: 0 everything compiles, 1 something does not.

const DEFAULT_ROOTS: Array[String] = ["res://game", "res://tests", "res://tools"]

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	quit(_execute())
	return true


func _execute() -> int:
	var roots: Array[String] = DEFAULT_ROOTS.duplicate()
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--roots="):
			roots = []
			for r: String in arg.substr(8).split(",", false):
				var trimmed: String = r.strip_edges()
				if trimmed != "":
					roots.append(trimmed if trimmed.begins_with("res://") else "res://" + trimmed)

	var scripts: Array[String] = []
	for root: String in roots:
		_walk(root, scripts)
	scripts.sort()

	var broken: PackedStringArray = PackedStringArray()
	for path: String in scripts:
		if load(path) == null:
			broken.append(path)

	print("parse check: %d script(s) across %s" % [scripts.size(), ", ".join(roots)])
	if broken.is_empty():
		print("PARSE OK")
		return 0
	print("")
	for path: String in broken:
		print("  ✗ %s" % path.replace("res://", ""))
	print("")
	print("PARSE FAILED — %d script(s) do not compile (details in the SCRIPT ERROR lines above)" % broken.size())
	return 1


static func _walk(dir_path: String, out: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	var sub_dirs: Array[String] = []
	for d: String in dir.get_directories():
		if not d.begins_with("."):
			sub_dirs.append(d)
	sub_dirs.sort()
	for d: String in sub_dirs:
		_walk("%s/%s" % [dir_path, d], out)
	for f: String in dir.get_files():
		if f.ends_with(".gd"):
			out.append("%s/%s" % [dir_path, f])
