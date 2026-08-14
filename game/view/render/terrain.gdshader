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
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform sampler2D pal_tex : filter_nearest, repeat_disable;

uniform vec2 map_px = vec2(8192.0, 8192.0);
uniform float snow_scale = 1.0;
uniform float detail = 1.0;
uniform float time_s = 0.0;

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
	// Slow swell far larger than the screen: the plain is not flat.
	float swell = fbm2(t * 0.021 + vec2(9.0, 61.0));
	// The wind does not work the whole plain equally. Modulating the ridge
	// amplitude over a kilometre scale is the difference between a snowfield and
	// a combed carpet: some of it is scoured smooth, some is heavy sastrugi.
	float force = 0.42 + 0.80 * fbm2(t * 0.013 + vec2(197.0, 31.0));
	float h = swell * 0.22 + (ridge_a * 0.50 + ridge_b * 0.28) * force;
	// Wind-combed grain, only worth fetching when the camera is close enough to
	// resolve it.
	h += (n1(vec2(q.x * 0.9, q.y * 6.1) + vec2(3.0, 91.0)) - 0.5) * 0.11 * fine;
	return clamp(h, 0.0, 1.0);
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
	// Heat is stamped as a disc, and a disc with a smooth falloff drawn over
	// snow is unmistakably a soft airbrush. Warping the lookup with the drift
	// field and a mid-scale noise gives the thaw a torn, organic rim that
	// follows the ground it is melting.
	vec2 hwarp = (n4(t * 0.62 + vec2(83.0, 149.0)).rg - vec2(0.5)) * 3.1
		+ (vec2(h) - vec2(0.5)) * 1.7;
	float heat = texture(heat_tex, (w + hwarp * 32.0) / map_px).r;

	// ---- tracks --------------------------------------------------------------
	// Contour lines of two slow fields, revealed only where people are. A worn
	// path is exactly this shape from the air: a long wandering line that does
	// not care about the tile grid and only exists where there is somewhere to
	// walk to. `city` is the blurred building-presence field, so tracks appear
	// between structures and fade out on the empty plain.
	// `city` is a heavily blurred 8-tile-per-texel field. Used raw as a mask it
	// paints its own texel grid on the ground as soft diagonal-cornered islands —
	// which is exactly what the second attempt at this did. Warped by noise it
	// stops being a grid and becomes a fringe.
	vec2 cwarp = (n4(t * 0.19 + vec2(53.0, 7.0)).ba - vec2(0.5)) * 150.0
		+ (n4(t * 0.77 + vec2(131.0, 19.0)).rg - vec2(0.5)) * 46.0;
	float city_w = texture(city_tex, (w + cwarp) / map_px).r;
	float lived = smoothstep(0.30, 0.74, city_w);
	float pf1 = fbm2(t * 0.043 + vec2(311.0, 77.0));
	float pf2 = fbm2(t * 0.029 + vec2(7.0, 199.0));
	// Width wobbles along the path: a track people wear is not a drafted line.
	float wob = 0.010 + 0.012 * n1(t * 0.31 + vec2(163.0, 29.0));
	float trail = max(
		1.0 - smoothstep(0.0, wob * 0.62, abs(pf1 - 0.5)),
		1.0 - smoothstep(0.0, wob * 0.44, abs(pf2 - 0.615)));
	float worn = clamp(trail * lived, 0.0, 1.0);

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
	float lying = clamp(depth + windy * 0.55, 0.0, 1.0) * takes_snow;
	float thr = 1.02 - lying * 1.22;
	float cover = smoothstep(thr - 0.050, thr + 0.050, h);
	cover *= smoothstep(0.0, 0.04, lying);
	// Warmth breaks the crust, and feet break it faster.
	float melt = smoothstep(0.16, 0.50, heat);
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
	vec3 scoured = mix(low, base, 0.22 + 0.34 * strat);
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

	float grain = (n1(t * 19.0) - 0.5) * prm.r * detail;
	albedo += vec3(grain, grain * 0.96, grain * 0.9);

	// ---- snow ----------------------------------------------------------------
	// Snow is NOT white. A white snowfield is a white rectangle; snow is a pale
	// blue-grey that only goes white where the light actually catches a crest.
	float crest = smoothstep(thr, min(thr + 0.42, 1.0), h);
	vec3 snow_col = mix(snow_mid, snow_lit, crest * crest);
	snow_col = mix(mix(snow_shadow, snow_mid, 0.55), snow_col,
		clamp(0.42 + lying * 0.9, 0.0, 1.0));
	// Wind-comb: fine parallel striations on the snow itself, along the wind.
	vec2 q = vec2(dot(t, WIND), dot(t, WIND_T));
	float comb = n1(vec2(q.x * 0.55, q.y * 3.7) + vec2(57.0, 13.0));
	snow_col *= 0.965 + comb * 0.07;
	albedo = mix(albedo, snow_col, cover);

	// The lip: a bright rim of packed drift right at the edge of the cover, and
	// a blue shadow immediately downwind of it. This is what makes a snow edge
	// read as a THICKNESS rather than as a painted boundary.
	float lip = cover * (1.0 - cover) * 4.0;
	albedo = mix(albedo, snow_lit, lip * lip * 0.30);
	// ...and the trough immediately downwind of the lip is in its shadow.
	float lee = smoothstep(0.35, 0.0, h - thr) * (1.0 - cover);
	albedo = mix(albedo, snow_shadow * 0.72, lee * 0.30 * takes_snow);

	// ---- worn ground ---------------------------------------------------------
	// A path is packed snow: darker, bluer, no sparkle, with two ruts in it.
	vec3 packed_snow = mix(snow_shadow * 0.86, snow_mid * 0.80, 0.5);
	albedo = mix(albedo, packed_snow, worn * 0.46);
	float rut = 1.0 - smoothstep(0.0, 0.004, abs(pf1 - 0.5));
	albedo *= 1.0 - rut * lived * 0.14;

	// ---- industrial soot -----------------------------------------------------
	float soot_mask = smoothstep(0.30, 0.86, soot) * (0.30 + 0.70 * fbm2(t * 1.22 + vec2(77.0)));
	albedo = mix(albedo, ash_col, clamp(soot_mask * 0.36, 0.0, 0.28));

	// ---- thaw ----------------------------------------------------------------
	// Wet ground next to a fire, and a ring of refrozen slush at the melt line.
	// This is the ONE place the plain is dark and shining, and it is a readout:
	// it means something there is burning.
	float wet = smoothstep(0.34, 0.80, heat);
	albedo = mix(albedo, albedo * vec3(0.80, 0.72, 0.66) + vec3(0.055, 0.034, 0.020), wet * 0.60);
	float slush = melt * (1.0 - melt) * 4.0;
	albedo = mix(albedo, mix(snow_shadow, snow_lit, 0.55), slush * 0.30);

	// ---- lighting ------------------------------------------------------------
	// The normal comes from the SAME drift field the crust does, so light rakes
	// along the drifts the player can see rather than across a hidden second
	// surface. Four extra fetches; this is the difference between "the frame has
	// been tinted" and "a low sun is crossing a snowfield".
	float relief = mix(prm.a, 1.15, cover * 0.7) * (1.0 - worn * 0.6);
	float e = 0.42;
	float hx = drift(t + vec2(e, 0.0), 0.0) - drift(t - vec2(e, 0.0), 0.0);
	float hy = drift(t + vec2(0.0, e), 0.0) - drift(t - vec2(0.0, e), 0.0);
	float amp = 5.0 * relief * (0.55 + 0.45 * detail);
	vec3 N = normalize(vec3(-hx * amp, -hy * amp, 1.0));
	// The key's elevation. A dusk sun sits at 0.16 and therefore only reaches
	// faces turned toward it; a noon sun at 0.95 reaches everything. This one
	// number is the difference between light falling on drifts and an orange
	// filter over the frame.
	vec3 L = normalize(vec3(sun_dir * (1.0 - sun_height * 0.55), max(sun_height, 0.06)));

	// Only lightly wrapped. A fully wrapped term (dot*0.5+0.5) hands flat ground
	// 0.58 of the key even when the key is horizontal, which is precisely how a
	// low sun turns back into a global orange multiply.
	float ndl = clamp(dot(N, L) * 0.92 + 0.08, 0.0, 1.0);
	ndl = ndl * ndl * (3.0 - 2.0 * ndl);
	// Troughs are shaded by their own drift walls. Cheap, and it is most of what
	// makes a snowfield look like it has depth.
	float ao = 0.46 + 0.62 * smoothstep(0.12, 0.88, h);

	vec3 light = sun_col * (sun_energy * (0.07 + 1.10 * ndl) * ao);
	light += sky_col * (sky_energy * (0.62 + 0.38 * N.z) * ao);
	// The night floor. A settlement is legible after dark because it is BURNING,
	// not because the renderer lifted a disc of ground around it: the bounce term
	// is driven by heat first and by mere presence only faintly. A district that
	// has frozen goes out.
	float lit_city = clamp(heat * 2.30 + city * 0.16, 0.0, 1.0);
	light += bounce_col * (bounce * lit_city * 0.46);
	// Beyond the settlement the night is allowed to be a night.
	light *= mix(1.0 - wild, 1.0, clamp(heat * 2.6 + city * 0.55, 0.0, 1.0));
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
	float sp = n1(t * 17.0 + vec2(time_s * 0.05, 0.0));
	col += vec3(1.0, 1.0, 1.05) * step(0.9905, sp) * cover * crest * prm.b * detail
		* (1.0 - worn) * (0.25 + sun_energy * 0.9);

	// Off the edge of the world.
	vec2 d = max(vec2(0.0) - muv, muv - vec2(1.0));
	col = mix(col, col * 0.18, clamp(max(d.x, d.y) * 10.0, 0.0, 1.0));

	COLOR = vec4(max(col, vec3(0.0)), 1.0);
}
