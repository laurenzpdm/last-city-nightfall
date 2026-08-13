class_name ProdRecipeBook
extends RefCounted
## The crafting graph, resolved once at world creation.
##
## Loads every [RecipeDef] out of `game/content/recipes/`, validates it, indexes
## it by id, by machine and by output item, and derives the two things nobody
## should compute twice:
##
##   * DEPTH — how many transformations a given item is from the ground. Raw ore
##     is 0, a plate is 1, a gear is 2, a shell is 3. [P18] lays its tree out on
##     this and [P20] plots progression against it.
##   * RATIOS — how many machines of recipe A feed one machine of recipe B. The
##     whole point of the recipe numbers is that this comes out clean, so the
##     book computes it and `describe_ratios()` prints it; a balance pass can
##     diff that text instead of re-deriving the arithmetic by hand.
##
## Nothing in here knows the name of a single recipe. Everything is derived from
## whatever is in the content folder, so a balance agent or [P10] can add,
## retune or gate a recipe without touching a line of code.

const CATEGORY: String = "recipes"
const MAX_DEPTH: int = 32

## id -> RecipeDef, every recipe that survived validation.
var by_id: Dictionary[StringName, RecipeDef] = {}
## Sorted ids, so every iteration that reaches state is ordered.
var ids: Array[StringName] = []
## item id -> sorted ids of the recipes that produce it (primary or byproduct).
var producers_of: Dictionary[StringName, Array] = {}
## item id -> sorted ids of the recipes that consume it.
var consumers_of: Dictionary[StringName, Array] = {}
## item id -> chain depth. Raw materials are 0.
var depth_of: Dictionary[StringName, int] = {}
## Every item the graph ever mentions, sorted. The stable metric key set.
var items: Array[StringName] = []
## Items no recipe produces: what has to come out of the ground or the ruins.
var raw_items: Array[StringName] = []
## Deepest chain the shipped content can reach.
var max_depth: int = 0
## Problems found while loading. Empty on clean content.
var problems: PackedStringArray = PackedStringArray()

var _by_machine: Dictionary[StringName, Array] = {}


## Loads and indexes the content folder. Safe to call on an empty folder.
func load_all() -> void:
	by_id.clear()
	ids.clear()
	producers_of.clear()
	consumers_of.clear()
	depth_of.clear()
	items.clear()
	raw_items.clear()
	_by_machine.clear()
	problems = PackedStringArray()
	max_depth = 0

	# Registry.ids() sorts StringName by intern pointer, so it is NOT alphabetical.
	# ids is re-sorted properly below; this loop only has to be complete.
	for rid: StringName in Registry.ids(CATEGORY):
		var res: Resource = Registry.get_item(CATEGORY, rid)
		var r := res as RecipeDef
		if r == null:
			problems.append("%s is in content/recipes but is not a RecipeDef" % String(rid))
			continue
		var issues: PackedStringArray = r.validate()
		if issues.size() > 0:
			problems.append("'%s' — %s" % [String(rid), ", ".join(issues)])
			continue
		by_id[rid] = r
		ids.append(rid)

	ids = ProdSort.names(ids)
	_index_items()
	_compute_depth()


## Every recipe a machine of this kind, carrying these tags, is allowed to run,
## in the order the definition lists them (`allowed` comes from the building def)
## with anything else the tags permit appended, sorted.
func for_machine(kind: StringName, tags: Array[StringName], allowed: Array[StringName]) -> Array[StringName]:
	var cached: Array = _by_machine.get(kind, [])
	if not cached.is_empty():
		var out_cached: Array[StringName] = []
		for c: Variant in cached:
			out_cached.append(StringName(String(c)))
		return out_cached

	var out: Array[StringName] = []
	var seen: Dictionary[StringName, bool] = {}
	for want: StringName in allowed:
		var r: RecipeDef = by_id.get(want)
		if r != null and r.runs_on(kind, tags) and not seen.has(want):
			seen[want] = true
			out.append(want)
	var extra: Array[StringName] = []
	for rid: StringName in ids:
		if seen.has(rid):
			continue
		var r2: RecipeDef = by_id[rid]
		if r2.runs_on(kind, tags):
			extra.append(rid)
	out.append_array(ProdSort.names(extra))
	var store: Array = []
	for o: StringName in out:
		store.append(String(o))
	_by_machine[kind] = store
	return out


func get_recipe(rid: StringName) -> RecipeDef:
	return by_id.get(rid)


func has(rid: StringName) -> bool:
	return by_id.has(rid)


func size() -> int:
	return ids.size()


## Chain depth of an item: 0 for anything that has to be dug up or salvaged.
func item_depth(item: StringName) -> int:
	return int(depth_of.get(item, 0))


## Chain depth of a recipe: one more than its deepest input.
func recipe_depth(rid: StringName) -> int:
	var r: RecipeDef = by_id.get(rid)
	if r == null:
		return 0
	var d: int = 0
	for k: StringName in r.sorted_outputs():
		d = maxi(d, item_depth(k))
	return d


## Machines of `producer` needed to keep one machine of `consumer` fed, per the
## item they share. Returns 0.0 when they do not share one. This is the number
## the design is balanced around: it should keep coming out at 1, 2 or 1/2.
func feed_ratio(producer: StringName, consumer: StringName, item: StringName) -> float:
	var p: RecipeDef = by_id.get(producer)
	var c: RecipeDef = by_id.get(consumer)
	if p == null or c == null:
		return 0.0
	var supply: float = p.output_per_minute(item)
	var draw: float = c.input_per_minute(item)
	if supply <= 0.0 or draw <= 0.0:
		return 0.0
	return draw / supply


## Human-readable ratio table. This is what a balance agent reads and diffs; it
## is generated from the live content, so it can never drift from the .tres.
func describe_ratios() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for consumer: StringName in ids:
		var c: RecipeDef = by_id[consumer]
		for item: StringName in c.sorted_inputs():
			for producer: Variant in producers_of.get(item, []):
				var pid: StringName = StringName(String(producer))
				var ratio: float = feed_ratio(pid, consumer, item)
				if ratio <= 0.0:
					continue
				out.append("%-16s <- %-16s %-14s x%.3f  (%.1f/min out, %.1f/min in)" % [
					String(consumer), String(pid), String(item), ratio,
					by_id[pid].output_per_minute(item), c.input_per_minute(item)])
	return out


## Everything [P18] needs to draw the tree, JSON-safe and sorted.
func to_json() -> Dictionary:
	var recipes: Array = []
	for rid: StringName in ids:
		var entry: Dictionary = by_id[rid].to_json()
		entry["depth"] = recipe_depth(rid)
		recipes.append(entry)
	var depths: Dictionary = {}
	for item: StringName in items:
		depths[String(item)] = depth_of.get(item, 0)
	var raws: Array = []
	for item2: StringName in raw_items:
		raws.append(String(item2))
	return {
		"recipes": recipes,
		"item_depth": depths,
		"raw_items": raws,
		"max_depth": max_depth,
	}


# =========================================================================
# internals
# =========================================================================

func _index_items() -> void:
	var seen: Dictionary[StringName, bool] = {}
	for rid: StringName in ids:
		var r: RecipeDef = by_id[rid]
		for item: StringName in r.sorted_inputs():
			seen[item] = true
			var cons: Array = consumers_of.get(item, [])
			cons.append(String(rid))
			consumers_of[item] = cons
		for out_item: StringName in r.all_outputs().keys():
			seen[out_item] = true
			var prod: Array = producers_of.get(out_item, [])
			prod.append(String(rid))
			producers_of[out_item] = prod

	for k: StringName in ProdSort.keys_of(seen):
		items.append(k)
		var plist: Array = producers_of.get(k, [])
		plist.sort()
		producers_of[k] = plist
		var clist: Array = consumers_of.get(k, [])
		clist.sort()
		consumers_of[k] = clist
		if plist.is_empty():
			raw_items.append(k)


## Longest path from a raw material. Memoised, cycle-safe: a recipe loop (steel
## from steel) resolves to the depth it had when the cycle was entered instead
## of recursing forever, because content is allowed to be wrong and the log is
## where that gets said, not the stack.
func _compute_depth() -> void:
	var visiting: Dictionary[StringName, bool] = {}
	for item: StringName in items:
		depth_of[item] = _depth(item, visiting, 0)
		max_depth = maxi(max_depth, depth_of[item])


func _depth(item: StringName, visiting: Dictionary[StringName, bool], guard: int) -> int:
	if depth_of.has(item):
		return depth_of[item]
	if visiting.has(item) or guard >= MAX_DEPTH:
		return 0
	var producers: Array = producers_of.get(item, [])
	if producers.is_empty():
		depth_of[item] = 0
		return 0
	visiting[item] = true
	var best: int = 0
	for pid: Variant in producers:
		var r: RecipeDef = by_id.get(StringName(String(pid)))
		if r == null:
			continue
		var deepest_input: int = 0
		for inp: StringName in r.sorted_inputs():
			deepest_input = maxi(deepest_input, _depth(inp, visiting, guard + 1))
		best = maxi(best, deepest_input + 1)
	visiting.erase(item)
	depth_of[item] = best
	return best
