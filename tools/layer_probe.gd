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
	for i: int in rows.size():
		for j: int in range(i + 1, rows.size()):
			if int(rows[i]["layer"]) == int(rows[j]["layer"]):
				print("  COLLISION: %s and %s both on layer %d — %s is drawn over %s" % [
					String(rows[i]["name"]), String(rows[j]["name"]),
					int(rows[i]["layer"]), String(rows[j]["name"]), String(rows[i]["name"])])
	get_tree().quit(0)


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
