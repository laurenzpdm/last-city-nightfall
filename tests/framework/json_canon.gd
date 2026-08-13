class_name JsonCanon
extends RefCounted
## Canonical serialization + structural diffing for arbitrary GDScript data.
##
## Why this exists: Godot dictionaries iterate in insertion order, so two
## structurally identical simulation states can stringify differently. Every
## comparison in this repo — assert_eq, assert_deterministic, and the
## determinism tripwire in tools/ — routes through here so a difference in
## *shape* is never mistaken for a difference in *state*, and vice versa.
##
## Two representations:
##   canon(v)  human-readable, key-sorted, 12-decimal floats. For assertions.
##   exact(v)  engine JSON with full float precision. For hashing replays.

const MAX_DEPTH: int = 96
const FLOAT_DECIMALS: int = 12
## Below int64 max, so an integral float still renders as a readable integer
## instead of scientific notation. RNG stream states live up here.
const INT_SAFE_LIMIT: float = 9.0e18


## Key-sorted, type-normalized string form. Equal strings mean equal data.
static func canon(value: Variant) -> String:
	var parts: PackedStringArray = PackedStringArray()
	_write(value, parts, 0)
	return "".join(parts)


## Full-precision canonical JSON. Only valid for JSON-safe data (parsed files,
## Sim.serialize() output). Used for replay hashing where every bit matters.
static func exact(value: Variant) -> String:
	return JSON.stringify(value, "", true, true)


## Stable content hash of a value. Same data in, same hash out, forever.
static func hash_of(value: Variant) -> String:
	return exact(value).sha256_text()


static func canon_hash(value: Variant) -> String:
	return canon(value).sha256_text()


## Short one-line preview, for failure messages that must not flood the console.
static func preview(value: Variant, limit: int = 220) -> String:
	var s: String = canon(value)
	if s.length() <= limit:
		return s
	return s.substr(0, limit) + "… (%d chars)" % s.length()


# --- diffing -----------------------------------------------------------------

## Every structural difference between a and b, in sorted path order.
## `ignore` drops entries whose key OR full path matches — that is how volatile
## fields such as wall_ms are excluded from a determinism comparison.
## `epsilon` is a numeric tolerance; leave it at 0.0 for determinism work, where
## the last bit is the whole point, and raise it when comparing values that have
## survived a lossy JSON round trip.
static func diff(a: Variant, b: Variant, ignore: PackedStringArray = PackedStringArray(), limit: int = 40, epsilon: float = 0.0) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	_diff(a, b, "$", ignore, out, limit, 0, epsilon)
	return out


## Deep copy with every ignored key removed. Feed this to hash_of() to compare
## two runs while tolerating known-volatile fields.
static func strip(value: Variant, ignore: PackedStringArray) -> Variant:
	return _strip(value, "$", ignore, 0)


static func load_file(path: String) -> Variant:
	var full: String = resolve(path)
	if not FileAccess.file_exists(full):
		return null
	var txt: String = FileAccess.get_file_as_string(full)
	if txt == "":
		return null
	return JSON.parse_string(txt)


## Accepts res:// paths, absolute OS paths and paths relative to the project.
static func resolve(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	if path.is_absolute_path():
		return path
	return "res://" + path


# --- internals ---------------------------------------------------------------

static func _write(value: Variant, out: PackedStringArray, depth: int) -> void:
	if depth > MAX_DEPTH:
		out.append("\"<max-depth>\"")
		return
	match typeof(value):
		TYPE_NIL:
			out.append("null")
		TYPE_BOOL:
			out.append("true" if bool(value) else "false")
		TYPE_INT:
			out.append(str(int(value)))
		TYPE_FLOAT:
			out.append(num(float(value)))
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			out.append(JSON.stringify(String(value)))
		TYPE_DICTIONARY:
			_write_dict(value as Dictionary, out, depth)
		TYPE_ARRAY:
			_write_array(value as Array, out, depth)
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			_write_array(_to_array(value), out, depth)
		TYPE_VECTOR2:
			var v2: Vector2 = value
			out.append("[%s,%s]" % [num(v2.x), num(v2.y)])
		TYPE_VECTOR2I:
			var v2i: Vector2i = value
			out.append("[%d,%d]" % [v2i.x, v2i.y])
		TYPE_VECTOR3:
			var v3: Vector3 = value
			out.append("[%s,%s,%s]" % [num(v3.x), num(v3.y), num(v3.z)])
		TYPE_VECTOR3I:
			var v3i: Vector3i = value
			out.append("[%d,%d,%d]" % [v3i.x, v3i.y, v3i.z])
		TYPE_RECT2I:
			var ri: Rect2i = value
			out.append("[%d,%d,%d,%d]" % [ri.position.x, ri.position.y, ri.size.x, ri.size.y])
		TYPE_RECT2:
			var rr: Rect2 = value
			out.append("[%s,%s,%s,%s]" % [num(rr.position.x), num(rr.position.y), num(rr.size.x), num(rr.size.y)])
		TYPE_COLOR:
			var c: Color = value
			out.append("[%s,%s,%s,%s]" % [num(c.r), num(c.g), num(c.b), num(c.a)])
		TYPE_OBJECT:
			var o: Object = value
			if o == null:
				out.append("null")
			else:
				out.append(JSON.stringify("<%s>" % o.get_class()))
		_:
			out.append(JSON.stringify(str(value)))


static func _write_dict(d: Dictionary, out: PackedStringArray, depth: int) -> void:
	var keys: Array = d.keys()
	keys.sort_custom(_key_less)
	out.append("{")
	for i: int in range(keys.size()):
		if i > 0:
			out.append(",")
		out.append(JSON.stringify(_key_str(keys[i])))
		out.append(":")
		_write(d[keys[i]], out, depth + 1)
	out.append("}")


static func _write_array(a: Array, out: PackedStringArray, depth: int) -> void:
	out.append("[")
	for i: int in range(a.size()):
		if i > 0:
			out.append(",")
		_write(a[i], out, depth + 1)
	out.append("]")


static func _to_array(value: Variant) -> Array:
	var out: Array = []
	for item: Variant in value:
		out.append(item)
	return out


static func _key_less(a: Variant, b: Variant) -> bool:
	return _key_str(a) < _key_str(b)


static func _key_str(k: Variant) -> String:
	match typeof(k):
		TYPE_STRING, TYPE_STRING_NAME:
			return String(k)
		TYPE_INT:
			# Zero-padded so 2 sorts before 10 — a numeric id map must not
			# reorder just because it grew past nine entries.
			return "#%020d" % int(k)
		_:
			return canon(k)


## Canonical float text. Integral values collapse to their integer form so a
## value that survives a JSON round trip as 3.0 still equals the int 3.
static func num(f: float) -> String:
	if is_nan(f):
		return "NaN"
	if is_inf(f):
		return "Inf" if f > 0.0 else "-Inf"
	if f == 0.0:
		return "0"
	if f == floor(f) and absf(f) < INT_SAFE_LIMIT:
		return str(int(f))
	var a: float = absf(f)
	if a < 1.0e-9 or a >= 1.0e15:
		# Outside the range where fixed-point text keeps its significant digits,
		# fall back to the engine's own shortest round-trip form.
		return str(f)
	return String.num(f, FLOAT_DECIMALS)


static func _diff(a: Variant, b: Variant, path: String, ignore: PackedStringArray, out: PackedStringArray, limit: int, depth: int, epsilon: float) -> void:
	if out.size() >= limit or depth > MAX_DEPTH:
		return
	var ta: int = typeof(a)
	var tb: int = typeof(b)
	if _is_numeric(ta) and _is_numeric(tb):
		# Exact by default on purpose. canon()'s 12-decimal text is a readability
		# tolerance for assertions; a determinism diff must see the last bit.
		var fa: float = float(a)
		var fb: float = float(b)
		if is_nan(fa) and is_nan(fb):
			return
		var delta: float = absf(fa - fb)
		if delta > epsilon * maxf(1.0, maxf(absf(fa), absf(fb))):
			out.append("%s  a=%s  b=%s" % [path, _num_full(fa), _num_full(fb)])
		return
	if ta != tb:
		out.append("%s  type a=%s b=%s" % [path, type_string(ta), type_string(tb)])
		return
	if ta == TYPE_DICTIONARY:
		_diff_dict(a as Dictionary, b as Dictionary, path, ignore, out, limit, depth, epsilon)
		return
	if ta == TYPE_ARRAY:
		_diff_array(a as Array, b as Array, path, ignore, out, limit, depth, epsilon)
		return
	var sa: String = canon(a)
	var sb: String = canon(b)
	if sa != sb:
		out.append("%s  a=%s  b=%s" % [path, _clip(sa), _clip(sb)])


static func _diff_dict(a: Dictionary, b: Dictionary, path: String, ignore: PackedStringArray, out: PackedStringArray, limit: int, depth: int, epsilon: float) -> void:
	var keys: Array = a.keys()
	for k: Variant in b.keys():
		if not a.has(k):
			keys.append(k)
	keys.sort_custom(_key_less)
	for k: Variant in keys:
		if out.size() >= limit:
			return
		var ks: String = _key_str(k)
		var sub: String = "%s.%s" % [path, ks]
		if _ignored(ks, sub, ignore):
			continue
		if not a.has(k):
			out.append("%s  missing in a (b=%s)" % [sub, _clip(canon(b[k]))])
			continue
		if not b.has(k):
			out.append("%s  missing in b (a=%s)" % [sub, _clip(canon(a[k]))])
			continue
		_diff(a[k], b[k], sub, ignore, out, limit, depth + 1, epsilon)


static func _diff_array(a: Array, b: Array, path: String, ignore: PackedStringArray, out: PackedStringArray, limit: int, depth: int, epsilon: float) -> void:
	if a.size() != b.size():
		out.append("%s  length a=%d b=%d" % [path, a.size(), b.size()])
	var n: int = mini(a.size(), b.size())
	for i: int in range(n):
		if out.size() >= limit:
			return
		_diff(a[i], b[i], "%s[%d]" % [path, i], ignore, out, limit, depth + 1, epsilon)


static func _ignored(key: String, path: String, ignore: PackedStringArray) -> bool:
	for pattern: String in ignore:
		if pattern == key or pattern == path:
			return true
	return false


static func _strip(value: Variant, path: String, ignore: PackedStringArray, depth: int) -> Variant:
	if depth > MAX_DEPTH:
		return value
	match typeof(value):
		TYPE_DICTIONARY:
			var src: Dictionary = value
			var out: Dictionary = {}
			for k: Variant in src.keys():
				var ks: String = _key_str(k)
				var sub: String = "%s.%s" % [path, ks]
				if _ignored(ks, sub, ignore):
					continue
				out[k] = _strip(src[k], sub, ignore, depth + 1)
			return out
		TYPE_ARRAY:
			var sa: Array = value
			var oa: Array = []
			for i: int in range(sa.size()):
				oa.append(_strip(sa[i], "%s[%d]" % [path, i], ignore, depth + 1))
			return oa
		_:
			return value


static func _is_numeric(t: int) -> bool:
	return t == TYPE_INT or t == TYPE_FLOAT


## Full-precision float text for diff output, so a divergence in the 15th
## decimal is visible instead of printing "a=0.1 b=0.1".
static func _num_full(f: float) -> String:
	if is_nan(f):
		return "NaN"
	if is_inf(f):
		return "Inf" if f > 0.0 else "-Inf"
	return String.num(f, 17) if absf(f) < 1.0e15 else str(f)


static func _clip(s: String, limit: int = 90) -> String:
	if s.length() <= limit:
		return s
	return s.substr(0, limit) + "…"
