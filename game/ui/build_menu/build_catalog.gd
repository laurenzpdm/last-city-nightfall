class_name LcnBuildCatalog
extends RefCounted
## [P18] The model behind the build palette. Sixty buildings, one keyboard.
##
## Factorio's lesson is that a build menu is a *search problem*, not a layout
## problem: past about twenty entries nobody scans a grid any more, they type.
## So this class is an index first and a list second.
##
##   catalog.rebuild(build_system)
##   for e: Entry in catalog.view(&"power", "coa"):   # tab + typed query
##       ...
##   catalog.note_used(&"coal_generator")             # feeds the recent list
##
## Everything is deterministic: entries sort by (tier, sort_order, name, id),
## search results sort by (score, tier, name, id), and no dictionary is ever
## iterated without sorting its keys first. Two players who type the same three
## letters see the same list in the same order.
##
## Locked buildings stay VISIBLE, dimmed, with the research that opens them.
## Hiding them would hide the game's own roadmap; a player who can see the
## Geothermal Tap greyed out with "needs deep drilling" has just been taught
## something a tutorial would have had to say out loud.

const MAX_RECENT: int = 12
const MAX_FAVOURITES: int = 20
const QUICKBAR_SLOTS: int = 10

## Pseudo-tabs. They are not content categories, they are ways of looking.
const TAB_ALL: StringName = &"__all"
const TAB_FAVOURITES: StringName = &"__favourites"
const TAB_RECENT: StringName = &"__recent"

## The order categories appear in, matching the order a city actually grows:
## make heat, move heat, dig, refine, move goods, house people, store, defend.
const CATEGORY_ORDER: Array[StringName] = [
	&"power", &"heat", &"extraction", &"production", &"logistics",
	&"housing", &"storage", &"defense", &"infrastructure",
]


## One buildable thing, indexed for search.
class Entry extends RefCounted:
	var id: StringName = &""
	var def: Resource = null
	var display_name: String = ""
	var category: StringName = &"infrastructure"
	var tier: int = 1
	var sort_order: int = 0
	var unlocked: bool = true
	var unlock_id: StringName = &""
	## The city already holds all of this kind it is allowed. Live, not indexed:
	## it changes every time something is placed or destroyed, and it is refreshed
	## by `refresh_caps()` on the same poll that feeds the rows their stock.
	var capped: bool = false
	## `max_count`, mirrored so the cap refresh does not re-read the resource.
	var max_count: int = 0
	var tags: Array[StringName] = []
	## Lower-case searchable text: name, id, category and tags.
	var haystack: String = ""
	## Filled by view(); meaningless outside a search.
	var score: int = 0

	func is_locked() -> bool:
		return not unlocked


var entries: Array[Entry] = []

var _by_id: Dictionary[StringName, Entry] = {}
var _by_category: Dictionary[StringName, Array] = {}
var _categories: Array[StringName] = []
var _recent: Array[StringName] = []
var _favourites: Array[StringName] = []
## Cache for view(): "<tab>|<query>" -> Array[Entry]. Cleared on every rebuild.
var _view_cache: Dictionary[String, Array] = {}
var _revision: int = 0


# ------------------------------------------------------------------ build ----

## Re-indexes from [P11]. Safe to call with null — the catalog simply empties,
## which is what happens before a world exists.
func rebuild(build_system: Object) -> void:
	entries.clear()
	_by_id.clear()
	_by_category.clear()
	_categories.clear()
	_view_cache.clear()
	_revision += 1
	if build_system == null or not build_system.has_method(&"all_defs"):
		return

	var defs: Array = build_system.call(&"all_defs")
	for raw: Variant in defs:
		var def: Resource = raw as Resource
		if def == null:
			continue
		var e := Entry.new()
		e.def = def
		e.id = LcnUiFormat.as_name(def.get(&"id"))
		if String(e.id) == "":
			continue
		e.display_name = LcnUiFormat.as_text(def.get(&"display_name"))
		if e.display_name == "":
			e.display_name = LcnUiFormat.item_name(e.id)
		e.category = LcnUiFormat.as_name(def.get(&"category"))
		if String(e.category) == "":
			e.category = &"infrastructure"
		e.tier = LcnUiFormat.as_int(def.get(&"tier"))
		e.sort_order = LcnUiFormat.as_int(def.get(&"sort_order"))
		e.unlock_id = LcnUiFormat.as_name(def.get(&"unlock_id"))
		var tags: Variant = def.get(&"tags")
		if typeof(tags) == TYPE_ARRAY:
			for t: Variant in tags:
				e.tags.append(StringName(String(t)))
		e.unlocked = true
		if String(e.unlock_id) != "" and build_system.has_method(&"is_unlocked"):
			e.unlocked = bool(build_system.call(&"is_unlocked", e.unlock_id))
		e.max_count = LcnUiFormat.as_int(def.get(&"max_count"))
		e.haystack = _haystack(e)
		entries.append(e)
		_by_id[e.id] = e

	entries.sort_custom(_entry_less)
	for e2: Entry in entries:
		var bucket: Array = _by_category.get(e2.category, [])
		bucket.append(e2)
		_by_category[e2.category] = bucket
	_categories = _ordered_categories(_by_category.keys())
	_prune_missing()


## THE FIRST ROW OF THE BUILD MENU WAS A BUILDING NOBODY CAN EVER PLACE.
##
## `artifacts/play_tour/shots/01_palette.png`: press B on a fresh save and the
## top of the "All" tab, under the cursor, is The Hearth — `max_count = 1`, and
## the city was founded around one. Press Enter and [P11] refuses it, correctly
## and out loud, in the first ten seconds of the first hour.
##
## Nothing here was missing. [P11] has answered `count_of` since it shipped;
## [P18]'s sheet has said "The city already has its Hearth." since it shipped;
## the rows have carried a dim-and-say-why treatment for locked entries since
## they shipped. Nobody had joined the three, so the one state the list could not
## show was the one a player meets first.
##
## Live rather than indexed, because a cap changes on placement and `rebuild()`
## does not run on placement. Costs a `count_of` call per capped KIND — three
## definitions in this build — on the panel's own 4 Hz poll.
func refresh_caps(build_system: Object) -> void:
	if build_system == null or not build_system.has_method(&"count_of"):
		return
	for e: Entry in entries:
		if e.max_count <= 0:
			continue
		e.capped = int(build_system.call(&"count_of", e.id)) >= e.max_count


## Bumped on every rebuild. Panels compare it instead of rebuilding their rows
## every frame — this is the whole reason the palette costs nothing to display.
func revision() -> int:
	return _revision


static func _haystack(e: Entry) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append(e.display_name.to_lower())
	parts.append(String(e.id).replace("_", " "))
	parts.append(String(e.category))
	for t: StringName in e.tags:
		parts.append(String(t).replace("_", " "))
	return " ".join(parts)


static func _entry_less(a: Entry, b: Entry) -> bool:
	if a.tier != b.tier:
		return a.tier < b.tier
	if a.sort_order != b.sort_order:
		return a.sort_order < b.sort_order
	if a.display_name != b.display_name:
		return a.display_name < b.display_name
	return String(a.id) < String(b.id)


func _ordered_categories(raw_keys: Array) -> Array[StringName]:
	var present: Dictionary[StringName, bool] = {}
	for k: Variant in raw_keys:
		present[StringName(String(k))] = true
	var out: Array[StringName] = []
	for c: StringName in CATEGORY_ORDER:
		if present.has(c):
			out.append(c)
			present.erase(c)
	var rest: Array = present.keys()
	rest = LcnUiFormat.sorted_names(rest)
	for c2: Variant in rest:
		out.append(StringName(String(c2)))
	return out


## Drops remembered ids that content no longer defines, so a save from an older
## build cannot leave a dead entry pinned to the quickbar forever.
func _prune_missing() -> void:
	if _by_id.is_empty():
		return
	var keep_recent: Array[StringName] = []
	for id: StringName in _recent:
		if _by_id.has(id):
			keep_recent.append(id)
	_recent = keep_recent
	var keep_fav: Array[StringName] = []
	for id2: StringName in _favourites:
		if _by_id.has(id2):
			keep_fav.append(id2)
	_favourites = keep_fav


# ------------------------------------------------------------------ query ----

func size() -> int:
	return entries.size()


func has(id: StringName) -> bool:
	return _by_id.has(id)


func entry(id: StringName) -> Entry:
	return _by_id.get(id)


func def_of(id: StringName) -> Resource:
	var e: Entry = _by_id.get(id)
	return null if e == null else e.def


func categories() -> Array[StringName]:
	return _categories.duplicate()


## The tab strip: the two pseudo-tabs that matter, then every category that has
## content. `count` lets the panel grey out an empty tab instead of hiding it.
func tabs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append({"id": TAB_ALL, "label": "All", "count": entries.size()})
	if not _favourites.is_empty():
		out.append({"id": TAB_FAVOURITES, "label": "Pinned", "count": _favourites.size()})
	if not _recent.is_empty():
		out.append({"id": TAB_RECENT, "label": "Recent", "count": _recent.size()})
	for c: StringName in _categories:
		out.append({
			"id": c,
			"label": LcnUiFormat.category_name(c),
			"count": (_by_category.get(c, []) as Array).size(),
		})
	return out


## THE call the palette makes every time the tab or the typed query changes.
## An empty query lists the tab in authored order; a non-empty one searches the
## WHOLE catalog and ignores the tab, because a player who types "rad" wants the
## radiator, not "no results in Storage".
func view(tab: StringName, query: String = "") -> Array[Entry]:
	var key: String = "%s|%s" % [String(tab), query.strip_edges().to_lower()]
	var cached: Array = _view_cache.get(key, [])
	if not cached.is_empty():
		var out_cached: Array[Entry] = []
		for c: Variant in cached:
			out_cached.append(c as Entry)
		return out_cached

	var result: Array[Entry] = _compute_view(tab, query)
	var store: Array = []
	for r: Entry in result:
		store.append(r)
	_view_cache[key] = store
	return result


func _compute_view(tab: StringName, query: String) -> Array[Entry]:
	var q: String = query.strip_edges().to_lower()
	if q != "":
		var hits: Array[Entry] = []
		for e: Entry in entries:
			e.score = match_score(e.display_name, String(e.id), e.haystack, q)
			if e.score > 0:
				hits.append(e)
		hits.sort_custom(_search_less)
		return hits

	var base: Array[Entry] = []
	match tab:
		TAB_ALL:
			base = entries.duplicate()
		TAB_FAVOURITES:
			for id: StringName in _favourites:
				var fe: Entry = _by_id.get(id)
				if fe != null:
					base.append(fe)
		TAB_RECENT:
			for id2: StringName in _recent:
				var re: Entry = _by_id.get(id2)
				if re != null:
					base.append(re)
		_:
			for raw: Variant in _by_category.get(tab, []):
				base.append(raw as Entry)
	return base


static func _search_less(a: Entry, b: Entry) -> bool:
	if a.score != b.score:
		return a.score > b.score
	if a.unlocked != b.unlocked:
		return a.unlocked
	if a.tier != b.tier:
		return a.tier < b.tier
	if a.display_name != b.display_name:
		return a.display_name < b.display_name
	return String(a.id) < String(b.id)


## How well one entry answers a typed query. 0 means "no match at all".
##
## The ladder is deliberately coarse and deliberately ordered: an exact name
## beats a prefix beats a word-start beats a substring beats an id match beats a
## fuzzy subsequence. Ties never decide anything on their own — _search_less
## falls through to tier and name, so the order is total and stable.
static func match_score(display_name: String, id: String, haystack: String, query: String) -> int:
	var q: String = query.strip_edges().to_lower()
	if q == "":
		return 0
	var name: String = display_name.to_lower()
	var flat_id: String = id.to_lower().replace("_", " ")

	if name == q or flat_id == q or id.to_lower() == q:
		return 1000
	if name.begins_with(q):
		return 900 - mini(80, name.length() - q.length())
	if flat_id.begins_with(q):
		return 860 - mini(80, flat_id.length() - q.length())

	for word: String in name.split(" ", false):
		if word.begins_with(q):
			return 800
	for word2: String in flat_id.split(" ", false):
		if word2.begins_with(q):
			return 780

	var at: int = name.find(q)
	if at >= 0:
		return 700 - mini(60, at)
	var at_id: int = flat_id.find(q)
	if at_id >= 0:
		return 660 - mini(60, at_id)
	var at_hay: int = haystack.find(q)
	if at_hay >= 0:
		return 560 - mini(60, at_hay)

	var fuzzy_name: int = _subsequence_score(name, q)
	if fuzzy_name > 0:
		return 420 + fuzzy_name
	var fuzzy_hay: int = _subsequence_score(haystack, q)
	if fuzzy_hay > 0:
		return 300 + fuzzy_hay
	return 0


## Subsequence match with a contiguity bonus: "hgb" finds "Housing Block",
## "cgen" finds "Coal Generator". Returns 0..100, or 0 when the letters are not
## all present in order.
static func _subsequence_score(haystack: String, query: String) -> int:
	var hi: int = 0
	var gaps: int = 0
	var runs: int = 0
	var last_hit: int = -2
	for i: int in query.length():
		var ch: String = query[i]
		var found: int = -1
		while hi < haystack.length():
			if haystack[hi] == ch:
				found = hi
				hi += 1
				break
			hi += 1
		if found < 0:
			return 0
		if found == last_hit + 1:
			runs += 1
		else:
			gaps += 1
		last_hit = found
	return clampi(100 - gaps * 8 + runs * 4, 1, 100)


# --------------------------------------------------------- recents / pins ----

## Records a placement. The recent list is a plain MRU — the most useful
## ordering there is, and the one every player already understands.
func note_used(id: StringName) -> void:
	if not _by_id.has(id):
		return
	_recent.erase(id)
	_recent.insert(0, id)
	while _recent.size() > MAX_RECENT:
		_recent.remove_at(_recent.size() - 1)
	_view_cache.erase("%s|" % String(TAB_RECENT))
	_view_cache.erase("%s|" % String(TAB_ALL))


func recent_ids() -> Array[StringName]:
	return _recent.duplicate()


func is_favourite(id: StringName) -> bool:
	return _favourites.has(id)


## Pin/unpin. Returns the new state so a panel can report it in one line.
func toggle_favourite(id: StringName) -> bool:
	if not _by_id.has(id):
		return false
	if _favourites.has(id):
		_favourites.erase(id)
		_view_cache.erase("%s|" % String(TAB_FAVOURITES))
		return false
	if _favourites.size() >= MAX_FAVOURITES:
		_favourites.remove_at(_favourites.size() - 1)
	_favourites.append(id)
	_view_cache.erase("%s|" % String(TAB_FAVOURITES))
	return true


func favourite_ids() -> Array[StringName]:
	return _favourites.duplicate()


## What the number keys 1..0 place. Pins first, in the order they were pinned,
## then the most recent things the player actually built. This is the quickbar:
## fast hands beat pretty menus.
func quickbar_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	var seen: Dictionary[StringName, bool] = {}
	for id: StringName in _favourites:
		if out.size() >= QUICKBAR_SLOTS:
			break
		if _by_id.has(id) and not seen.has(id):
			seen[id] = true
			out.append(id)
	for id2: StringName in _recent:
		if out.size() >= QUICKBAR_SLOTS:
			break
		if _by_id.has(id2) and not seen.has(id2):
			seen[id2] = true
			out.append(id2)
	return out


# ------------------------------------------------------------ persistence ----

func to_dict() -> Dictionary:
	var fav: Array = []
	for f: StringName in _favourites:
		fav.append(String(f))
	var rec: Array = []
	for r: StringName in _recent:
		rec.append(String(r))
	return {"favourites": fav, "recent": rec}


func from_dict(data: Dictionary) -> void:
	_favourites.clear()
	_recent.clear()
	for f: Variant in data.get("favourites", []):
		var fid := StringName(String(f))
		if not _favourites.has(fid):
			_favourites.append(fid)
	for r: Variant in data.get("recent", []):
		var rid := StringName(String(r))
		if not _recent.has(rid):
			_recent.append(rid)
	while _favourites.size() > MAX_FAVOURITES:
		_favourites.remove_at(_favourites.size() - 1)
	while _recent.size() > MAX_RECENT:
		_recent.remove_at(_recent.size() - 1)
	_prune_missing()
	_view_cache.clear()
