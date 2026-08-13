class_name ProdSort
extends RefCounted
## Deterministic ordering for StringName keys.
##
## `Array.sort()` on StringName compares INTERNED POINTERS, not text. The result
## is stable inside one process and stable across two identical processes — which
## is exactly what makes it dangerous, because the determinism replay goes green
## on it. What it is NOT is stable across BUILDS: intern order depends on which
## name the engine happened to see first, so adding a recipe somewhere else in
## the project can silently reorder an iteration here, and two balance runs of
## different builds stop being comparable.
##
## Every iteration in game/sim/production/ that can reach state goes through
## this. Found by [P06], who lost a determinism run to it.

## Item ids in true alphabetical order.
static func names(keys: Array) -> Array[StringName]:
	var text: Array[String] = []
	for k: Variant in keys:
		text.append(String(k))
	text.sort()
	var out: Array[StringName] = []
	for t: String in text:
		out.append(StringName(t))
	return out


## Sorted keys of an item table, ready to iterate.
static func keys_of(d: Dictionary) -> Array[StringName]:
	return names(d.keys())
