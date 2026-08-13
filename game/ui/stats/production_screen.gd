class_name LcnProductionScreen
extends LcnStatsScreen
## Production versus consumption, per item, with the bottleneck named. [P20]
##
## The left two thirds are the chart: the selected item's production and
## consumption over the chosen window, nights shaded. The right third is the
## table — every item the recipe graph knows about, made per minute against used
## per minute, what is in the yards, and what is wrong with it.
##
## Click a row to plot it. Click a column head to sort by it. The bottleneck row
## is marked with an ember bar and the sentence above the table says, in words,
## which item is holding the factory back and how many machines are standing
## still because of it.
##
## That last sentence is the whole point of this screen. A table of forty rows
## is data; "Iron Plate is the bottleneck — 6 machines standing idle waiting for
## it" is a decision.

const COL_ITEM: float = 0.34
const COL_MADE: float = 0.17
const COL_USED: float = 0.17
const COL_STOCK: float = 0.15
const HEADLINE_H: float = 40.0
const TABLE_W: float = 470.0

var model: LcnProductionModel = LcnProductionModel.new()
var selected: StringName = &""
var sort_column: StringName = &"made"
var sort_ascending: bool = false
## Rows the table can show at once, recomputed on layout.
var _visible_rows: int = 0
var _scroll: int = 0
var _rows: Array[Dictionary] = []


func screen_title() -> String:
	return "Production"


func screen_subtitle() -> String:
	return "What the factory makes, what it eats, and what is stopping it."


func _build() -> void:
	make_plot()
	plot.zero_baseline = true
	plot.show_legend = true
	var sim: Node = _autoload("Sim")
	model.bind(recorder, sim.call("get_system", &"production") if sim != null else null)


func _layout() -> void:
	if plot == null:
		return
	var t: LcnStatsTheme = _theme()
	var table_w: float = minf(TABLE_W, size.x * 0.42)
	plot.position = Vector2(0.0, HEADLINE_H)
	plot.size = Vector2(maxf(200.0, size.x - table_w - t.GAP), maxf(120.0, size.y - HEADLINE_H))
	_visible_rows = maxi(1, int((size.y - HEADLINE_H - t.ROW_H * 1.6) / t.ROW_H))


func _refresh() -> void:
	model.refresh(window_id, _window_samples())
	_rows = model.rows()
	model.sort_by(sort_column, sort_ascending)
	_rows = model.rows()
	if selected == &"" and not _rows.is_empty():
		selected = StringName(String(_rows[0]["item"]))
	if model.bottleneck() != &"" and selected == &"":
		selected = model.bottleneck()
	_bind_plot()
	var t: LcnStatTrack = track()
	if dirty("%s/%d/%s/%s/%d" % [String(window_id), 0 if t == null else t.latest_tick,
			String(selected), String(sort_column), _rows.size()]):
		queue_redraw()


func _bind_plot() -> void:
	var t: LcnStatTrack = track()
	plot.track = t
	plot.bands = bands_for(t)
	plot.marks = []
	plot.clear_entries()
	if selected == &"":
		plot.empty_note = "Pick an item on the right."
		return
	var colour: Color = LcnStatsDefs.item_colour(selected)
	plot.title = "%s — units per minute" % LcnStatsDefs.item_label(selected)
	plot.add_entry(LcnStatsDefs.produced_key(selected), "Made",
		colour, LcnGraphPlot.Mode.RATE, true)
	plot.add_entry(LcnStatsDefs.consumed_key(selected), "Used",
		LcnStatsTheme.ACCENT, LcnGraphPlot.Mode.RATE, false)
	plot.refresh()


func _window_samples() -> int:
	match window_id:
		LcnStatsRecorder.T_FINE:
			return 120       # the last minute
		LcnStatsRecorder.T_MID:
			return 240       # the last twenty minutes
		_:
			return -1        # the whole run


# ===================================================================  draw ===

func _draw() -> void:
	var t: LcnStatsTheme = _theme()
	clear_hot()
	_draw_headline(t)
	_draw_table(t)


func _draw_headline(t: LcnStatsTheme) -> void:
	var head: String = model.headline()
	var size_head: int = t.fs(t.FS_HEAD)
	var bottleneck: bool = model.bottleneck() != &""
	var rect := Rect2(Vector2.ZERO, Vector2(size.x, HEADLINE_H - 6.0))
	t.plate(self, rect, t.PANEL_HEAD, t.RIM_SOFT)
	var accent: Color = t.ACCENT if bottleneck else t.GOOD
	draw_rect(Rect2(rect.position, Vector2(3.0, rect.size.y)), accent, true)
	t.text(self, Vector2(14.0, HEADLINE_H * 0.5 + float(size_head) * 0.36), head,
		size_head, t.TEXT if not bottleneck else t.TEXT_BRIGHT)


func _draw_table(t: LcnStatsTheme) -> void:
	var x0: float = plot.position.x + plot.size.x + t.GAP
	var w: float = maxf(120.0, size.x - x0)
	var y: float = HEADLINE_H
	t.plate(self, Rect2(Vector2(x0, y), Vector2(w, size.y - y)), t.PANEL, t.RIM_SOFT)

	var small: int = t.fs(t.FS_SMALL)
	var body: int = t.fs(t.FS_BODY)
	var head_y: float = y + t.ROW_H * 0.8
	var cols: Array[Dictionary] = [
		{"id": &"label", "text": "ITEM", "x": x0 + 8.0, "w": w * COL_ITEM, "right": false},
		{"id": &"made", "text": "MADE", "x": x0 + w * COL_ITEM, "w": w * COL_MADE, "right": true},
		{"id": &"used", "text": "USED", "x": x0 + w * (COL_ITEM + COL_MADE), "w": w * COL_USED, "right": true},
		{"id": &"stock", "text": "STOCK", "x": x0 + w * (COL_ITEM + COL_MADE + COL_USED), "w": w * COL_STOCK, "right": true},
	]
	for c: Dictionary in cols:
		var label: String = String(c["text"])
		if StringName(String(c["id"])) == sort_column:
			label += " ↓" if not sort_ascending else " ↑"
		var cx: float = float(c["x"])
		var cw: float = float(c["w"])
		if bool(c["right"]):
			t.text_right(self, cx + cw - 6.0, head_y, label, small, t.TEXT_DIM)
		else:
			t.caps(self, Vector2(cx, head_y), label, small, t.TEXT_DIM)
		add_hot(Rect2(Vector2(cx, y + 4.0), Vector2(cw, t.ROW_H)), &"sort",
			StringName(String(c["id"])))
	draw_line(Vector2(x0 + 6.0, head_y + 5.0), Vector2(x0 + w - 6.0, head_y + 5.0),
		t.RIM_SOFT, 1.0)

	var ry: float = head_y + 10.0
	var shown: int = 0
	for i: int in range(_scroll, _rows.size()):
		if ry + t.ROW_H > size.y - 4.0:
			break
		var row: Dictionary = _rows[i]
		var item := StringName(String(row["item"]))
		var rrect := Rect2(Vector2(x0 + 4.0, ry), Vector2(w - 8.0, t.ROW_H))
		var is_bottleneck: bool = item == model.bottleneck()
		if item == selected:
			draw_rect(rrect, t.ROW_SELECTED, true)
		elif hot_index >= 0 and hot_index < hot.size() \
				and StringName(String(hot[hot_index]["id"])) == &"row" \
				and StringName(String(hot[hot_index]["arg"])) == item:
			draw_rect(rrect, t.ROW_HOVER, true)
		elif shown % 2 == 1:
			draw_rect(rrect, t.ROW_ODD, true)
		if is_bottleneck:
			draw_rect(Rect2(rrect.position, Vector2(3.0, rrect.size.y)), t.ACCENT, true)

		var base: float = ry + t.ROW_H * 0.5 + float(body) * 0.34
		var colour: Color = row["colour"]
		draw_rect(Rect2(Vector2(x0 + 10.0, ry + t.ROW_H * 0.5 - 4.0), Vector2(8.0, 8.0)),
			colour, true)
		var made: float = float(row["made"])
		var used: float = float(row["used"])
		t.text(self, Vector2(x0 + 24.0, base), String(row["label"]), body,
			t.TEXT_BRIGHT if is_bottleneck else t.TEXT)
		t.text_right(self, float(cols[1]["x"]) + float(cols[1]["w"]) - 6.0, base,
			LcnStatsTheme.compact(made), body,
			t.TEXT if made > 0.0 else t.TEXT_FAINT)
		t.text_right(self, float(cols[2]["x"]) + float(cols[2]["w"]) - 6.0, base,
			LcnStatsTheme.compact(used), body,
			t.BAD if used > made + 0.01 else t.TEXT_DIM)
		var stock: float = float(row["stock"])
		var delta: float = float(row["stock_delta"])
		t.text_right(self, float(cols[3]["x"]) + float(cols[3]["w"]) - 6.0, base,
			LcnStatsTheme.compact(stock), body,
			t.WARN if stock <= 0.0 and used > 0.0 else t.TEXT_DIM)
		if absf(delta) >= 1.0:
			var arrow: String = "▲" if delta > 0.0 else "▼"
			var acol: Color = t.GOOD if delta > 0.0 else t.BAD
			t.text(self, Vector2(x0 + w - 14.0, base), arrow, t.fs(t.FS_TINY), acol)
		add_hot(rrect, &"row", item)
		ry += t.ROW_H
		shown += 1

	if _rows.is_empty():
		t.text(self, Vector2(x0 + 12.0, ry + float(body)),
			"No recipe has produced anything yet.", body, t.TEXT_FAINT)
	elif shown < _rows.size() - _scroll:
		t.text_right(self, x0 + w - 8.0, size.y - 8.0,
			"%d more — scroll" % (_rows.size() - _scroll - shown), small, t.TEXT_FAINT)


# =================================================================  input ====

func activate(index: int) -> void:
	if index < 0 or index >= hot.size():
		return
	var e: Dictionary = hot[index]
	match StringName(String(e["id"])):
		&"row":
			selected = StringName(String(e["arg"]))
			invalidate()
			_bind_plot()
			queue_redraw()
		&"sort":
			var col := StringName(String(e["arg"]))
			if col == sort_column:
				sort_ascending = not sort_ascending
			else:
				sort_column = col
				sort_ascending = col == &"label"
			invalidate()
			refresh()
			queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var wheel := event as InputEventMouseButton
	if wheel != null and wheel.pressed:
		if wheel.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll = clampi(_scroll + 2, 0, maxi(0, _rows.size() - 1))
			queue_redraw()
			accept_event()
			return
		if wheel.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll = clampi(_scroll - 2, 0, maxi(0, _rows.size() - 1))
			queue_redraw()
			accept_event()
			return
	super._gui_input(event)


func _autoload(n: String) -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(n))
