class_name BuildUndoStack
extends RefCounted
## Undo/redo history for construction, with grouping.
##
## Storage only — the build system knows how to invert an action, the stack
## knows what order to hand them back in. Open a group and every action pushed
## until it closes collapses into one step for the player.

## Deepest history kept. Old steps fall off the bottom; a run cannot rewind
## an hour of city building from a stack that also has to be serialized.
const MAX_DEPTH: int = 64

var _undo: Array[BuildAction] = []
var _redo: Array[BuildAction] = []
var _open: Array[BuildAction] = []


## Starts collecting into one group. Groups may nest; the outermost wins.
func begin_group(label: String, tick: int) -> void:
	_open.append(BuildAction.group(label, tick))


## Closes the innermost group. An empty group is dropped rather than pushed,
## so a stamp that placed nothing does not eat an undo press.
func end_group() -> BuildAction:
	if _open.is_empty():
		return null
	var g: BuildAction = _open.pop_back()
	if g.children.is_empty():
		return null
	push(g)
	return g


## True while at least one group is open.
func grouping() -> bool:
	return not _open.is_empty()


## Records an action. Any redo history is discarded, as in every editor.
func push(action: BuildAction) -> void:
	if not _open.is_empty():
		_open[_open.size() - 1].children.append(action)
		return
	_undo.append(action)
	_redo.clear()
	while _undo.size() > MAX_DEPTH:
		_undo.pop_front()


## Most recent action, removed from the undo side. Null when empty.
func pop_undo() -> BuildAction:
	if _undo.is_empty():
		return null
	return _undo.pop_back()


## Puts an undone action on the redo side.
func push_redo(action: BuildAction) -> void:
	_redo.append(action)
	while _redo.size() > MAX_DEPTH:
		_redo.pop_front()


func pop_redo() -> BuildAction:
	if _redo.is_empty():
		return null
	return _redo.pop_back()


## Puts a redone action back on the undo side without clearing redo history.
func push_undo_silent(action: BuildAction) -> void:
	_undo.append(action)
	while _undo.size() > MAX_DEPTH:
		_undo.pop_front()


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo_depth() -> int:
	return _undo.size()


func redo_depth() -> int:
	return _redo.size()


## Label of the next undo step, for the button tooltip.
func peek_undo_label() -> String:
	return _undo[_undo.size() - 1].label if not _undo.is_empty() else ""


func peek_redo_label() -> String:
	return _redo[_redo.size() - 1].label if not _redo.is_empty() else ""


## Every REMOVE action still on the stack, so deferred refunds can be stamped in.
func remove_actions() -> Array[BuildAction]:
	var out: Array[BuildAction] = []
	for a: BuildAction in _undo:
		_collect_removes(a, out)
	for a: BuildAction in _redo:
		_collect_removes(a, out)
	return out


static func _collect_removes(a: BuildAction, into: Array[BuildAction]) -> void:
	if a.kind == BuildAction.Kind.GROUP:
		for c: BuildAction in a.children:
			_collect_removes(c, into)
	elif a.kind == BuildAction.Kind.REMOVE:
		into.append(a)


func clear() -> void:
	_undo.clear()
	_redo.clear()
	_open.clear()


func to_dict() -> Dictionary:
	var u: Array = []
	for a: BuildAction in _undo:
		u.append(a.to_dict())
	var r: Array = []
	for a: BuildAction in _redo:
		r.append(a.to_dict())
	return {"undo": u, "redo": r}


func from_dict(data: Dictionary) -> void:
	clear()
	for raw: Variant in data.get("undo", []):
		if typeof(raw) == TYPE_DICTIONARY:
			_undo.append(BuildAction.from_dict(raw))
	for raw: Variant in data.get("redo", []):
		if typeof(raw) == TYPE_DICTIONARY:
			_redo.append(BuildAction.from_dict(raw))
