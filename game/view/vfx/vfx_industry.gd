class_name LcnVfxIndustry
extends Node2D
## Fire, smoke, sparks and hot air. [P14]
##
## The contract this obeys is [P02]'s, and it is the reason the effect is worth
## anything: a chimney smokes because the building under it is ACTUALLY burning
## fuel this tick, at a density proportional to what it is actually producing.
## A browned-out district visibly stops smoking. A frozen generator stops
## throwing embers. A workshop only throws sparks on the ticks [P04] says it is
## crafting. Nothing here is decoration on a timer.
##
## Four pooled emitters serve the whole city:
##   embers  additive, rising, off anything with an open firebox
##   smoke   mixed, wind-bent, thickening with industry
##   sparks  additive, short, off machines that are cutting metal right now
##   haze    a barely-there carrier for the heat refraction [P13]'s post stack
##           puts over the same tiles
##
## Cost is bounded by SOURCE_SCAN_MAX structures inspected on a
## SOURCE_REFRESH_FRAMES cadence and POINTS_MAX emission points, so it does not
## grow with the size of the city — the fortieth chimney is three floats.

var embers: LcnVfxPointField = null
var smoke: LcnVfxPointField = null
var sparks: LcnVfxPointField = null
var haze: LcnVfxPointField = null

var _model: LcnWorldModel = null
var _heat: SimSystem = null
var _prod: SimSystem = null
var _has_power: bool = false
var _has_state: bool = false

var _furnace: PackedVector2Array = PackedVector2Array()
var _works: PackedVector2Array = PackedVector2Array()
var _vents: PackedVector2Array = PackedVector2Array()
var _crafting: PackedVector2Array = PackedVector2Array()
var _frames: int = 0
var _scanned: int = 0
var _heat_sum: float = 0.0


func setup(model: LcnWorldModel) -> void:
	_model = model

	embers = _add("Embers", {
		"amount": LcnVfxTuning.EMBER_AMOUNT, "lifetime": LcnVfxTuning.EMBER_LIFETIME,
		"texture": LcnVfxArt.texture("dot"), "additive": true, "z": 22,
		"direction": Vector2.UP, "spread_deg": 30.0,
		"speed_min": 26.0, "speed_max": 70.0, "gravity": Vector2(0.0, -18.0),
		"damping": 0.8, "scale_min": 0.10, "scale_max": 0.30,
		"ramp": LcnVfxArt.ramp([
			LcnVfxTuning.EMBER_HOT, LcnVfxTuning.EMBER_MID, LcnVfxTuning.EMBER_DIM,
			Color(LcnVfxTuning.EMBER_DIM.r, LcnVfxTuning.EMBER_DIM.g,
				LcnVfxTuning.EMBER_DIM.b, 0.0)] as Array[Color]),
		"turbulence": true, "turb_strength": 1.8, "turb_scale": 3.4,
	})

	smoke = _add("Smoke", {
		"amount": LcnVfxTuning.SMOKE_AMOUNT, "lifetime": LcnVfxTuning.SMOKE_LIFETIME,
		"texture": LcnVfxArt.texture("puff"), "z": 24,
		"direction": Vector2.UP, "spread_deg": 16.0,
		"speed_min": 14.0, "speed_max": 34.0, "gravity": Vector2(0.0, -12.0),
		"damping": 0.3, "scale_min": 0.30, "scale_max": 0.75,
		"scale_curve": _grow_curve(),
		"ramp": LcnVfxArt.ramp([
			Color(LcnVfxTuning.SMOKE_DARK.r, LcnVfxTuning.SMOKE_DARK.g,
				LcnVfxTuning.SMOKE_DARK.b, 0.0),
			Color(LcnVfxTuning.SMOKE_DARK.r, LcnVfxTuning.SMOKE_DARK.g,
				LcnVfxTuning.SMOKE_DARK.b, 0.42),
			Color(LcnVfxTuning.SMOKE_LIGHT.r, LcnVfxTuning.SMOKE_LIGHT.g,
				LcnVfxTuning.SMOKE_LIGHT.b, 0.22),
			Color(LcnVfxTuning.SMOKE_LIGHT.r, LcnVfxTuning.SMOKE_LIGHT.g,
				LcnVfxTuning.SMOKE_LIGHT.b, 0.0)] as Array[Color]),
		"turbulence": true, "turb_strength": 1.0, "turb_scale": 1.6,
	})

	sparks = _add("Sparks", {
		"amount": LcnVfxTuning.SPARK_AMOUNT, "lifetime": LcnVfxTuning.SPARK_LIFETIME,
		"texture": LcnVfxArt.texture("mote"), "additive": true, "z": 23,
		"direction": Vector2.UP, "spread_deg": 110.0,
		"speed_min": 70.0, "speed_max": 190.0, "gravity": Vector2(0.0, 240.0),
		"damping": 2.0, "scale_min": 0.08, "scale_max": 0.18,
		"ramp": LcnVfxArt.ramp([LcnVfxTuning.SPARK, LcnVfxTuning.EMBER_MID,
			Color(LcnVfxTuning.EMBER_DIM.r, LcnVfxTuning.EMBER_DIM.g,
				LcnVfxTuning.EMBER_DIM.b, 0.0)] as Array[Color]),
	})

	haze = _add("HeatHaze", {
		"amount": LcnVfxTuning.HAZE_AMOUNT, "lifetime": LcnVfxTuning.HAZE_LIFETIME,
		"texture": LcnVfxArt.texture("haze"), "additive": true, "z": 21,
		"direction": Vector2.UP, "spread_deg": 22.0,
		"speed_min": 12.0, "speed_max": 30.0, "gravity": Vector2(0.0, -20.0),
		"damping": 0.5, "scale_min": 0.25, "scale_max": 0.55,
		"scale_curve": _grow_curve(),
		"ramp": LcnVfxArt.ramp([
			Color(1.0, 0.72, 0.44, 0.0), Color(1.0, 0.62, 0.34, 0.085),
			Color(1.0, 0.62, 0.34, 0.0)] as Array[Color]),
	})


func _add(node_name: String, cfg: Dictionary) -> LcnVfxPointField:
	var f := LcnVfxPointField.new()
	f.name = node_name
	add_child(f)
	f.configure(cfg)
	return f


## Smoke that does not expand as it rises reads as a string of beads.
static func _grow_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.35))
	c.add_point(Vector2(0.45, 0.85))
	c.add_point(Vector2(1.0, 1.4))
	return c


## Late binding: [P02] and [P04] may not exist yet in a parallel build, and the
## effect degrades to "what the building definition says it burns" rather than
## disappearing.
func bind_sim() -> void:
	_heat = Sim.get_system(&"heat")
	_prod = Sim.get_system(&"production")
	_has_power = _heat != null and _heat.has_method("power_factor") \
		and _heat.has_method("has_building")
	_has_state = _prod != null and _prod.has_method("state_of") \
		and _prod.has_method("has_machine")


func update(view: Rect2, wind: Vector2, calm: bool, quality: float) -> void:
	_frames += 1
	if _model == null:
		return
	if _frames % LcnVfxTuning.SOURCE_REFRESH_FRAMES == 1:
		_rescan(view)
	for f: LcnVfxPointField in [embers, smoke, sparks, haze]:
		f.set_view(view)

	# Smoke is the only stream the wind really owns; embers are light enough to
	# be pushed, sparks are thrown too hard and too briefly to care.
	smoke.set_wind(wind, 0.85, Vector2(0.0, -12.0))
	embers.set_wind(wind, 0.35, Vector2(0.0, -18.0))
	haze.set_wind(wind, 0.15, Vector2(0.0, -20.0))

	var q: float = clampf(quality, 0.0, 1.0) * (0.55 if calm else 1.0)
	embers.set_points(_furnace)
	embers.set_density(share_for(_furnace.size()) * q)
	smoke.set_points(_plumes())
	smoke.set_density(share_for(_furnace.size() + _works.size()) * q)
	sparks.set_points(_crafting)
	sparks.set_density(share_for(_crafting.size()) * q * 0.8)
	haze.set_points(_vents)
	haze.set_density(share_for(_vents.size()) * q * 0.7)


## Density per emitter falls as the number of sources rises: forty chimneys share
## one particle buffer, so each one has to smoke less or the buffer starves the
## nearest and most visible plume to feed the far ones.
static func share_for(n: int) -> float:
	if n <= 0:
		return 0.0
	return clampf(0.35 + 0.65 * sqrt(clampf(float(n) / 12.0, 0.0, 1.0)), 0.0, 1.0)


func _plumes() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector2 in _furnace:
		if out.size() >= LcnVfxTuning.POINTS_MAX:
			return out
		out.append(p)
	for p: Vector2 in _works:
		if out.size() >= LcnVfxTuning.POINTS_MAX:
			return out
		out.append(p)
	return out


## Rebuilds the source lists. Structures are sorted by how much the player is
## likely to be looking at them (bright and central first) so the cap drops the
## right ones.
func _rescan(view: Rect2) -> void:
	_furnace.clear()
	_works.clear()
	_vents.clear()
	_crafting.clear()
	_heat_sum = 0.0
	_scanned = 0
	var all: Array[Dictionary] = _model.buildings()
	if all.is_empty():
		return
	var grown: Rect2 = view.grow(64.0)
	var mid: Vector2 = view.get_center()
	var cand: Array[Dictionary] = []
	for b: Dictionary in all:
		var centre: Vector2 = b["centre"]
		if not grown.has_point(centre):
			continue
		_scanned += 1
		if _scanned > LcnVfxTuning.SOURCE_SCAN_MAX:
			break
		var state: int = int(b["state"])
		if state == LcnWorldModel.BUILD_GHOST or state == LcnWorldModel.BUILD_CONSTRUCTING:
			continue
		var cls: StringName = LcnVfxTuning.fx_class(b["kind"], b["arch"])
		if cls == &"none":
			continue
		var live: float = _live_intensity(b, state)
		if live < 0.08:
			continue
		_heat_sum += live
		cand.append({"pos": centre, "cls": cls, "live": live, "id": int(b["id"]),
			"lift": float(b.get("lift", 0.0)),
			"score": live * 2.0 - centre.distance_to(mid) / maxf(view.size.x, 1.0)})
	cand.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"]))

	for e: Dictionary in cand:
		var pos: Vector2 = e["pos"]
		# Smoke leaves the roof, not the floor. `lift` is the sprite's vertical
		# offset, so this is the top of the actual silhouette on screen.
		var top: Vector2 = pos + Vector2(0.0, -14.0 - float(e["lift"]) * 0.8)
		match StringName(e["cls"]):
			&"furnace":
				if _furnace.size() < LcnVfxTuning.POINTS_MAX:
					_furnace.append(top)
			&"works":
				if _works.size() < LcnVfxTuning.POINTS_MAX:
					_works.append(top)
				if _is_crafting(int(e["id"])) and _crafting.size() < LcnVfxTuning.POINTS_MAX:
					_crafting.append(pos + Vector2(0.0, -6.0))
			&"vent":
				if _vents.size() < LcnVfxTuning.POINTS_MAX:
					_vents.append(pos + Vector2(0.0, -8.0))


## What this building is actually doing right now, not what its sheet says it
## could do. Frozen and disabled structures fall to a trickle; a starved network
## dims every chimney hanging off it.
func _live_intensity(b: Dictionary, state: int) -> float:
	var w: float = float(b["warm"])
	if state == LcnWorldModel.BUILD_FROZEN:
		return w * 0.05
	if state == LcnWorldModel.BUILD_DISABLED:
		return w * 0.10
	if _has_power:
		var id: int = int(b["id"])
		if bool(_heat.call("has_building", id)):
			w *= clampf(0.20 + float(_heat.call("power_factor", id)) * 0.90, 0.0, 1.15)
	return w


func _is_crafting(id: int) -> bool:
	if not _has_state:
		return false
	if not bool(_prod.call("has_machine", id)):
		return false
	return int(_prod.call("state_of", id)) == ProdMachine.State.RUNNING


func stats() -> Dictionary:
	return {
		"furnaces": _furnace.size(),
		"works": _works.size(),
		"vents": _vents.size(),
		"crafting": _crafting.size(),
		"scanned": _scanned,
		"heat_sum": snappedf(_heat_sum, 0.01),
		"fuel": "metered" if _has_power else "sheet",
	}
