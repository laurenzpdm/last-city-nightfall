class_name ResearchEffects
extends RefCounted
## The numeric payoff layer: every completed node's effects, merged, cached.
##
## This is how a tech tree stops being a list of unlocked buildings and starts
## being a curve. Other systems ask one question per tick at most:
##
##   var m: float = 1.0
##   var r: SimSystem = Sim.get_system(&"research")
##   if r != null:
##       m = r.multiplier(ResearchDefs.E_HEAT_LOSS_MULT)
##
## Stacking is ADDITIVE around zero (see ResearchDefs) so two +20% nodes make
## 1.4 rather than 1.44. A tech tree that multiplies goes exponential by tier 3
## and the balance sheet stops meaning anything.

## key -> summed value. Recomputed only when a node completes.
var _values: Dictionary[StringName, float] = {}
## key -> sorted list of node ids contributing, for "why is this number 1.4?".
var _sources: Dictionary[StringName, Array] = {}


func clear() -> void:
	_values.clear()
	_sources.clear()


## Folds one completed node into the layer. Idempotent per node id: applying the
## same node twice is refused, because a save reload must not double a bonus.
func apply(node: ResearchNode) -> bool:
	if node == null:
		return false
	var keys: Array = node.effects.keys()
	keys.sort()
	for k: Variant in keys:
		var key: StringName = StringName(String(k))
		var contributors: Array = _sources.get(key, [])
		if contributors.has(String(node.id)):
			return false
		contributors.append(String(node.id))
		contributors.sort()
		_sources[key] = contributors
		_values[key] = float(_values.get(key, 0.0)) + float(node.effects[k])
	return true


## Raw sum for a key. 0.0 when nothing has touched it.
func modifier(key: StringName) -> float:
	return float(_values.get(key, 0.0))


## 1.0 + the sum, floored at zero so a stack of penalties can never invert a
## rate into a negative one.
func multiplier(key: StringName) -> float:
	return maxf(0.0, 1.0 + float(_values.get(key, 0.0)))


func has(key: StringName) -> bool:
	return _values.has(key)


## Which nodes produced this number. What a tooltip shows on the modifier row.
func sources_of(key: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	for s: Variant in _sources.get(key, []):
		out.append(StringName(String(s)))
	return out


## Every live modifier, sorted, JSON-safe. Goes straight into serialize().
func snapshot() -> Dictionary:
	var out: Dictionary = {}
	var keys: Array = _values.keys()
	keys.sort()
	for k: StringName in keys:
		out[String(k)] = snappedf(float(_values[k]), 0.0001)
	return out


## The same numbers with their provenance, for the tree view's effect panel.
func detailed() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var keys: Array = _values.keys()
	keys.sort()
	for k: StringName in keys:
		var sources: Array = _sources.get(k, [])
		out.append({
			"key": String(k),
			"value": snappedf(float(_values[k]), 0.0001),
			"multiplier": snappedf(multiplier(k), 0.0001),
			"is_multiplier": ResearchDefs.is_multiplier_key(k),
			"sources": sources.duplicate(),
		})
	return out


func size() -> int:
	return _values.size()
