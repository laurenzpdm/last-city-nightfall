extends Node
## INTEGRATOR PROBE. Boots the real game with a view and prints, in draw order,
## every CanvasLayer that is actually in the tree — layer number, tree index and
## whether `LcnLayers` has a row for it.
##
##   godot --path . res://tools/layer_probe.tscn -- --force-ui
##
## Two parts can each be internally consistent and still both take layer 80. The
## table cannot see that on its own: `enforce()` only corrects a layer that
## DISAGREES with the table, and two parts that agree with the same row agree
## with each other right up until one of them is drawn over the other. This
## prints the tie-break that actually decides it — sibling order in the tree.

const SETTLE_FRAMES: int = 8


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var boot: PackedScene = load("res://game/boot.tscn") as PackedScene
	if boot == null:
		print("layer probe: no boot scene")
		get_tree().quit(2)
		return
	var node: Node = boot.instantiate()
	get_tree().root.add_child(node)
	for _i: int in SETTLE_FRAMES:
		await get_tree().process_frame

	var found: Array[CanvasLayer] = []
	_collect(get_tree().root, found)
	var rows: Array[Dictionary] = []
	for cl: CanvasLayer in found:
		rows.append({
			"name": String(cl.name),
			"layer": cl.layer,
			"index": cl.get_index(),
			"parent": String(cl.get_parent().name) if cl.get_parent() != null else "-",
			"known": _known(cl.name),
			"visible": cl.visible,
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["layer"]) != int(b["layer"]):
			return int(a["layer"]) < int(b["layer"])
		return int(a["index"]) < int(b["index"]))
	print("LAYER PROBE — %d canvas layer(s), painted bottom to top" % rows.size())
	for r: Dictionary in rows:
		print("  layer %3d  idx %3d  %-22s parent=%-16s table=%s visible=%s" % [
			int(r["layer"]), int(r["index"]), String(r["name"]), String(r["parent"]),
			"yes" if bool(r["known"]) else "NO ROW", str(r["visible"])])

	# Same layer + later in the tree = drawn on top. Name every such pair.
	var bad: int = 0
	for i: int in rows.size():
		for j: int in range(i + 1, rows.size()):
			if int(rows[i]["layer"]) == int(rows[j]["layer"]):
				bad += 1
				print("  COLLISION: %s and %s both on layer %d — %s is drawn over %s" % [
					String(rows[i]["name"]), String(rows[j]["name"]),
					int(rows[i]["layer"]), String(rows[j]["name"]), String(rows[i]["name"])])

	# RANK, not just collision. Two parts on two different numbers never collide
	# and can still be in the wrong order: [P22]'s card sat alone on 78, agreed
	# with the table, collided with nothing, and covered the cost column of every
	# building in [P18]'s palette in six of six `artifacts/ui_tour` frames. The
	# probe printed a clean table for that build. It does not any more.
	for line: String in LcnLayers.table_violations():
		bad += 1
		print("  RANK: " + line)
	for row: Dictionary in LcnLayers.violations(get_tree()):
		if row.get("node") == null:
			continue   # a table row — already printed above, from the table alone
		bad += 1
		print("  VIOLATION: %s (%s) at layer %d — %s" % [
			String(row.get("key", "?")), String(row.get("owner", "?")),
			int(row.get("actual", -1)), String(row.get("why", "violates the table"))])

	print("LAYER PROBE — %s" % ("the stack is ordered" if bad == 0
		else "%d problem(s) above" % bad))
	get_tree().quit(1 if bad > 0 else 0)


func _known(n: StringName) -> bool:
	for slot: Dictionary in LcnLayers.SLOTS:
		for candidate: String in (slot["names"] as Array):
			if candidate == String(n):
				return true
	return false


func _collect(node: Node, out: Array[CanvasLayer]) -> void:
	var cl := node as CanvasLayer
	if cl != null:
		out.append(cl)
	for child: Node in node.get_children():
		_collect(child, out)
