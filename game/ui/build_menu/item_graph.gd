class_name LcnItemGraph
extends RefCounted
## [P18] The graph behind the recipe browser: what makes this, what is it for.
##
## Factorio players live in this screen, and the reason is that it answers the
## only two questions that matter in a production game — "where does this come
## from" and "what is it good for" — and lets you walk the answer in both
## directions until you understand the whole chain.
##
## The graph is assembled from two sources, and it degrades from both:
##
##   1. [P04]'s RecipeDef content (`game/content/recipes/`), read by DUCK TYPING.
##      Nothing here knows [P04]'s class; it reads inputs/outputs/time/machines
##      under any of the obvious spellings. The day the recipes land, the browser
##      fills up with no code change.
##   2. [P11]'s BuildingDefs, which already describe a real economy today: what
##      a building COSTS, what it BURNS, what it EXTRACTS, what it stores and
##      what upkeep it draws. That is a genuine "what is scrap for" answer in a
##      build with zero recipes in it.
##
## Deterministic throughout: every dictionary is sorted before iteration and
## every result list has a total order.

## One craft, normalised out of whatever shape [P04] authored it in.
class Recipe extends RefCounted:
	var id: StringName = &""
	var display_name: String = ""
	var inputs: Dictionary[StringName, int] = {}
	var outputs: Dictionary[StringName, int] = {}
	var seconds: float = 1.0
	## Building kinds that can run it.
	var machines: Array[StringName] = []
	## Heat units the craft burns, and what it gives back as waste. In this game
	## that is not a footnote: every recipe competes with the radiators.
	var heat_cost: float = 0.0
	var waste_heat: float = 0.0
	## Coldest temperature the craft still runs at, or NAN when it does not care.
	var min_temperature_c: float = NAN
	var res: Resource = null

	## "2 Iron Plate + 1 Gear -> 1 Steel Plate, 3 s"
	func summary() -> String:
		var text: String = "%s  ->  %s,  %s" % [
			LcnUiFormat.items(inputs, " + "),
			LcnUiFormat.items(outputs, " + "),
			LcnUiFormat.duration(seconds)]
		if heat_cost > 0.0:
			text += ",  %s heat" % LcnUiFormat.num(heat_cost)
		return text

	## The per-second heat draw of running this craft continuously.
	func heat_per_second() -> float:
		return heat_cost / maxf(0.05, seconds)

	func rate_of(item: StringName) -> float:
		var amount: int = int(outputs.get(item, 0))
		if amount == 0:
			amount = -int(inputs.get(item, 0))
		return float(amount) / maxf(0.05, seconds)


## One item, with every way into it and every way out of it.
class ItemNode extends RefCounted:
	var id: StringName = &""
	var display_name: String = ""
	## {how, recipe, building, amount, rate, text}
	var made_by: Array[Dictionary] = []
	var used_by: Array[Dictionary] = []

	func is_orphan() -> bool:
		return made_by.is_empty()


const HOW_RECIPE: StringName = &"recipe"
const HOW_EXTRACT: StringName = &"extract"
const HOW_RECIPE_INPUT: StringName = &"recipe_input"
const HOW_BUILD_COST: StringName = &"build_cost"
const HOW_FUEL: StringName = &"fuel"
const HOW_UPKEEP: StringName = &"upkeep"
const HOW_STORED: StringName = &"stored"

var _items: Dictionary[StringName, ItemNode] = {}
var _recipes: Dictionary[StringName, Recipe] = {}
var _item_ids: Array[StringName] = []
var _recipe_ids: Array[StringName] = []
var _revision: int = 0


# ------------------------------------------------------------------ build ----

## Rebuilds from content. `build_system` supplies the building defs; `registry`
## is the Registry autoload (passed in, never named, so this file is testable in
## isolation and can be handed a fake).
func rebuild(build_system: Object, registry: Object = null) -> void:
	_items.clear()
	_recipes.clear()
	_item_ids.clear()
	_recipe_ids.clear()
	_revision += 1

	_ingest_recipes(registry)
	_ingest_buildings(build_system)

	_item_ids = _sorted_names(_items.keys())
	_recipe_ids = _sorted_names(_recipes.keys())
	for id: StringName in _item_ids:
		var node: ItemNode = _items[id]
		node.made_by.sort_custom(_edge_less)
		node.used_by.sort_custom(_edge_less)


func revision() -> int:
	return _revision


func _ingest_recipes(registry: Object) -> void:
	if registry == null or not registry.has_method(&"all"):
		return
	for raw: Variant in registry.call(&"all", "recipes"):
		var res: Resource = raw as Resource
		if res == null:
			continue
		var r: Recipe = _read_recipe(res)
		if r == null:
			continue
		_recipes[r.id] = r
		var out_keys: Array = r.outputs.keys()
		out_keys = LcnUiFormat.sorted_names(out_keys)
		for k: Variant in out_keys:
			var item := StringName(String(k))
			_node(item).made_by.append({
				"how": String(HOW_RECIPE), "recipe": String(r.id), "building": "",
				"amount": int(r.outputs[k]), "rate": r.rate_of(item),
				"text": "%s every %s%s" % [
					LcnUiFormat.items({item: int(r.outputs[k])}),
					LcnUiFormat.duration(r.seconds), _in_machine(r)],
			})
		var in_keys: Array = r.inputs.keys()
		in_keys = LcnUiFormat.sorted_names(in_keys)
		for k2: Variant in in_keys:
			var item2 := StringName(String(k2))
			_node(item2).used_by.append({
				"how": String(HOW_RECIPE_INPUT), "recipe": String(r.id), "building": "",
				"amount": int(r.inputs[k2]), "rate": -r.rate_of(item2),
				"text": "%s uses %s every %s%s" % [
					r.display_name, LcnUiFormat.items({item2: int(r.inputs[k2])}),
					LcnUiFormat.duration(r.seconds), _in_machine(r)],
			})


## Normalises one authored recipe. Every field has three or four accepted
## spellings because this file must not force [P04] into a schema it did not
## agree to; it only has to recognise one when it sees it.
func _read_recipe(res: Resource) -> Recipe:
	var r := Recipe.new()
	r.res = res
	r.id = LcnUiFormat.as_name(res.get(&"id"))
	if String(r.id) == "":
		r.id = StringName(res.resource_path.get_file().get_basename())
	if String(r.id) == "":
		return null
	r.display_name = LcnUiFormat.as_text(res.get(&"display_name"))
	if r.display_name == "":
		r.display_name = LcnUiFormat.as_text(res.get(&"name"))
	if r.display_name == "":
		r.display_name = LcnUiFormat.item_name(r.id)
	r.inputs = _amounts(res, [&"inputs", &"ingredients", &"in_items", &"consumes"])
	r.outputs = _amounts(res, [&"outputs", &"results", &"out_items", &"produces"])
	r.seconds = _seconds(res)
	r.heat_cost = LcnUiFormat.as_number(res.get(&"heat_cost"))
	r.waste_heat = LcnUiFormat.as_number(res.get(&"waste_heat"))
	var floor_c: Variant = res.get(&"min_temperature_c")
	if typeof(floor_c) == TYPE_FLOAT or typeof(floor_c) == TYPE_INT:
		r.min_temperature_c = float(floor_c)
	for m: StringName in _names(res, [&"machines", &"buildings", &"crafters", &"made_in"]):
		r.machines.append(m)
	r.machines.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return r


func _ingest_buildings(build_system: Object) -> void:
	if build_system == null or not build_system.has_method(&"all_defs"):
		return
	for raw: Variant in build_system.call(&"all_defs"):
		var def: Resource = raw as Resource
		if def == null:
			continue
		var kind := LcnUiFormat.as_name(def.get(&"id"))
		var title: String = LcnUiFormat.as_text(def.get(&"display_name"))
		if title == "":
			title = LcnUiFormat.item_name(kind)

		var cost: Variant = def.get(&"cost")
		if typeof(cost) == TYPE_DICTIONARY:
			var ck: Array = (cost as Dictionary).keys()
			ck = LcnUiFormat.sorted_names(ck)
			for k: Variant in ck:
				var item := StringName(String(k))
				_node(item).used_by.append({
					"how": String(HOW_BUILD_COST), "recipe": "", "building": String(kind),
					"amount": int((cost as Dictionary)[k]), "rate": 0.0,
					"text": "%s costs %s to build" % [
						title, LcnUiFormat.items({item: int((cost as Dictionary)[k])})],
				})

		var upkeep: Variant = def.get(&"upkeep")
		if typeof(upkeep) == TYPE_DICTIONARY:
			var uk: Array = (upkeep as Dictionary).keys()
			uk = LcnUiFormat.sorted_names(uk)
			for k2: Variant in uk:
				var item2 := StringName(String(k2))
				var per_min: int = int((upkeep as Dictionary)[k2])
				_node(item2).used_by.append({
					"how": String(HOW_UPKEEP), "recipe": "", "building": String(kind),
					"amount": per_min, "rate": -float(per_min) / 60.0,
					"text": "%s draws %s per minute" % [
						title, LcnUiFormat.items({item2: per_min})],
				})

		var fuels: Variant = def.get(&"fuel_items")
		var burn: float = LcnUiFormat.as_number(def.get(&"fuel_burn_rate"))
		if typeof(fuels) == TYPE_ARRAY:
			for f: Variant in fuels:
				var item3 := StringName(String(f))
				_node(item3).used_by.append({
					"how": String(HOW_FUEL), "recipe": "", "building": String(kind),
					"amount": 0, "rate": -burn,
					"text": "%s burns %s at %s" % [
						title, LcnUiFormat.item_name(item3),
						LcnUiFormat.rate(burn, "%s/s" % LcnUiFormat.item_name(item3))],
				})

		var ore := LcnUiFormat.as_name(def.get(&"extracts"))
		# "*" means "whatever seam it stands on". It is a wildcard, not an item,
		# and a browser that lists it has an entry nobody can ever hold.
		if String(ore) != "" and String(ore) != "*":
			var rate: float = LcnUiFormat.as_number(def.get(&"extract_rate"))
			_node(ore).made_by.append({
				"how": String(HOW_EXTRACT), "recipe": "", "building": String(kind),
				"amount": 0, "rate": rate,
				"text": "%s digs %s" % [title,
					LcnUiFormat.per_minute(rate, " %s/min" % LcnUiFormat.item_name(ore))],
			})

		var filter: Variant = def.get(&"storage_filter")
		if typeof(filter) == TYPE_ARRAY:
			for s: Variant in filter:
				_node(StringName(String(s))).used_by.append({
					"how": String(HOW_STORED), "recipe": "", "building": String(kind),
					"amount": LcnUiFormat.as_int(def.get(&"storage_capacity")), "rate": 0.0,
					"text": "%s stores it" % title,
				})

		var recipes: Variant = def.get(&"recipes")
		if typeof(recipes) == TYPE_ARRAY:
			for rid: Variant in recipes:
				var recipe: Recipe = _recipes.get(StringName(String(rid)))
				if recipe == null:
					continue
				if not recipe.machines.has(kind):
					recipe.machines.append(kind)
					recipe.machines.sort_custom(
						func(a: StringName, b: StringName) -> bool: return String(a) < String(b))


## " in the Smelter" — a recipe named after its own output ("Iron Plate makes
## 1 Iron Plate") tells a player nothing; the machine is the useful half.
static func _in_machine(r: Recipe) -> String:
	if r.machines.is_empty():
		return ""
	var names: PackedStringArray = PackedStringArray()
	for m: StringName in r.machines:
		names.append(LcnUiFormat.item_name(m))
	return "  in the %s" % LcnUiFormat.prose_list(names, "or")


func _node(id: StringName) -> ItemNode:
	var existing: ItemNode = _items.get(id)
	if existing != null:
		return existing
	var n := ItemNode.new()
	n.id = id
	n.display_name = LcnUiFormat.item_name(id)
	_items[id] = n
	return n


# ------------------------------------------------------------------ query ----

func item_ids() -> Array[StringName]:
	return _item_ids.duplicate()


func recipe_ids() -> Array[StringName]:
	return _recipe_ids.duplicate()


func item(id: StringName) -> ItemNode:
	return _items.get(id)


func recipe(id: StringName) -> Recipe:
	return _recipes.get(id)


func item_count() -> int:
	return _item_ids.size()


func recipe_count() -> int:
	return _recipe_ids.size()


## Every way this item comes into existence.
func producers_of(id: StringName) -> Array[Dictionary]:
	var n: ItemNode = _items.get(id)
	return [] if n == null else n.made_by.duplicate()


## Every way this item is spent.
func consumers_of(id: StringName) -> Array[Dictionary]:
	var n: ItemNode = _items.get(id)
	return [] if n == null else n.used_by.duplicate()


## The item the browser should open on: the one with the most edges, because
## that is the one the city's economy actually turns on. Alphabetical order
## would open on whatever happens to start with 'a'.
func busiest_item() -> StringName:
	var best: StringName = &""
	var best_score: int = -1
	for id: StringName in _item_ids:
		var n: ItemNode = _items[id]
		var score: int = n.made_by.size() + n.used_by.size()
		if score > best_score:
			best_score = score
			best = id
	return best


## Items with no producer at all — the shopping list of things the city cannot
## currently make. This is the single most useful derived fact in the browser.
func orphans() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in _item_ids:
		if (_items[id] as ItemNode).is_orphan():
			out.append(id)
	return out


## Walks upstream: everything that has to exist before this item can. Breadth
## first, depth-capped, each item reported once, in discovery order.
func chain_upstream(id: StringName, max_depth: int = 4) -> Array[Dictionary]:
	return _walk(id, max_depth, true)


## Walks downstream: everything this item ends up in.
func chain_downstream(id: StringName, max_depth: int = 4) -> Array[Dictionary]:
	return _walk(id, max_depth, false)


func _walk(start: StringName, max_depth: int, upstream: bool) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary[StringName, bool] = {start: true}
	var frontier: Array[StringName] = [start]
	var depth: int = 0
	while depth < max_depth and not frontier.is_empty():
		depth += 1
		var next: Array[StringName] = []
		for id: StringName in frontier:
			var node: ItemNode = _items.get(id)
			if node == null:
				continue
			var edges: Array[Dictionary] = node.made_by if upstream else node.used_by
			for e: Dictionary in edges:
				var rid := StringName(String(e.get("recipe", "")))
				if String(rid) == "":
					continue
				var r: Recipe = _recipes.get(rid)
				if r == null:
					continue
				var side: Dictionary = r.inputs if upstream else r.outputs
				var keys: Array = side.keys()
				keys = LcnUiFormat.sorted_names(keys)
				for k: Variant in keys:
					var item_id := StringName(String(k))
					if seen.has(item_id):
						continue
					seen[item_id] = true
					next.append(item_id)
					out.append({
						"item": String(item_id), "depth": depth,
						"via": String(rid), "from": String(id),
					})
		frontier = next
	return out


## One search box over items, recipes and buildings. Returns rows shaped
## {kind, id, label, detail, score}, best first.
func search(query: String, build_system: Object = null, limit: int = 40) -> Array[Dictionary]:
	var q: String = query.strip_edges().to_lower()
	var out: Array[Dictionary] = []
	if q == "":
		# An empty box lists the whole shelf: items first, then the crafts.
		for id: StringName in _item_ids:
			out.append(_item_row(id, 0))
		for rid: StringName in _recipe_ids:
			var recipe: Recipe = _recipes[rid]
			out.append({"kind": "recipe", "id": String(rid), "label": recipe.display_name,
				"detail": recipe.summary(), "score": 0})
		return out.slice(0, limit)

	for id2: StringName in _item_ids:
		var node: ItemNode = _items[id2]
		var s: int = LcnBuildCatalog.match_score(node.display_name, String(id2), String(id2).replace("_", " "), q)
		if s > 0:
			out.append(_item_row(id2, s))
	for rid: StringName in _recipe_ids:
		var r: Recipe = _recipes[rid]
		var rs: int = LcnBuildCatalog.match_score(r.display_name, String(rid), String(rid).replace("_", " "), q)
		if rs > 0:
			out.append({"kind": "recipe", "id": String(rid), "label": r.display_name,
				"detail": r.summary(), "score": rs})
	if build_system != null and build_system.has_method(&"all_defs"):
		for raw: Variant in build_system.call(&"all_defs"):
			var def: Resource = raw as Resource
			if def == null:
				continue
			var name: String = LcnUiFormat.as_text(def.get(&"display_name"))
			var bid: String = LcnUiFormat.as_text(def.get(&"id"))
			var bs: int = LcnBuildCatalog.match_score(name, bid, bid.replace("_", " "), q)
			if bs > 0:
				out.append({"kind": "building", "id": bid, "label": name,
					"detail": LcnUiFormat.category_name(LcnUiFormat.as_name(def.get(&"category"))),
					"score": bs})
	out.sort_custom(_row_less)
	return out.slice(0, limit)


func _item_row(id: StringName, score: int) -> Dictionary:
	var node: ItemNode = _items[id]
	var made: int = node.made_by.size()
	var used: int = node.used_by.size()
	return {
		"kind": "item", "id": String(id), "label": node.display_name,
		"detail": "%d way%s in, %d way%s out" % [made, "" if made == 1 else "s", used, "" if used == 1 else "s"],
		"score": score,
	}


static func _row_less(a: Dictionary, b: Dictionary) -> bool:
	var sa: int = int(a.get("score", 0))
	var sb: int = int(b.get("score", 0))
	if sa != sb:
		return sa > sb
	var ka: String = String(a.get("kind", ""))
	var kb: String = String(b.get("kind", ""))
	if ka != kb:
		return ka < kb
	return String(a.get("id", "")) < String(b.get("id", ""))


static func _edge_less(a: Dictionary, b: Dictionary) -> bool:
	var ha: String = String(a.get("how", ""))
	var hb: String = String(b.get("how", ""))
	if ha != hb:
		return ha < hb
	var ra: String = String(a.get("recipe", ""))
	var rb: String = String(b.get("recipe", ""))
	if ra != rb:
		return ra < rb
	return String(a.get("building", "")) < String(b.get("building", ""))


# --------------------------------------------------------------- reading -----

static func _amounts(res: Resource, fields: Array[StringName]) -> Dictionary[StringName, int]:
	var out: Dictionary[StringName, int] = {}
	for field: StringName in fields:
		var v: Variant = res.get(field)
		if typeof(v) == TYPE_DICTIONARY:
			var keys: Array = (v as Dictionary).keys()
			keys = LcnUiFormat.sorted_names(keys)
			for k: Variant in keys:
				out[StringName(String(k))] = int((v as Dictionary)[k])
			return out
		if typeof(v) == TYPE_ARRAY:
			# [{item: "x", amount: 2}, ...] or ["x", "y"]
			for e: Variant in (v as Array):
				if typeof(e) == TYPE_DICTIONARY:
					var d: Dictionary = e
					var id := StringName(String(d.get("item", d.get("id", ""))))
					if String(id) == "":
						continue
					out[id] = int(d.get("amount", d.get("count", 1)))
				else:
					out[StringName(String(e))] = 1
			return out
	return out


static func _names(res: Resource, fields: Array[StringName]) -> Array[StringName]:
	var out: Array[StringName] = []
	for field: StringName in fields:
		var v: Variant = res.get(field)
		if typeof(v) == TYPE_ARRAY:
			for e: Variant in (v as Array):
				out.append(StringName(String(e)))
			return out
		if typeof(v) == TYPE_STRING or typeof(v) == TYPE_STRING_NAME:
			if String(v) != "":
				out.append(StringName(String(v)))
			return out
	return out


static func _seconds(res: Resource) -> float:
	for field: StringName in [&"seconds", &"craft_seconds", &"time", &"duration"]:
		var v: Variant = res.get(field)
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			if float(v) > 0.0:
				return float(v)
	for field2: StringName in [&"craft_time_ticks", &"ticks", &"duration_ticks", &"time_ticks"]:
		var v2: Variant = res.get(field2)
		if typeof(v2) == TYPE_INT or typeof(v2) == TYPE_FLOAT:
			if float(v2) > 0.0:
				return float(v2) * LcnUiFormat.SECONDS_PER_TICK
	return 1.0


static func _sorted_names(keys: Array) -> Array[StringName]:
	var strings: Array[String] = []
	for k: Variant in keys:
		strings.append(String(k))
	strings.sort()
	var out: Array[StringName] = []
	for s: String in strings:
		out.append(StringName(s))
	return out
