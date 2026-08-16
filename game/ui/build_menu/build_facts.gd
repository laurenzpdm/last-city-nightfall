class_name LcnBuildFacts
extends RefCounted
## [P18] The tooltip that answers the real question.
##
## "Coal Generator: produces heat" is not information. This class reads the LIVE
## simulation and produces the sheet a player actually needs before spending
## forty-five seconds of build time in the dark:
##
##   * what it costs and whether the city can pay for it RIGHT NOW
##   * what it produces and consumes, in the units the rest of the UI uses
##   * how [P02] will treat it — its derived load-shedding priority, its heat
##     loss per tile, its radiance — read from the same HeatDef the solver uses,
##     so the tooltip cannot drift from the simulation
##   * how long it takes to build, measured against how long is left until dark
##   * and CONTEXTUAL WARNINGS: no pipe reaches this tile, nothing in the city
##     makes iron plate, the grid is already thirty units short, that pipe will
##     become the new bottleneck, there is no coal within reach of that drill
##
## Everything is duck-typed against the sim systems. Any of them may be absent
## while the other parts land; a missing system removes a line, never a panel.
##
## The output is plain data — dictionaries of rows and warnings — so the panel
## that draws it is dumb and the whole thing is testable headlessly.

const NEAR_CONDUIT_TILES: int = 6
const SCAN_BUDGET: int = 4096          ## hard cap on cells touched by any one hint
const LOW_FUEL_SECONDS: float = 90.0

enum Sev { INFO, TIGHT, BLOCKING }


## Everything a sheet needs to know about the world it is describing.
## Built once per hover, not per row.
class Ctx extends RefCounted:
	var build: Object = null
	var heat: Object = null
	var grid: Object = null
	var citizens: Object = null
	var climate: Object = null
	var production: Object = null
	var research: Object = null
	## Where the ghost currently sits. Without a cell the sheet still works; it
	## just cannot answer "here".
	var cell: Vector2i = Vector2i.ZERO
	var rot: int = 0
	var has_cell: bool = false

	## Pulls the systems out of Sim. `sim` is the Sim autoload, passed in so this
	## file never names an autoload and stays unit-testable.
	static func from_sim(sim: Object, cell: Vector2i = Vector2i.ZERO, rot: int = 0, has_cell: bool = false) -> Ctx:
		var c := Ctx.new()
		if sim != null and sim.has_method(&"get_system"):
			c.build = sim.call(&"get_system", &"build")
			c.heat = sim.call(&"get_system", &"heat")
			c.grid = sim.call(&"get_system", &"grid")
			c.citizens = sim.call(&"get_system", &"citizens")
			c.climate = sim.call(&"get_system", &"climate")
			c.production = sim.call(&"get_system", &"production")
			c.research = sim.call(&"get_system", &"research")
		c.cell = cell
		c.rot = rot
		c.has_cell = has_cell
		return c


# ============================================================== the sheet =====

## The full fact sheet for a building DEFINITION — what the palette shows.
static func sheet(def: Resource, ctx: Ctx) -> Dictionary:
	if def == null:
		return {"id": "", "title": "—", "sections": [], "warnings": []}

	var kind := LcnUiFormat.as_name(def.get(&"id"))
	var out: Dictionary = {
		"id": String(kind),
		"title": LcnUiFormat.as_text(def.get(&"display_name")),
		"subtitle": _subtitle(def),
		"description": LcnUiFormat.as_text(def.get(&"description")),
		"tint": def.get(&"tint"),
		"sections": [],
		"warnings": [],
		"cost": {},
		"locked": false,
		"links_items": [],
		"links_buildings": [],
	}
	if String(out["title"]) == "":
		out["title"] = LcnUiFormat.item_name(kind)

	var sections: Array = out["sections"]
	var warnings: Array = out["warnings"]
	var link_items: Array = out["links_items"]
	var link_buildings: Array = out["links_buildings"]

	# --- locked ---------------------------------------------------------------
	var unlock := LcnUiFormat.as_name(def.get(&"unlock_id"))
	if String(unlock) != "" and ctx.build != null and ctx.build.has_method(&"is_unlocked"):
		if not bool(ctx.build.call(&"is_unlocked", unlock)):
			out["locked"] = true
			_warn(warnings, Sev.BLOCKING, &"locked",
				"Locked. %s opens it." % LcnUiFormat.item_name(unlock))

	# --- cost -----------------------------------------------------------------
	out["cost"] = _cost_block(def, ctx, warnings, link_items)

	# --- structure ------------------------------------------------------------
	sections.append(_structure_section(def))

	# --- heat -----------------------------------------------------------------
	var heat_section: Dictionary = _heat_section(def, kind)
	if not (heat_section["rows"] as Array).is_empty():
		sections.append(heat_section)

	# --- work & people --------------------------------------------------------
	var work: Dictionary = _work_section(def, ctx, link_items)
	if not (work["rows"] as Array).is_empty():
		sections.append(work)

	# --- what it makes --------------------------------------------------------
	var makes: Dictionary = _output_section(def, ctx, link_items)
	if not (makes["rows"] as Array).is_empty():
		sections.append(makes)

	# --- what it enables ------------------------------------------------------
	var enables: Dictionary = _enables_section(def, ctx, link_buildings)
	if not (enables["rows"] as Array).is_empty():
		sections.append(enables)

	# --- the contextual part, which is the whole point ------------------------
	_placement_warnings(def, kind, ctx, warnings)
	_heat_warnings(def, kind, ctx, warnings)
	_fuel_warnings(def, ctx, warnings, link_items)
	_staffing_warnings(def, ctx, warnings)
	_time_warnings(def, ctx, warnings)

	warnings.sort_custom(_warning_less)
	return out


static func _subtitle(def: Resource) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append(LcnUiFormat.category_name(LcnUiFormat.as_name(def.get(&"category"))))
	var tier: int = LcnUiFormat.as_int(def.get(&"tier"))
	if tier > 1:
		parts.append("tier %d" % tier)
	var tags: Variant = def.get(&"tags")
	if typeof(tags) == TYPE_ARRAY and (tags as Array).has(&"unique"):
		parts.append("unique")
	return "  ·  ".join(parts)


# ---------------------------------------------------------------- cost -------

static func _cost_block(def: Resource, ctx: Ctx, warnings: Array, link_items: Array) -> Dictionary:
	var bill: Dictionary = def.get(&"cost") if typeof(def.get(&"cost")) == TYPE_DICTIONARY else {}
	var keys: Array = bill.keys()
	keys = LcnUiFormat.sorted_names(keys)
	var rows: Array = []
	var affordable: bool = true
	var short: PackedStringArray = PackedStringArray()
	var stock: Object = _stock(ctx)

	for k: Variant in keys:
		var item := StringName(String(k))
		var need: int = int(bill[k])
		var have: int = -1
		if stock != null:
			have = int(stock.call(&"count", item))
		var tone: int = LcnUiStyle.Tone.NEUTRAL
		if have >= 0:
			if have < need:
				tone = LcnUiStyle.Tone.BAD
				affordable = false
				short.append("%d %s" % [need - have, LcnUiFormat.item_name(item)])
			elif have < need * 2:
				tone = LcnUiStyle.Tone.WARN
			else:
				tone = LcnUiStyle.Tone.GOOD
		rows.append({
			"item": String(item),
			"label": LcnUiFormat.item_name(item),
			"need": need,
			"have": have,
			"tone": tone,
		})
		link_items.append(String(item))

	if not short.is_empty():
		var text: String = "Short %s." % LcnUiFormat.prose_list(short)
		var orphan: PackedStringArray = _unproduced(short_items(bill, stock), ctx)
		if not orphan.is_empty():
			text += " Nothing in the city makes %s yet." % LcnUiFormat.prose_list(orphan)
		_warn(warnings, Sev.BLOCKING, &"materials", text)

	var ticks: int = LcnUiFormat.as_int(def.get(&"build_time_ticks"))
	var power: float = 1.0
	if ctx.build != null and ctx.build.has_method(&"build_power"):
		power = maxf(0.05, float(ctx.build.call(&"build_power")))
	return {
		"rows": rows,
		"affordable": affordable,
		"build_ticks": ticks,
		"build_seconds": float(ticks) / maxf(0.05, power) * LcnUiFormat.SECONDS_PER_TICK,
		"build_label": LcnUiFormat.duration(float(ticks) / maxf(0.05, power) * LcnUiFormat.SECONDS_PER_TICK),
	}


## The shortfall per item, as {item: missing}. Public so the palette can colour
## a row without rebuilding the whole sheet.
static func short_items(bill: Dictionary, stock: Object) -> Dictionary:
	var out: Dictionary = {}
	if stock == null:
		return out
	var keys: Array = bill.keys()
	keys = LcnUiFormat.sorted_names(keys)
	for k: Variant in keys:
		var item := StringName(String(k))
		var missing: int = int(bill[k]) - int(stock.call(&"count", item))
		if missing > 0:
			out[item] = missing
	return out


## Which of these items nothing in the city currently produces. This is the line
## that turns "short 20 iron plate" into an actionable sentence.
static func _unproduced(missing: Dictionary, ctx: Ctx) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if ctx.build == null or not ctx.build.has_method(&"all_buildings"):
		return out
	var made: Dictionary[StringName, bool] = {}
	for raw: Variant in ctx.build.call(&"all_buildings"):
		var b: Object = raw
		if b == null:
			continue
		var d: Resource = b.get(&"def") as Resource
		if d == null:
			continue
		var ore := LcnUiFormat.as_name(d.get(&"extracts"))
		if String(ore) != "":
			made[ore] = true
		var recipes: Variant = d.get(&"recipes")
		if typeof(recipes) == TYPE_ARRAY:
			for r: Variant in recipes:
				for produced: StringName in _recipe_outputs(StringName(String(r))):
					made[produced] = true
	var keys: Array = missing.keys()
	keys = LcnUiFormat.sorted_names(keys)
	for k: Variant in keys:
		var item := StringName(String(k))
		if not made.has(item):
			out.append(LcnUiFormat.item_name(item))
	return out


static func _recipe_outputs(recipe_id: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	var res: Resource = _registry_item("recipes", recipe_id)
	if res == null:
		return out
	for field: StringName in [&"outputs", &"results", &"products"]:
		var v: Variant = res.get(field)
		if typeof(v) == TYPE_DICTIONARY:
			var keys: Array = (v as Dictionary).keys()
			keys = LcnUiFormat.sorted_names(keys)
			for k: Variant in keys:
				out.append(StringName(String(k)))
			return out
		if typeof(v) == TYPE_ARRAY:
			for e: Variant in v:
				out.append(StringName(String(e)))
			return out
	return out


# ------------------------------------------------------------ sections -------

static func _structure_section(def: Resource) -> Dictionary:
	var rows: Array = []
	var size: Vector2i = def.get(&"size") if typeof(def.get(&"size")) == TYPE_VECTOR2I else Vector2i.ONE
	_row(rows, "Footprint", LcnUiFormat.footprint(size))
	var drag: int = LcnUiFormat.as_int(def.get(&"drag_mode"))
	if drag == 1:
		_row(rows, "Placement", "drag a line", LcnUiStyle.Tone.DIM)
	elif drag == 2:
		_row(rows, "Placement", "drag an area", LcnUiStyle.Tone.DIM)
	if LcnUiFormat.as_flag(def.get(&"rotatable")):
		_row(rows, "Rotation", "%d facings  (R)" % maxi(1, LcnUiFormat.as_int(def.get(&"rotation_symmetry"))), LcnUiStyle.Tone.DIM)
	_row(rows, "Hit points", LcnUiFormat.num(LcnUiFormat.as_number(def.get(&"hp"))))
	var armor: float = LcnUiFormat.as_number(def.get(&"armor"))
	if armor > 0.0:
		_row(rows, "Armour", "%s per hit" % LcnUiFormat.num(armor))
	if LcnUiFormat.as_flag(def.get(&"walkable")):
		_row(rows, "Traffic", "walkable", LcnUiStyle.Tone.DIM)
	elif not LcnUiFormat.as_flag(def.get(&"blocks_movement")):
		_row(rows, "Traffic", "does not block movement", LcnUiStyle.Tone.DIM)
	var spacing: int = LcnUiFormat.as_int(def.get(&"min_spacing"))
	if spacing > 0:
		_row(rows, "Spacing", "%d tiles from another one" % spacing, LcnUiStyle.Tone.WARN)
	var cap: int = LcnUiFormat.as_int(def.get(&"max_count"))
	if cap > 0:
		_row(rows, "Limit", "%d in the city" % cap, LcnUiStyle.Tone.WARN)
	var vision: float = LcnUiFormat.as_number(def.get(&"vision_radius"))
	if vision > 0.0:
		_row(rows, "Vision", "%s tiles" % LcnUiFormat.num(vision))
	var weapon := LcnUiFormat.as_name(def.get(&"weapon_id"))
	if String(weapon) != "":
		_row(rows, "Weapon", LcnUiFormat.item_name(weapon), LcnUiStyle.Tone.ACCENT)
	return {"heading": "Structure", "rows": rows}


## Heat facts read out of [P02]'s OWN derivation, not re-guessed here.
## HeatDef.from_resource is what the solver runs on this definition, so a
## content change or a rule change shows up in the tooltip on the same build.
static func _heat_section(def: Resource, kind: StringName) -> Dictionary:
	var rows: Array = []
	var hd: Object = _heat_def(kind, def)
	if hd == null:
		# No heat part in this build: fall back to the raw schema fields.
		var produced: float = LcnUiFormat.as_number(def.get(&"heat_produced"))
		var consumed: float = LcnUiFormat.as_number(def.get(&"heat_consumed"))
		if produced > 0.0:
			_row(rows, "Produces", LcnUiFormat.rate(produced), LcnUiStyle.Tone.ACCENT)
		if consumed > 0.0:
			_row(rows, "Draws", LcnUiFormat.rate(consumed), LcnUiStyle.Tone.WARN)
		return {"heading": "Heat", "rows": rows}

	if LcnUiFormat.as_number(hd.get(&"output")) > 0.0:
		_row(rows, "Produces", LcnUiFormat.rate(LcnUiFormat.as_number(hd.get(&"output"))), LcnUiStyle.Tone.ACCENT)
		var ramp: float = LcnUiFormat.as_number(hd.get(&"ramp"))
		if ramp > 0.0:
			_row(rows, "Spin-up", LcnUiFormat.duration(LcnUiFormat.as_number(hd.get(&"output")) / maxf(0.001, ramp)),
				LcnUiStyle.Tone.DIM)
	if LcnUiFormat.as_number(hd.get(&"demand")) > 0.0:
		_row(rows, "Draws", LcnUiFormat.rate(LcnUiFormat.as_number(hd.get(&"demand"))), LcnUiStyle.Tone.WARN)
		_row(rows, "Shed priority", "%d  (%s)" % [
			LcnUiFormat.as_int(hd.get(&"priority")), _priority_words(LcnUiFormat.as_int(hd.get(&"priority")))],
			LcnUiStyle.Tone.DIM)
	if LcnUiFormat.as_number(hd.get(&"capacity")) > 0.0:
		_row(rows, "Carries", LcnUiFormat.rate(LcnUiFormat.as_number(hd.get(&"capacity"))), LcnUiStyle.Tone.ACCENT)
		_row(rows, "Loss per tile", LcnUiFormat.rate(LcnUiFormat.as_number(hd.get(&"loss_per_tile"))),
			LcnUiStyle.Tone.DIM)
		if LcnUiFormat.as_flag(hd.get(&"repeater")):
			_row(rows, "Repeater", "restores pressure downstream", LcnUiStyle.Tone.GOOD)
	if LcnUiFormat.as_number(hd.get(&"storage")) > 0.0:
		_row(rows, "Stores", "%s u" % LcnUiFormat.num(LcnUiFormat.as_number(hd.get(&"storage"))))
		_row(rows, "Discharges", LcnUiFormat.rate(LcnUiFormat.as_number(hd.get(&"discharge_rate"))))
	if LcnUiFormat.as_number(hd.get(&"local_buffer")) > 0.0:
		_row(rows, "Rides out", "%s u of brownout" % LcnUiFormat.num(LcnUiFormat.as_number(hd.get(&"local_buffer"))),
			LcnUiStyle.Tone.DIM)
	if LcnUiFormat.as_number(hd.get(&"radius")) > 0.0 and LcnUiFormat.as_number(hd.get(&"radiance")) > 0.0:
		_row(rows, "Warms", "%s tiles, up to +%s°C" % [
			LcnUiFormat.num(LcnUiFormat.as_number(hd.get(&"radius"))), LcnUiFormat.num(LcnUiFormat.as_number(hd.get(&"radiance")))],
			LcnUiStyle.Tone.ACCENT)
	_row(rows, "Insulation", LcnUiFormat.percent(LcnUiFormat.as_number(hd.get(&"insulation"))), LcnUiStyle.Tone.DIM)
	var fuel := LcnUiFormat.as_name(hd.get(&"fuel"))
	if String(fuel) != "":
		var per_unit: float = LcnUiFormat.as_number(hd.get(&"fuel_per_unit"))
		_row(rows, "Burns", "%s at %s" % [
			LcnUiFormat.item_name(fuel),
			LcnUiFormat.rate(per_unit * maxf(0.0, LcnUiFormat.as_number(hd.get(&"output"))), "%s/s" % LcnUiFormat.item_name(fuel))],
			LcnUiStyle.Tone.WARN)
	return {"heading": "Heat", "rows": rows}


static func _priority_words(priority: int) -> String:
	if priority >= 80:
		return "shed last"
	if priority >= 60:
		return "shed late"
	if priority >= 40:
		return "shed with industry"
	return "shed first"


static func _work_section(def: Resource, ctx: Ctx, link_items: Array) -> Dictionary:
	var rows: Array = []
	var workers: int = LcnUiFormat.as_int(def.get(&"workers_required"))
	if workers > 0:
		var idle: int = _idle_workers(ctx)
		var tone: int = LcnUiStyle.Tone.NEUTRAL
		var suffix: String = ""
		if idle >= 0:
			tone = LcnUiStyle.Tone.GOOD if idle >= workers else LcnUiStyle.Tone.BAD
			suffix = "   (%d idle)" % idle
		_row(rows, "Crew", "%d%s" % [workers, suffix], tone)
		var cap: int = LcnUiFormat.as_int(def.get(&"staff_capacity"))
		if cap > workers:
			_row(rows, "Room for", "%d" % cap, LcnUiStyle.Tone.DIM)
	var residents: int = LcnUiFormat.as_int(def.get(&"residents"))
	if residents > 0:
		_row(rows, "Houses", "%d citizens" % residents, LcnUiStyle.Tone.GOOD)
	var upkeep: Variant = def.get(&"upkeep")
	if typeof(upkeep) == TYPE_DICTIONARY and not (upkeep as Dictionary).is_empty():
		_row(rows, "Upkeep", "%s per minute" % LcnUiFormat.items(upkeep), LcnUiStyle.Tone.WARN)
		var ukeys: Array = (upkeep as Dictionary).keys()
		ukeys = LcnUiFormat.sorted_names(ukeys)
		for k: Variant in ukeys:
			link_items.append(String(k))
	return {"heading": "Work", "rows": rows}


static func _output_section(def: Resource, ctx: Ctx, link_items: Array) -> Dictionary:
	var rows: Array = []
	var ore := LcnUiFormat.as_name(def.get(&"extracts"))
	if String(ore) != "":
		var rate: float = LcnUiFormat.as_number(def.get(&"extract_rate"))
		if String(ore) == "*":
			# The wildcard extractor digs whatever seam it is standing on; there
			# is no item called "*" and pretending there is puts one in the browser.
			_row(rows, "Extracts", "whatever seam it stands on  (%s)" % \
				LcnUiFormat.per_minute(rate, "/min"), LcnUiStyle.Tone.ACCENT)
		else:
			_row(rows, "Extracts", "%s  (%s)" % [
				LcnUiFormat.item_name(ore), LcnUiFormat.per_minute(rate, " %s/min" % LcnUiFormat.item_name(ore))],
				LcnUiStyle.Tone.ACCENT)
			link_items.append(String(ore))
	var recipes: Variant = def.get(&"recipes")
	if typeof(recipes) == TYPE_ARRAY and not (recipes as Array).is_empty():
		var names: PackedStringArray = PackedStringArray()
		for r: Variant in recipes:
			names.append(LcnUiFormat.item_name(StringName(String(r))))
		_row(rows, "Recipes", ", ".join(names), LcnUiStyle.Tone.LINK)
		var speed: float = LcnUiFormat.as_number(def.get(&"craft_speed"))
		if not is_equal_approx(speed, 1.0):
			_row(rows, "Craft speed", "x%s" % LcnUiFormat.num(speed))
	var storage: int = LcnUiFormat.as_int(def.get(&"storage_capacity"))
	if storage > 0:
		var filter: Variant = def.get(&"storage_filter")
		var what: String = "anything"
		if typeof(filter) == TYPE_ARRAY and not (filter as Array).is_empty():
			var fnames: PackedStringArray = PackedStringArray()
			for f: Variant in filter:
				fnames.append(LcnUiFormat.item_name(StringName(String(f))))
				link_items.append(String(f))
			what = LcnUiFormat.prose_list(fnames, "or")
		_row(rows, "Stores", "%d slots of %s" % [storage, what])
	if ctx.production != null and ctx.production.has_method(&"describe_kind"):
		var extra: String = LcnUiFormat.as_text(ctx.production.call(&"describe_kind", LcnUiFormat.as_name(def.get(&"id"))))
		if extra != "":
			_row(rows, "Production", extra, LcnUiStyle.Tone.DIM)
	return {"heading": "Makes", "rows": rows}


## What laying this down opens up. Computed from the connection contract in the
## content itself: anything whose must_connect matches what this offers can only
## be built next to one of these.
static func _enables_section(def: Resource, ctx: Ctx, link_buildings: Array) -> Dictionary:
	var rows: Array = []
	var offers: Array = def.get(&"connects_as") if typeof(def.get(&"connects_as")) == TYPE_ARRAY else []
	var needs: Array = def.get(&"must_connect") if typeof(def.get(&"must_connect")) == TYPE_ARRAY else []
	if not needs.is_empty():
		var need_names: PackedStringArray = PackedStringArray()
		for n: Variant in needs:
			need_names.append(String(n).replace("_", " "))
		_row(rows, "Must touch", LcnUiFormat.prose_list(need_names, "or"), LcnUiStyle.Tone.WARN)
	if not offers.is_empty() and ctx.build != null and ctx.build.has_method(&"all_defs"):
		var offered: Dictionary[StringName, bool] = {}
		for o: Variant in offers:
			offered[StringName(String(o))] = true
		var enabled: PackedStringArray = PackedStringArray()
		for raw: Variant in ctx.build.call(&"all_defs"):
			var other: Resource = raw as Resource
			if other == null or other == def:
				continue
			var other_needs: Variant = other.get(&"must_connect")
			if typeof(other_needs) != TYPE_ARRAY:
				continue
			for n2: Variant in other_needs:
				if offered.has(StringName(String(n2))):
					enabled.append(LcnUiFormat.as_text(other.get(&"display_name")))
					link_buildings.append(LcnUiFormat.as_text(other.get(&"id")))
					break
		if not enabled.is_empty():
			_row(rows, "Lets you place", LcnUiFormat.prose_list(enabled), LcnUiStyle.Tone.GOOD)
	var ore := LcnUiFormat.as_name(def.get(&"needs_ore"))
	if String(ore) != "":
		var coverage: int = maxi(1, LcnUiFormat.as_int(def.get(&"ore_coverage")))
		var what: String = "any deposit" if String(ore) == "*" else LcnUiFormat.item_name(ore)
		_row(rows, "Sits on", "%s  (%d tile%s)" % [what, coverage, "" if coverage == 1 else "s"],
			LcnUiStyle.Tone.WARN)
	return {"heading": "Connections", "rows": rows}


# ------------------------------------------------------------- warnings ------

static func _placement_warnings(def: Resource, kind: StringName, ctx: Ctx, warnings: Array) -> void:
	if ctx.build == null:
		return
	if LcnUiFormat.as_int(def.get(&"max_count")) > 0 and ctx.build.has_method(&"count_of"):
		var have: int = int(ctx.build.call(&"count_of", kind))
		var cap: int = LcnUiFormat.as_int(def.get(&"max_count"))
		if have >= cap:
			# "its The Hearth" is what a naive format string produces, and it is
			# the kind of sentence that tells a player nobody read this screen.
			var what: String = LcnUiFormat.as_text(def.get(&"display_name"))
			if what.begins_with("The "):
				what = what.substr(4)
			var text: String = "The city already has its %s." % what
			if cap > 1:
				text = "The city already has all %d of its %s." % [cap, what]
			_warn(warnings, Sev.BLOCKING, &"max_count", text)
	if not ctx.has_cell or not ctx.build.has_method(&"can_place"):
		return
	var check: Dictionary = ctx.build.call(&"can_place", kind, ctx.cell, ctx.rot, true, -1)
	if bool(check.get("ok", false)):
		return
	# [P11] refuses for the same three reasons this sheet has already worded in
	# its own voice. Printing both is how a tooltip ends up saying "the city can
	# only support 1 The Hearth" directly under "the city already has its Hearth".
	var code := LcnUiFormat.as_name(check.get("code", ""))
	if code == &"insufficient_materials" or code == &"locked" or code == &"max_count":
		return
	var text: String = String(check.get("reason", ""))
	if code == &"needs_ore":
		var hint: String = _nearest_ore_hint(def, ctx)
		if hint != "":
			text += " " + hint
	_warn(warnings, Sev.BLOCKING, &"placement", text)


## "The nearest coal seam is 14 tiles north-east." Bounded: one nearest-resource
## query on [P01], which already answers this in a spiral scan.
static func _nearest_ore_hint(def: Resource, ctx: Ctx) -> String:
	if ctx.grid == null or not ctx.grid.has_method(&"nearest_resource"):
		return ""
	var want := LcnUiFormat.as_name(def.get(&"needs_ore"))
	if String(want) == "" or String(want) == "*":
		return ""
	var kind_index: int = _resource_index(ctx.grid, want)
	if kind_index < 0:
		return ""
	var found: Vector2i = ctx.grid.call(&"nearest_resource", ctx.cell, kind_index, 48)
	if found.x < 0:
		return "No %s within reach of here." % LcnUiFormat.item_name(want)
	return "The nearest %s is %s." % [LcnUiFormat.item_name(want), LcnUiFormat.bearing(ctx.cell, found)]


## Grid resource kinds are an enum on [P01]. Ask it for the mapping when it
## exposes one; otherwise the hint quietly stays silent rather than guessing.
static func _resource_index(grid: Object, ore: StringName) -> int:
	for method: StringName in [&"resource_index_of", &"resource_kind_id", &"deposit_index"]:
		if grid.has_method(method):
			return int(grid.call(method, ore))
	var names: Variant = grid.get(&"RESOURCE_NAMES")
	if typeof(names) == TYPE_ARRAY:
		var arr: Array = names
		for i: int in arr.size():
			if StringName(String(arr[i])) == ore:
				return i
	return -1


static func _heat_warnings(def: Resource, kind: StringName, ctx: Ctx, warnings: Array) -> void:
	if ctx.heat == null:
		return
	var hd: Object = _heat_def(kind, def)
	var demand: float = 0.0
	var output: float = 0.0
	var capacity: float = 0.0
	if hd != null:
		demand = LcnUiFormat.as_number(hd.get(&"demand"))
		output = LcnUiFormat.as_number(hd.get(&"output"))
		capacity = LcnUiFormat.as_number(hd.get(&"capacity"))
	else:
		demand = LcnUiFormat.as_number(def.get(&"heat_consumed"))
		output = LcnUiFormat.as_number(def.get(&"heat_produced"))
		capacity = LcnUiFormat.as_number(def.get(&"conduit_throughput"))

	var totals: Dictionary = {}
	if ctx.heat.has_method(&"totals"):
		totals = ctx.heat.call(&"totals")
	var deficit: float = float(totals.get("deficit", 0.0))
	var supply: float = float(totals.get("supply", 0.0))
	var city_demand: float = float(totals.get("demand", 0.0))

	if demand > 0.0:
		if deficit > 0.01:
			_warn(warnings, Sev.TIGHT, &"grid_short",
				"The grid is already %s short. This asks for %s more." % [
					LcnUiFormat.rate(deficit), LcnUiFormat.rate(demand)])
		else:
			var headroom: float = supply - city_demand
			if headroom < demand:
				_warn(warnings, Sev.TIGHT, &"grid_headroom",
					"Only %s of headroom left; this draws %s." % [
						LcnUiFormat.rate(maxf(0.0, headroom)), LcnUiFormat.rate(demand)])
	if output > 0.0 and deficit > 0.01:
		_warn(warnings, Sev.INFO, &"grid_relief",
			"Covers %s of the %s the city is short." % [
				LcnUiFormat.rate(minf(output, deficit)), LcnUiFormat.rate(deficit)])

	if not ctx.has_cell:
		return

	# Does heat actually REACH this tile? A consumer with no conduit next to it
	# is the single most common way a player loses a building to the cold.
	if demand > 0.0 or LcnUiFormat.as_number(def.get(&"heat_radius")) > 0.0:
		var join: Dictionary = _network_next_to(def, ctx)
		if int(join.get("network", -1)) < 0:
			var hint: String = _nearest_conduit_hint(ctx)
			_warn(warnings, Sev.TIGHT, &"no_heat_here",
				"No heat main reaches this tile.%s" % ("" if hint == "" else " " + hint))
		elif capacity <= 0.0:
			var nid: int = int(join["network"])
			var stats: Dictionary = _network_stats(ctx, nid)
			if not stats.is_empty():
				var net_deficit: float = float(stats.get("deficit", 0.0))
				if net_deficit > 0.01:
					_warn(warnings, Sev.TIGHT, &"local_short",
						"The network here is %s short already." % LcnUiFormat.rate(net_deficit))

	if capacity > 0.0:
		var join2: Dictionary = _network_next_to(def, ctx)
		var nid2: int = int(join2.get("network", -1))
		if nid2 >= 0:
			var stats2: Dictionary = _network_stats(ctx, nid2)
			var moving: float = float(stats2.get("delivered", stats2.get("supply", 0.0)))
			if moving > capacity + 0.01:
				_warn(warnings, Sev.TIGHT, &"pipe_bottleneck",
					"This carries %s; the network here already moves %s, so it becomes the new bottleneck." % [
						LcnUiFormat.rate(capacity), LcnUiFormat.rate(moving)])


## The heat network adjacent to the footprint this ghost would occupy, if any.
## Bounded by the footprint perimeter, so it is O(footprint) and not O(map).
static func _network_next_to(def: Resource, ctx: Ctx) -> Dictionary:
	if ctx.build == null or ctx.heat == null or not ctx.build.has_method(&"building_at"):
		return {}
	var cells: Array = []
	if def.has_method(&"cells_at"):
		cells = def.call(&"cells_at", ctx.cell, ctx.rot)
	else:
		cells = [ctx.cell]
	var own: Dictionary[Vector2i, bool] = {}
	for c: Variant in cells:
		own[c as Vector2i] = true
	var checked: int = 0
	for c2: Variant in cells:
		var cell: Vector2i = c2
		for d: Vector2i in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
			var n: Vector2i = cell + d
			if own.has(n):
				continue
			checked += 1
			if checked > SCAN_BUDGET:
				return {}
			var b: Object = ctx.build.call(&"building_at", n)
			if b == null:
				continue
			var id: int = LcnUiFormat.as_int(b.get(&"id"))
			if not ctx.heat.has_method(&"network_of"):
				continue
			var nid: int = int(ctx.heat.call(&"network_of", id))
			if nid >= 0:
				return {"network": nid, "building": id, "cell": n}
	return {}


static func _network_stats(ctx: Ctx, nid: int) -> Dictionary:
	if ctx.heat == null or nid < 0 or not ctx.heat.has_method(&"network_stats"):
		return {}
	return ctx.heat.call(&"network_stats", nid)


## Direction and distance to the closest conduit already standing. One pass over
## the building list, which is a few hundred entries even in a large city, and
## only when the player is hovering something that needs heat.
static func _nearest_conduit_hint(ctx: Ctx) -> String:
	if ctx.build == null or not ctx.build.has_method(&"all_buildings"):
		return ""
	var best: Vector2i = Vector2i(-1, -1)
	var best_d: int = 1 << 30
	var seen: int = 0
	for raw: Variant in ctx.build.call(&"all_buildings"):
		seen += 1
		if seen > SCAN_BUDGET:
			break
		var b: Object = raw
		var d: Resource = b.get(&"def") as Resource
		if d == null or not LcnUiFormat.as_flag(d.get(&"is_heat_conduit")):
			continue
		var cell: Vector2i = b.get(&"cell")
		var dist: int = absi(cell.x - ctx.cell.x) + absi(cell.y - ctx.cell.y)
		if dist < best_d:
			best_d = dist
			best = cell
	if best.x < 0:
		return "Nothing carries heat yet — lay pipe from the hearth."
	var where: String = LcnUiFormat.bearing(ctx.cell, best)
	if best_d <= NEAR_CONDUIT_TILES:
		return "The closest pipe is only %s — one short run reaches it." % where
	return "The closest pipe is %s." % where


static func _fuel_warnings(def: Resource, ctx: Ctx, warnings: Array, link_items: Array) -> void:
	var fuels: Variant = def.get(&"fuel_items")
	var burn: float = LcnUiFormat.as_number(def.get(&"fuel_burn_rate"))
	if typeof(fuels) != TYPE_ARRAY or (fuels as Array).is_empty() or burn <= 0.0:
		return
	var stock: Object = _stock(ctx)
	var first := StringName(String((fuels as Array)[0]))
	link_items.append(String(first))
	if stock == null:
		return
	var have: int = int(stock.call(&"count", first))
	var seconds: float = float(have) / maxf(0.0001, burn)
	if have <= 0:
		_warn(warnings, Sev.BLOCKING, &"no_fuel",
			"You have no %s. It will not light." % LcnUiFormat.item_name(first))
	elif seconds < LOW_FUEL_SECONDS:
		_warn(warnings, Sev.TIGHT, &"low_fuel",
			"%d %s left — about %s of burn." % [
				have, LcnUiFormat.item_name(first), LcnUiFormat.duration(seconds)])


static func _staffing_warnings(def: Resource, ctx: Ctx, warnings: Array) -> void:
	var need: int = LcnUiFormat.as_int(def.get(&"workers_required"))
	if need <= 0:
		return
	var idle: int = _idle_workers(ctx)
	if idle < 0:
		return
	if idle < need:
		_warn(warnings, Sev.TIGHT, &"crew",
			"Needs %d worker%s; %d idle. It will run at a fraction until someone is free." % [
				need, "" if need == 1 else "s", idle])


## Nightfall is the clock this whole game is played against, so a build time is
## only meaningful next to it.
static func _time_warnings(def: Resource, ctx: Ctx, warnings: Array) -> void:
	if ctx.climate == null or not ctx.climate.has_method(&"seconds_until_night"):
		return
	var to_night: float = float(ctx.climate.call(&"seconds_until_night"))
	if to_night <= 0.0:
		return
	var power: float = 1.0
	if ctx.build != null and ctx.build.has_method(&"build_power"):
		power = maxf(0.05, float(ctx.build.call(&"build_power")))
	var seconds: float = LcnUiFormat.as_number(LcnUiFormat.as_int(def.get(&"build_time_ticks"))) / power * LcnUiFormat.SECONDS_PER_TICK
	if seconds > to_night:
		_warn(warnings, Sev.TIGHT, &"too_slow",
			"Takes %s to raise; nightfall is in %s." % [
				LcnUiFormat.duration(seconds), LcnUiFormat.duration(to_night)])


# =========================================================== live instance ====

## The sheet for a building that ALREADY EXISTS. This is where [P02]'s
## per-consumer bottleneck attribution finally reaches a pixel: the sim knows
## exactly which tile choked this building and why, and until now nothing showed
## it to anyone.
static func instance_sheet(instance: Object, ctx: Ctx) -> Dictionary:
	if instance == null:
		return {"title": "—", "sections": [], "warnings": []}
	var def: Resource = instance.get(&"def") as Resource
	var id: int = LcnUiFormat.as_int(instance.get(&"id"))
	var out: Dictionary = {
		"id": LcnUiFormat.as_text(instance.get(&"kind")),
		"instance_id": id,
		"title": LcnUiFormat.as_text(def.get(&"display_name")) if def != null else LcnUiFormat.as_text(instance.get(&"kind")),
		"subtitle": "#%d  ·  %s" % [id, _state_name(LcnUiFormat.as_int(instance.get(&"state")))],
		"description": LcnUiFormat.as_text(def.get(&"description")) if def != null else "",
		"tint": def.get(&"tint") if def != null else Color.WHITE,
		"sections": [],
		"warnings": [],
		"cost": {},
		"locked": false,
		"links_items": [],
		"links_buildings": [],
	}
	var sections: Array = out["sections"]
	var warnings: Array = out["warnings"]

	var status: Array = []
	var hp: float = LcnUiFormat.as_number(instance.get(&"hp"))
	var max_hp: float = maxf(1.0, LcnUiFormat.as_number(instance.get(&"max_hp")))
	_row(status, "Condition", "%s / %s  (%s)" % [
		LcnUiFormat.num(hp), LcnUiFormat.num(max_hp), LcnUiFormat.percent(hp / max_hp)],
		LcnUiStyle.Tone.GOOD if hp >= max_hp * 0.99 else (
			LcnUiStyle.Tone.BAD if hp < max_hp * 0.35 else LcnUiStyle.Tone.WARN))
	var state: int = LcnUiFormat.as_int(instance.get(&"state"))
	if state == 0 or state == 1:
		var progress: float = LcnUiFormat.as_number(instance.get(&"progress"))
		var total: float = maxf(1.0, LcnUiFormat.as_number(def.get(&"build_time_ticks"))) if def != null else 1.0
		_row(status, "Built", LcnUiFormat.percent(clampf(progress / total, 0.0, 1.0)), LcnUiStyle.Tone.ACCENT)
		if instance.has_method(&"missing_items"):
			var missing: Dictionary = instance.call(&"missing_items")
			if not missing.is_empty():
				_row(status, "Waiting on", LcnUiFormat.items(missing), LcnUiStyle.Tone.BAD)
				_warn(warnings, Sev.TIGHT, &"site_waiting",
					"This site is waiting for %s." % LcnUiFormat.items(missing))
	if not LcnUiFormat.as_flag(instance.get(&"enabled")):
		_warn(warnings, Sev.INFO, &"switched_off", "Switched off by hand.")
	sections.append({"heading": "Status", "rows": status})

	if ctx.heat != null and ctx.heat.has_method(&"has_building") and bool(ctx.heat.call(&"has_building", id)):
		var rows: Array = []
		var served: float = float(ctx.heat.call(&"served_of", id)) if ctx.heat.has_method(&"served_of") else 1.0
		var temp: float = float(ctx.heat.call(&"temperature_of", id)) if ctx.heat.has_method(&"temperature_of") else 0.0
		_row(rows, "Heat served", LcnUiFormat.percent(served),
			LcnUiStyle.Tone.GOOD if served > 0.98 else (LcnUiStyle.Tone.BAD if served < 0.5 else LcnUiStyle.Tone.WARN))
		_row(rows, "Inside", "%d°C" % int(roundf(temp)),
			LcnUiStyle.Tone.BAD if temp < 0.0 else LcnUiStyle.Tone.NEUTRAL)
		var nid: int = int(ctx.heat.call(&"network_of", id)) if ctx.heat.has_method(&"network_of") else -1
		if nid >= 0:
			_row(rows, "Network", "#%d" % nid, LcnUiStyle.Tone.DIM)
			var stats: Dictionary = _network_stats(ctx, nid)
			if not stats.is_empty():
				_row(rows, "Network balance", "%s of %s" % [
					LcnUiFormat.rate(float(stats.get("delivered", 0.0))),
					LcnUiFormat.rate(float(stats.get("demand", 0.0)))],
					LcnUiStyle.supply_tone(float(stats.get("delivered", 0.0)), float(stats.get("demand", 0.0))))
		if ctx.heat.has_method(&"is_frozen") and bool(ctx.heat.call(&"is_frozen", id)):
			_warn(warnings, Sev.BLOCKING, &"frozen", "Frozen. It does nothing until heat comes back.")
		if served < 0.995 and ctx.heat.has_method(&"bottleneck_of"):
			var why: Dictionary = ctx.heat.call(&"bottleneck_of", id)
			if not why.is_empty():
				var text: String = _bottleneck_sentence(why)
				_row(rows, "Limited by", _bottleneck_word(LcnUiFormat.as_text(why.get("kind", ""))),
					LcnUiStyle.Tone.BAD)
				_warn(warnings, Sev.TIGHT, &"bottleneck", text)
		sections.append({"heading": "Heat", "rows": rows})

	if def != null:
		var st: Dictionary = _structure_section(def)
		sections.append(st)
	warnings.sort_custom(_warning_less)
	return out


## Two words for the row; the sentence underneath does the explaining.
static func _bottleneck_word(kind: String) -> String:
	match kind:
		"capacity", "throughput": return "pipe capacity"
		"supply": return "no generation"
		"unreachable": return "nothing reaches it"
		"priority": return "load shedding"
		"distance": return "distance loss"
		"disconnected": return "no network"
	return kind if kind != "" else "unattributed"


## Turns [P02]'s bottleneck record into a sentence with a place in it, because
## "throughput" on its own tells a player nothing about where to dig.
static func _bottleneck_sentence(why: Dictionary) -> String:
	var kind: String = String(why.get("kind", ""))
	var cell_raw: Variant = why.get("cell", null)
	var where: String = ""
	if typeof(cell_raw) == TYPE_ARRAY and (cell_raw as Array).size() >= 2:
		where = " at (%d, %d)" % [int((cell_raw as Array)[0]), int((cell_raw as Array)[1])]
	var what: String = String(why.get("building", ""))
	var who: String = "" if what == "" else " (%s)" % LcnUiFormat.item_name(StringName(what))
	# The vocabulary is [P02]'s: HeatFlow attributes every browned-out consumer to
	# the tile that bound the solve. These are the words for those kinds.
	match kind:
		"capacity", "throughput":
			return "Starved: the pipe%s%s is already carrying all it can." % [where, who]
		"supply":
			return "Starved: nothing on this network makes enough heat."
		"unreachable":
			return "Starved: no generator on this network can reach it — the run is broken or unpowered."
		"priority":
			return "Shed on purpose: something with a higher priority took the heat first."
		"distance":
			return "Starved: too far from the source — heat is lost along the way%s." % where
		"disconnected":
			return "Not connected to any heat network."
	if kind == "":
		return "Starved, and the solver did not attribute a cause this tick."
	return "Limited by %s%s%s." % [kind, where, who]


static func _state_name(state: int) -> String:
	match state:
		0: return "planned"
		1: return "building"
		2: return "running"
		3: return "switched off"
		4: return "frozen"
		5: return "being demolished"
		6: return "destroyed"
	return "unknown"


# ------------------------------------------------------------- plumbing ------

static func _row(rows: Array, label: String, value: String, tone: int = LcnUiStyle.Tone.NEUTRAL) -> void:
	rows.append({"label": label, "value": value, "tone": tone})


static func _warn(warnings: Array, severity: int, key: StringName, text: String) -> void:
	for w: Variant in warnings:
		if StringName(String((w as Dictionary).get("key", ""))) == key:
			return
	warnings.append({
		"key": String(key),
		"severity": severity,
		"tone": LcnUiStyle.Tone.BAD if severity == Sev.BLOCKING else (
			LcnUiStyle.Tone.WARN if severity == Sev.TIGHT else LcnUiStyle.Tone.DIM),
		"text": text,
	})


static func _warning_less(a: Dictionary, b: Dictionary) -> bool:
	var sa: int = int(a.get("severity", 0))
	var sb: int = int(b.get("severity", 0))
	if sa != sb:
		return sa > sb
	return String(a.get("key", "")) < String(b.get("key", ""))


static func _stock(ctx: Ctx) -> Object:
	if ctx.build == null:
		return null
	var s: Variant = ctx.build.get(&"stock")
	return s as Object


static func _idle_workers(ctx: Ctx) -> int:
	if ctx.citizens == null:
		return -1
	for method: StringName in [&"idle_workers", &"available_workers", &"unemployed", &"idle_builders"]:
		if ctx.citizens.has_method(method):
			return int(ctx.citizens.call(method))
	return -1


## [P02]'s own normalisation of a definition, or null when heat is not in this
## build. Cached per kind: HeatDef.from_resource walks a dozen properties and a
## tooltip must never be the reason a frame is late.
const HEAT_DEF_PATH: String = "res://game/sim/heat/heat_def.gd"

static var _heat_defs: Dictionary[StringName, Object] = {}


static func _heat_def(kind: StringName, def: Resource) -> Object:
	if _heat_defs.has(kind):
		return _heat_defs[kind]
	if def == null or not ResourceLoader.exists(HEAT_DEF_PATH):
		_heat_defs[kind] = null
		return null
	var script: Script = load(HEAT_DEF_PATH) as Script
	if script == null:
		_heat_defs[kind] = null
		return null
	var obj: Object = script.call(&"from_resource", kind, def) as Object
	_heat_defs[kind] = obj
	return obj


## Drops the derived-heat cache. Called when a world is created, because content
## can be re-scanned between worlds in tests.
static func reset_caches() -> void:
	_heat_defs.clear()


## Content lookup that never names the Registry autoload directly, so this file
## can be exercised from a bare test process.
static func _registry_item(category: String, id: StringName) -> Resource:
	var loop: MainLoop = Engine.get_main_loop()
	if loop == null:
		return null
	var root: Node = (loop as SceneTree).root if loop is SceneTree else null
	if root == null:
		return null
	var registry: Node = root.get_node_or_null(^"/root/Registry")
	if registry == null:
		return null
	return registry.call(&"get_item", category, id) as Resource


## Flat text of a sheet. Used by tests and by the log, and it is the fastest way
## for a human to check that the tooltip says something worth reading.
static func to_text(sheet_data: Dictionary) -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("%s — %s" % [String(sheet_data.get("title", "")), String(sheet_data.get("subtitle", ""))])
	var desc: String = String(sheet_data.get("description", ""))
	if desc != "":
		lines.append(desc)
	for raw: Variant in sheet_data.get("sections", []):
		var section: Dictionary = raw
		var rows: Array = section.get("rows", [])
		if rows.is_empty():
			continue
		lines.append("[%s]" % String(section.get("heading", "")))
		for r: Variant in rows:
			var row: Dictionary = r
			lines.append("  %-16s %s" % [String(row.get("label", "")), String(row.get("value", ""))])
	var warnings: Array = sheet_data.get("warnings", [])
	if not warnings.is_empty():
		lines.append("[!]")
		for w: Variant in warnings:
			lines.append("  %s" % String((w as Dictionary).get("text", "")))
	return "\n".join(lines)
