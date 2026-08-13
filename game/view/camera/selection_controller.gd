class_name SelectionController
extends RefCounted
## Hover, click-select and box-select, expressed purely in world coordinates.
##
## It never touches simulation state. Entity lookup goes through a provider object so
## the sim systems that own entities ([P11] build, [P07] combat) can answer without this
## file knowing anything about them; any change a selection leads to must still be sent
## with Sim.submit_command by whoever acts on it ([P18]).
##
## A provider is any Object implementing either or both of:
##   func entity_at_world(pos: Vector2) -> int                       # -1 when empty
##   func entities_in_world_rect(rect: Rect2) -> PackedInt32Array
## Cell-space equivalents are accepted too:
##   func entity_at_cell(cell: Vector2i) -> int
##   func entities_in_cell_rect(rect: Rect2i) -> PackedInt32Array

signal hover_changed(cell: Vector2i, world_pos: Vector2, inside: bool)
signal selection_changed(ids: PackedInt32Array, cell_rect: Rect2i)
signal box_changed(rect: Rect2, active: bool)

var tile_size: int = CameraTuning.TILE_SIZE
var drag_threshold_px: float = 5.0
var provider: Object = null

var hovered_cell: Vector2i = Vector2i.ZERO
var hovered_world: Vector2 = Vector2.ZERO
var hovering: bool = false

var selected: PackedInt32Array = PackedInt32Array()
var selected_cells: Rect2i = Rect2i()
var has_selection: bool = false

var box_active: bool = false

var _pressed: bool = false
var _press_world: Vector2 = Vector2.ZERO
var _press_screen: Vector2 = Vector2.ZERO
var _current_world: Vector2 = Vector2.ZERO
var _additive: bool = false


# --- hover ---------------------------------------------------------------------

func set_hover(world_pos: Vector2, inside: bool) -> void:
	var cell: Vector2i = world_to_cell(world_pos, tile_size)
	var changed: bool = cell != hovered_cell or inside != hovering
	hovered_world = world_pos
	hovered_cell = cell
	hovering = inside
	if changed:
		hover_changed.emit(cell, world_pos, inside)


# --- click / box ---------------------------------------------------------------

func press(world_pos: Vector2, screen_pos: Vector2, additive: bool) -> void:
	_pressed = true
	_additive = additive
	_press_world = world_pos
	_press_screen = screen_pos
	_current_world = world_pos
	box_active = false


## Screen position is what decides click-versus-drag, so the threshold stays 5 px of
## hand movement whether you are zoomed into a workshop or out over the whole city.
func motion(world_pos: Vector2, screen_pos: Vector2) -> void:
	if not _pressed:
		return
	_current_world = world_pos
	if not box_active and screen_pos.distance_to(_press_screen) > drag_threshold_px:
		box_active = true
	if box_active:
		box_changed.emit(box_rect(), true)


func release(world_pos: Vector2, _screen_pos: Vector2) -> PackedInt32Array:
	if not _pressed:
		return selected
	_current_world = world_pos
	_pressed = false
	var was_box: bool = box_active
	box_active = false
	var rect: Rect2 = box_rect()
	var cells: Rect2i = cell_rect(_press_world, _current_world, tile_size)
	var found: PackedInt32Array = _query_box(rect, cells) if was_box else _query_point(world_pos)
	_commit(found, cells if was_box else Rect2i(world_to_cell(world_pos, tile_size), Vector2i.ONE))
	box_changed.emit(rect, false)
	return selected


## Abandon an in-flight box without touching the committed selection.
func cancel() -> void:
	if not _pressed and not box_active:
		return
	_pressed = false
	box_active = false
	box_changed.emit(box_rect(), false)


func clear() -> void:
	if not has_selection and selected.is_empty():
		return
	selected = PackedInt32Array()
	selected_cells = Rect2i()
	has_selection = false
	selection_changed.emit(selected, selected_cells)


func is_pressed() -> bool:
	return _pressed


## Live box in world space; empty-sized before the drag threshold is crossed.
func box_rect() -> Rect2:
	var a: Vector2 = _press_world
	var b: Vector2 = _current_world
	return Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (b - a).abs())


func box_cell_rect() -> Rect2i:
	return cell_rect(_press_world, _current_world, tile_size)


# --- queries -------------------------------------------------------------------

func _commit(found: PackedInt32Array, cells: Rect2i) -> void:
	var merged: PackedInt32Array = found
	if _additive and not selected.is_empty():
		merged = PackedInt32Array(selected)
		for id: int in found:
			if merged.find(id) == -1:
				merged.append(id)
	merged.sort()
	selected = merged
	selected_cells = cells
	has_selection = not selected.is_empty()
	selection_changed.emit(selected, selected_cells)


func _query_point(world_pos: Vector2) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if provider == null:
		return out
	if provider.has_method(&"entity_at_world"):
		var id: int = int(provider.call(&"entity_at_world", world_pos))
		if id >= 0:
			out.append(id)
		return out
	if provider.has_method(&"entity_at_cell"):
		var id2: int = int(provider.call(&"entity_at_cell", world_to_cell(world_pos, tile_size)))
		if id2 >= 0:
			out.append(id2)
	return out


func _query_box(rect: Rect2, cells: Rect2i) -> PackedInt32Array:
	if provider == null:
		return PackedInt32Array()
	if provider.has_method(&"entities_in_world_rect"):
		return _to_ids(provider.call(&"entities_in_world_rect", rect))
	if provider.has_method(&"entities_in_cell_rect"):
		return _to_ids(provider.call(&"entities_in_cell_rect", cells))
	return PackedInt32Array()


static func _to_ids(value: Variant) -> PackedInt32Array:
	if value is PackedInt32Array:
		var packed: PackedInt32Array = value
		return packed
	var out: PackedInt32Array = PackedInt32Array()
	if value is Array:
		for v: Variant in value:
			out.append(int(v))
	return out


# --- grid maths ----------------------------------------------------------------

## floor(), not truncation — otherwise every cell left of x=0 is off by one.
static func world_to_cell(world_pos: Vector2, tile: int) -> Vector2i:
	var t: float = float(maxi(tile, 1))
	return Vector2i(int(floor(world_pos.x / t)), int(floor(world_pos.y / t)))


static func cell_to_world(cell: Vector2i, tile: int) -> Vector2:
	return Vector2(cell) * float(tile)


static func cell_centre(cell: Vector2i, tile: int) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * float(tile)


## Inclusive cell rectangle covering both world points, in any order.
static func cell_rect(a: Vector2, b: Vector2, tile: int) -> Rect2i:
	var lo: Vector2i = world_to_cell(Vector2(minf(a.x, b.x), minf(a.y, b.y)), tile)
	var hi: Vector2i = world_to_cell(Vector2(maxf(a.x, b.x), maxf(a.y, b.y)), tile)
	return Rect2i(lo, hi - lo + Vector2i.ONE)
