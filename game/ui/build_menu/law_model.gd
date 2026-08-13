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
	## The two sides of the argument, as [P06] wrote them. A law screen that
	## shows only the case FOR a law is a shop window; both sides is a decision.
	var argument_for: String = ""
	var argument_against: String = ""
	## What the city says afterwards. Shown only once it has been signed.
	var signed_line: String = ""
	## One-line mechanical summary, when the content carries one.
	var summary: String = ""
	var chapter: StringName = &"the_book"
	var chapter_title: String = "The Book"
	## Sub-heading inside the chapter, as authored ("The Children").
	var section: String = ""
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

	## Hope gained and discontent earned by signing, plus the hours of argument.
	## For [P06]'s Book this IS the price — no law in it costs materials.
	var hope_on_sign: float = 0.0
	var discontent_on_sign: float = 0.0
	var hope_rate: float = 0.0
	var discontent_rate: float = 0.0
	var debate_hours: float = 0.0
	var min_day: int = 0

	func cost_label() -> String:
		var parts: PackedStringArray = PackedStringArray()
		if not cost.is_empty():
			parts.append(LcnUiFormat.items(cost))
		if cost_points > 0.0:
			parts.append(LcnUiFormat.num(cost_points))
		if absf(hope_on_sign) > 0.01:
			parts.append("%s hope" % LcnUiFormat.signed(hope_on_sign))
		if absf(discontent_on_sign) > 0.01:
			parts.append("%s discontent" % LcnUiFormat.signed(discontent_on_sign))
		if absf(hope_rate) > 0.001 or absf(discontent_rate) > 0.001:
			parts.append("%s hope and %s discontent every day it stands" % [
				LcnUiFormat.signed(hope_rate), LcnUiFormat.signed(discontent_rate)])
		if debate_hours > 0.0:
			parts.append("%s hours of argument" % LcnUiFormat.num(debate_hours))
		if parts.is_empty():
			return "nothing but the signature"
		return "   ·   ".join(parts)

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
		l.id = LcnUiFormat.as_name(res.get(&"id"))
		if String(l.id) == "":
			l.id = StringName(res.resource_path.get_file().get_basename())
		if String(l.id) == "":
			continue
		l.title = _first_string(res, [&"title", &"display_name", &"name"])
		if l.title == "":
			l.title = LcnUiFormat.item_name(l.id)
		l.prose = _first_string(res, [&"prose", &"text", &"body", &"description", &"flavour"])
		l.summary = _first_string(res, [&"summary", &"effect_text", &"subtitle"])
		l.argument_for = _first_string(res, [&"argument_for", &"case_for", &"pro"])
		l.argument_against = _first_string(res, [&"argument_against", &"case_against", &"con"])
		l.signed_line = _first_string(res, [&"signed_line", &"aftermath"])
		l.hope_on_sign = LcnUiFormat.as_number(res.get(&"hope_on_sign"))
		l.discontent_on_sign = LcnUiFormat.as_number(res.get(&"discontent_on_sign"))
		l.hope_rate = LcnUiFormat.as_number(res.get(&"hope_rate"))
		l.discontent_rate = LcnUiFormat.as_number(res.get(&"discontent_rate"))
		l.debate_hours = LcnUiFormat.as_number(res.get(&"debate_hours"))
		l.min_day = LcnUiFormat.as_int(res.get(&"min_day"))
		# `section` is the authored chapter heading ("The Children"); `branch` is
		# the machine key. Group by the key, show the heading.
		l.section = _first_string(res, [&"section", &"chapter_title"])
		var chapter: String = _first_string(res, [&"chapter", &"branch", &"category", &"book"])
		if chapter != "" or l.section != "":
			l.chapter = StringName(chapter if chapter != "" else l.section.to_snake_case())
			l.chapter_title = LcnUiFormat.item_name(l.chapter)
		for line: String in _policy_lines(res):
			l.effects.append(line)
		l.slot = StringName(_first_string(res, [&"slot", &"exclusive_group", &"group", &"pair"]))
		l.sort_order = LcnUiFormat.as_int(res.get(&"sort_order"))
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


## Numeric policy and faction shifts, turned into sentences. A law screen that
## printed `child_risk: 0.04` would be a debug view.
static func _policy_lines(res: Resource) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var policy: Variant = res.get(&"policy")
	if typeof(policy) == TYPE_DICTIONARY:
		for k: StringName in LcnUiFormat.sorted_names((policy as Dictionary).keys()):
			var v: float = LcnUiFormat.as_number((policy as Dictionary)[k])
			out.append("%s %s" % [LcnUiFormat.item_name(k), LcnUiFormat.signed(v * 100.0) + "%"])
	var approval: Variant = res.get(&"approval")
	if typeof(approval) == TYPE_DICTIONARY:
		for k2: StringName in LcnUiFormat.sorted_names((approval as Dictionary).keys()):
			var a: float = LcnUiFormat.as_number((approval as Dictionary)[k2])
			out.append("the %s %s it (%s)" % [
				LcnUiFormat.item_name(k2).to_lower(),
				"back" if a >= 0.0 else "resent",
				LcnUiFormat.signed(a)])
	var flags: Variant = res.get(&"flags")
	if typeof(flags) == TYPE_ARRAY:
		for f: Variant in (flags as Array):
			out.append(LcnUiFormat.item_name(LcnUiFormat.as_name(f)))
	return out


## Some society systems keep the book in code rather than in content. If [P06]
## publishes one, read it — the screen is about the laws, not about where they
## happen to be stored.
func _ingest_from_system(society: Object) -> void:
	if society == null:
		return
	for method: StringName in [&"book_view", &"book_of_laws", &"all_laws", &"laws"]:
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
				l.id = LcnUiFormat.as_name((entry as Resource).get(&"id"))
				l.title = LcnUiFormat.as_text((entry as Resource).get(&"title"))
				if l.title == "":
					l.title = LcnUiFormat.item_name(l.id)
				l.prose = LcnUiFormat.as_text((entry as Resource).get(&"prose"))
				_add(l)
		if not laws.is_empty():
			return


func _from_dict(d: Dictionary) -> LawRecord:
	var l := LawRecord.new()
	l.id = LcnUiFormat.as_name(d.get("id", ""))
	l.title = LcnUiFormat.as_text(d.get("title", d.get("name", "")))
	if l.title == "":
		l.title = LcnUiFormat.item_name(l.id)
	l.prose = LcnUiFormat.as_text(d.get("prose", d.get("text", d.get("description", ""))))
	l.argument_for = LcnUiFormat.as_text(d.get("argument_for", ""))
	l.argument_against = LcnUiFormat.as_text(d.get("argument_against", ""))
	l.signed_line = LcnUiFormat.as_text(d.get("signed_line", ""))
	l.summary = LcnUiFormat.as_text(d.get("summary", ""))
	l.section = LcnUiFormat.as_text(d.get("section", ""))
	l.chapter = LcnUiFormat.as_name(d.get("chapter", d.get("branch", "the_book")))
	l.chapter_title = LcnUiFormat.item_name(l.chapter)
	l.slot = LcnUiFormat.as_name(d.get("slot", ""))
	l.sort_order = LcnUiFormat.as_int(d.get("sort_order", 0))
	l.forecloses = _name_list(d.get("excludes", []))
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


## [P06] publishes a page-by-page standing for the whole book, including WHY a
## page is closed and which law closed it. When it does, that is the answer —
## re-deriving availability here would produce a second, worse one.
## Returns false when the view was unusable, so the derived path still runs.
func _apply_book_view(society: Object) -> bool:
	var raw: Variant = society.call(&"book_view")
	if typeof(raw) != TYPE_ARRAY or (raw as Array).is_empty():
		return false
	var seen: int = 0
	for entry: Variant in (raw as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = entry
		var l: LawRecord = _by_id.get(LcnUiFormat.as_name(d.get("id", "")))
		if l == null:
			continue
		seen += 1
		l.signed_tick = LcnUiFormat.as_int(d.get("signed_tick", -1))
		l.blocked_reason = LcnUiFormat.as_text(d.get("reason", ""))
		if LcnUiFormat.as_flag(d.get("signed", false)):
			l.status = Status.ENACTED
			l.blocked_reason = ""
			continue
		if LcnUiFormat.as_flag(d.get("pending", false)):
			l.status = Status.BLOCKED
			l.blocked_reason = "On the table — the room is still arguing."
			continue
		if LcnUiFormat.as_flag(d.get("available", false)):
			l.status = Status.AVAILABLE
			l.blocked_reason = ""
			continue
		var blocked_by: StringName = LcnUiFormat.as_name(d.get("blocked_by", ""))
		var other: LawRecord = _by_id.get(blocked_by)
		if other != null and other.forecloses.has(l.id):
			l.status = Status.FORECLOSED
			if l.blocked_reason == "":
				l.blocked_reason = "%s was signed instead." % other.title
		else:
			l.status = Status.BLOCKED
			if l.blocked_reason == "" and other != null:
				l.blocked_reason = "Waiting on %s." % other.title
	return seen > 0


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
	if society != null and society.has_method(&"book_view") and _apply_book_view(society):
		return
	var signed: Dictionary[StringName, bool] = {}
	if society != null:
		for method: StringName in [&"laws_signed", &"enacted_laws", &"signed_laws", &"active_laws"]:
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


## The command the panel submits when the player puts a law to the room. Kept
## here so the panel never invents a command shape and a test can assert on it.
static func enact_command(id: StringName) -> Dictionary:
	return {"system": &"society", "op": "sign", "law": String(id)}


## Takes a proposed law back off the table before the room finishes arguing.
static func withdraw_command() -> Dictionary:
	return {"system": &"society", "op": "withdraw"}


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
