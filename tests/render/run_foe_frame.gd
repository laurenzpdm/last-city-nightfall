extends SceneTree
## CAN YOU FIND THE MONSTERS IN THE FRAME THE GAME ACTUALLY MAKES? [P13]
##
##   tools/run_visual.sh --scenario=first_night --out=artifacts/mine
##   godot --headless --path . --script tests/render/run_foe_frame.gd
##   LCN_FRAME_DIR=artifacts/mine godot --headless --path . --script tests/render/run_foe_frame.gd
##
## THIS SUITE EXISTS BECAUSE EVERY INSTRUMENT BEFORE IT WAS A BENCH.
##
## Four rounds of this project have shipped a contrast fix that measured
## beautifully and could not be seen. The last one graded eleven of eleven
## creatures at delta-L 0.42 on `tests/render/night_contrast.tscn`, ran an
## ablation against its parent commit, found and fixed a false green in its own
## rig — excellent work by every standard — and then a critic opened
## `artifacts/CRIT/shots/assault.world.png`, the ordinary output of the ordinary
## harness, scanned it for the foe cue and found:
##
##     105 pixels, two clusters, and BOTH were the temperature labels
##     "41C" and "31C". Not one creature. Ten hostiles alive, 21 agents drawn.
##
## The rig was not wrong. It simply did not contain the picture: no post grade,
## no night vignette, and no "under attack" red wash — which is the one thing on
## the screen guaranteed to be there at the exact moment a hostile has to be
## found, and which is the exact opposite colour to the cold blue-white rim that
## is the ONLY thing separating a foe from a citizen.
##
## So this file owns one rule and refuses to bend it:
##
##     IT MAY NOT STAND ANYTHING UP. It opens a PNG the harness wrote, with the
##     wash in it, the grade in it and the HUD in it, and it measures THAT.
##
## It grades three things, and each of them can be checked by hand from the same
## artifacts folder:
##
##   1. LIFT     every hostile is brighter than the plain around it, measured at
##               the rectangle `LcnEntityRenderer` logged for that creature in
##               the run's own `log.txt`, against a ring drawn OUTSIDE its light
##               pool so the pool cannot flatter itself.
##   2. COLD     ...and bluer than it, because value alone does not tell a
##               player which of two figures is the one that wants to kill them.
##   3. BLIND    a scan of the WHOLE frame that does not know where anything is
##               finds a cold, bright, compact cluster on top of every hostile,
##               and does not find very many anywhere else. This is the critic's
##               own test, run against the build automatically.
##
## And it carries its own control: the same blind scan is run on a night frame
## from the same run with ZERO hostiles in it. A scanner that lights up on an
## empty night is a scanner that would have passed the broken build too.
##
## WHAT MAKES IT RED. Measured, not guessed — each of these was applied to a
## scratch copy of `game/view/render/entity_renderer.gd` and a smoke visual run
## re-graded:
##
##   `_draw_foe_pools` returning immediately (no cold pool)
##       → LIFT drops from 0.25–0.33 to 0.09–0.15 and the BLIND scan finds
##         nothing on any hostile: 0 of 6 recalled.
##   `foe_lit_share` back to `lit_share` (the treatment keyed off the local
##   ground, which is how it shipped)
##       → the hostiles inside the perimeter, the ones the alert stack is
##         shouting about, fall to LIFT 0.04–0.14.
##   `MIN_LIFT` moved down to make the above go green
##       → the control frame is unaffected, which is the tell: a threshold that
##         only ever moves in one direction is not measuring anything.
##
## A NOTE ON THE VERDICT. If no visual run exists in `artifacts/` this suite
## reports PARTIAL and names the command to run. It does not report a pass: a
## check that could not ask its question has not answered it, and that failure
## mode has cost this project three separate rounds.

# --- what "findable" means, in the graded frame, as delivered numbers ---------

## Luminance the figure must clear the plain around it. The brief is 0.25–0.30
## delivered; measured on `artifacts/H1_smoke2` after the fix the hostiles land
## at 0.25–0.33 and before it at 0.09–0.15, so this sits below the fix and well
## above the defect rather than snug against either.
const MIN_LIFT: float = 0.17
## ...and blue-minus-red, which is what says FOE rather than merely FIGURE. The
## city's own people are lit warm by the city's own fires and read negative here.
const MIN_COLD: float = 0.030
## Share of the hostiles on screen that must clear both. Not 1.0: a creature can
## legitimately be behind a building at the instant the shutter opens, and a
## gate that goes red for correct occlusion teaches people to ignore it.
const MIN_PASS_SHARE: float = 0.80

## The ring the plain is read from, in screen pixels from the figure's centre.
## Starts outside the pool on purpose — a mark that brightens its own reference
## measures nothing.
const RING_IN: float = 75.0
const RING_OUT: float = 130.0

# --- the blind scan -----------------------------------------------------------

## Blue-minus-red and luminance-above-the-local-plain a pixel needs to be part of
## a candidate. Both are read at HALF resolution, which is also the honest
## resolution for "at a glance".
const SCAN_COLD: float = 0.055
const SCAN_LIFT: float = 0.055
## Half-res block the local plain is estimated over (128 full-res pixels).
const SCAN_BLOCK: int = 64
## A candidate smaller than this in half-res pixels is grain; larger is the sky.
const SCAN_MIN_AREA: int = 30
const SCAN_MAX_AREA: int = 1600
## Text rows, panel edges and bar fills are long and thin. A creature is not.
const SCAN_MAX_ASPECT: float = 3.5
## HOW THE NOISE FLOOR IS SET, AND WHY IT IS NOT A CONSTANT.
##
## Most of what a blind cold-bright scan finds in a `.world` frame is INTERFACE:
## the clock's digits, the stores row, the alert stack, the threat radar. That is
## not a rendering defect — a player reads a panel as a panel — but it is exactly
## what fooled the last scan of this build, which reported "105 pixels, two
## clusters" and both were temperature labels.
##
## So the floor is measured, not declared. The same scan is run on a night frame
## from the SAME RUN with zero hostiles alive: same city, same hour, same HUD.
## Whatever it finds there is the interface, and an assault frame is allowed that
## many plus SCAN_NOISE_SLACK. A change that floods the frame with cold blobs to
## make the recall check pass shows up here immediately; a change that only
## lights up the creatures does not.
const SCAN_NOISE_SLACK: int = 8
## A sanity ceiling on the control itself. Not the test — the test is the
## comparison — but a control that finds two hundred things is a broken scanner
## and must not be allowed to authorise anything.
const SCAN_CONTROL_MAX: int = 60
## How far a cluster may be from a hostile's rectangle and still be that hostile.
const SCAN_SLACK: float = 26.0
## Two hostiles closer than this on screen are one shape, and asking a scanner to
## separate them would be asking it to lie.
const GROUP_PX: float = 34.0

## How far the foe-mark dump may be from the shot's tick and still describe it.
## The shutter strips the modal layers and waits two process frames before it
## reads, so the photograph is a frame or two after the line that announced it.
const DUMP_SLACK_TICKS: int = 40

var _checks: int = 0
var _fails: PackedStringArray = PackedStringArray()
var _unchecked: PackedStringArray = PackedStringArray()
var _notes: PackedStringArray = PackedStringArray()
var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var dir: String = _find_run()
	if dir.is_empty():
		_unchecked.append(
			"no visual run in artifacts/ has a world frame with a hostile in it — run"
			+ " `tools/run_visual.sh --scenario=first_night --out=artifacts/vis`"
			+ " (or point LCN_FRAME_DIR at one) and grade THAT")
	else:
		_grade(dir)
	return _verdict()


func _verdict() -> bool:
	for n: String in _notes:
		print("  " + n)
	for line: String in _fails:
		print("  FAIL  " + line)
	for u: String in _unchecked:
		print("  UNCHECKED  " + u)
	if not _fails.is_empty():
		print("TESTS FAILED — %d of %d checks failed" % [_fails.size(), _checks])
		quit(mini(_fails.size(), 120))
		return true
	if not _unchecked.is_empty():
		print("TESTS PASSED, PARTIAL — %d checks, %d unchecked"
			% [_checks, _unchecked.size()])
		quit(0)
		return true
	print("TESTS PASSED — %d checks, 0 failures" % _checks)
	quit(0)
	return true


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(what)


# ============================================================ finding the run ==

## An artifacts folder with a `log.txt` and a `shots/` that between them contain
## at least one world frame photographed with something hostile alive.
func _find_run() -> String:
	var root: String = ProjectSettings.globalize_path("res://artifacts")
	var want: String = String(OS.get_environment("LCN_FRAME_DIR")).strip_edges()
	var order: PackedStringArray = PackedStringArray()
	if not want.is_empty():
		order.append(want if want.begins_with("/") \
			else ProjectSettings.globalize_path("res://" + want))
	# The gate's own visual pass, so `tools/check.sh` grades the run it just made
	# rather than whatever happens to be lying around.
	order.append(root.path_join("gate/visual"))
	var rest: PackedStringArray = PackedStringArray()
	var d: DirAccess = DirAccess.open(root)
	if d != null:
		for name: String in d.get_directories():
			rest.append(root.path_join(name))
	rest.sort()
	rest.reverse()
	order.append_array(rest)
	for cand: String in order:
		if not FileAccess.file_exists(cand.path_join("log.txt")):
			continue
		for shot: Dictionary in _shots(cand):
			if int(shot["hostiles"]) > 0 \
					and FileAccess.file_exists(_world_png(cand, String(shot["name"]))):
				return cand
	return ""


static func _world_png(dir: String, shot_name: String) -> String:
	return dir.path_join("shots/%s.world.png" % shot_name)


## Every `shot <name> at t<tick> — <phase> of day N, H hostile(s) alive` line.
func _shots(dir: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var re := RegEx.new()
	re.compile("shot (\\S+) at t(\\d+) — (\\w+) of day \\d+, (\\d+) hostile")
	for line: String in _lines(dir):
		var m: RegExMatch = re.search(line)
		if m == null:
			continue
		out.append({
			"name": m.get_string(1), "tick": int(m.get_string(2)),
			"phase": m.get_string(3), "hostiles": int(m.get_string(4)),
		})
	return out


## Every `foemarks t<tick> zoom Z n<N> | kind@x,y,w,h,glG,litL ...` line, which
## `LcnEntityRenderer._log_foe_marks` writes while anything hostile is on screen.
func _dumps(dir: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var head := RegEx.new()
	head.compile("foemarks t(\\d+) zoom ([\\d.]+) n(\\d+) \\| (.*)$")
	var ent := RegEx.new()
	ent.compile("([a-z_]+)@(-?\\d+),(-?\\d+),(\\d+),(\\d+),gl([\\d.]+),lit([\\d.]+)")
	for line: String in _lines(dir):
		var m: RegExMatch = head.search(line)
		if m == null:
			continue
		var marks: Array[Rect2] = []
		var kinds: PackedStringArray = PackedStringArray()
		for e: RegExMatch in ent.search_all(m.get_string(4)):
			kinds.append(e.get_string(1))
			marks.append(Rect2(float(e.get_string(2)), float(e.get_string(3)),
				float(e.get_string(4)), float(e.get_string(5))))
		out.append({"tick": int(m.get_string(1)), "marks": marks, "kinds": kinds})
	return out


func _lines(dir: String) -> PackedStringArray:
	var f: FileAccess = FileAccess.open(dir.path_join("log.txt"), FileAccess.READ)
	if f == null:
		return PackedStringArray()
	return f.get_as_text().split("\n")


# =================================================================== grading ==

func _grade(dir: String) -> void:
	_notes.append("grading %s" % dir)
	var dumps: Array[Dictionary] = _dumps(dir)
	var shots: Array[Dictionary] = _shots(dir)

	# The control FIRST: it sets the noise floor the assault frames are read
	# against, so it can never be tuned to whatever the assault happened to need.
	var control: int = 0
	var floor_n: int = -1
	for shot: Dictionary in shots:
		if int(shot["hostiles"]) != 0 or String(shot["phase"]).findn("night") < 0:
			continue
		var cpng: String = _world_png(dir, String(shot["name"]))
		if not FileAccess.file_exists(cpng) or control >= 2:
			continue
		floor_n = maxi(floor_n, _grade_control(cpng, shot))
		control += 1

	var graded: int = 0
	for shot2: Dictionary in shots:
		var png: String = _world_png(dir, String(shot2["name"]))
		if int(shot2["hostiles"]) > 0 and FileAccess.file_exists(png):
			if _grade_assault(png, shot2, dumps, floor_n):
				graded += 1
	if graded == 0:
		_unchecked.append(
			"no world frame in this run could be graded — either nothing hostile was"
			+ " photographed, or LcnEntityRenderer wrote no `foemarks` line near a shot")
	if control == 0:
		_unchecked.append(
			"this run has no night frame with ZERO hostiles in it, so the blind scan"
			+ " ran without its control and could be finding the city rather than"
			+ " the creatures")


## The frame that matters: hostiles alive, wash on, HUD on.
func _grade_assault(png: String, shot: Dictionary, dumps: Array[Dictionary],
		floor_n: int) -> bool:
	var tick: int = int(shot["tick"])
	var best: Dictionary = {}
	var best_d: int = DUMP_SLACK_TICKS + 1
	for d: Dictionary in dumps:
		var gap: int = absi(int(d["tick"]) - tick)
		if gap < best_d:
			best_d = gap
			best = d
	if best.is_empty():
		_unchecked.append("%s: %d hostile(s) alive at t%d but no foemarks line within %d ticks"
			% [shot["name"], shot["hostiles"], tick, DUMP_SLACK_TICKS])
		return false

	var f: _Frame = _Frame.read(png)
	if f == null:
		_unchecked.append("%s: could not read %s" % [shot["name"], png])
		return false

	var marks: Array[Rect2] = best["marks"]
	var kinds: PackedStringArray = best["kinds"]
	var on: Array[Rect2] = []
	var on_kinds: PackedStringArray = PackedStringArray()
	for i: int in marks.size():
		if f.rect().intersects(marks[i]):
			on.append(marks[i])
			on_kinds.append(kinds[i])
	if on.is_empty():
		_unchecked.append("%s: every hostile the renderer logged is off the glass" % shot["name"])
		return false

	# --- 1 + 2: every creature against the plain it is standing on -------------
	var lift_ok: int = 0
	var cold_ok: int = 0
	var worst: PackedStringArray = PackedStringArray()
	for i: int in on.size():
		var r: Rect2 = on[i]
		var lift: float = f.fig_p95_l(r) - f.ring_med_l(r, RING_IN, RING_OUT)
		var cold: float = f.fig_p90_c(r) - f.ring_med_c(r, RING_IN, RING_OUT)
		if lift >= MIN_LIFT:
			lift_ok += 1
		if cold >= MIN_COLD:
			cold_ok += 1
		if lift < MIN_LIFT or cold < MIN_COLD:
			worst.append("%s at %d,%d lift %.3f cold %+.3f"
				% [on_kinds[i], int(r.position.x), int(r.position.y), lift, cold])
	var need: int = int(ceil(float(on.size()) * MIN_PASS_SHARE))
	_ok(lift_ok >= need,
		("%s (%s): only %d of %d hostiles are %.2f brighter than the plain around"
		+ " them in the shipped frame — need %d. %s")
		% [png.get_file(), shot["phase"], lift_ok, on.size(), MIN_LIFT, need,
			" · ".join(worst)])
	_ok(cold_ok >= need,
		("%s: only %d of %d hostiles read COLDER than the plain (b-r +%.3f), which"
		+ " is the only thing separating one from a citizen — need %d. %s")
		% [png.get_file(), cold_ok, on.size(), MIN_COLD, need, " ".join(worst)])

	# --- 3: the critic's own scan, which knows nothing --------------------------
	var found: Array[Dictionary] = f.scan()
	var hit: int = 0
	var noise: int = 0
	for c: Dictionary in found:
		var b: Rect2 = c["box"]
		var matched: bool = false
		for r2: Rect2 in on:
			if b.grow(SCAN_SLACK).intersects(r2):
				matched = true
				break
		if matched:
			hit += 1
		else:
			noise += 1
	var groups: int = _groups(on)
	_ok(hit >= groups,
		("%s: a blind scan of the whole frame found %d cold-bright cluster(s) on the"
		+ " hostiles, and there are %d separable group(s) of them. A creature nobody"
		+ " can find is a creature that is not in the picture.")
		% [png.get_file(), hit, groups])
	if floor_n >= 0:
		_ok(noise <= floor_n + SCAN_NOISE_SLACK,
			("%s: the same scan found %d cluster(s) that are NOT a hostile, against"
			+ " %d on the control night frame with nothing alive in it (slack %d)."
			+ " The fix is supposed to light up the creatures, not the frame.")
			% [png.get_file(), noise, floor_n, SCAN_NOISE_SLACK])
	_notes.append("%s  t%d dump t%d  %d hostile(s) on glass: lift %d/%d  cold %d/%d  blind %d hit / %d noise / %d group(s)"
		% [png.get_file(), tick, int(best["tick"]), on.size(),
			lift_ok, on.size(), cold_ok, on.size(), hit, noise, groups])
	return true


## The control. Same scan, same city, same hour, nothing hostile alive. Returns
## the cluster count, which becomes the noise floor every assault frame in this
## run is read against.
func _grade_control(png: String, shot: Dictionary) -> int:
	var f: _Frame = _Frame.read(png)
	if f == null:
		return -1
	var n: int = f.scan().size()
	_ok(n <= SCAN_CONTROL_MAX,
		("%s: the blind scan finds %d cold-bright cluster(s) on a night frame with"
		+ " NO hostiles in it (sanity ceiling %d). A scanner that lights up on an"
		+ " empty night cannot certify anything about a full one.")
		% [png.get_file(), n, SCAN_CONTROL_MAX])
	_notes.append("%s  control (%s, 0 hostile): %d cluster(s) — this is the interface"
		% [png.get_file(), shot["phase"], n])
	return n


## Hostile rectangles merged into the shapes a player could actually separate.
static func _groups(marks: Array[Rect2]) -> int:
	var owner: PackedInt32Array = PackedInt32Array()
	owner.resize(marks.size())
	for i: int in marks.size():
		owner[i] = i
	for i: int in marks.size():
		for j: int in range(i + 1, marks.size()):
			if marks[i].grow(GROUP_PX).intersects(marks[j]):
				var a: int = _root(owner, i)
				var b: int = _root(owner, j)
				if a != b:
					owner[b] = a
	var seen: Dictionary[int, bool] = {}
	for i2: int in marks.size():
		seen[_root(owner, i2)] = true
	return seen.size()


static func _root(owner: PackedInt32Array, i: int) -> int:
	var r: int = i
	while owner[r] != r:
		r = owner[r]
	return r


# ===================================================================== pixels ==

## One shipped PNG, read once, with the two measurements this suite makes.
class _Frame extends RefCounted:
	var w: int = 0
	var h: int = 0
	var lum: PackedFloat32Array = PackedFloat32Array()
	var cold: PackedFloat32Array = PackedFloat32Array()
	## Half resolution, for the blind scan — which is also the resolution "at a
	## glance" actually means.
	var sw: int = 0
	var sh: int = 0
	var slum: PackedFloat32Array = PackedFloat32Array()
	var scold: PackedFloat32Array = PackedFloat32Array()

	static func read(path: String) -> _Frame:
		var img: Image = Image.load_from_file(path)
		if img == null or img.get_width() <= 0:
			return null
		img.convert(Image.FORMAT_RGB8)
		var f := _Frame.new()
		f.w = img.get_width()
		f.h = img.get_height()
		f._fill(img, false)
		var small: Image = img.duplicate()
		small.resize(f.w / 2, f.h / 2, Image.INTERPOLATE_BILINEAR)
		f.sw = small.get_width()
		f.sh = small.get_height()
		f._fill(small, true)
		return f

	func _fill(img: Image, small: bool) -> void:
		var d: PackedByteArray = img.get_data()
		var n: int = img.get_width() * img.get_height()
		var l: PackedFloat32Array = PackedFloat32Array()
		var c: PackedFloat32Array = PackedFloat32Array()
		l.resize(n)
		c.resize(n)
		for i: int in n:
			var o: int = i * 3
			var r: float = float(d[o]) / 255.0
			var g: float = float(d[o + 1]) / 255.0
			var b: float = float(d[o + 2]) / 255.0
			l[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
			c[i] = b - r
		if small:
			slum = l
			scold = c
		else:
			lum = l
			cold = c

	func rect() -> Rect2:
		return Rect2(0.0, 0.0, float(w), float(h))

	# --- the anchored measurement ---------------------------------------------

	func fig_p95_l(r: Rect2) -> float:
		return _pct(_box(lum, w, h, r), 0.95)

	func fig_p90_c(r: Rect2) -> float:
		return _pct(_box(cold, w, h, r), 0.90)

	func ring_med_l(r: Rect2, r0: float, r1: float) -> float:
		return _pct(_ring(lum, r, r0, r1), 0.50)

	func ring_med_c(r: Rect2, r0: float, r1: float) -> float:
		return _pct(_ring(cold, r, r0, r1), 0.50)

	func _box(src: PackedFloat32Array, iw: int, ih: int, r: Rect2) -> PackedFloat32Array:
		var out: PackedFloat32Array = PackedFloat32Array()
		var x0: int = clampi(int(r.position.x), 0, iw - 1)
		var y0: int = clampi(int(r.position.y), 0, ih - 1)
		var x1: int = clampi(int(r.end.x), 0, iw)
		var y1: int = clampi(int(r.end.y), 0, ih)
		for y: int in range(y0, y1):
			for x: int in range(x0, x1):
				out.append(src[y * iw + x])
		return out

	## An annulus around the figure's centre, sampled on a 2 px lattice — 35000
	## pixels is more of the plain than any median needs.
	func _ring(src: PackedFloat32Array, r: Rect2, r0: float, r1: float) -> PackedFloat32Array:
		var c: Vector2 = r.get_center()
		var out: PackedFloat32Array = PackedFloat32Array()
		var y0: int = maxi(0, int(c.y - r1))
		var y1: int = mini(h, int(c.y + r1) + 1)
		var x0: int = maxi(0, int(c.x - r1))
		var x1: int = mini(w, int(c.x + r1) + 1)
		var lo: float = r0 * r0
		var hi: float = r1 * r1
		for y: int in range(y0, y1, 2):
			for x: int in range(x0, x1, 2):
				var dx: float = float(x) - c.x
				var dy: float = float(y) - c.y
				var d2: float = dx * dx + dy * dy
				if d2 >= lo and d2 <= hi:
					out.append(src[y * w + x])
		return out

	static func _pct(v: PackedFloat32Array, q: float) -> float:
		if v.is_empty():
			return 0.0
		v.sort()
		return v[clampi(int(float(v.size() - 1) * q), 0, v.size() - 1)]

	# --- the blind scan --------------------------------------------------------

	## Every cold, locally-bright, compact cluster in the frame, in FULL-res
	## coordinates. Knows nothing about where anything is.
	func scan() -> Array[Dictionary]:
		var bg: PackedFloat32Array = _plain()
		var mask: PackedByteArray = PackedByteArray()
		mask.resize(sw * sh)
		for i: int in sw * sh:
			mask[i] = 1 if (scold[i] > SCAN_COLD and slum[i] > bg[i] + SCAN_LIFT) else 0
		var out: Array[Dictionary] = []
		var seen: PackedByteArray = PackedByteArray()
		seen.resize(sw * sh)
		var stack: PackedInt32Array = PackedInt32Array()
		for start: int in sw * sh:
			if mask[start] == 0 or seen[start] == 1:
				continue
			seen[start] = 1
			stack.clear()
			stack.append(start)
			var area: int = 0
			var x0: int = sw
			var x1: int = -1
			var y0: int = sh
			var y1: int = -1
			while not stack.is_empty():
				var p: int = stack[stack.size() - 1]
				stack.remove_at(stack.size() - 1)
				area += 1
				var px: int = p % sw
				var py: int = p / sw
				x0 = mini(x0, px)
				x1 = maxi(x1, px)
				y0 = mini(y0, py)
				y1 = maxi(y1, py)
				for dy: int in range(-1, 2):
					for dx: int in range(-1, 2):
						var nx: int = px + dx
						var ny: int = py + dy
						if nx < 0 or ny < 0 or nx >= sw or ny >= sh:
							continue
						var q: int = ny * sw + nx
						if mask[q] == 1 and seen[q] == 0:
							seen[q] = 1
							stack.append(q)
			if area < SCAN_MIN_AREA or area > SCAN_MAX_AREA:
				continue
			var bw: float = float(x1 - x0 + 1)
			var bh: float = float(y1 - y0 + 1)
			if maxf(bw, bh) / maxf(minf(bw, bh), 1.0) > SCAN_MAX_ASPECT:
				continue
			out.append({
				"area": area,
				"box": Rect2(float(x0) * 2.0, float(y0) * 2.0, bw * 2.0, bh * 2.0),
			})
		return out

	## The local plain, as a block-median luminance at half resolution. A block
	## median rather than a mean because a lit window inside the block would drag
	## a mean up and hide a creature standing beside it.
	func _plain() -> PackedFloat32Array:
		var out: PackedFloat32Array = PackedFloat32Array()
		out.resize(sw * sh)
		var bx: int = (sw + SCAN_BLOCK - 1) / SCAN_BLOCK
		var by: int = (sh + SCAN_BLOCK - 1) / SCAN_BLOCK
		for j: int in by:
			for i: int in bx:
				var x0: int = i * SCAN_BLOCK
				var y0: int = j * SCAN_BLOCK
				var x1: int = mini(x0 + SCAN_BLOCK, sw)
				var y1: int = mini(y0 + SCAN_BLOCK, sh)
				var vals: PackedFloat32Array = PackedFloat32Array()
				for y: int in range(y0, y1, 2):
					for x: int in range(x0, x1, 2):
						vals.append(slum[y * sw + x])
				var med: float = _pct(vals, 0.50)
				for y2: int in range(y0, y1):
					for x2: int in range(x0, x1):
						out[y2 * sw + x2] = med
		return out
