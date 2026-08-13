class_name LcnProductionModel
extends RefCounted
## Turns the recorded history into the production table, and names the one item
## that is holding the whole factory back. [P20]
##
## The table is per item: made per minute, used per minute, the difference, what
## is in the yards, and how the yard is trending. That is the Factorio screen.
##
## THE BOTTLENECK is the part that is ours rather than borrowed, and it is
## answered from evidence rather than from a heuristic. [P04] already knows
## exactly which machines are standing still and exactly which item each one is
## waiting for — `stalled_machines()` returns the reason and the item. So the
## bottleneck is not "the item with the worst ratio"; it is **the item the most
## machines are currently stopped waiting for**, with the ratio used only to
## break ties and to word the sentence underneath.
##
## That distinction matters. A city can be short of ammunition and not care,
## because nothing consumes it yet. A city short of iron plate with six machines
## dark is a city that has stopped. Only the second one is a bottleneck.

## Reasons [P04] gives a stalled machine that mean "waiting for an item".
const STARVED_REASON: StringName = &"missing_input"
const FULL_REASON: StringName = &"output_full"

## Rows returned by [method rows].
##   item, label, colour, made, used, net, stock, stock_delta,
##   starving, blocked, depth, share, bottleneck, verdict

var recorder: LcnStatsRecorder = null

var _rows: Array[Dictionary] = []
var _bottleneck: StringName = &""
var _headline: String = ""
var _sig: String = ""
var _production: Object = null


func bind(rec: LcnStatsRecorder, production: Object) -> void:
	recorder = rec
	_production = production
	_sig = ""


## Rebuilds the table from the given track and window, if anything changed.
## `window` is a count of samples; -1 means everything the track holds.
func refresh(track_id: StringName, window: int, force: bool = false) -> void:
	if recorder == null:
		return
	var track: LcnStatTrack = recorder.track(track_id)
	if track == null:
		return
	var sig: String = "%s/%d/%d" % [String(track_id), track.latest_tick, window]
	if sig == _sig and not force:
		return
	_sig = sig
	_rows = _build(track, window)
	_pick_bottleneck()


func rows() -> Array[Dictionary]:
	return _rows


func bottleneck() -> StringName:
	return _bottleneck


## One sentence a player can act on. Never empty; when nothing is wrong it says
## so, because "no bottleneck" is itself the answer to the question they asked.
func headline() -> String:
	return _headline


## Sorts the table in place. `column` is a row key; ascending is opt-in because
## every interesting question here is "which is the biggest".
func sort_by(column: StringName, ascending: bool = false) -> void:
	var key: String = String(column)
	_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var av: Variant = a.get(key, 0)
		var bv: Variant = b.get(key, 0)
		if typeof(av) == TYPE_STRING or typeof(av) == TYPE_STRING_NAME:
			var sa: String = String(av)
			var sb: String = String(bv)
			return sa < sb if ascending else sa > sb
		var fa: float = float(av)
		var fb: float = float(bv)
		if is_equal_approx(fa, fb):
			# A stable tie-break, so two runs of the same build produce the same
			# table and a screenshot diff means something.
			return String(a["item"]) < String(b["item"])
		return fa < fb if ascending else fa > fb)


## The item the screen should open on: the bottleneck if there is one, the
## busiest line otherwise, and the first row if the factory is asleep.
func default_selection() -> StringName:
	if _bottleneck != &"":
		return _bottleneck
	if _rows.is_empty():
		return &""
	var best: Dictionary = _rows[0]
	for r: Dictionary in _rows:
		if float(r["made"]) > float(best["made"]):
			best = r
	return StringName(String(best["item"]))


## Totals across the window, for the strip above the table.
## {items_per_min, active_lines, deepest, starved_machines, blocked_machines}
func summary() -> Dictionary:
	var per_min: float = 0.0
	var lines: int = 0
	var starved: int = 0
	var blocked: int = 0
	for r: Dictionary in _rows:
		var made: float = float(r["made"])
		per_min += made
		if made > 0.001:
			lines += 1
		starved += int(r["starving"])
		blocked += int(r["blocked"])
	return {"items_per_min": per_min, "active_lines": lines, "items": _rows.size(),
		"starved_machines": starved, "blocked_machines": blocked}


func row_for(item: StringName) -> Dictionary:
	for r: Dictionary in _rows:
		if StringName(String(r["item"])) == item:
			return r
	return {}


# ==================================================================  build ===

func _build(track: LcnStatTrack, window: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var starving: Dictionary[StringName, int] = {}
	var blocked: Dictionary[StringName, int] = {}
	_read_stalls(starving, blocked)

	var n: int = track.sample_count()
	var span: int = n - 1 if window <= 0 else mini(n - 1, window)
	if span < 1:
		return out
	var seconds: float = float(span) * track.sample_seconds()
	var per_min: float = 60.0 / maxf(0.001, seconds)

	var total_made: float = 0.0
	for item: StringName in recorder.items:
		var p: LcnStatSeries = track.series(LcnStatsDefs.produced_key(item))
		var c: LcnStatSeries = track.series(LcnStatsDefs.consumed_key(item))
		var s: LcnStatSeries = track.series(LcnStatsDefs.stock_key(item))
		if p == null:
			continue
		var made: float = (p.last() - p.back(span)) * per_min
		var used: float = ((c.last() - c.back(span)) * per_min) if c != null else 0.0
		var stock: float = s.last() if s != null else 0.0
		var stock_delta: float = (stock - s.back(span)) if s != null else 0.0
		total_made += made
		out.append({
			"item": String(item),
			"label": LcnStatsDefs.item_label(item),
			"colour": LcnStatsDefs.item_colour(item),
			"made": made,
			"used": used,
			"net": made - used,
			"stock": stock,
			"stock_delta": stock_delta,
			"starving": float(starving.get(item, 0)),
			"blocked": float(blocked.get(item, 0)),
			"share": 0.0,
			"bottleneck": false,
			"verdict": "",
		})
	for row: Dictionary in out:
		row["share"] = float(row["made"]) / maxf(0.001, total_made)
		row["verdict"] = _verdict(row)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["item"]) < String(b["item"]))
	return out


## Machines stopped right now, grouped by the item they are stopped on. This is
## the evidence the bottleneck verdict is built from.
func _read_stalls(starving: Dictionary[StringName, int],
		blocked: Dictionary[StringName, int]) -> void:
	if _production == null or not _production.has_method("stalled_machines"):
		return
	for entry: Dictionary in _production.call("stalled_machines"):
		var reason: StringName = StringName(String(entry.get("reason", "")))
		var item: StringName = StringName(String(entry.get("item", "")))
		if String(item) == "":
			continue
		if reason == STARVED_REASON:
			starving[item] = starving.get(item, 0) + 1
		elif reason == FULL_REASON:
			blocked[item] = blocked.get(item, 0) + 1


func _verdict(row: Dictionary) -> String:
	var starving: int = int(row["starving"])
	var blocked: int = int(row["blocked"])
	var made: float = float(row["made"])
	var used: float = float(row["used"])
	if starving > 0:
		return "%d machine%s waiting" % [starving, "" if starving == 1 else "s"]
	if blocked > 0:
		return "%d backed up" % blocked
	if used > 0.0 and made < used * 0.95:
		return "short %s/min" % LcnStatsTheme.compact(used - made)
	if made > 0.0 and used <= 0.001:
		return "piling up"
	if made <= 0.001 and used <= 0.001:
		return "idle"
	return "balanced"


## The one item to blame, and the sentence that explains why.
func _pick_bottleneck() -> void:
	_bottleneck = &""
	_headline = ""
	if _rows.is_empty():
		_headline = "Nothing has been produced yet."
		return

	var best: Dictionary = {}
	var best_score: float = 0.0
	for row: Dictionary in _rows:
		var score: float = float(row["starving"]) * 100.0
		score += float(row["blocked"]) * 8.0
		var deficit: float = float(row["used"]) - float(row["made"])
		if deficit > 0.0:
			score += 10.0 * deficit / maxf(0.001, float(row["used"]))
		if float(row["stock"]) <= 0.0 and float(row["used"]) > 0.0:
			score += 6.0
		if score > best_score:
			best_score = score
			best = row
	if best.is_empty() or best_score <= 0.0:
		var busiest: Dictionary = _rows[0]
		for r: Dictionary in _rows:
			if float(r["made"]) > float(busiest["made"]):
				busiest = r
		if float(busiest["made"]) <= 0.001:
			# "Nothing is starved, the busiest line is at 0/min" is technically
			# true and useless. A factory that has not started says so.
			_headline = "Nothing has been made in this window. No machine finished a craft."
			return
		_headline = "Nothing is starved. %s is the busiest line at %s/min." % [
			String(busiest["label"]), LcnStatsTheme.compact(float(busiest["made"]))]
		return

	_bottleneck = StringName(String(best["item"]))
	best["bottleneck"] = true
	var starving: int = int(best["starving"])
	if starving > 0:
		_headline = "%s is the bottleneck — %d machine%s standing idle waiting for it, %s/min made against %s/min asked for." % [
			String(best["label"]), starving, "" if starving == 1 else "s",
			LcnStatsTheme.compact(float(best["made"])),
			LcnStatsTheme.compact(float(best["used"]))]
		return
	if int(best["blocked"]) > 0:
		_headline = "%s is backing up — %d machine%s cannot put it anywhere. Nothing downstream is taking it." % [
			String(best["label"]), int(best["blocked"]),
			"" if int(best["blocked"]) == 1 else "s"]
		return
	_headline = "%s is short: %s/min made against %s/min consumed." % [
		String(best["label"]), LcnStatsTheme.compact(float(best["made"])),
		LcnStatsTheme.compact(float(best["used"]))]
