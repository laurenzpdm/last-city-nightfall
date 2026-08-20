shader_type canvas_item;

// THE GROUND. [P13], third pass.
//
// One quad over the visible rect, everything evaluated per pixel in WORLD space:
// no tile image to repeat, no atlas to read as an atlas, no chunk to seam.
//
// WHAT THE SECOND PASS GOT WRONG, and what this fixes. A critic opened a real
// 1920x1080 midday frame and saw "one large soft grey-white cloud-noise field —
// it reads as fog, not as snow-covered ground. There is no tile structure, no
// drift, no rock, no track, no edge." Every word of that was true and all of it
// came from three decisions:
//
//   * the snow-cover threshold used a WIDE smoothstep (0.42 of band) against a
//     LOW-frequency noise, so every snow/rock boundary was a soft gradient a
//     hundred pixels across. That is the definition of a cloud.
//   * the height field that shaded the surface was isotropic fbm. Wind-blown
//     snow is not isotropic; it is sastrugi, long streaks lying down one axis.
//     Without an axis a snowfield has no direction and reads as noise.
//   * nothing in the frame was at the scale of a tile, so there was no size
//     reference and the ground could be at any distance — which is why it read
//     as weather rather than as a floor.
//
// So: ONE height field `h`, anisotropic along WIND, drives the shading normal,
// the snow coverage AND the drift lip, which is why snow now lies in the troughs
// and rock shows on the scoured crests instead of the two being unrelated fields
// mixed together. Coverage is a NARROW threshold against that same field, so an
// edge is an edge. A per-tile facet term gives the surface a size. Tracks are
// contour lines of a slow field, revealed by the city presence texture, so paths
// appear between buildings and nowhere else.
//
// Written for GL Compatibility: constant loop bounds, no derivatives, no
// textureLod, no dynamic indexing. Everything expensive is behind `detail`,
// which the renderer lowers as the camera pulls out.

uniform sampler2D kind_tex : filter_nearest, repeat_disable;
uniform sampler2D snow_tex : filter_linear, repeat_disable;
uniform sampler2D heat_tex : filter_linear, repeat_disable;
uniform sampler2D soot_tex : filter_linear, repeat_disable;
uniform sampler2D city_tex : filter_linear, repeat_disable;
// THE GROUND'S MEMORY of where the population actually went. One texel per tile,
// written by LcnEntityRenderer at every footfall, aged on the sim clock. Black
// default on purpose: an unbound sampler2D reads WHITE, and a white wear field
// is a plain trodden flat from edge to edge before anyone has taken a step.
uniform sampler2D wear_tex : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform sampler2D pal_tex : filter_nearest, repeat_disable;

uniform vec2 map_px = vec2(8192.0, 8192.0);
uniform float snow_scale = 1.0;
uniform float detail = 1.0;
// HOW BIG A TILE IS ON THE MONITOR RIGHT NOW. Every edge in this shader used to
// be a constant in the height field's units, which means its width on screen was
// whatever the camera happened to make of it: a crust boundary that is two
// pixels at the assault zoom is forty at the strategic one, and a plain whose
// every boundary is forty pixels wide is the "one large soft cloud-noise field"
// three critics in a row have now written down. With the tile's screen size in
// hand an edge can be authored as ONE PIXEL and stay one pixel at every zoom.
uniform float px_tile = 20.0;
uniform float time_s = 0.0;
// 0..1 from [P09] via LcnWorldModel.storm(). Drives the spindrift, which is the
// only part of this game's weather that survives being photographed.
uniform float storm = 0.0;

// --- the light rig (see LcnPalette.light_at, which evaluates the same terms) --
uniform vec2 sun_dir = vec2(-0.5, -0.7);
uniform vec3 sun_col = vec3(1.0);
uniform float sun_energy = 0.9;
uniform float sun_height = 0.8;
uniform vec3 sky_col = vec3(0.55, 0.63, 0.78);
uniform float sky_energy = 0.42;
uniform vec3 bounce_col = vec3(0.62, 0.74, 0.98);
uniform float bounce = 0.0;
uniform float wild = 0.0;
uniform vec3 warm_col = vec3(1.0, 0.54, 0.24);

uniform vec3 snow_mid = vec3(0.765, 0.812, 0.878);
uniform vec3 snow_lit = vec3(0.976, 0.988, 1.000);
uniform vec3 snow_shadow = vec3(0.498, 0.573, 0.678);
uniform vec3 ash_col = vec3(0.169, 0.149, 0.129);
// THE ERRATICS ARE ROCK WHEREVER THEY LIE. Painted out of the host terrain's own
// low/high the blocks on a snowfield came out pale blue-grey, which on a pale
// blue-grey plain is a scatter of soft discs — bubbles, not stone. A boulder is
// the same rock whatever has drifted over it, and having it be the one thing in
// the frame that is NOT the local palette is exactly what gives it its edge.
uniform vec3 stone_dark = vec3(0.106, 0.122, 0.184);
uniform vec3 stone_lite = vec3(0.400, 0.428, 0.512);

varying vec2 world_pos;

const float INV_NOISE = 1.0 / 256.0;
// The prevailing wind. Every drift on the plain lies down this axis, which is
// what makes the ground read as a surface the weather has worked on rather than
// as a field of noise. Deliberately off both screen axes so nothing lines up
// with the tile grid or the edge of the monitor.
const vec2 WIND = vec2(0.8862, 0.4632);
const vec2 WIND_T = vec2(-0.4632, 0.8862);

float n1(vec2 p) {
	return texture(noise_tex, p * INV_NOISE).r;
}

vec4 n4(vec2 p) {
	return texture(noise_tex, p * INV_NOISE);
}

// Two octaves, two fetches. `p` is in tiles.
float fbm2(vec2 p) {
	float s = texture(noise_tex, p * INV_NOISE).r * 0.64;
	s += texture(noise_tex, (p * 2.07 + vec2(19.0, 53.0)) * INV_NOISE).a * 0.36;
	return s;
}

float fbm3(vec2 p) {
	float s = texture(noise_tex, p * INV_NOISE).r * 0.52;
	s += texture(noise_tex, (p * 2.03 + vec2(37.0, 11.0)) * INV_NOISE).g * 0.31;
	s += texture(noise_tex, (p * 4.11 + vec2(5.0, 71.0)) * INV_NOISE).b * 0.17;
	return s;
}

// Deterministic per-tile hash. Cheap, no fetch — this is what gives the ground
// a SIZE: one 32 px cell of the world is visibly one cell.
float tile_hash(vec2 c) {
	return fract(sin(dot(c, vec2(127.1, 311.7))) * 43758.5453);
}

// ---------------------------------------------------------------------------
// THE DRIFT FIELD. Anisotropic: 8x longer along the wind than across it, so a
// single feature is a streak and not a blob. Ridged, because a drift has a crest
// and two faces, and plain fbm has neither.
//
// Returns the surface height in 0..1. This one function decides the shading
// normal, where snow lies, and where the crust breaks — they cannot disagree.
float drift(vec2 t, float fine) {
	vec2 q = vec2(dot(t, WIND), dot(t, WIND_T));
	// Long sastrugi: ~14 tiles along the wind, ~1.8 across.
	float a = fbm2(vec2(q.x * 0.072, q.y * 0.56) + vec2(101.0, 7.0));
	float ridge_a = 1.0 - abs(a * 2.0 - 1.0);
	// Second rank, half the length, offset so the two never phase-lock.
	float b = fbm2(vec2(q.x * 0.21, q.y * 1.35) + vec2(41.0, 173.0));
	float ridge_b = 1.0 - abs(b * 2.0 - 1.0);
	// THIRD RANK, AND THE ONE THE PLAY CAMERA ACTUALLY RESOLVES. The two ranks
	// above are 14 tiles by 1.8 and 4.8 by 0.74 — at 20 px a tile that is a
	// 280x36 px smear and a 96x15 px smear, and a plain made of nothing else is
	// what `artifacts/H4b_now/shots/midday.world.png` shows when you crop 340 px
	// of it and look at 1:1: long soft parallel brush strokes with no edge
	// anywhere in them. This rank is 2.4 tiles by 0.63 — 48 px by 13 px — so
	// there is drift structure at the size of the things standing on it, and it
	// is in `h` rather than behind `fine` so the LIGHT rakes it too. One fetch.
	float c = n1(vec2(q.x * 0.42, q.y * 1.60) + vec2(211.0, 47.0));
	// ...AND IT IS BEHIND `fine`, WHICH IS WHAT TURNS THE HATCH BACK INTO DUNES.
	// The lighting block calls this function four more times at `t +/- 0.42` with
	// `fine = 0.0` to build the shading normal. This rank has an across-wind
	// period of 0.63 of a tile, so a 0.84-tile finite difference of it is not a
	// slope, it is an alias — and that alias, multiplied by a normal amplitude of
	// 7.5, is what painted the same 15-px diagonal comb over every pixel of
	// `artifacts/P13/frames/midday_play.png` at every hour. Weighted by `fine` it
	// leaves `h` exactly where it was at play zoom (the centre tap passes
	// `detail`, which is 1.0 at every zoom a session uses) and disappears from
	// the four normal taps, so the LIGHT now rakes the two long ranks and the
	// swell — the forms a drift actually has — while the crust edge still breaks
	// along this one.
	float ridge_c = (1.0 - abs(c * 2.0 - 1.0)) * fine;
	// Slow swell far larger than the screen: the plain is not flat.
	float swell = fbm2(t * 0.021 + vec2(9.0, 61.0));
	// The wind does not work the whole plain equally. Modulating the ridge
	// amplitude over a kilometre scale is the difference between a snowfield and
	// a combed carpet: some of it is scoured smooth, some is heavy sastrugi.
	float force = 0.42 + 0.80 * fbm2(t * 0.013 + vec2(197.0, 31.0));
	float h = swell * 0.22 + (ridge_a * 0.44 + ridge_b * 0.24 + ridge_c * 0.17) * force;
	// Wind-combed grain, only worth fetching when the camera is close enough to
	// resolve it.
	h += (n1(vec2(q.x * 0.9, q.y * 6.1) + vec2(3.0, 91.0)) - 0.5) * 0.11 * fine;
	return clamp(h, 0.0, 1.0);
}

// ---------------------------------------------------------------------------
// FROST-SHATTERED STONE — the only hard edge on this plain, and the reason it
// has a size.
//
// WHY THIS EXISTS. Every field above is a linearly-filtered fetch of a 256 px
// value-noise texture, which can only produce soft ramps: crop 340 px of the
// open plain out of any shipped frame in `artifacts/` and look at it at 1:1 and
// it is smeared paint. There is no edge in it, and because there is no edge
// there is nothing whose size the eye can read, so the ground could be at any
// distance and reads as weather rather than as a floor. Factorio's ground is
// legible at a glance because it is full of small hard-edged things at the
// scale of one tile. This is that, derived from the terrain rather than
// scattered as props: one candidate block per 3x3 tiles, accepted according to
// how much the wind works that surface, so the rock shelves are littered, the
// open snow carries the odd erratic and the deep drifts have swallowed theirs.
//
// It is not a second scatter on top of [P13]'s LcnScenery. Those are landmarks
// — a stand of dead trees, a wreck — placed at 44 candidates per 32x32 chunk
// and refused almost everywhere; nine of them reach a real frame. These are
// ground texture at forty times the density and a twentieth of the size, they
// cost no node, no draw call and no texture fetch, and they are what carries
// the drift: snow banks on the upwind face of every one of them, which is
// drift structure keyed to something the player can actually point at.
//
// Everything a cell draws is bounded inside that cell (centre in the middle
// 40%, radius <= 0.40 tiles, shadow and bank <= 2.1 radii) so one hash lookup
// is enough and there is no seam. Pure arithmetic — no branch, no fetch.
const float STONE_CELL = 3.0;

// x body, y lambert on the body, z contact shadow, w upwind snow bank.
vec4 stones(vec2 t, vec3 L, float density, float aa) {
	vec2 sc = t / STONE_CELL;
	vec2 cell = floor(sc);
	vec2 f = (sc - cell) * STONE_CELL;
	float h0 = tile_hash(cell);
	float present = step(h0, density);
	float h1 = tile_hash(cell + vec2(37.0, 17.0));
	float h2 = tile_hash(cell + vec2(101.0, 5.0));
	vec2 p = (vec2(h1, h2) * 0.40 + vec2(0.30)) * STONE_CELL;
	// A SCATTER OF EQUAL DOTS IS A PATTERN, NOT A ROCK FIELD. The first pass ran
	// 0.13..0.40 tiles, which at play zoom is 5..16 px — a narrow enough band
	// that every block read as the same object repeated, and the plain came back
	// looking like it had measles. Cubed, so most blocks are small chips and the
	// occasional one is a boulder three times their size.
	float rr = fract(h0 * 31.7);
	float r = max(0.09 + 0.34 * rr * rr * rr, 0.02);
	vec2 e = f - p;
	// Wind space, so "upwind" is a sign rather than a rotation.
	vec2 el = vec2(dot(e, WIND), dot(e, WIND_T));
	float d = length(el) / r;
	float body = smoothstep(1.0, 1.0 - clamp(aa / r, 0.02, 0.9), d) * present;
	// A block, not a ball: the dome is shallow and the rim is what catches the
	// light, which is what a shattered slab seen from directly above looks like.
	float nz = sqrt(max(0.0, 1.0 - min(d, 1.0) * min(d, 1.0)));
	vec3 N = normalize(vec3(el / r, nz * 0.80 + 0.30));
	// A ROCK IS A DARK THING. Handed the full 0..1 lambert the blocks came back
	// as pale domes floating over the plain — the frame's own LcnScenery
	// boulders, four inches away in the same crop, are hard dark silhouettes
	// with a lit top edge, and these have to belong to the same world. The
	// lambert is squeezed into the bottom half of the range, so the top of a
	// block catches the key and the rest of it stays stone.
	float lam = clamp(dot(N, L) * 0.85 + 0.15, 0.0, 1.0) * 0.52 + 0.06;
	vec2 Lw = vec2(dot(L.xy, WIND), dot(L.xy, WIND_T));
	float dsh = length(el + Lw * r * 0.75) / r;
	float shad = smoothstep(1.15, 0.40, dsh) * present * (1.0 - body);
	// The drift. Snow piles on the side the wind comes from and the lee behind
	// is scoured, which is the one shape on a wind-worked plain that says which
	// way the weather runs.
	float dbk = length(el + vec2(r * 0.85, 0.0)) / r;
	float bank = smoothstep(1.25, 0.30, dbk) * present * (1.0 - body);
	// The rim. A hairline of the block's own shadow all the way round it is what
	// separates it from the ground at any zoom, and it is the one hard edge on
	// this plain that survives being photographed.
	float rim = body * smoothstep(0.72, 0.97, d);
	return vec4(body, lam * (1.0 - rim * 0.55), shad, bank);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 w = world_pos;
	vec2 t = w * 0.03125;              // world position in tiles
	vec2 muv = w / map_px;             // 0..1 across the map

	// ---- terrain kind, with an organically warped lookup ---------------------
	// Sampling the kind field straight gives the map's tile grid back as a
	// staircase. Pushing the sample point around with noise turns every kind
	// boundary into a drift edge with lobes and fingers. The warp is stretched
	// along the wind so a rock field breaks out of the snow in the same
	// direction everything else on the plain runs.
	vec4 wn = n4(t * 0.31 + vec2(13.0, 3.0));
	vec4 wn2 = n4(t * 1.42 + vec2(61.0, 29.0));
	vec2 warp = (wn.rg - vec2(0.5)) * 3.4 + (wn2.ba - vec2(0.5)) * 1.05;
	warp = WIND * (warp.x * 2.1) + WIND_T * (warp.y * 0.75);
	float kind = texture(kind_tex, (w + warp * 32.0) / map_px).r;
	float pu = (kind * 255.0 + 0.5) / 16.0;

	vec4 base4 = texture(pal_tex, vec2(pu, 0.125));
	vec3 base = base4.rgb;
	vec3 low = texture(pal_tex, vec2(pu, 0.375)).rgb;
	vec3 high = texture(pal_tex, vec2(pu, 0.625)).rgb;
	vec4 prm = texture(pal_tex, vec2(pu, 0.875));
	float takes_snow = base4.a;

	// ---- fields --------------------------------------------------------------
	// `prm.g` is the terrain's drift rating: how much of this surface the wind
	// works. A snowfield is shaped by the WIND (the same `h` that lights it and
	// decides where the crust is), bare rock by its own strata. Shading rock off
	// the drift field is how every terrain in the frame ended up painted with one
	// isotropic noise and the whole plain read as one cloud.
	float windy = clamp(prm.g, 0.0, 1.0);
	float depth = clamp(texture(snow_tex, muv).r * snow_scale, 0.0, 1.0) * takes_snow;
	// Soot is stamped at one texel per two tiles; sampled straight, its texel grid
	// shows up as 64 px blocky steps at close zoom. Warped by the same field that
	// tears the thaw edge, it becomes grime blown downwind of a chimney.
	float soot = texture(soot_tex,
		(w + (n4(t * 0.44 + vec2(29.0, 173.0)).gb - vec2(0.5)) * 74.0) / map_px).r;
	float city = texture(city_tex, muv).r;

	float h = drift(t, detail);
	// The key's elevation. A dusk sun sits at 0.16 and therefore only reaches
	// faces turned toward it; a noon sun at 0.95 reaches everything. This one
	// number is the difference between light falling on drifts and an orange
	// filter over the frame. Evaluated here rather than down in the lighting
	// block because the stones need it to know which of their faces is lit.
	vec3 L = normalize(vec3(sun_dir * (1.0 - sun_height * 0.55), max(sun_height, 0.06)));

	// ---- stone ---------------------------------------------------------------
	// One block per 3x3 tiles, offered and mostly refused. `prm.g` is how hard
	// the wind works this surface: a scoured rock shelf is littered, open snow
	// carries the odd erratic, a deep drift has swallowed its own. Frozen water
	// and open ice get none at all (`takes_snow` is 0 for exactly those two),
	// because a boulder standing on a lake is a bug and not a rock.
	// AA is one and a half SCREEN pixels wide converted into tiles, so the edge
	// is an edge at the assault zoom and at the strategic zoom alike.
	float stone_aa = clamp(1.5 / max(px_tile, 2.0), 0.012, 0.22);
	float stone_amt = clamp(0.60 - clamp(prm.g, 0.0, 1.0) * 0.52, 0.0, 0.60)
		* takes_snow * (1.0 - smoothstep(0.10, 0.40, city));
	vec4 st = stones(t, L, stone_amt, stone_aa);
	// The bank is snow, so it only piles where snow is lying at all; the lee
	// scour behind the block is there whatever the weather.
	h = clamp(h + st.w * 0.30 - st.x * 0.18, 0.0, 1.0);

	// Heat is stamped as a disc, and a disc with a smooth falloff drawn over
	// snow is unmistakably a soft airbrush. Warping the lookup with the drift
	// field and a mid-scale noise gives the thaw a torn, organic rim that
	// follows the ground it is melting.
	// Smooth warp only. Perturbing a 2-tile-per-texel field with the HIGH
	// frequency drift term tears its texel grid open instead of its outline, and
	// the melt edge came back as a chain of 8 px blocks along the belt line.
	vec2 hwarp = (n4(t * 0.31 + vec2(83.0, 149.0)).rg - vec2(0.5)) * 2.6
		+ (n4(t * 0.09 + vec2(11.0, 211.0)).ba - vec2(0.5)) * 3.4;
	float heat = texture(heat_tex, (w + hwarp * 32.0) / map_px).r;

	// ---- tracks --------------------------------------------------------------
	// WHERE PEOPLE HAVE ACTUALLY WALKED. This used to be two contour lines of a
	// slow noise field, revealed wherever the blurred building-presence texture
	// was high — a shape that looks like paths from the air and is a path-shaped
	// lie: it appeared the instant a building was placed, it ran where nobody
	// had ever been, and it was pixel-identical at hour 3 and hour 1. It is now
	// the wear field, written at the footfalls the entity pass already records
	// and aged over game hours, so the plaza is worn because the city wore it
	// and an abandoned quarter goes back under the snow.
	//
	// The field is one texel per tile and sampled linearly, so used raw it draws
	// its own 32 px grid as soft diamonds. Warped by two octaves of noise it
	// stops being a grid: the path wanders off the tiles the pathfinder used,
	// which is what a real trodden route does.
	vec2 wwarp = (n4(t * 0.37 + vec2(19.0, 97.0)).rg - vec2(0.5)) * 13.0
		+ (n4(t * 0.13 + vec2(53.0, 7.0)).ba - vec2(0.5)) * 26.0;
	float wear = texture(wear_tex, (w + wwarp) / map_px).r;
	// Width and depth wobble along the route: a track people wear is not a
	// drafted line, and this is the ONE thing the old contour version had right.
	//
	// THE RESPONSE CURVE, MEASURED. The first version mapped smoothstep(0.045,
	// 0.42) onto the field, and 260 ticks of 46 people walking a settlement
	// moved the photograph by 0.37% of the screen at a mean of 0.0002 — the two
	// plates were indistinguishable held side by side, which is a wear field
	// that exists in the data and not in the picture. One person crossing fresh
	// snow leaves a line you can see, so the curve starts where a single
	// crossing lands and saturates a couple of crossings later.
	float wob = 0.62 + 0.38 * n1(t * 0.31 + vec2(163.0, 29.0));
	float worn = clamp(smoothstep(0.050, 0.35, wear) * wob, 0.0, 1.0);

	// HOW MUCH KEY LIGHT IS ACTUALLY LANDING OUT HERE, 0..1.
	//
	// Three of the terms below are near-specular — the bright lip of packed
	// drift, the moon or sun catching a crest, the crystalline glint — and a
	// specular response is proportional to the source. They were all running at
	// full strength after dark, which is why the night plain came out dotted
	// with small cold-bright spots. That is not merely wrong about snow; it
	// collides head-on with the ONE cue [P13] gives a player for telling a
	// creature from a citizen after dark. The proof is in the frames:
	// `tests/render/run_foe_frame.gd`'s blind cold-bright scan finds 118
	// clusters on a hostile-free deep_night frame from `artifacts/H4b_v4`,
	// against 52 on `artifacts/H4b_nofloor`, whose night ground has no light on
	// it at all — so two thirds of what that scanner was picking up out of an
	// empty night was this shader's own sparkle. A snowfield at midnight is
	// legible by its SHAPE, not by its highlights.
	float daylight = clamp(sun_energy * (1.0 - wild) * 0.90, 0.0, 1.0);

	// ---- the crust -----------------------------------------------------------
	// Coverage is a NARROW threshold against the drift field, so a snow edge is
	// an EDGE. Snow lies where the drift is high and the wind has scoured the
	// crests bare — one field, so the two always agree.
	// Snow terrain HAS snow on it. `depth` is [P01]'s live accumulation field and
	// it is small — a fraction of the cap in a fresh world — so gating the crust
	// on it alone meant the plain was drawn entirely in the base tone with no
	// crust, no edge and no lip anywhere: a velvet blanket, which is what the
	// critic's word "fog" was describing. The terrain's own drift rating is the
	// floor; accumulation piles on top of it.
	//
	// THE THRESHOLD WAS SET SO HIGH THAT THE PLAIN HAD ALMOST NO SNOW ON IT.
	// At `thr = 1.02 - lying * 1.22` with open snow's drift rating of 0.62 and
	// [P01]'s accumulation sitting near 0.1, the bar came out at 0.60 against a
	// drift field whose mean is about 0.5 — so roughly a fifth of the open plain
	// was crusted and four fifths of it was drawn in `scoured`, the DARK
	// wind-stripped tone the drifts are supposed to lie ON. That is why the
	// snowfield in `artifacts/CRIT/shots/midday.world.png` measures a median of
	// 0.182 with a 10-90 spread of 0.119: it is not a snowfield in the picture,
	// it is the scour under one.
	//
	// The bar is now the other side of the drift field's mean, so open snow is
	// mostly crust with scoured lanes cut through it, deep snow is a white
	// field, and grit and rock still come out bare. Their drift ratings already
	// separate them; only the mapping from rating to bar was wrong.
	// STORM'S SHARE IS THE WEATHER YOU CAN SEE IN A STILL, and 0.16 of it was not
	// enough to move a bar that ran from 0.94 down to 0.04. On the bar below,
	// 0.30 of `lying` is 0.065 of the threshold, which over open snow is fifteen
	// points of coverage: a snowing afternoon has visibly MORE white on the
	// ground than a clear one, in the same frame, with no particle in it.
	float lying = clamp(depth * 1.20 + windy * 0.95 + storm * 0.30, 0.0, 1.0) * takes_snow;
	// AND THEN IT WAS SET SO LOW THAT THE PLAIN HAD NOTHING BUT SNOW ON IT, WHICH
	// IS THE SAME DEFECT WITH THE SIGN FLIPPED. `drift()` returns a field whose
	// mean over open ground is about 0.49 and whose useful spread is roughly
	// 0.35..0.68; the bar was `0.94 - lying * 0.90`, and open snow's own drift
	// rating of 0.62 alone puts `lying` at 0.59 before a flake has fallen, so the
	// bar landed at 0.41 and every accumulating tile in the world pushed it lower
	// still. At 0.04 — where the shipped preview settlement sits — the threshold
	// is BELOW THE FLOOR OF THE FIELD, so `cover` is 1.0 in every pixel of the
	// frame. That is why `artifacts/P13/frames/midday_play.png` before this change
	// is a white sheet with soft blue smears on it: there is no crust boundary
	// anywhere in it to see, only the lambert of a smooth field, and no amount of
	// edge-sharpening downstream can draw an edge that was never crossed.
	//
	// The bar now lives inside the field it is measuring. Same spread and same
	// ordering — bare rock keeps only what catches in its high ground, open snow
	// is mostly crust with scoured lanes cut through it, deep snow is a white
	// field — but every one of those is now a real fraction between 0 and 1
	// instead of a saturated 1.
	// The numbers: `drift()` measured over a 200x200 tile patch of open plain has
	// mean 0.627, sd 0.104, decile 0.497 and 0.766 — so a bar of 0.755 leaves a
	// fifth of a surface under crust, 0.628 leaves half and 0.540 leaves four
	// fifths. Bare rock (drift rating 0.18) keeps only what catches in its high
	// ground, dry open snow (0.62) is half crust and half scoured lane, and a
	// surface that is either deep snow or being snowed on goes to four fifths
	// white. Reproduce the distribution with tests/render/test_terrain_field.gd's
	// drift-field case.
	float thr = 0.755 - lying * 0.215;
	// THE CRUST BREAKS ALONG A COMB THE PLAY CAMERA CAN RESOLVE. The edge used
	// to be a threshold on a field built entirely from linearly-filtered single
	// texels of a 256px value noise, so every boundary was a smooth blob and the
	// whole plain measured 0.008 of local structure at 9 px — an out-of-focus
	// photograph. This rakes the bar itself across the wind at a pitch of about
	// half a tile, which at the zoom a session runs at (0.5-0.85, so 16-27 px a
	// tile) puts a finger of bare scour every 8-14 screen pixels along every
	// snow edge in the frame.
	vec2 qc = vec2(dot(t, WIND), dot(t, WIND_T));
	// FRAY THE EDGE, DO NOT FRAY THE FIELD. This is the defect that survived five
	// rounds and it was written HERE, not in the drift field. The two combs below
	// move the coverage bar by up to +/-0.13 of the height field, and the bar is
	// crossed with a smoothstep 0.052 wide — so at ANY point on the plain, edge or
	// not, the comb is more than twice as wide as the transition it is jittering.
	// The result is that coverage flips fully on and fully off along a half-tile
	// pitch EVERYWHERE, and what the frame shows is not a snowfield with torn
	// edges but a diagonal hatch laid edge to edge over the whole monitor at one
	// frequency. Open `artifacts/P13/frames/midday_play.png` from before this
	// change: there is no square inch of it without the same comb in it, which is
	// the definition of wallpaper, and it is why five critics in a row wrote down
	// "no drift structure at play zoom" about a shader that has three ranks of
	// drift in it. The structure was there; the hatch was painted over it.
	//
	// So the fray is windowed on DISTANCE FROM THE BAR. Within about a twentieth
	// of the height field of the edge it is at full strength and the boundary
	// tears exactly as intended; a fifth of the field away — the middle of a
	// snowfield, the middle of a scoured lane — it is arithmetically zero and the
	// surface is left to the drift, the comb striations and the light.
	// The window is TIGHT, and it has to be, because the field it is windowing is
	// smooth. A threshold 0.05 wide crossed by a field whose gradient is 0.1 per
	// tile is an edge twelve screen pixels across however narrow the threshold
	// looks written down — which is why the scoured patches in the previous frame
	// are soft blue clouds. The fray is what makes the boundary hard: inside a
	// fiftieth of the bar it swings the bar by more than the whole transition
	// width, so cover flips on and off along a half-tile comb and the boundary
	// comes out ragged, with fingers of scour reaching into the crust and vice
	// versa. Two hundredths out and it is gone again.
	float near_edge = 1.0 - smoothstep(0.02, 0.10, abs(h - thr));
	thr += ((n1(vec2(qc.x * 0.26, qc.y * 2.15) + vec2(157.0, 83.0)) - 0.5) * 0.19
	// ...and a second, finer comb, at about a fifth of a tile across the wind, so
	// the edge frays at four screen pixels as well as at fourteen. Two scales of
	// fray is the difference between a torn edge and a wavy line.
		+ (n1(vec2(qc.x * 1.10, qc.y * 5.20) + vec2(67.0, 199.0)) - 0.5) * 0.085 * detail)
		* near_edge;
	// AND THE EDGE IS AN EDGE. At +/-0.055 of the height field the crust faded
	// over about five screen pixels, which is a soft boundary, and a plain whose
	// every boundary is soft is the "one large soft cloud-noise field" the frame
	// keeps being called. Half that, so the snow line lands in two pixels and
	// the eye has something to catch on.
	float cover = smoothstep(thr - 0.016, thr + 0.016, h);
	cover *= smoothstep(0.0, 0.04, lying);
	// Warmth breaks the crust, and feet break it faster.
	float melt = smoothstep(0.30, 0.70, heat);
	// ...and falling snow fills the tracks back in. A route walked all day still
	// wins; a route walked once at dawn is under an afternoon of snowfall.
	worn *= 1.0 - storm * 0.42;
	cover *= (1.0 - melt) * (1.0 - worn * 0.85);

	// ---- bare ground ---------------------------------------------------------
	// Strata, quantised into facets. Rock that is smoothly shaded is mud; rock
	// that steps between a handful of tones reads as rock.
	float strat = fbm2(vec2(t.x * 0.42 + t.y * 0.19, t.y * 0.51 - t.x * 0.13));
	float facet = floor(strat * 4.0) * 0.25;
	// TWO surfaces, not one tone. `rocky` is the exposed shelf, faceted by its
	// strata; `scoured` is the wind-stripped snowpack the drifts lie ON, and it
	// has to be decisively DARKER than the drift or there is no crust to see.
	// Blending both toward the same mid tone is why the previous attempt at a
	// crust changed the frame by 0.001 of a stop: the snow and the ground it lay
	// on were the same colour, so the edge between them was invisible.
	vec3 rocky = mix(low, high, mix(strat, facet, 0.62));
	// SCOUR AND CRUST WERE THE SAME VALUE, WHICH IS WHY THE PLAIN HAD NO SHAPE.
	// `mix(low, base, 0.22..0.56)` on open snow lands at 0.49 luminance against a
	// crust at 0.62-0.85 — a ratio of 1.4, which is a quarter of a stop, which is
	// nothing. Every drift boundary in the frame was therefore an edge between
	// two tones the eye cannot separate, and the ground came out as one soft
	// field however sharply the threshold that drew it was cut. Wind-stripped
	// snowpack is DARK: it is the shadowed pack under the drift, not another
	// shade of the drift. At 0.30 against 0.62-0.85 a crust edge is finally a
	// step you can see across a room.
	// ...AND THEN NOT SO DARK THAT THE PLAIN IS A PHOTOCOPY. `low * 0.62` puts
	// open snow's scour at 0.31 luminance against a crust at 0.80 — one and a
	// half stops, which was the right call when the scour was four fifths of the
	// picture and the wrong one now the bar above has put it back to a third of
	// it. Wind-stripped snowpack is not rock: it is the shadowed pack UNDER the
	// drift, a stop below it, not a hole in it. At 0.50 against 0.80 a crust edge
	// is still a step the eye catches across a room, and the plain stops reading
	// as a black-and-white jigsaw at play zoom.
	vec3 scoured = mix(low * 1.00, base * 1.02, 0.18 + 0.42 * strat);
	vec3 albedo = mix(rocky, scoured, windy);
	// Fracture lines. Two contour sets at right angles read as a broken shelf.
	float crack = max(
		1.0 - smoothstep(0.0, 0.030, abs(fbm2(t * 0.30 + vec2(17.0, 5.0)) - 0.5)),
		1.0 - smoothstep(0.0, 0.024, abs(fbm2(t * 0.47 + vec2(211.0, 91.0)) - 0.44)));
	albedo *= 1.0 - crack * 0.34 * (1.0 - prm.g);
	// Open ice keeps its cracks bright instead of dark: it is lit from inside.
	albedo = mix(albedo, high, crack * prm.b * 0.45 * (1.0 - takes_snow));

	// Per-tile facet. Two identical tiles of ground should not be the same
	// picture, and the world should have a visible unit of size.
	albedo = mix(albedo, high, smoothstep(0.74, 0.99, h) * 0.22 * windy);
	albedo = mix(albedo, low, smoothstep(0.30, 0.02, h) * 0.20 * windy);

	float tf = tile_hash(floor(t)) - 0.5;
	albedo *= 1.0 + tf * 0.10 * (0.30 + 0.70 * detail);
	// A hairline crease on the tile boundary, close in only. Not a grid overlay:
	// at 2% it is below conscious notice and above the threshold where the eye
	// stops being able to judge how far away the ground is.
	vec2 fr = abs(fract(t) - 0.5);
	float seam = smoothstep(0.44, 0.50, max(fr.x, fr.y));
	albedo *= 1.0 - seam * 0.055 * detail * detail;

	// SNOW HAS A TOOTH. At `prm.r` (0.055-0.07 for snow) this was a 3% speckle,
	// which is under the noise floor of a JPEG let alone of an eye, and the
	// surface it was supposed to break up came out as flat paint. 2.4x, and it
	// stays behind `detail` so the strategic zoom does not shimmer.
	float grain = (n1(t * 19.0) - 0.5) * prm.r * 2.4 * detail;
	albedo += vec3(grain, grain * 0.96, grain * 0.9);

	// The block itself, and the ground it is standing on. Drawn BEFORE the snow
	// so a drift can bury one, and its contact shadow darkens the ground rather
	// than the block, which is the difference between a rock lying on a plain
	// and a grey circle painted on one.
	vec3 stone_col = mix(stone_dark * 0.72, stone_lite * 0.86, clamp(0.22 + tf * 0.9, 0.0, 1.0));
	albedo *= 1.0 - st.z * 0.38;
	albedo = mix(albedo, stone_col, st.x);

	// ---- snow ----------------------------------------------------------------
	// Snow is NOT white. A white snowfield is a white rectangle; snow is a pale
	// blue-grey that only goes white where the light actually catches a crest.
	// The crest band was 0.42 of the height field wide, so `crest` reached 1.0
	// only on the very tallest drift on the map and every ordinary drift top
	// stopped at snow_mid. Narrowed, so the top of an ordinary drift is the
	// brightest thing on the plain, which is what a lit crest is for.
	float crest = smoothstep(thr, min(thr + 0.24, 1.0), h);
	vec3 snow_col = mix(snow_mid, snow_lit, crest * crest * (0.16 + 0.84 * daylight));
	snow_col = mix(mix(snow_shadow, snow_mid, 0.55), snow_col,
		clamp(0.42 + lying * 0.9, 0.0, 1.0));
	// Wind-comb: parallel striations on the snow itself, along the wind.
	// PITCHED FOR THE CAMERA THE GAME IS PLAYED AT. At 3.7 across the wind one
	// striation was 0.27 of a tile — under 6 screen pixels at play zoom — so the
	// comb averaged itself away into a flat tone before it ever reached the
	// frame, and contributed nothing but shimmer. At 1.9 a striation is half a
	// tile, and the amplitude that was 7% is 15%, because a wind-combed
	// snowfield is visibly ribbed and this one was not.
	vec2 q = qc;
	float comb = n1(vec2(q.x * 0.42, q.y * 1.90) + vec2(57.0, 13.0));
	snow_col *= 0.925 + comb * 0.155;
	albedo = mix(albedo, snow_col, cover);

	// The lip: a bright rim of packed drift right at the edge of the cover, and
	// a blue shadow immediately downwind of it. This is what makes a snow edge
	// read as a THICKNESS rather than as a painted boundary.
	float lip = cover * (1.0 - cover) * 4.0;
	albedo = mix(albedo, snow_lit, lip * lip * 0.30 * (0.10 + 0.90 * daylight));
	// ...and the trough immediately downwind of the lip is in its shadow.
	float lee = smoothstep(0.35, 0.0, h - thr) * (1.0 - cover);
	albedo = mix(albedo, snow_shadow * 0.72, lee * 0.30 * takes_snow);

	// ---- worn ground ---------------------------------------------------------
	// A path is packed snow: darker, bluer, no sparkle. And it goes THROUGH
	// stages, which is the whole point of a field that accumulates — a route
	// used once is a discolouration, a route used all day is trodden down to the
	// grit under it. A player watching their own city for three hours can see
	// which of the two the road to the hearth has become.
	vec3 packed_snow = mix(snow_shadow * 0.86, snow_mid * 0.80, 0.5);
	albedo = mix(albedo, packed_snow, worn * 0.58);
	float core = smoothstep(0.52, 0.94, wear);
	albedo = mix(albedo, mix(scoured, ash_col, 0.30), core * 0.34);

	// ---- industrial soot -----------------------------------------------------
	float soot_mask = smoothstep(0.30, 0.86, soot) * (0.30 + 0.70 * fbm2(t * 1.22 + vec2(77.0)));
	albedo = mix(albedo, ash_col, clamp(soot_mask * 0.36, 0.0, 0.28));

	// ---- thaw ----------------------------------------------------------------
	// Wet ground next to a fire, and a ring of refrozen slush at the melt line.
	// This is the ONE place the plain is dark and shining, and it is a readout:
	// it means something there is burning.
	// Thawed ground is WET GRAVEL, not a burn mark. Melting the crust exposes the
	// dark scoured surface underneath, and left at that the pool around a Hearth
	// reads as a smoke stain a hundred tiles wide; lifting it back toward the
	// terrain's own mid tone keeps it dark without turning it into a hole.
	albedo = mix(albedo, base, melt * 0.34);
	float wet = smoothstep(0.34, 0.80, heat);
	albedo = mix(albedo, albedo * vec3(0.80, 0.72, 0.66) + vec3(0.055, 0.034, 0.020), wet * 0.60);
	float slush = melt * (1.0 - melt) * 4.0;
	albedo = mix(albedo, mix(snow_shadow, snow_lit, 0.55), slush * 0.30);

	// ---- blowing snow --------------------------------------------------------
	// WEATHER YOU CAN SEE IN A STILL. [P14] draws the flakes in the air and does
	// it well, but a photograph of falling snow from this camera is a scatter of
	// white specks, which is why a critic holding a real frame of this build said
	// there is no visible weather in it. What a still CAN carry is what the wind
	// is doing to the GROUND: long tongues of spindrift streaming downwind,
	// bright where they lift over a drift crest, gone in the lee behind it.
	//
	// They are anisotropic along the same WIND every drift on this plain lies
	// down, so a storm does not look like a second unrelated texture laid over
	// the first — it looks like the wind that built the drifts, harder. Scrolled
	// by `time_s` so they stream in motion; frozen, they are unmistakably a plain
	// in a blizzard rather than a plain at noon.
	if (storm > 0.01) {
		vec2 sq = vec2(q.x - time_s * (0.9 + storm * 2.6), q.y);
		float tongue = n1(vec2(sq.x * 0.085, sq.y * 2.7) + vec2(23.0, 61.0));
		float tongue2 = n1(vec2(sq.x * 0.150, sq.y * 4.3) + vec2(137.0, 5.0));
		float band = smoothstep(0.68 - storm * 0.18, 0.92, max(tongue, tongue2 * 0.94));
		// It rides over the crests and pours into the troughs behind them.
		band *= 0.40 + 0.80 * smoothstep(thr - 0.20, thr + 0.28, h);
		// A TONGUE OF SPINDRIFT IS A THREAD, NOT A SMEAR. Against the dark plain
		// this shipped as at 0.60 it was the only bright thing on the ground and
		// it read as the surface; against a plain that is now actually snow it
		// only has to be the thing MOVING over it. Narrower band, lighter touch,
		// and the drifts underneath stay the structure the eye reads.
		albedo = mix(albedo, snow_lit, clamp(band * storm * 0.30, 0.0, 0.30));
		// ...and everything behind it loses a little of its contrast, which is
		// what makes the streaks read as being IN FRONT of the ground.
		albedo = mix(albedo, mix(snow_mid, snow_shadow, 0.42), storm * 0.11);
	}

	// ---- lighting ------------------------------------------------------------
	// The normal comes from the SAME drift field the crust does, so light rakes
	// along the drifts the player can see rather than across a hidden second
	// surface. Four extra fetches; this is the difference between "the frame has
	// been tinted" and "a low sun is crossing a snowfield".
	float relief = mix(prm.a, 1.15, cover * 0.7) * (1.0 - worn * 0.6);
	// THE STEP AND THE AMPLITUDE ARE THE OTHER HALF OF THE SAME DEFECT. A step of
	// 0.42 tiles samples the field at 13 screen pixels and an amplitude of 7.5
	// turns a height difference of 0.1 into a 37-degree face, so every ripple in
	// the field became a full swing of the lambert and the plain came out with
	// more local contrast in it than the buildings standing on it. That is the
	// literal mechanism behind "the city does not occupy the screen": the ground
	// was the loudest thing in the frame and it had nothing to say. A wider step
	// reads the drift instead of the ripple, and a gentler amplitude puts the
	// plain back where a plain belongs — quiet, with the contrast spent on the
	// crust edges, the lee shadows, the rock and the city.
	float e = 0.70;
	float hx = drift(t + vec2(e, 0.0), 0.0) - drift(t - vec2(e, 0.0), 0.0);
	float hy = drift(t + vec2(0.0, e), 0.0) - drift(t - vec2(0.0, e), 0.0);
	float amp = 4.6 * relief * (0.55 + 0.45 * detail);
	vec3 N = normalize(vec3(-hx * amp, -hy * amp, 1.0));

	// Only lightly wrapped. A fully wrapped term (dot*0.5+0.5) hands flat ground
	// 0.58 of the key even when the key is horizontal, which is precisely how a
	// low sun turns back into a global orange multiply.
	float ndl = clamp(dot(N, L) * 0.92 + 0.08, 0.0, 1.0);
	ndl = ndl * ndl * (3.0 - 2.0 * ndl);
	// A stone is not a piece of the snowfield, so it does not take the
	// snowfield's normal. Its own lambert wins on its own body, which is what
	// gives it a lit face and a dark one and therefore a shape.
	ndl = mix(ndl, st.y, st.x * 0.85);
	// FALLING SNOW IS A SOFTBOX — AND A SOFTBOX IS DIMMER THAN THE SUN IT
	// REPLACES, WHICH IS THE HALF THIS SHADER GOT WRONG.
	//
	// The direction dissolving is right: under a snowing sky shadows lose their
	// edge and drift faces stop separating, and a still frame of a snowing
	// afternoon has to be a different picture from a still frame of a clear one.
	// But mixing `ndl` toward a constant 0.58-1.0 RAISES the key on flat ground —
	// at dusk, from 0.078 to 0.28 — and dusk's key is a 1.44-energy copper. The
	// arithmetic and the frame agree: `artifacts/H4b_now/shots/dusk.world.png`
	// measures red-minus-blue +0.098 over the open plain against midday's
	// -0.045, and what it looks like is an orange filter laid over a desert.
	// That is precisely the failure the whole light rig was built to end, put
	// back by the weather term.
	//
	// So the softbox now MOVES the energy instead of inventing it: the key gives
	// up over half its power and the sky fill takes it, which is what actually
	// happens when cloud swallows a sun. The picture that comes out is flatter,
	// BLUER and about as bright — a snowing dusk is a cold grey-blue afternoon
	// with a copper smear low on one side, and a clear dusk still has its raking
	// key and its long shadows.
	float soft = clamp(storm * 0.90, 0.0, 0.72);
	ndl = mix(ndl, 0.40 + 0.52 * N.z, soft);
	float key_e = sun_energy * (1.0 - soft * 0.62);
	float fill_e = sky_energy * (1.0 + soft * 1.45);
	// Troughs are shaded by their own drift walls. Cheap, and it is most of what
	// makes a snowfield look like it has depth. A block sitting on the ground
	// occludes it too, and that contact is most of what welds it down.
	// WIDENED ON PURPOSE, AND IT IS THE CHEAP HALF OF A TRADE. The night needs
	// more contrast, and there are two ways to buy it: brighter highlights, or
	// deeper troughs. Highlights are small and round and they are exactly what
	// [P13]'s creature scan mistakes for a creature. A trough follows the drift
	// it is cut into, so it is forty pixels long and eight wide and no scanner
	// that rejects things longer than three and a half times their width will
	// ever see it. Contrast bought here is free of that collision.
	float ao = (0.40 + 0.74 * smoothstep(0.10, 0.90, h)) * (1.0 - st.z * 0.30);

	// THE WILDERNESS LOSES ITS AMBIENT, NOT ITS MOON.
	//
	// `light *= mix(1.0 - wild, 1.0, ...)` took the key and the fill down
	// together, and at deep night's wild of 0.88 that left the plain on 12% of
	// everything — including 12% of the one term that has a DIRECTION in it. A
	// snowfield with no key has no crests, so the plain out there went not
	// merely dark but featureless: `artifacts/CRIT/shots/deep_night.world.png`
	// measures a 10-90 spread of 0.039 and 0.007 of local gradient over the open
	// plain, which is a black rectangle with a gradient on it, and "dark AND
	// empty" is the one thing a night in this game may not be.
	//
	// The penalty is split. The fill — the flat blue hemisphere that lights
	// everything equally and therefore describes nothing — takes the whole of
	// it. The key keeps most of itself, so a low moon still rakes the drifts and
	// a crest still reads against the trough behind it. On FLAT ground the two
	// forms land within 5% of each other, which matters: the entity twin in
	// `light_at` keeps the single uniform `dark`, because a figure has no drift
	// normal to rake, and this split is deliberately mean-preserving so the
	// figure and the snow it stands on still agree about the level.
	float out_there = 1.0 - clamp(heat * 2.6 + city * 0.55, 0.0, 1.0);
	// ...and as the key turns into a hemisphere it stops being a key, so it has
	// to start taking the wilderness penalty a fill takes. Without this line the
	// softbox is a loophole: a snowing night lights the whole plain flat at 71%
	// of the moon and the dark goes out of the dark.
	vec3 light = sun_col * (key_e * (0.045 + 1.10 * ndl) * ao)
		* (1.0 - wild * mix(0.42, 1.0, soft) * out_there);
	light += sky_col * (fill_e * (0.62 + 0.38 * N.z) * ao)
		* (1.0 - wild * out_there);
	// The night floor. A settlement is legible after dark because it is BURNING,
	// not because the renderer lifted a disc of ground around it: the bounce term
	// is driven by heat first and by mere presence only faintly. A district that
	// has frozen goes out.
	float lit_city = clamp(heat * 2.30 + city * 0.16, 0.0, 1.0);
	light += bounce_col * (bounce * lit_city * 0.46);
	// Ground next to a fire is lit BY the fire, in the fire's colour, and this is
	// the strongest single instrument the renderer has. Squared falloff so the
	// pool has a hot centre and a long cold tail instead of a flat disc.
	// Squared falloff so a pool has a hot centre and a long cold tail instead of
	// a flat disc, and scaled hard by the hour: a brazier is the brightest thing
	// on the plain at midnight and all but invisible at noon, which is the whole
	// dramatic arc of a day in this game.
	float fire = heat * heat;
	light += warm_col * (fire * 1.25 * (0.10 + 0.90 * bounce));

	vec3 col = albedo * light;

	// Crystalline glint, only on lit crests, only close in, never on a path.
	// ...and it goes out under falling snow, because a fresh fall has no facets
	// in it yet: another thing a still frame of a blizzard has that a still
	// frame of a clear afternoon does not.
	float sp = n1(t * 17.0 + vec2(time_s * 0.05, 0.0));
	col += vec3(1.0, 1.0, 1.05) * step(0.9905, sp) * cover * crest * prm.b * detail
		* (1.0 - worn) * (0.15 + daylight * 1.05) * (1.0 - clamp(storm * 0.85, 0.0, 1.0));

	// ---- the highlight shoulder ----------------------------------------------
	// A SNOWFIELD AT NOON IS THE ONE SURFACE IN THIS GAME THAT CAN CLIP, AND IT
	// WAS CLIPPING OVER MOST OF THE FRAME. With a key of 1.4 and a fill of 0.8
	// the crust receives `light` of about 1.7, so the whole of the daylit plain
	// arrived above 1.0 and was flattened to paper by the framebuffer: `frame_lab`
	// graded midday_play at 0.751 mean and called it a white field, and every
	// crest, lip and comb this shader draws into the top of the range was being
	// drawn into the clip and thrown away. That is why five rounds of "no drift
	// structure at play zoom" survived a shader with three ranks of drift in it —
	// half the day, the structure was there and the monitor could not show it.
	//
	// The obvious fix is to turn the day down, and it is the wrong one: the arc
	// from noon to midnight is what this game is about, `run_ground_frame` grades
	// it as a SEPARATION between the darkest tenth of the day and the brightest
	// tenth of the night, and darkening the day closes it from the wrong end.
	//
	// So the top of the range gets a shoulder instead of a wall. Everything below
	// SHOULDER is untouched — the mid-tones, the night, the whole of the arc —
	// and everything above it is compressed onto an asymptote at 1.0, so a lit
	// crest is still the brightest thing on the plain and still has a value
	// ABOVE the crust beside it instead of being the same white. Applied to
	// luminance and scaled back onto the colour so the shoulder cannot shift a
	// hue, which a per-channel curve would.
	const float SHOULDER = 0.60;
	float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
	float over = max(lum - SHOULDER, 0.0);
	float rolled = lum - over + over / (1.0 + over / (1.0 - SHOULDER));
	col *= rolled / max(lum, 0.0001);

	// Off the edge of the world.
	vec2 d = max(vec2(0.0) - muv, muv - vec2(1.0));
	col = mix(col, col * 0.18, clamp(max(d.x, d.y) * 10.0, 0.0, 1.0));

	COLOR = vec4(max(col, vec3(0.0)), 1.0);
}
