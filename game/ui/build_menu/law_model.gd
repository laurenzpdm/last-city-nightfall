class_name LcnLawModel
extends RefCounted
## [P18] The Book of Laws, as data.
##
## A law screen is not a shop. Frostpunk's Book works because signing a law is
## slow, worded, and *closes doors* — and the screen says so before you sign.
## So this model is built around three things, and the panel is forbidden from
## showing a law without all three:
##
##   THE PROSE     the authored text, in full, not a stat line
##   THE PRICE     what it costs to sign and what it costs to keep
##   THE COST YOU  every law this one forecloses, by name, resolved from both
##   CANNOT UNDO   explicit `forecloses` lists and from exclusive slots — if two
##                 laws share a slot, signing one buries the other, and that is
##                 a fact the content already states and nobody was showing.
##
## Duck-typed against [P06]'s content and system, so it lights up when they land
## and honestly reports an empty book until then.

enum Status { AVAILABLE, ENACTED, BLOCKED, FORECLOSED }


class LawRecord extends RefCounted:
	var id: StringName = &""
	var title: String = ""
	## The authored paragraph. The whole point of the screen.
	var prose: String = ""
	## One-line mechanical summary, when the content carries one.
	var summary: String = ""
	var chapter: StringName = &"the_book"
	var chapter_title: String = "The Book"
	## Exclusive group: signing one law in a slot forecloses its siblings.
	var slot: StringName = &""
	var sort_order: int = 0
	var cost: Dictionary = {}
	var cost_points: float = 0.0
	var upkeep: Dictionary = {}
	var requires: Array[StringName] = []
	var forecloses: Array[StringName] = []
	## Human-readable consequences the content lists.
	var effects: PackedStringArray = PackedStringArray()
	var status: int = Status.AVAILABLE
	var blocked_reason: String = ""
	## Titles of every law this one closes off, resolved and sorted.
	var forecloses_titles: PackedStringArray = PackedStringArray()
	var signed_tick: int = -1
	var res: Resource = null

	func is_signed() -> bool:
		return status == Status.ENACTED

	func cost_label() -> String:
		if not cost.is_empty():
			return LcnUiFormat.items(cost)
		if cost_points > 0.0:
			return "%s" % LcnUiFormat.num(cost_points)
		return "nothing but the signature"

	func weight_line() -> String:
		if forecloses_titles.is_empty():
			return "Signing this closes nothing else."
		return "Signing this buries %s. There is no second signature." % \
			LcnUiFormat.prose_list(forecloses_titles)


var laws: Array[LawRecord] = []

var _by_id: Dictionary[StringName, LawRecord] = {}
var _chapters: Array[StringName] = []
var _revision: int = 0
var _has_system: bool = false


func rebuild(society: Object, registry: Object = null) -> void:
	laws.clear()
	_by_id.clear()
	_chapters.clear()
	_revision += 1
	_has_system = society != null

	_ingest(registry)
	if laws.is_empty():
		_ingest_from_system(society)
	_resolve_foreclosure()
	laws.sort_custom(_law_less)
	var seen: Dictionary[StringName, bool] = {}
	for l: LawRecord in laws:
		if not seen.has(l.chapter):
			seen[l.chapter] = true
			_chapters.append(l.chapter)
	refresh_state(society)


func revision() -> int:
	return _revision


func is_empty() -> bool:
	return laws.is_empty()


## True when [P06] is in this build. False means the screen is showing content
## with no system behind it, and it must say so rather than pretend.
func has_system() -> bool:
	return _has_system


func chapters() -> Array[StringName]:
	return _chapters.duplicate()


func chapter_title(id: StringName) -> String:
	for l: LawRecord in laws:
		if l.chapter == id:
			return l.chapter_title
	return LcnUiFormat.item_name(id)


func laws_in(chapter: StringName) -> Array[LawRecord]:
	var out: Array[LawRecord] = []
	for l: LawRecord in laws:
		if l.chapter == chapter:
			out.append(l)
	return out


func law(id: StringName) -> LawRecord:
	return _by_id.get(id)


func signed_count() -> int:
	var n: int = 0
	for l: LawRecord in laws:
		if l.is_signed():
			n += 1
	return n


# ---------------------------------------------------------------- ingest -----

func _ingest(registry: Object) -> void:
	if registry == null or not registry.has_method(&"all"):
		return
	for raw: Variant in registry.call(&"all", "laws"):
		var res: Resource = raw as Resource
		if res == null:
			continue
		var l := LawRecord.new()
		l.res = res
		l.id = StringName(String(res.get(&"id")))
		if String(l.id) == "":
			l.id = StringName(res.resource_path.get_file().get_basename())
		if String(l.id) == "":
			continue
		l.title = _first_string(res, [&"title", &"display_name", &"name"])
		if l.title == "":
			l.title = LcnUiFormat.item_name(l.id)
		l.prose = _first_string(res, [&"prose", &"text", &"body", &"description", &"flavour"])
		l.summary = _first_string(res, [&"summary", &"effect_text", &"subtitle"])
		var chapter: String = _first_string(res, [&"chapter", &"branch", &"category", &"book"])
		if chapter != "":
			l.chapter = StringName(chapter)
			l.chapter_title = LcnUiFormat.item_name(l.chapter)
		l.slot = StringName(_first_string(res, [&"slot", &"exclusive_group", &"group", &"pair"]))
		l.sort_order = int(res.get(&"sort_order"))
		for field: StringName in [&"cost", &"cost_items", &"price"]:
			var c: Variant = res.get(field)
			if typeof(c) == TYPE_DICTIONARY and not (c as Dictionary).is_empty():
				l.cost = c
				break
			if (typeof(c) == TYPE_FLOAT or typeof(c) == TYPE_INT) and float(c) > 0.0:
				l.cost_points = float(c)
		var up: Variant = res.get(&"upkeep")
		if typeof(up) == TYPE_DICTIONARY:
			l.upkeep = up
		l.requires = _names(res, [&"requires", &"prereqs", &"needs"])
		l.forecloses = _names(res, [&"forecloses", &"excludes", &"blocks", &"conflicts", &"opposes"])
		for e: String in _strings(res, [&"effects", &"consequences", &"outcomes"]):
			l.effects.append(e)
		_add(l)


## Some society systems keep the book in code rather than in content. If [P06]
## publishes one, read it — the screen is about the laws, not about where they
## happen to be stored.
func _ingest_from_system(society: Object) -> void:
	if society == null:
		return
	for method: StringName in [&"book_of_laws", &"all_laws", &"laws"]:
		if not society.has_method(method):
			continue
		var raw: Variant = society.call(method)
		if typeof(raw) != TYPE_ARRAY:
			continue
		for entry: Variant in (raw as Array):
			if typeof(entry) == TYPE_DICTIONARY:
				_add(_from_dict(entry))
			elif entry is Resource:
				var l := LawRecord.new()
				l.res = entry
				l.id = StringName(String((entry as Resource).get(&"id")))
				l.title = String((entry as Resource).get(&"title"))
				if l.title == "":
					l.title = LcnUiFormat.item_name(l.id)
				l.prose = String((entry as Resource).get(&"prose"))
				_add(l)
		if not laws.is_empty():
			return


func _from_dict(d: Dictionary) -> LawRecord:
	var l := LawRecord.new()
	l.id = StringName(String(d.get("id", "")))
	l.title = String(d.get("title", d.get("name", LcnUiFormat.item_name(l.id))))
	l.prose = String(d.get("prose", d.get("text", d.get("description", ""))))
	l.summary = String(d.get("summary", ""))
	l.chapter = StringName(String(d.get("chapter", "the_book")))
	l.chapter_title = LcnUiFormat.item_name(l.chapter)
	l.slot = StringName(String(d.get("slot", "")))
	l.sort_order = int(d.get("sort_order", 0))
	var c: Variant = d.get("cost", {})
	if typeof(c) == TYPE_DICTIONARY:
		l.cost = c
	elif typeof(c) == TYPE_FLOAT or typeof(c) == TYPE_INT:
		l.cost_points = float(c)
	l.requires = _name_list(d.get("requires", []))
	l.forecloses = _name_list(d.get("forecloses", d.get("excludes", [])))
	for e: Variant in d.get("effects", []):
		l.effects.append(String(e))
	return l


func _add(l: LawRecord) -> void:
	if String(l.id) == "" or _by_id.has(l.id):
		return
	_by_id[l.id] = l
	laws.append(l)


## Explicit foreclosure lists plus exclusive-slot siblings, made symmetric —
## if A forecloses B then B forecloses A, because a player looking at B must be
## told what signing A would have cost them.
func _resolve_foreclosure() -> void:
	var by_slot: Dictionary[StringName, Array] = {}
	for l: LawRecord in laws:
		if String(l.slot) == "":
			continue
		var bucket: Array = by_slot.get(l.slot, [])
		bucket.append(l.id)
		by_slot[l.slot] = bucket
	for l2: LawRecord in laws:
		var set: Dictionary[StringName, bool] = {}
		for f: StringName in l2.forecloses:
			if _by_id.has(f) and f != l2.id:
				set[f] = true
		if String(l2.slot) != "":
			for sib: Variant in by_slot.get(l2.slot, []):
				var sid := StringName(String(sib))
				if sid != l2.id:
					set[sid] = true
		for other: LawRecord in laws:
			if other.id != l2.id and other.forecloses.has(l2.id):
				set[other.id] = true
		var keys: Array = set.keys()
		keys = LcnUiFormat.sorted_names(keys)
		var resolved: Array[StringName] = []
		var titles: PackedStringArray = PackedStringArray()
		for k: Variant in keys:
			var kid := StringName(String(k))
			resolved.append(kid)
			titles.append((_by_id[kid] as LawRecord).title)
		l2.forecloses = resolved
		l2.forecloses_titles = titles


static func _law_less(a: LawRecord, b: LawRecord) -> bool:
	if a.chapter != b.chapter:
		return String(a.chapter) < String(b.chapter)
	if a.sort_order != b.sort_order:
		return a.sort_order < b.sort_order
	if a.title != b.title:
		return a.title < b.title
	return String(a.id) < String(b.id)


# ----------------------------------------------------------------- state -----

## Re-reads which laws are signed and which are still open. Called whenever
## Bus.law_enacted fires, not per frame.
func refresh_state(society: Object) -> void:
	var signed: Dictionary[StringName, bool] = {}
	if society != null:
		for method: StringName in [&"enacted_laws", &"signed_laws", &"active_laws"]:
			if not society.has_method(method):
				continue
			var raw: Variant = society.call(method)
			if typeof(raw) == TYPE_ARRAY:
				for e: Variant in (raw as Array):
					signed[StringName(String(e))] = true
				break
			if typeof(raw) == TYPE_DICTIONARY:
				for k: Variant in (raw as Dictionary).keys():
					signed[StringName(String(k))] = true
				break

	for l: LawRecord in laws:
		var is_signed: bool = signed.has(l.id)
		if not is_signed and society != null and society.has_method(&"is_enacted"):
			is_signed = bool(society.call(&"is_enacted", l.id))
		l.status = Status.ENACTED if is_signed else Status.AVAILABLE
		l.blocked_reason = ""

	for l2: LawRecord in laws:
		if l2.status == Status.ENACTED:
			continue
		for f: StringName in l2.forecloses:
			var other: LawRecord = _by_id.get(f)
			if other != null and other.status == Status.ENACTED:
				l2.status = Status.FORECLOSED
				l2.blocked_reason = "%s was signed instead." % other.title
				break
		if l2.status != Status.AVAILABLE:
			continue
		var missing: PackedStringArray = PackedStringArray()
		for r: StringName in l2.requires:
			var pre: LawRecord = _by_id.get(r)
			if pre != null and pre.status != Status.ENACTED:
				missing.append(pre.title)
		if not missing.is_empty():
			l2.status = Status.BLOCKED
			l2.blocked_reason = "Waiting on %s." % LcnUiFormat.prose_list(missing)
			continue
		if society != null and society.has_method(&"can_enact"):
			var verdict: Variant = society.call(&"can_enact", l2.id)
			if typeof(verdict) == TYPE_DICTIONARY:
				if not bool((verdict as Dictionary).get("ok", true)):
					l2.status = Status.BLOCKED
					l2.blocked_reason = String((verdict as Dictionary).get("reason", "Not yet."))
			elif typeof(verdict) == TYPE_BOOL and not bool(verdict):
				l2.status = Status.BLOCKED
				l2.blocked_reason = "Not yet."


## The command the panel submits when the player signs. Kept here so the panel
## never invents a command shape and so a test can assert on it.
static func enact_command(id: StringName) -> Dictionary:
	return {"system": &"society", "op": "enact_law", "law": String(id)}


static func status_word(status: int) -> String:
	match status:
		Status.ENACTED: return "signed"
		Status.BLOCKED: return "not yet"
		Status.FORECLOSED: return "closed"
	return "open"


static func status_tone(status: int) -> int:
	match status:
		Status.ENACTED: return LcnUiStyle.Tone.GOOD
		Status.BLOCKED: return LcnUiStyle.Tone.WARN
		Status.FORECLOSED: return LcnUiStyle.Tone.DIM
	return LcnUiStyle.Tone.ACCENT


# --------------------------------------------------------------- reading -----

static func _first_string(res: Resource, fields: Array[StringName]) -> String:
	for f: StringName in fields:
		var v: Variant = res.get(f)
		if (typeof(v) == TYPE_STRING or typeof(v) == TYPE_STRING_NAME) and String(v) != "":
			return String(v)
	return ""


static func _names(res: Resource, fields: Array[StringName]) -> Array[StringName]:
	for f: StringName in fields:
		var v: Variant = res.get(f)
		var got: Array[StringName] = _name_list(v)
		if not got.is_empty():
			return got
	return []


static func _name_list(raw: Variant) -> Array[StringName]:
	var out: Array[StringName] = []
	if typeof(raw) == TYPE_ARRAY:
		for e: Variant in (raw as Array):
			var s := StringName(String(e))
			if String(s) != "" and not out.has(s):
				out.append(s)
	elif (typeof(raw) == TYPE_STRING or typeof(raw) == TYPE_STRING_NAME) and String(raw) != "":
		out.append(StringName(String(raw)))
	return out


static func _strings(res: Resource, fields: Array[StringName]) -> PackedStringArray:
	for f: StringName in fields:
		var v: Variant = res.get(f)
		if typeof(v) == TYPE_ARRAY:
			var out: PackedStringArray = PackedStringArray()
			for e: Variant in (v as Array):
				out.append(String(e))
			if not out.is_empty():
				return out
	return PackedStringArray()
