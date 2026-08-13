class_name NarrativeJournal
extends RefCounted
## The record of the winter. Everything that happened to Caldera Nine, in order,
## with the reason it happened and what the player did about it.
##
## Two streams, because they are read in two different ways:
##
##   entries  the CHRONICLE. Beats, dilemmas, decisions, deaths that mattered.
##            Read after the fact, at the end of a run, to answer "how did we
##            get here". Every entry carries its causes, so the chronicle is
##            also the audit trail for this whole part: if an event fired for
##            no reason, the chronicle says so in the player's own language.
##
##   feed     the TICKER. Overheard lines, obituaries, scout reports. Read in
##            the corner of the eye while playing. Short-lived by design.
##
## Both are ring buffers. This is serialized into every save and into every
## harness state dump, and a chronicle that grows without a ceiling would make
## a twelve-hour run's state.json unreadable.

var entries: Array[Dictionary] = []
var feed: Array[Dictionary] = []

var _next_seq: int = 1


func reset() -> void:
	entries.clear()
	feed.clear()
	_next_seq = 1


## A thing that happened, with the state that caused it.
func record(tick: int, day: int, kind: StringName, id: StringName, title: String,
		text: String, causes: PackedStringArray = PackedStringArray()) -> Dictionary:
	var row: Dictionary = {
		"seq": _next_seq,
		"tick": tick,
		"day": day,
		"kind": String(kind),
		"id": String(id),
		"title": title,
		"text": text,
		"causes": _to_array(causes),
	}
	_next_seq += 1
	entries.append(row)
	if entries.size() > NarrativeDefs.JOURNAL_KEEP:
		entries.remove_at(0)
	return row


## Attaches the outcome of a decision to the entry that posed it.
func close(seq: int, choice: String, outcome: String, effects: PackedStringArray) -> void:
	for i: int in range(entries.size() - 1, -1, -1):
		var row: Dictionary = entries[i]
		if int(row.get("seq", 0)) != seq:
			continue
		row["choice"] = choice
		row["outcome"] = outcome
		row["effects"] = _to_array(effects)
		return


func say(tick: int, day: int, kind: StringName, line: String, source: String = "") -> void:
	feed.append({
		"tick": tick, "day": day, "kind": String(kind),
		"text": line, "source": source,
	})
	if feed.size() > NarrativeDefs.FEED_KEEP:
		feed.remove_at(0)


## Newest last, at most `n`. What a chronicle panel renders.
func last(n: int = 20) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var start: int = maxi(0, entries.size() - n)
	for i: int in range(start, entries.size()):
		out.append((entries[i] as Dictionary).duplicate(true))
	return out


## Newest FIRST, at most `n`. What a ticker renders.
func recent_feed(n: int = 8) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var start: int = maxi(0, feed.size() - n)
	for i: int in range(feed.size() - 1, start - 1, -1):
		out.append((feed[i] as Dictionary).duplicate(true))
	return out


func count_of_kind(kind: StringName) -> int:
	var n: int = 0
	for row: Dictionary in entries:
		if String(row.get("kind", "")) == String(kind):
			n += 1
	return n


func serialize() -> Dictionary:
	return {
		"next_seq": _next_seq,
		"entries": entries.duplicate(true),
		"feed": feed.duplicate(true),
	}


func deserialize(data: Dictionary) -> void:
	reset()
	_next_seq = int(data.get("next_seq", 1))
	for raw: Variant in data.get("entries", []):
		if typeof(raw) == TYPE_DICTIONARY:
			entries.append((raw as Dictionary).duplicate(true))
	for raw: Variant in data.get("feed", []):
		if typeof(raw) == TYPE_DICTIONARY:
			feed.append((raw as Dictionary).duplicate(true))


func _to_array(s: PackedStringArray) -> Array:
	var out: Array = []
	for line: String in s:
		out.append(line)
	return out
