class_name LcnNightScreen
extends LcnStatsScreen
## The after-action report. The screen that makes a player say one more day. [P20]
##
## Four blocks and a verdict:
##
##   VERDICT          HELD CLEAN / HELD / HELD, BARELY / MAULED, and the headline
##   WHAT YOU MADE    the biggest production lines of the night, as bars
##   WHAT IT COST     heat, people, buildings, ammunition
##   WHAT NEARLY WENT the closest call, in one sentence
##   THE RECORD       what happened, in order
##
## It appears on its own at dawn — [LcnStats] raises it when `Bus.day_started`
## fires and a night has just closed — and it can be walked back through with
## the arrow keys, because the fourth night is only interesting next to the
## third one.

const PAD: float = 18.0
const BAR_H: float = 18.0
const BLOCK_GAP: float = 14.0

## Reports newest last. Bounded: the history behind them is bounded too.
var reports: Array[Dictionary] = []
## Which report is shown. -1 means the newest.
var index: int = -1


func screen_title() -> String:
	return "Night report"


func screen_subtitle() -> String:
	return "What the night cost, and what nearly ended it."


func _build() -> void:
	pass


## Called by [LcnStats] when a night closes.
func capture(report: Dictionary) -> void:
	if report.is_empty():
		return
	reports.append(report)
	if reports.size() > 32:
		reports.remove_at(0)
	index = -1
	invalidate()
	queue_redraw()


func current() -> Dictionary:
	if reports.is_empty():
		return {}
	var i: int = index if index >= 0 else reports.size() - 1
	return reports[clampi(i, 0, reports.size() - 1)]


func step(delta: int) -> void:
	if reports.is_empty():
		return
	var i: int = index if index >= 0 else reports.size() - 1
	index = clampi(i + delta, 0, reports.size() - 1)
	invalidate()
	queue_redraw()


func _refresh() -> void:
	# A night still in progress is shown live, so the panel is never empty just
	# because dawn has not arrived. It is rebuilt on the refresh tick, which is
	# six times a second, which is far more often than a night changes shape.
	if journal == null or recorder == null:
		return
	var live: Dictionary = journal.current_night()
	if live.is_empty():
		return
	var report: Dictionary = LcnNightReport.build(recorder, journal, live)
	if report.is_empty():
		return
	if not reports.is_empty() and not bool((reports[reports.size() - 1] as Dictionary).get("complete", true)) :
		reports[reports.size() - 1] = report
	else:
		reports.append(report)
	index = -1
	if dirty("live/%d" % int(report["to_tick"])):
		queue_redraw()


func _draw() -> void:
	var t: LcnStatsTheme = _theme()
	var report: Dictionary = current()
	if report.is_empty():
		t.plate(self, Rect2(Vector2.ZERO, size), t.PANEL, t.RIM_SOFT)
		t.text_centre(self, size.x * 0.5, size.y * 0.45,
			"No night has been survived yet.", t.fs(t.FS_HEAD), t.TEXT_DIM)
		t.text_centre(self, size.x * 0.5, size.y * 0.45 + 22.0,
			"The report is written at dawn.", t.fs(t.FS_BODY), t.TEXT_FAINT)
		return

	var col_w: float = (size.x - PAD * 4.0) / 3.0
	var head_h: float = _draw_verdict(t, report)
	var y: float = head_h + BLOCK_GAP
	var body_h: float = size.y - y - PAD
	_draw_made(t, report, Rect2(Vector2(PAD, y), Vector2(col_w, body_h)))
	_draw_cost(t, report, Rect2(Vector2(PAD * 2.0 + col_w, y), Vector2(col_w, body_h)))
	_draw_record(t, report, Rect2(Vector2(PAD * 3.0 + col_w * 2.0, y),
		Vector2(col_w, body_h)))


func _draw_verdict(t: LcnStatsTheme, report: Dictionary) -> float:
	var h: float = 96.0
	var rect := Rect2(Vector2(PAD, 0.0), Vector2(size.x - PAD * 2.0, h))
	t.plate(self, rect, t.PANEL_HEAD, t.RIM)
	var verdict: String = String(report["verdict"])
	var colour: Color = t.GOOD
	if verdict == "MAULED":
		colour = t.BAD
	elif verdict == "HELD, BARELY":
		colour = t.WARN
	elif verdict == "HELD":
		colour = t.COOL
	draw_rect(Rect2(rect.position, Vector2(4.0, rect.size.y)), colour, true)

	t.caps(self, Vector2(PAD + 18.0, 30.0), verdict, t.fs(t.FS_TITLE), colour, 2.6)
	t.text(self, Vector2(PAD + 18.0, 52.0), String(report["headline"]),
		t.fs(t.FS_BODY), t.TEXT_DIM)
	t.text(self, Vector2(PAD + 18.0, 78.0), String(report["closest_call"]),
		t.fs(t.FS_HEAD), t.TEXT_BRIGHT)
	if reports.size() > 1:
		var i: int = index if index >= 0 else reports.size() - 1
		t.text_right(self, rect.position.x + rect.size.x - 14.0, 26.0,
			"report %d of %d   ← →" % [i + 1, reports.size()],
			t.fs(t.FS_SMALL), t.TEXT_FAINT)
	if not bool(report.get("complete", true)):
		t.text_right(self, rect.position.x + rect.size.x - 14.0, 48.0,
			"the night is still going", t.fs(t.FS_SMALL), t.WARN)
	return h


func _draw_made(t: LcnStatsTheme, report: Dictionary, rect: Rect2) -> void:
	t.plate(self, rect, t.PANEL, t.RIM_SOFT)
	var y: float = _block_head(t, rect, "What you made")
	var made: Array = report["produced"]
	if made.is_empty():
		t.text(self, Vector2(rect.position.x + 14.0, y + 16.0),
			"Nothing was produced.", t.fs(t.FS_BODY), t.TEXT_FAINT)
		return
	var top: float = maxf(1.0, float((made[0] as Dictionary)["amount"]))
	var body: int = t.fs(t.FS_BODY)
	for entry: Dictionary in made:
		var f: float = float(entry["amount"]) / top
		var bar := Rect2(Vector2(rect.position.x + 14.0, y + 4.0),
			Vector2((rect.size.x - 28.0) * f, BAR_H))
		var colour: Color = entry["colour"]
		draw_rect(Rect2(Vector2(rect.position.x + 14.0, y + 4.0),
			Vector2(rect.size.x - 28.0, BAR_H)), Color(0.0, 0.0, 0.0, 0.25), true)
		draw_rect(bar, Color(colour.r, colour.g, colour.b, 0.55), true)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x, 2.0)), colour, true)
		t.text(self, Vector2(rect.position.x + 20.0, y + BAR_H - 1.0),
			String(entry["label"]), body, t.TEXT_BRIGHT)
		t.text_right(self, rect.position.x + rect.size.x - 18.0, y + BAR_H - 1.0,
			LcnStatsTheme.compact(float(entry["amount"])), body, t.TEXT)
		y += BAR_H + 10.0

	var used: Array = report["consumed"]
	if used.is_empty():
		return
	y += 8.0
	t.caps(self, Vector2(rect.position.x + 14.0, y), "and consumed",
		t.fs(t.FS_TINY), t.TEXT_FAINT)
	y += 16.0
	for entry2: Dictionary in used:
		if y > rect.position.y + rect.size.y - 12.0:
			break
		t.text(self, Vector2(rect.position.x + 20.0, y), String(entry2["label"]),
			t.fs(t.FS_SMALL), t.TEXT_DIM)
		t.text_right(self, rect.position.x + rect.size.x - 18.0, y,
			LcnStatsTheme.compact(float(entry2["amount"])), t.fs(t.FS_SMALL), t.TEXT_DIM)
		y += float(t.fs(t.FS_SMALL)) + 6.0


func _draw_cost(t: LcnStatsTheme, report: Dictionary, rect: Rect2) -> void:
	t.plate(self, rect, t.PANEL, t.RIM_SOFT)
	var y: float = _block_head(t, rect, "What it cost")
	var heat: Dictionary = report["heat"]
	var soc: Dictionary = report["society"]
	var com: Dictionary = report["combat"]
	var city: Dictionary = report["city"]
	var rows: Array[Dictionary] = [
		_row("People lost", "%d" % int(soc["deaths"]),
			t.BAD if float(soc["deaths"]) > 0.0 else t.TEXT_DIM),
		_row("Structures lost", "%d" % int(com["structures_lost"]),
			t.BAD if float(com["structures_lost"]) > 0.0 else t.TEXT_DIM),
		_row("Buildings frozen", "%d" % int(heat["peak_frozen"]),
			t.WARN if float(heat["peak_frozen"]) > 0.0 else t.TEXT_DIM),
		_row("Grid short for", LcnStatsTheme.duration(float(heat["deficit_seconds"])),
			t.WARN if float(heat["deficit_seconds"]) > 1.0 else t.TEXT_DIM),
		_row("Worst deficit", "%s heat/s" % LcnStatsTheme.compact(float(heat["worst_deficit"])),
			t.TEXT_DIM),
		_row("Buffer low point", LcnStatsTheme.compact(float(heat["min_buffer"])), t.TEXT_DIM),
		_row("Heat on defence", LcnStatsTheme.compact(float(com["defence_heat"])), t.HOT),
		_row("Enemies killed", "%d" % int(com["kills"]), t.GOOD),
		_row("Damage absorbed", LcnStatsTheme.compact(float(com["damage_taken"])), t.TEXT_DIM),
		_row("Peak on the map", "%d" % int(com["peak_enemies"]), t.TEXT_DIM),
		_row("Crafts finished", "%d" % int(city["crafts"]), t.TEXT_DIM),
		_row("Hope", "%.2f → %.2f" % [float(soc["hope_start"]), float(soc["hope_end"])],
			t.GOOD if float(soc["hope_end"]) >= float(soc["hope_start"]) else t.BAD),
		_row("Discontent", "%.2f → %.2f" % [float(soc["discontent_start"]),
			float(soc["discontent_end"])],
			t.BAD if float(soc["discontent_end"]) > float(soc["discontent_start"]) else t.GOOD),
		_row("Coldest it got", "%.1f C" % float(soc["coldest"]), t.COOL),
	]
	var body: int = t.fs(t.FS_BODY)
	var step: float = float(body) + 9.0
	for i: int in rows.size():
		if y + step > rect.position.y + rect.size.y - 6.0:
			break
		var r: Dictionary = rows[i]
		if i % 2 == 1:
			draw_rect(Rect2(Vector2(rect.position.x + 6.0, y - float(body) + 2.0),
				Vector2(rect.size.x - 12.0, step - 2.0)), t.ROW_ODD, true)
		t.text(self, Vector2(rect.position.x + 14.0, y), String(r["label"]), body, t.TEXT_DIM)
		t.text_right(self, rect.position.x + rect.size.x - 14.0, y,
			String(r["value"]), body, r["colour"])
		y += step


func _draw_record(t: LcnStatsTheme, report: Dictionary, rect: Rect2) -> void:
	t.plate(self, rect, t.PANEL, t.RIM_SOFT)
	var y: float = _block_head(t, rect, "The record")
	var events: Array = report["events"]
	var small: int = t.fs(t.FS_SMALL)
	var tiny: int = t.fs(t.FS_TINY)
	if events.is_empty():
		t.text(self, Vector2(rect.position.x + 14.0, y + 10.0),
			"A quiet night. Nothing was signed, nothing was finished, nothing came.",
			small, t.TEXT_FAINT)
		return
	for m: Dictionary in events:
		if y + float(small) + float(tiny) + 8.0 > rect.position.y + rect.size.y - 6.0:
			break
		var colour: Color = LcnStatsJournal.kind_colour(int(m["kind"]))
		draw_rect(Rect2(Vector2(rect.position.x + 12.0, y - float(small) + 2.0),
			Vector2(3.0, float(small))), colour, true)
		t.text(self, Vector2(rect.position.x + 21.0, y), String(m["text"]), small, t.TEXT)
		t.text(self, Vector2(rect.position.x + 21.0, y + float(tiny) + 4.0),
			"%s  ·  %s" % [LcnStatsJournal.kind_label(int(m["kind"])),
				LcnStatsTheme.ticks_as_clock(int(m["tick"]))], tiny, t.TEXT_FAINT)
		y += float(small) + float(tiny) + 12.0


func _block_head(t: LcnStatsTheme, rect: Rect2, title: String) -> float:
	t.caps(self, Vector2(rect.position.x + 14.0, rect.position.y + 22.0), title,
		t.fs(t.FS_SMALL), t.ACCENT)
	draw_line(Vector2(rect.position.x + 12.0, rect.position.y + 30.0),
		Vector2(rect.position.x + rect.size.x - 12.0, rect.position.y + 30.0),
		t.RIM_SOFT, 1.0)
	return rect.position.y + 50.0


func _row(label: String, value: String, colour: Color) -> Dictionary:
	return {"label": label, "value": value, "colour": colour}
