class_name ResearchGraph
extends RefCounted
## The tech tree as an actual directed acyclic graph, plus the one-time layout
## [P18] draws it from.
##
## Everything in here is derived ONCE at world creation and then read. The tree
## does not change shape at runtime — what changes is which nodes are done — so
## depth, topological order, dependents and the grid layout are computed in
## build() and never recomputed on a tick.
##
## Determinism: every traversal iterates sorted id arrays. Two builds of the same
## content produce the same order, the same depths and the same coordinates.

## Nodes by id.
var nodes: Dictionary[StringName, ResearchNode] = {}
## Sorted node ids. The canonical iteration order for the whole part.
var ids: Array[StringName] = []
## id -> sorted prerequisite ids that actually exist.
var prereqs: Dictionary[StringName, Array] = {}
## id -> sorted ids of nodes that list it as a prerequisite.
var dependents: Dictionary[StringName, Array] = {}
## id -> longest distance from a root. This is the tree view's column.
var depth: Dictionary[StringName, int] = {}
## Prerequisites-first order. Every node appears after all of its prereqs.
var order: Array[StringName] = []
## id -> {column, row}
var placement: Dictionary[StringName, Vector2i] = {}
## Layout extents.
var columns: int = 0
var rows: int = 0
## Everything build() found wrong with the content, human-readable.
var problems: PackedStringArray = PackedStringArray()
## Branch key -> {row_start, row_end} band the lane occupies.
var bands: Dictionary[StringName, Vector2i] = {}


## Builds the graph from a set of nodes. Bad content is reported in `problems`
## and routed around — a dangling prerequisite drops that one edge instead of
## taking the tree down, because a half-authored branch must never stop a run.
func build(source: Array[ResearchNode]) -> void:
	nodes.clear()
	ids.clear()
	prereqs.clear()
	dependents.clear()
	depth.clear()
	order.clear()
	placement.clear()
	bands.clear()
	columns = 0
	rows = 0
	problems = PackedStringArray()

	for n: ResearchNode in source:
		if n == null:
			continue
		if String(n.id) == "":
			problems.append("a research node has no id")
			continue
		if nodes.has(n.id):
			problems.append("duplicate research id '%s'" % String(n.id))
			continue
		for issue: String in n.validate():
			problems.append("'%s' — %s" % [String(n.id), issue])
		nodes[n.id] = n

	var raw: Array = nodes.keys()
	raw.sort()
	for k: StringName in raw:
		ids.append(k)

	for id: StringName in ids:
		var n: ResearchNode = nodes[id]
		var kept: Array[StringName] = []
		for p: StringName in n.prereqs:
			if not nodes.has(p):
				problems.append("'%s' requires '%s', which does not exist" % [String(id), String(p)])
				continue
			if kept.has(p):
				continue
			kept.append(p)
		kept.sort()
		prereqs[id] = kept
		var empty: Array[StringName] = []
		dependents[id] = empty

	for id: StringName in ids:
		for p: StringName in prereqs[id]:
			var arr: Array = dependents[p]
			arr.append(id)
	for id2: StringName in ids:
		var d: Array = dependents[id2]
		d.sort()
		dependents[id2] = d

	_break_cycles()
	_topo()
	_depths()
	_layout()


## Every node with no prerequisites — where a fresh campaign can start.
func roots() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in ids:
		if (prereqs[id] as Array).is_empty():
			out.append(id)
	return out


## Leaves: nothing depends on them. The ends of the campaign.
func leaves() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in ids:
		if (dependents[id] as Array).is_empty():
			out.append(id)
	return out


func has(id: StringName) -> bool:
	return nodes.has(id)


func node(id: StringName) -> ResearchNode:
	return nodes.get(id)


func size() -> int:
	return ids.size()


## Sorted ids belonging to one branch.
func branch_ids(branch: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in ids:
		if nodes[id].branch == branch:
			out.append(id)
	return out


## Every prerequisite of `id`, transitively, sorted. The "what does this cost me
## in total" question the tree view answers on hover.
func ancestors(id: StringName) -> Array[StringName]:
	var seen: Dictionary[StringName, bool] = {}
	var stack: Array[StringName] = []
	for p0: StringName in prereqs.get(id, []):
		stack.append(p0)
	while not stack.is_empty():
		var cur: StringName = stack.pop_back()
		if seen.has(cur):
			continue
		seen[cur] = true
		for p: StringName in prereqs.get(cur, []):
			stack.append(p)
	var out: Array = seen.keys()
	out.sort()
	var typed: Array[StringName] = []
	for k: StringName in out:
		typed.append(k)
	return typed


## Everything that becomes reachable once `id` is done, transitively.
func descendants(id: StringName) -> Array[StringName]:
	var seen: Dictionary[StringName, bool] = {}
	var stack: Array[StringName] = []
	stack.append_array(dependents.get(id, [] as Array[StringName]))
	while not stack.is_empty():
		var cur: StringName = stack.pop_back()
		if seen.has(cur):
			continue
		seen[cur] = true
		stack.append_array(dependents.get(cur, [] as Array[StringName]))
	var out: Array = seen.keys()
	out.sort()
	var typed: Array[StringName] = []
	for k: StringName in out:
		typed.append(k)
	return typed


## Every edge as {from, to}, sorted. What the tree view draws lines from.
func edges() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: StringName in ids:
		for p: StringName in prereqs[id]:
			out.append({
				"from": String(p),
				"to": String(id),
				"from_branch": String(nodes[p].branch),
				"to_branch": String(nodes[id].branch),
				"cross_branch": nodes[p].branch != nodes[id].branch,
			})
	return out


## True when no node can reach itself through prerequisites. build() guarantees
## it by dropping the edge that closes a cycle, so this is the test's assertion
## rather than a runtime question.
func is_acyclic() -> bool:
	var state: Dictionary[StringName, int] = {}
	for id: StringName in ids:
		if _cycle_from(id, state).size() > 0:
			return false
	return true


## Ids that can never be reached because a prerequisite chain is broken. With a
## clean graph this is always empty; it is the assertion that the whole tree is
## actually researchable.
func unreachable() -> Array[StringName]:
	var reachable: Dictionary[StringName, bool] = {}
	for id: StringName in order:
		var ok: bool = true
		for p: StringName in prereqs[id]:
			if not reachable.has(p):
				ok = false
				break
		if ok:
			reachable[id] = true
	var out: Array[StringName] = []
	for id2: StringName in ids:
		if not reachable.has(id2):
			out.append(id2)
	return out


# ==========================================================================
#  INTERNALS
# ==========================================================================

## Kahn's algorithm over sorted ids, so the order is stable rather than merely
## valid. Anything left over sat in a cycle and is appended at the end.
func _topo() -> void:
	var indeg: Dictionary[StringName, int] = {}
	for id: StringName in ids:
		indeg[id] = (prereqs[id] as Array).size()
	var ready: Array[StringName] = []
	for id2: StringName in ids:
		if indeg[id2] == 0:
			ready.append(id2)
	while not ready.is_empty():
		var cur: StringName = ready.pop_front()
		order.append(cur)
		var next_ready: Array[StringName] = []
		for d: StringName in dependents[cur]:
			indeg[d] = indeg[d] - 1
			if indeg[d] == 0:
				next_ready.append(d)
		if not next_ready.is_empty():
			ready.append_array(next_ready)
			ready.sort()
	if order.size() != ids.size():
		for id3: StringName in ids:
			if not order.has(id3):
				order.append(id3)


## Longest path from a root, walked in topological order so every prerequisite
## already has its depth. This is the column a node sits in.
func _depths() -> void:
	for id: StringName in ids:
		depth[id] = 0
	for id2: StringName in order:
		var d: int = 0
		for p: StringName in prereqs[id2]:
			d = maxi(d, int(depth.get(p, 0)) + 1)
		depth[id2] = d
		columns = maxi(columns, d + 1)


## A cycle in a hand-authored tree is a content bug, not a runtime condition.
## The edge that closes it is dropped and reported, so the rest of the tree
## still works and the log names exactly which prerequisite to delete.
func _break_cycles() -> void:
	var guard: int = 0
	while guard < 64:
		guard += 1
		var state: Dictionary[StringName, int] = {}
		var found: Array[StringName] = []
		for id: StringName in ids:
			found = _cycle_from(id, state)
			if found.size() > 0:
				break
		if found.is_empty():
			return
		# found is [.., a, b] where b depends on a and a reaches b: drop b -> a.
		var last: StringName = found[found.size() - 1]
		var prev: StringName = found[found.size() - 2] if found.size() >= 2 else found[0]
		var arr: Array = prereqs[last]
		arr.erase(prev)
		prereqs[last] = arr
		var dep: Array = dependents[prev]
		dep.erase(last)
		dependents[prev] = dep
		problems.append("cycle broken: dropped prerequisite '%s' from '%s'" % [String(prev), String(last)])


## Iterative DFS returning the node chain that closes a cycle, or [].
## state: 0/absent = unvisited, 1 = on the stack, 2 = finished.
func _cycle_from(start: StringName, state: Dictionary[StringName, int]) -> Array[StringName]:
	if int(state.get(start, 0)) != 0:
		return [] as Array[StringName]
	var path: Array[StringName] = []
	var stack: Array = [[start, 0]]
	while not stack.is_empty():
		var frame: Array = stack[stack.size() - 1]
		var id: StringName = frame[0]
		var idx: int = frame[1]
		if idx == 0:
			if int(state.get(id, 0)) == 1:
				var out: Array[StringName] = []
				var from: int = path.find(id)
				if from >= 0:
					for i: int in range(from, path.size()):
						out.append(path[i])
				out.append(id)
				return out
			if int(state.get(id, 0)) == 2:
				stack.pop_back()
				continue
			state[id] = 1
			path.append(id)
		var list: Array = prereqs.get(id, [])
		if idx < list.size():
			frame[1] = idx + 1
			stack.append([list[idx], 0])
			continue
		state[id] = 2
		path.pop_back()
		stack.pop_back()
	return [] as Array[StringName]


## Branches become horizontal bands, depth becomes the column. Inside a band a
## node takes the first free row of its column, so lines never overlap a node
## and a lane's height is exactly as tall as its widest column.
func _layout() -> void:
	var row_cursor: int = 0
	var branches: Array[StringName] = []
	for b: StringName in ResearchDefs.BRANCH_ORDER:
		branches.append(b)
	# Any branch the content invented that is not in the canonical order still
	# gets a band, appended in sorted order, rather than being drawn on top of
	# another lane.
	var extra: Array[StringName] = []
	for id: StringName in ids:
		var b2: StringName = nodes[id].branch
		if not branches.has(b2) and not extra.has(b2):
			extra.append(b2)
	extra.sort()
	branches.append_array(extra)

	for branch: StringName in branches:
		var members: Array[StringName] = branch_ids(branch)
		if members.is_empty():
			continue
		# Sort by (column, tier, id) so the assignment cannot depend on hash order.
		members.sort_custom(func(a: StringName, b: StringName) -> bool:
			var da: int = int(depth[a])
			var db: int = int(depth[b])
			if da != db:
				return da < db
			var ta: int = nodes[a].tier
			var tb: int = nodes[b].tier
			if ta != tb:
				return ta < tb
			return String(a) < String(b))

		var used: Dictionary[int, Dictionary] = {}   ## column -> {row: true}
		var band_h: int = 0
		# Explicit hints are placed first so an automatic row cannot steal one.
		for pass_i: int in 2:
			for id3: StringName in members:
				var n: ResearchNode = nodes[id3]
				var hinted: bool = n.row_hint >= 0
				if (pass_i == 0) != hinted:
					continue
				var col: int = int(depth[id3])
				var taken: Dictionary = used.get(col, {})
				var local: int = n.row_hint if hinted else 0
				while taken.has(local):
					local += 1
				taken[local] = true
				used[col] = taken
				placement[id3] = Vector2i(col, row_cursor + local)
				band_h = maxi(band_h, local + 1)
		bands[branch] = Vector2i(row_cursor, row_cursor + band_h - 1)
		row_cursor += band_h
	rows = row_cursor
