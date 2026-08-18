extends SceneTree
## IS THERE A DAY IN THE FRAME THE GAME ACTUALLY MAKES? [P13]
##
##   xvfb-run -a tools/run_visual.sh --scenario=first_night --out=artifacts/mine
##   godot --headless --path . --script tests/render/run_ground_frame.gd
##   LCN_FRAME_DIR=artifacts/mine godot --headless --path . --script tests/render/run_ground_frame.gd
##
## THE RULE THIS FILE OBEYS IS THE ONE THE PROJECT LEARNED THE HARD WAY. It may
## not stand anything up. It opens the PNGs the ordinary harness wrote — with the
## post grade in them, the vignette in them, [P14]'s weather in them, the HUD in
## them and [P15]'s threat wash in them — and it measures THOSE. A sprite suite
## reading its own cache, a frame lab photographing the title screen and a
## contrast rig with no screen wash in it have each already cost this build a
## round; the ground does not get a fourth.
##
## WHAT IT GRADES, AND WHY EACH NUMBER IS THE RIGHT NUMBER.
##
## Everything is read from two fixed rectangles of OPEN PLAIN either side of the
## settlement — x 60..400 and x 1500..1860, y 380..940. They are the same
## rectangles in every shot, they never touch a HUD panel in any shot of
## `first_night`, and the city is never in them. Nothing is aligned, tracked or
## chosen per frame, so there is no knob here that could be turned to flatter a
## build.
##
##   1. DAYLIGHT   the plain at midday has to be daylit snow, in absolute terms.
##                 Not "brighter than night" — brighter than a grey card. The
##                 defect was never relative contrast; it was that the entire
##                 day lived below 0.25 luminance, where a monitor, a Steam
##                 screenshot and a human eye all give up at once.
##   2. RANGE      ...and it has to use some of the scale it is given. A plain
##                 whose 10th and 90th percentiles are 0.12 apart has no shape
##                 in it whatever its median is.
##   3. STRUCTURE  ...and carry local structure at the LAG a drift actually
##                 subtends at the zoom a session sits at (0.50-0.85, so 16-27
##                 screen px per tile — see the `render: ground zoom` line in
##                 the run's own log.txt).
##   4. ARC        midday must be a different picture from deep night by a
##                 RATIO, not by an offset — so brightening the whole game
##                 cannot pass this — and deep night must still be dark.
##   5. HUE        dusk must be a different COLOUR from midday, not the same
##                 picture at half a stop. Red-minus-blue, which no change in
##                 exposure anywhere can move.
##   6. NIGHT      deep night must be dark AND have something in it: a floor on
##                 its range and its local gradient, under a ceiling on its
##                 median. The two together cannot be satisfied by lifting the
##                 night — only by giving it a low key that rakes the drifts.
##
## WHAT MAKES IT RED — MEASURED, NOT ASSERTED. Every bar below sits in the gap
## between two full `first_night` visual runs made half an hour apart on this
## machine, same scenario, same seed, same shots:
##
##   `artifacts/H4_base`, the build EXACTLY as it shipped into this wave
##   (verified against `artifacts/CRIT` to four decimals: midday 0.1641 vs
##   0.1643, opening 0.1357 vs 0.1357, assault 0.0710 vs 0.0712 — the frames a
##   critic graded and the frames this suite grades are the same frames):
##
##       midday   p50 0.182  p90 0.233  spread 0.119  grad 0.0135
##       dusk     p50 0.082  warm -0.0289
##       night    p50 0.057  spread 0.039  grad 0.0070
##       midday/night 3.17 · dusk-minus-midday hue -0.002 · day-3 afternoon 0.099
##
##   ...against `artifacts/H4_v2`, the same run after this wave's treatment.
##   Six of the seven checks below are RED on the first table. The one that is
##   not — the ceiling on how bright the night may be — is a guard rail, and it
##   is here so that a later wave cannot pass the other six by turning the
##   brightness up.
const SHOT_DAY: String = "midday"
const SHOT_DUSK: String = "dusk"
const SHOT_NIGHT: String = "deep_night"
const SHOT_LATE: String = "third_day_city"

## The two rectangles of open plain, as x, y, width, height.
const BANDS: Array[Rect2i] = [
	Rect2i(60, 380, 340, 560),
	Rect2i(1500, 380, 360, 560),
]

# --- the bars, each sitting in a measured gap (see the header) ----------------

## Median luminance of the daylit plain. Base 0.182, treated 0.29-0.31.
const DAY_MEDIAN: float = 0.240
## ...and its 90th percentile, which is what a drift crest in sun has to reach.
## Base 0.233, treated 0.39-0.41.
const DAY_P90: float = 0.320
## 10th-to-90th spread. Base 0.119, treated 0.20-0.22.
const DAY_SPREAD: float = 0.165
## Mean |dL| at a 4 px lag over the daylit plain — the wind comb and the broken
## crust, at the scale the play camera resolves them. Base 0.0135, treated 0.023.
const DAY_GRAD: float = 0.0190
## THE ARC. Midday against deep night, on the same ground.
##
## THIS BAR USED TO BE `midday p50 / night p50 >= 3.90` AND IT WAS UNREACHABLE,
## WHICH I FOUND BY TURNING THE NIGHT OFF RATHER THAN BY ARGUING ABOUT IT.
## `artifacts/H4b_nofloor` is an ordinary `tools/run_visual.sh` of first_night
## with deep_night's and night's `sun_energy` AND `sky_energy` set to exactly
## zero — a ground with no light on it whatever. Its open plain still measures
##
##     p10 0.034   p50 0.067   p90 0.112
##
## so 0.067 of the 0.106 this build's night reads — 63% of it — is drawn by
## something that is not the ground: the post stack's grain and low fog, [P14]'s
## whiteout veil and falling snow, and the star field. The ground's own share is
## 0.039. Asking a 0.355 midday for a 3.90 ratio is asking the night plain for
## 0.091, which means asking the GROUND for 0.024 — a black plain — and the
## ablation shows a black plain scores 5.28 and sails through. A ratio of medians
## against a floor this large is a bar you pass by deleting the ground.
##
## So the arc is now stated as a SEPARATION: the darkest tenth of the daylit
## plain has to be half again brighter than the brightest tenth of the night
## plain, so the two distributions do not merely differ in the middle, they come
## apart. Measured: `artifacts/CRIT` 0.115/0.090 = 1.28, this build 1.63.
## What stops it being bought by darkening the night is NIGHT_TEXTURE below,
## which the black-ground ablation fails outright.
const ARC_SEPARATION: float = 1.45
## Dusk's red-minus-blue minus midday's. Base -0.002 (dusk and noon were the
## same colour); treated +0.06 or better.
const HUE_SPLIT: float = 0.035
## Deep night's median may not exceed this. Base 0.057. This is the guard rail:
## it is the check that a build cannot pass the other six by lifting the frame.
const NIGHT_CEIL: float = 0.150
## ...but the night has to have something in it. Base spread 0.039, grad 0.0070.
##
## BOTH OF THESE ARE WEAK AND THE ABLATION SAYS SO. `artifacts/H4b_nofloor`, the
## run whose night ground receives no light at all, measures spread 0.078 and
## grad 0.0146 and clears both. They are kept because they are cheap and they
## still catch the ORIGINAL failure (the shipped build's 0.039 and 0.0070), but
## the check that actually asks whether there is a snowfield out there in the
## dark is NIGHT_TEXTURE.
const NIGHT_SPREAD: float = 0.070
const NIGHT_GRAD: float = 0.0105
## An afternoon on day three has to be an afternoon. Base 0.099 — darker than
## day one's DUSK, which is the whole of "hour three looks like hour one" said
## as a number. Treated 0.17-0.20.
const LATE_DAY_MEDIAN: float = 0.150

## 7. EDGE — is there a HARD edge anywhere on this ground?
##
## Every other number here can be satisfied by a soft field: raise its level,
## widen its range, give it a low-frequency gradient and DAYLIGHT, RANGE,
## STRUCTURE and ARC all go green while the plain still reads as smeared paint.
## Crop 340 px of `artifacts/CRIT/shots/midday.world.png` and look at it at 1:1
## and that is exactly what it is — long soft parallel brush strokes, no
## boundary anywhere, nothing whose size the eye can read. Three separate
## critics have written down that same sentence in different words.
##
## So this counts EDGES: the share of band pixels whose luminance steps by at
## least EDGE_STEP across two screen pixels. Two pixels, not four, because an
## edge is a thing that happens between adjacent pixels and a four-pixel lag
## measures slope instead. Measured on the shipped frames a critic graded:
##
##     artifacts/CRIT   midday 1.18%   dusk 0.07%   deep_night 0.02%
##
## Two hundredths of one per cent of the night plain has an edge in it. The film
## grain in the post stack is inside that number, and so it is on both sides of
## every comparison this bar is set from.
const EDGE_STEP: float = 0.045
const EDGE_LAG: int = 2
## Midday: base 1.18%, treated 4.0%.
const DAY_EDGES: float = 0.020
## Deep night: base 0.02%, treated 0.9%. A night is allowed to be dark. It is
## not allowed to be a gradient. The lightless-ground ablation scores 0.39% here
## — film grain in the shadows makes two-pixel steps of its own — so this bar
## sits above the ablation and NIGHT_TEXTURE carries the real weight.
const NIGHT_EDGES: float = 0.0060

## 9. TEXTURE — the one number film grain, a star field and a fog ramp cannot buy.
##
## Every other structure check on this page can be satisfied without any ground
## in the frame, and that is not a guess: `artifacts/H4b_nofloor` sets the
## night's key and fill to zero and passes all twelve of them. Grain makes
## two-pixel steps, stars make isolated bright pixels, and the post stack's low
## fog makes a smooth vertical ramp that widens any percentile spread. A drift
## is none of those things: it is a correlated feature ten to sixty pixels
## across.
##
## So the band is meaned down 4x4 — which averages grain and single-pixel stars
## out of existence — and then high-passed against a 68 px box, which removes
## the fog ramp and anything else smooth. What is left is structure at exactly
## the scale a drift subtends at the zoom a session runs at, and its 10-to-90
## spread is the number. Measured on the plain, midday / deep night:
##
##     artifacts/CRIT (shipped)      0.0687 / 0.0050
##     the black-ground ablation     0.1423 / 0.0093
##     this build                    0.1423 / 0.0366
##
## The night column is the whole point: the shipped build and a ground with no
## light on it are indistinguishable, and this build is four times either.
const DAY_TEXTURE: float = 0.100
const NIGHT_TEXTURE: float = 0.020
## Downsample before measuring texture: 4x4 screen pixels per cell.
const TEX_DOWN: int = 4
## High-pass box, in cells. 17 cells is 68 screen pixels.
const TEX_BOX: int = 17

## 8. DUSK IS A KEY, NOT A FILTER — the ceiling on check 5's floor.
##
## HUE says dusk must be a different colour from midday. On its own that is
## satisfied most easily by the worst available means: multiply the whole frame
## by orange. This build did exactly that, and not even deliberately — the
## snowfall softbox mixed the shading term toward a constant, which on flat
## ground RAISED a 1.44-energy copper key from 0.078 to 0.28, and
## `artifacts/H4b_now/shots/dusk.world.png` came back measuring red-minus-blue
## +0.098 over the open plain: a copper desert at nineteen below.
##
## The art direction is one sentence — the orange belongs to the KEY, and
## everything the sun cannot reach falls into a blue fill. So the open plain at
## dusk, most of which is not facing a sun sitting at 0.16 of elevation, has to
## come out cold on average even while the frame is warmer than noon.
const DUSK_WARM_CEIL: float = 0.070

## Pixel lag the local gradient is read at. Four screen pixels is about a fifth
## of a tile at play zoom: fine enough that only surface detail lives there,
## coarse enough that it is not measuring sensor grain.
const GRAD_LAG: int = 4

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
			"no visual run in artifacts/ carries the four shots this suite reads"
			+ " (%s, %s, %s, %s) — run" % [SHOT_DAY, SHOT_DUSK, SHOT_NIGHT, SHOT_LATE]
			+ " `tools/run_visual.sh --scenario=first_night --out=artifacts/vis`"
			+ " (or point LCN_FRAME_DIR at one) and grade THAT")
	else:
		_grade(dir)
	return _verdict()


func _grade(dir: String) -> void:
	_notes.append("frames: %s" % dir)
	var day: Dictionary = _plain(dir, SHOT_DAY)
	var dusk: Dictionary = _plain(dir, SHOT_DUSK)
	var night: Dictionary = _plain(dir, SHOT_NIGHT)
	var late: Dictionary = _plain(dir, SHOT_LATE)
	for row: Array in [[SHOT_DAY, day], [SHOT_DUSK, dusk], [SHOT_NIGHT, night], [SHOT_LATE, late]]:
		var s: Dictionary = row[1]
		if s.is_empty():
			continue
		_notes.append("%-16s p10 %.3f  p50 %.3f  p90 %.3f  spread %.3f  hue %+.4f  grad %.4f  edges %.2f%%  tex %.4f"
			% [row[0], s["p10"], s["p50"], s["p90"], float(s["p90"]) - float(s["p10"]),
				s["hue"], s["grad"], float(s["edges"]) * 100.0, s["tex"]])

	if day.is_empty():
		_unchecked.append("no %s.world.png in %s" % [SHOT_DAY, dir])
	else:
		_ok(float(day["p50"]) >= DAY_MEDIAN,
			"DAYLIGHT: the plain at midday reads %.3f, and daylit snow has to clear %.3f"
			% [day["p50"], DAY_MEDIAN])
		_ok(float(day["p90"]) >= DAY_P90,
			"DAYLIGHT: the brightest tenth of the midday plain reaches only %.3f (bar %.3f)"
			% [day["p90"], DAY_P90])
		_ok(float(day["p90"]) - float(day["p10"]) >= DAY_SPREAD,
			"RANGE: the whole midday plain lives inside %.3f of luminance (bar %.3f) — no shape"
			% [float(day["p90"]) - float(day["p10"]), DAY_SPREAD])
		_ok(float(day["grad"]) >= DAY_GRAD,
			"STRUCTURE: %.4f of local gradient at %d px on the midday plain (bar %.4f)"
			% [day["grad"], GRAD_LAG, DAY_GRAD])
		_ok(float(day["edges"]) >= DAY_EDGES,
			"EDGE: %.2f%% of the midday plain steps by %.3f across %d px (bar %.2f%%) — smeared paint"
			% [float(day["edges"]) * 100.0, EDGE_STEP, EDGE_LAG, DAY_EDGES * 100.0])
		_ok(float(day["tex"]) >= DAY_TEXTURE,
			"TEXTURE: %.4f of drift-scale structure on the midday plain (bar %.4f)"
			% [day["tex"], DAY_TEXTURE])

	if day.is_empty() or night.is_empty():
		_unchecked.append("cannot compare midday against deep night without both frames")
	else:
		var sep: float = float(day["p10"]) / maxf(float(night["p90"]), 0.0005)
		_ok(sep >= ARC_SEPARATION,
			"ARC: the darkest tenth of the midday plain (%.3f) is only %.2fx the brightest"
			% [day["p10"], sep]
			+ " tenth of the night plain (%.3f) — bar %.2fx" % [night["p90"], ARC_SEPARATION])
		_ok(float(night["p50"]) <= NIGHT_CEIL,
			"NIGHT: deep night reads %.3f on the open plain — that is not a night (ceiling %.3f)"
			% [night["p50"], NIGHT_CEIL])
		_ok(float(night["p90"]) - float(night["p10"]) >= NIGHT_SPREAD,
			"NIGHT: the night plain spans %.3f (bar %.3f) — dark, and empty with it"
			% [float(night["p90"]) - float(night["p10"]), NIGHT_SPREAD])
		_ok(float(night["grad"]) >= NIGHT_GRAD,
			"NIGHT: %.4f of local gradient out on the night plain (bar %.4f) — nothing is out there"
			% [night["grad"], NIGHT_GRAD])
		_ok(float(night["edges"]) >= NIGHT_EDGES,
			"EDGE: %.2f%% of the night plain carries a hard edge (bar %.2f%%) — a gradient, not a plain"
			% [float(night["edges"]) * 100.0, NIGHT_EDGES * 100.0])
		_ok(float(night["tex"]) >= NIGHT_TEXTURE,
			"TEXTURE: %.4f of drift-scale structure on the night plain (bar %.4f) — grain and"
			% [night["tex"], NIGHT_TEXTURE]
			+ " stars over a black quad score this, so there is nothing out there")

	if day.is_empty() or dusk.is_empty():
		_unchecked.append("cannot compare dusk against midday without both frames")
	else:
		var split: float = float(dusk["hue"]) - float(day["hue"])
		_ok(split >= HUE_SPLIT,
			"HUE: dusk is %+.4f warmer than midday (bar %+.4f) — the same picture, dimmer"
			% [split, HUE_SPLIT])
		_ok(float(dusk["hue"]) <= DUSK_WARM_CEIL,
			"FILTER: the dusk plain is %+.4f red-minus-blue (ceiling %+.4f) — that is a"
			% [dusk["hue"], DUSK_WARM_CEIL]
			+ " orange filter over the frame, not a low copper key on cold snow")

	if late.is_empty():
		_unchecked.append("no %s.world.png in %s" % [SHOT_LATE, dir])
	else:
		_ok(float(late["p50"]) >= LATE_DAY_MEDIAN,
			"LATE DAY: the afternoon of day three reads %.3f (bar %.3f) — hour three is hour one"
			% [late["p50"], LATE_DAY_MEDIAN])


# ----------------------------------------------------------------- measuring --

## Luminance statistics over the two fixed plain bands of one `.world` shot.
## Empty when the shot is not in this run.
func _plain(dir: String, shot: String) -> Dictionary:
	var path: String = dir.path_join("shots/%s.world.png" % shot)
	if not FileAccess.file_exists(path):
		return {}
	var img: Image = Image.new()
	if img.load(path) != OK:
		return {}
	img.convert(Image.FORMAT_RGB8)
	var w: int = img.get_width()
	var h: int = img.get_height()
	var raw: PackedByteArray = img.get_data()

	var hist: PackedInt32Array = PackedInt32Array()
	hist.resize(1024)
	var n: int = 0
	var sum_r: float = 0.0
	var sum_b: float = 0.0
	var grad_sum: float = 0.0
	var grad_n: int = 0
	var edge_hits: int = 0
	var edge_n: int = 0
	var tex_sum: float = 0.0
	var tex_n: int = 0
	var lum: PackedFloat32Array = PackedFloat32Array()

	for band: Rect2i in BANDS:
		var x0: int = maxi(0, band.position.x)
		var y0: int = maxi(0, band.position.y)
		var x1: int = mini(w, band.position.x + band.size.x)
		var y1: int = mini(h, band.position.y + band.size.y)
		if x1 - x0 < 16 or y1 - y0 < 16:
			continue
		var bw: int = x1 - x0
		var bh: int = y1 - y0
		lum.resize(bw * bh)
		for y: int in bh:
			var src: int = ((y0 + y) * w + x0) * 3
			var dst: int = y * bw
			for x: int in bw:
				var r: float = float(raw[src]) / 255.0
				var g: float = float(raw[src + 1]) / 255.0
				var b: float = float(raw[src + 2]) / 255.0
				var l: float = 0.2126 * r + 0.7152 * g + 0.0722 * b
				lum[dst + x] = l
				sum_r += r
				sum_b += b
				hist[clampi(int(l * 1023.0), 0, 1023)] += 1
				n += 1
				src += 3
		# Local gradient at GRAD_LAG, both axes, inside this band only — a step
		# across the gap between the two bands is the city, not the ground.
		for y2: int in bh:
			var row: int = y2 * bw
			for x2: int in bw - GRAD_LAG:
				grad_sum += absf(lum[row + x2 + GRAD_LAG] - lum[row + x2])
				grad_n += 1
		for y3: int in bh - GRAD_LAG:
			var a: int = y3 * bw
			var c: int = (y3 + GRAD_LAG) * bw
			for x3: int in bw:
				grad_sum += absf(lum[c + x3] - lum[a + x3])
				grad_n += 1
		# ...and how many of those steps are big enough to be an EDGE rather than
		# a slope, at the two-pixel lag an edge actually lives at.
		for y4: int in bh:
			var r4: int = y4 * bw
			for x4: int in bw - EDGE_LAG:
				if absf(lum[r4 + x4 + EDGE_LAG] - lum[r4 + x4]) >= EDGE_STEP:
					edge_hits += 1
				edge_n += 1
		for y5: int in bh - EDGE_LAG:
			var a5: int = y5 * bw
			var c5: int = (y5 + EDGE_LAG) * bw
			for x5: int in bw:
				if absf(lum[c5 + x5] - lum[a5 + x5]) >= EDGE_STEP:
					edge_hits += 1
				edge_n += 1
		tex_sum += _texture(lum, bw, bh)
		tex_n += 1

	if n < 1000:
		return {}
	return {
		"p10": _pct(hist, n, 0.10),
		"p50": _pct(hist, n, 0.50),
		"p90": _pct(hist, n, 0.90),
		"hue": (sum_r - sum_b) / float(n),
		"grad": grad_sum / float(maxi(1, grad_n)),
		"edges": float(edge_hits) / float(maxi(1, edge_n)),
		"tex": tex_sum / float(maxi(1, tex_n)),
	}


## Drift-scale structure in one band: mean the field down TEX_DOWN x TEX_DOWN so
## grain and single-pixel stars are gone, high-pass it against a TEX_BOX box so
## the post stack's smooth vertical fog is gone, and return the 10-to-90 spread
## of what is left. See the header on DAY_TEXTURE for what each step removes and
## why nothing that is not the ground can score here.
static func _texture(lum: PackedFloat32Array, bw: int, bh: int) -> float:
	var cw: int = bw / TEX_DOWN
	var ch: int = bh / TEX_DOWN
	if cw < TEX_BOX + 2 or ch < TEX_BOX + 2:
		return 0.0
	var cell: PackedFloat32Array = PackedFloat32Array()
	cell.resize(cw * ch)
	var inv: float = 1.0 / float(TEX_DOWN * TEX_DOWN)
	for cy: int in ch:
		for cx: int in cw:
			var acc: float = 0.0
			for dy: int in TEX_DOWN:
				var base: int = (cy * TEX_DOWN + dy) * bw + cx * TEX_DOWN
				for dx: int in TEX_DOWN:
					acc += lum[base + dx]
			cell[cy * cw + cx] = acc * inv
	# Separable box mean, clamped at the edges.
	var half: int = TEX_BOX / 2
	var rowb: PackedFloat32Array = PackedFloat32Array()
	rowb.resize(cw * ch)
	for cy2: int in ch:
		for cx2: int in cw:
			var a2: float = 0.0
			for k: int in TEX_BOX:
				a2 += cell[cy2 * cw + clampi(cx2 + k - half, 0, cw - 1)]
			rowb[cy2 * cw + cx2] = a2 / float(TEX_BOX)
	var hist: PackedInt32Array = PackedInt32Array()
	hist.resize(1024)
	var n: int = 0
	for cy3: int in ch:
		for cx3: int in cw:
			var a3: float = 0.0
			for k2: int in TEX_BOX:
				a3 += rowb[clampi(cy3 + k2 - half, 0, ch - 1) * cw + cx3]
			var hp: float = cell[cy3 * cw + cx3] - a3 / float(TEX_BOX)
			# Centred on 0.5 so the same percentile helper can read it.
			hist[clampi(int((hp + 0.5) * 1023.0), 0, 1023)] += 1
			n += 1
	if n < 64:
		return 0.0
	return _pct(hist, n, 0.90) - _pct(hist, n, 0.10)


static func _pct(hist: PackedInt32Array, n: int, f: float) -> float:
	var want: int = int(float(n) * f)
	var seen: int = 0
	for i: int in hist.size():
		seen += hist[i]
		if seen >= want:
			return (float(i) + 0.5) / 1024.0
	return 1.0


# ============================================================ finding the run ==

## The newest artifacts folder that carries all four shots this suite reads.
## LCN_FRAME_DIR wins; then the gate's own visual pass, so `tools/check.sh`
## grades the run it just made rather than whatever is lying around.
func _find_run() -> String:
	var root: String = ProjectSettings.globalize_path("res://artifacts")
	var want: String = String(OS.get_environment("LCN_FRAME_DIR")).strip_edges()
	var order: PackedStringArray = PackedStringArray()
	if not want.is_empty():
		order.append(want if want.begins_with("/") \
			else ProjectSettings.globalize_path("res://" + want))
	order.append(root.path_join("gate/visual"))
	var rest: Array[Dictionary] = []
	var d: DirAccess = DirAccess.open(root)
	if d != null:
		for name: String in d.get_directories():
			var log: String = root.path_join(name).path_join("log.txt")
			if FileAccess.file_exists(log):
				rest.append({"dir": root.path_join(name),
					"at": FileAccess.get_modified_time(log)})
	rest.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["at"]) > int(b["at"]))
	for row: Dictionary in rest:
		order.append(String(row["dir"]))
	for cand: String in order:
		var ok: bool = true
		for shot: String in [SHOT_DAY, SHOT_DUSK, SHOT_NIGHT, SHOT_LATE]:
			if not FileAccess.file_exists(cand.path_join("shots/%s.world.png" % shot)):
				ok = false
				break
		if ok:
			return cand
	return ""


# ------------------------------------------------------------------ plumbing --

func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(what)


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
