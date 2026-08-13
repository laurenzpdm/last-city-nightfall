class_name LcnNightReport
extends RefCounted
## The after-action report. What the night cost, and what nearly ended it. [P20]
##
## Built at dawn from the recorded history between the tick the sun went down
## and the tick it came back up. Nothing here is measured live; it is all
## differences across a window of the mid-resolution track, which is why the
## report can be rebuilt for any past night at any time and why it costs nothing
## while the night is actually happening.
##
## The shape is deliberate and it is the "one more day" screen:
##
##   HELD / LOST      the verdict, in three words
##   WHAT YOU MADE    the six biggest production lines of the night
##   WHAT IT COST     heat burned on defence, fuel, people, buildings
##   WHAT NEARLY WENT the closest call, worded — the buffer that hit zero for
##                    forty seconds, the eleven buildings that froze, the hope
##                    that fell through the floor
##
## A report that only lists totals is a spreadsheet. The closest call is what
## makes a player rebuild the grid before the next dusk.

## Items listed in the produced / consumed columns.
const TOP_N: int = 6


## Builds one report. `night` is a band from [LcnStatsJournal]; an unfinished
## night reports what has happened so far, which is what the live panel shows.
static func build(recorder: LcnStatsRecorder, journal: LcnStatsJournal,
		night: Dictionary) -> Dictionary:
	if recorder == null or night.is_empty():
		return {}
	var from_tick: int = int(night.get("from_tick", 0))
	var to_tick: int = int(night.get("to_tick", -1))
	var track: LcnStatTrack = _best_track(recorder, from_tick)
	if track == null or track.sample_count() < 2:
		return {}
	if to_tick < 0:
		to_tick = track.latest_tick
	var a: int = track.index_at_tick(from_tick)
	var b: int = track.index_at_tick(to_tick)
	if a < 0 or b <= a:
		return {}

	var seconds: float = float(to_tick - from_tick) * 0.05
	var report: Dictionary = {
		"night": int(night.get("night", 0)),
		"from_tick": from_tick,
		"to_tick": to_tick,
		"seconds": seconds,
		"complete": int(night.get("to_tick", -1)) >= 0,
		"produced": _top_items(recorder, track, a, b, LcnStatsDefs.P_PRODUCED),
		"consumed": _top_items(recorder, track, a, b, LcnStatsDefs.P_CONSUMED),
	}
	report["heat"] = _heat(track, a, b)
	report["combat"] = _combat(track, a, b)
	report["society"] = _society(track, a, b)
	report["city"] = _city(track, a, b)
	report["events"] = _events(journal, from_tick, to_tick)
	report["closest_call"] = _closest_call(report)
	report["verdict"] = _verdict(report)
	report["headline"] = _headline(report)
	return report


## The finest track that still reaches back to the start of the night. A night
## is minutes long, so the fine track almost never qualifies and the mid track
## almost always does — but a very long day falls through to the run track
## rather than reporting half a night as a whole one.
static func _best_track(recorder: LcnStatsRecorder, from_tick: int) -> LcnStatTrack:
	for track: LcnStatTrack in [recorder.fine, recorder.mid, recorder.run]:
		if track.sample_count() >= 2 and track.oldest_tick <= from_tick:
			return track
	return recorder.run


static func _top_items(recorder: LcnStatsRecorder, track: LcnStatTrack,
		a: int, b: int, prefix: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for item: StringName in recorder.items:
		var key := StringName(prefix + String(item))
		var s: LcnStatSeries = track.series(key)
		if s == null:
			continue
		var amount: float = s.at(b) - s.at(a)
		if amount <= 0.5:
			continue
		out.append({
			"item": String(item),
			"label": LcnStatsDefs.item_label(item),
			"colour": LcnStatsDefs.item_colour(item),
			"amount": amount,
		})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if is_equal_approx(float(x["amount"]), float(y["amount"])):
			return String(x["item"]) < String(y["item"])
		return float(x["amount"]) > float(y["amount"]))
	return out.slice(0, TOP_N)


static func _heat(track: LcnStatTrack, a: int, b: int) -> Dictionary:
	var deficit: LcnStatSeries = track.series(&"heat_deficit")
	var buffer: LcnStatSeries = track.series(&"heat_buffer")
	var frozen: LcnStatSeries = track.series(&"heat_frozen")
	var brownouts: LcnStatSeries = track.series(&"heat_brownouts")
	var worst_deficit: float = 0.0
	var min_buffer: float = INF
	var start_buffer: float = buffer.at(a) if buffer != null else 0.0
	var peak_frozen: float = 0.0
	var deficit_samples: int = 0
	var longest_run: int = 0
	var run: int = 0
	for i: int in range(a, b + 1):
		if deficit != null:
			var d: float = deficit.at(i)
			worst_deficit = maxf(worst_deficit, d)
			if d > 0.01:
				deficit_samples += 1
				run += 1
				longest_run = maxi(longest_run, run)
			else:
				run = 0
		if buffer != null:
			min_buffer = minf(min_buffer, buffer.at(i))
		if frozen != null:
			peak_frozen = maxf(peak_frozen, frozen.at(i))
	if min_buffer == INF:
		min_buffer = 0.0
	var sample_s: float = track.sample_seconds()
	return {
		"worst_deficit": worst_deficit,
		"deficit_seconds": float(deficit_samples) * sample_s,
		"longest_deficit_seconds": float(longest_run) * sample_s,
		"min_buffer": min_buffer,
		"start_buffer": start_buffer,
		"end_buffer": buffer.at(b) if buffer != null else 0.0,
		"peak_frozen": peak_frozen,
		"brownouts": (brownouts.at(b) - brownouts.at(a)) if brownouts != null else 0.0,
	}


static func _combat(track: LcnStatTrack, a: int, b: int) -> Dictionary:
	return {
		"kills": _delta(track, &"kills", a, b),
		"damage_taken": _delta(track, &"damage_taken", a, b),
		"damage_dealt": _delta(track, &"damage_dealt", a, b),
		"structures_lost": _delta(track, &"structures_lost", a, b),
		"defence_heat": _delta(track, &"defence_heat", a, b),
		"peak_enemies": _peak(track, &"enemies_alive", a, b),
	}


static func _society(track: LcnStatTrack, a: int, b: int) -> Dictionary:
	return {
		"deaths": _delta(track, &"deaths", a, b),
		"pop_start": _at(track, &"pop", a),
		"pop_end": _at(track, &"pop", b),
		"hope_start": _at(track, &"hope", a),
		"hope_end": _at(track, &"hope", b),
		"hope_low": _trough(track, &"hope", a, b),
		"discontent_start": _at(track, &"discontent", a),
		"discontent_end": _at(track, &"discontent", b),
		"discontent_high": _peak(track, &"discontent", a, b),
		"warmth_low": _trough(track, &"avg_warmth", a, b),
		"coldest": _trough(track, &"temperature", a, b),
	}


static func _city(track: LcnStatTrack, a: int, b: int) -> Dictionary:
	return {
		"crafts": _delta(track, &"crafts", a, b),
		"items_moved": _delta(track, &"items_moved", a, b),
		"buildings_start": _at(track, &"buildings", a),
		"buildings_end": _at(track, &"buildings", b),
		"stalled_peak": _peak(track, &"machines_stalled", a, b),
	}


static func _events(journal: LcnStatsJournal, from_tick: int, to_tick: int) -> Array[Dictionary]:
	if journal == null:
		return []
	return journal.between(from_tick, to_tick,
		[LcnStatsJournal.Kind.LAW, LcnStatsJournal.Kind.RESEARCH,
		LcnStatsJournal.Kind.WAVE, LcnStatsJournal.Kind.STORM,
		LcnStatsJournal.Kind.LOSS, LcnStatsJournal.Kind.END])


## The one line that makes a player go back and change something. Candidates are
## scored on how close each came to ending the run, and the worst one is worded.
static func _closest_call(report: Dictionary) -> String:
	var heat: Dictionary = report["heat"]
	var soc: Dictionary = report["society"]
	var com: Dictionary = report["combat"]
	var best: String = ""
	var best_score: float = 0.0

	var longest: float = float(heat["longest_deficit_seconds"])
	if longest > 1.0:
		var score: float = 40.0 + longest
		if score > best_score:
			best_score = score
			best = "The grid ran short for %s without a break — the longest stretch of the night." % \
				LcnStatsTheme.duration(longest)
	var frozen: float = float(heat["peak_frozen"])
	if frozen >= 1.0:
		var score2: float = 60.0 + frozen * 8.0
		if score2 > best_score:
			best_score = score2
			best = "%d building%s went below working temperature at once. Another minute and they would not have come back." % \
				[int(frozen), "" if int(frozen) == 1 else "s"]
	var deaths: float = float(soc["deaths"])
	if deaths >= 1.0:
		var score3: float = 100.0 + deaths * 10.0
		if score3 > best_score:
			best_score = score3
			best = "%d %s died before dawn." % [int(deaths),
				"person" if int(deaths) == 1 else "people"]
	if float(soc["hope_low"]) < 0.20:
		var score4: float = 90.0 + (0.20 - float(soc["hope_low"])) * 200.0
		if score4 > best_score:
			best_score = score4
			best = "Hope fell to %.2f. Much lower and they stop believing there is a morning." % \
				float(soc["hope_low"])
	if float(soc["discontent_high"]) > 0.75:
		var score5: float = 85.0 + (float(soc["discontent_high"]) - 0.75) * 200.0
		if score5 > best_score:
			best_score = score5
			best = "Discontent peaked at %.2f. They are one bad law from refusing you." % \
				float(soc["discontent_high"])
	if float(com["structures_lost"]) >= 1.0:
		var score6: float = 95.0 + float(com["structures_lost"]) * 12.0
		if score6 > best_score:
			best_score = score6
			best = "%d structure%s taken apart while you watched." % [
				int(com["structures_lost"]),
				"" if int(com["structures_lost"]) == 1 else "s"]
	if best == "":
		best = "Nothing came close. The grid held, nobody died, and every machine that started the night was still running at dawn."
	return best


static func _verdict(report: Dictionary) -> String:
	var soc: Dictionary = report["society"]
	var com: Dictionary = report["combat"]
	var heat: Dictionary = report["heat"]
	if float(soc["deaths"]) >= 5.0 or float(com["structures_lost"]) >= 3.0:
		return "MAULED"
	if float(soc["deaths"]) > 0.0 or float(com["structures_lost"]) > 0.0 \
			or float(heat["peak_frozen"]) > 0.0:
		return "HELD, BARELY"
	if float(heat["longest_deficit_seconds"]) > 5.0:
		return "HELD"
	return "HELD CLEAN"


static func _headline(report: Dictionary) -> String:
	var com: Dictionary = report["combat"]
	var soc: Dictionary = report["society"]
	var parts: PackedStringArray = PackedStringArray()
	parts.append("Night %d, %s" % [int(report["night"]),
		LcnStatsTheme.duration(float(report["seconds"]))])
	if float(com["kills"]) > 0.0:
		parts.append("%d killed" % int(com["kills"]))
	if float(soc["deaths"]) > 0.0:
		parts.append("%d lost" % int(soc["deaths"]))
	var produced: Array = report["produced"]
	if not produced.is_empty():
		parts.append("%s %s made" % [
			LcnStatsTheme.compact(float((produced[0] as Dictionary)["amount"])),
			String((produced[0] as Dictionary)["label"]).to_lower()])
	return "  ·  ".join(parts)


# ------------------------------------------------------------------ helpers --

static func _delta(track: LcnStatTrack, key: StringName, a: int, b: int) -> float:
	var s: LcnStatSeries = track.series(key)
	return 0.0 if s == null else maxf(0.0, s.at(b) - s.at(a))


static func _at(track: LcnStatTrack, key: StringName, i: int) -> float:
	var s: LcnStatSeries = track.series(key)
	return 0.0 if s == null else s.at(i)


static func _peak(track: LcnStatTrack, key: StringName, a: int, b: int) -> float:
	var s: LcnStatSeries = track.series(key)
	if s == null:
		return 0.0
	var best: float = s.at(a)
	for i: int in range(a, b + 1):
		best = maxf(best, s.at(i))
	return best


static func _trough(track: LcnStatTrack, key: StringName, a: int, b: int) -> float:
	var s: LcnStatSeries = track.series(key)
	if s == null:
		return 0.0
	var best: float = s.at(a)
	for i: int in range(a, b + 1):
		best = minf(best, s.at(i))
	return best
