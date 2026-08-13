extends SceneTree
## Determinism replay checker — the tripwire the whole project rests on.
##
##   Godot --headless --path . --script tools/json_diff.gd -- \
##       --a=artifacts/det_a/state.json --b=artifacts/det_b/state.json \
##       [--ignore=wall_ms] [--max=20] [--quiet]
##
## Compares two harness state dumps and reports the FIRST divergent key path,
## which is the one piece of information that turns "the replay broke" into
## "threat.next_spawn_tick moved by one".
##
## Two comparisons run, because they fail in different ways:
##   1. hash of the normalized text — catches anything, including differences
##      too small for a double to represent after a JSON round trip;
##   2. structural diff of the parsed data — says WHERE.
## If (1) differs and (2) finds nothing, the divergence is below JSON precision
## and that is reported as such rather than swept away.
##
## Exit codes: 0 identical, 2 usage/IO error, 3 divergent.

const DEFAULT_IGNORE: String = "wall_ms"

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	quit(_execute())
	return true


func _execute() -> int:
	var a_path: String = ""
	var b_path: String = ""
	var ignore_csv: String = DEFAULT_IGNORE
	var limit: int = 20
	var quiet: bool = false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--a="):
			a_path = arg.substr(4)
		elif arg.begins_with("--b="):
			b_path = arg.substr(4)
		elif arg.begins_with("--ignore="):
			ignore_csv = arg.substr(9)
		elif arg.begins_with("--max="):
			limit = maxi(1, int(arg.substr(6)))
		elif arg == "--quiet":
			quiet = true

	if a_path == "" or b_path == "":
		print("usage: --a=<state.json> --b=<state.json> [--ignore=k1,k2] [--max=N] [--quiet]")
		return 2

	var canon_script: Script = load("res://tests/framework/json_canon.gd") as Script
	if canon_script == null:
		print("determinism: cannot load tests/framework/json_canon.gd")
		return 2

	var ignore: PackedStringArray = PackedStringArray()
	for key: String in ignore_csv.split(",", false):
		var trimmed: String = key.strip_edges()
		if trimmed != "":
			ignore.append(trimmed)

	var a_raw: Variant = canon_script.call("load_file", a_path)
	var b_raw: Variant = canon_script.call("load_file", b_path)
	if a_raw == null:
		print("determinism: cannot read %s" % a_path)
		return 2
	if b_raw == null:
		print("determinism: cannot read %s" % b_path)
		return 2

	var a: Variant = canon_script.call("strip", a_raw, ignore)
	var b: Variant = canon_script.call("strip", b_raw, ignore)
	var a_hash: String = canon_script.call("hash_of", a)
	var b_hash: String = canon_script.call("hash_of", b)
	var identical: bool = a_hash == b_hash
	var diff: PackedStringArray = canon_script.call("diff", a, b, PackedStringArray(), limit, 0.0)

	if identical and diff.is_empty():
		if not quiet:
			print("determinism: IDENTICAL   sha256 %s   (%d top-level keys, ignoring %s)" % [
				a_hash.substr(0, 16), _size_of(a), ", ".join(ignore)])
		return 0

	print("")
	print("═══ DETERMINISM BROKEN ═══")
	print("  a: %s   sha256 %s" % [a_path, a_hash.substr(0, 16)])
	print("  b: %s   sha256 %s" % [b_path, b_hash.substr(0, 16)])
	print("")
	if diff.is_empty():
		print("  The two states hash differently but every parsed value matches.")
		print("  The divergence is finer than JSON can express — compare the raw")
		print("  files, and suspect a 64-bit integer (an id, a hash, an Rng state)")
		print("  being written where a double cannot hold it.")
		return 3
	print("  FIRST DIVERGENCE")
	print("    %s" % diff[0])
	if diff.size() > 1:
		print("")
		print("  %d more divergent path(s):" % (diff.size() - 1))
		for i: int in range(1, diff.size()):
			print("    %s" % diff[i])
	print("")
	print("  A replay that differs means something in game/sim/** read the wall")
	print("  clock, a frame delta, raw randf(), unsorted dictionary order, or")
	print("  input. Run tools/lint_sim.sh, then bisect on the system named above.")
	return 3


func _size_of(v: Variant) -> int:
	match typeof(v):
		TYPE_DICTIONARY:
			return (v as Dictionary).size()
		TYPE_ARRAY:
			return (v as Array).size()
		_:
			return 1
