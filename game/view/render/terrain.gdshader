shader_type canvas_item;

// The ground. [P13], second pass.
//
// One quad over the visible rect. Everything below is evaluated per pixel in
// WORLD space, which is the whole point: there is no tile image to repeat, no
// atlas to read as an atlas, and no chunk boundary to seam, because no chunk is
// ever drawn. Terrain kind, snow, heat, soot and city presence arrive as small
// data textures; the surface itself is generated here.
//
// Written for GL Compatibility: constant loop bounds, no derivatives, no
// textureLod, no dynamic indexing. Every extra cost is behind `detail`, which
// the renderer lowers as the camera pulls out and the detail stops being visible.

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

vec4 n4(vec2 p) {
	return texture(noise_tex, p * INV_NOISE);
}

float n1(vec2 p) {
	return texture(noise_tex, p * INV_NOISE).r;
}

// Three octaves of value noise, one texture fetch each. `p` is in tiles.
float fbm3(vec2 p) {
	float s = texture(noise_tex, p * INV_NOISE).r * 0.5;
	s += texture(noise_tex, (p * 2.03 + vec2(37.0, 11.0)) * INV_NOISE).g * 0.3;
	s += texture(noise_tex, (p * 4.11 + vec2(5.0, 71.0)) * INV_NOISE).b * 0.2;
	return s;
}

float fbm2(vec2 p) {
	float s = texture(noise_tex, p * INV_NOISE).r * 0.62;
	s += texture(noise_tex, (p * 2.07 + vec2(19.0, 53.0)) * INV_NOISE).a * 0.38;
	return s;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 w = world_pos;
	vec2 t = w * 0.03125;              // world position in tiles
	vec2 muv = w / map_px;             // 0..1 across the map

	// ---- terrain kind, with an organically warped lookup ---------------------
	// Sampling the kind field straight gives you the map's tile grid back as a
	// staircase. Pushing the sample point around with two octaves of noise turns
	// every kind boundary into a drift edge with lobes and fingers, at every
	// zoom, for two texture fetches.
	vec4 wn = n4(t * 0.34 + vec2(13.0, 3.0));
	vec4 wn2 = n4(t * 1.55 + vec2(61.0, 29.0));
	vec2 warp = (wn.rg - vec2(0.5)) * 4.6 + (wn2.ba - vec2(0.5)) * 1.25;
	float kind = texture(kind_tex, (w + warp * 32.0) / map_px).r;
	float pu = (kind * 255.0 + 0.5) / 16.0;

	vec4 base4 = texture(pal_tex, vec2(pu, 0.125));
	vec3 base = base4.rgb;
	vec3 low = texture(pal_tex, vec2(pu, 0.375)).rgb;
	vec3 high = texture(pal_tex, vec2(pu, 0.625)).rgb;
	vec4 prm = texture(pal_tex, vec2(pu, 0.875));
	float takes_snow = base4.a;

	// ---- surface ------------------------------------------------------------
	// Three scales stacked: a macro field far larger than the screen so the
	// ground has weather at the kilometre scale, a mid field at a few tiles, and
	// a fine field the player only sees when zoomed in.
	float macro = fbm2(t * 0.055 + vec2(101.0, 7.0));
	float mid = fbm3(t * 0.62);
	float fine = n1(t * 5.3 + vec2(3.0, 91.0));
	float h = mid * 0.58 + macro * 0.42;
	float v = clamp(h * 1.24 + fine * 0.16 * detail - 0.18, 0.0, 1.0);

	vec3 albedo = mix(low, high, v);
	albedo = mix(albedo, base, 0.40);
	// Macro tone drift: this is what stops a snowfield reading as one flat value
	// with a tile pattern printed on it.
	albedo *= (0.84 + macro * 0.34);

	// Wind-scoured ridges, sheared so they never line up with the axes.
	float ridge_n = fbm2(vec2(t.x + t.y * 0.42, t.y * 1.9) * 0.5);
	float ridge = 1.0 - abs(ridge_n * 2.0 - 1.0);
	albedo = mix(albedo, high, clamp((ridge - 0.62) * 2.4, 0.0, 1.0) * 0.55 * prm.g);
	albedo = mix(albedo, low, clamp((0.34 - ridge) * 1.7, 0.0, 1.0) * 0.28 * prm.g);

	float grain = (n1(t * 21.0) - 0.5) * prm.r * detail;
	albedo += vec3(grain, grain * 0.96, grain * 0.9);

	// ---- snow ---------------------------------------------------------------
	float depth = clamp(texture(snow_tex, muv).r * snow_scale, 0.0, 1.0) * takes_snow;
	float heat = texture(heat_tex, muv).r;
	depth *= clamp(1.0 - heat * 1.15, 0.0, 1.0);

	// Coverage is a threshold against world-space noise, not a per-tile stamp,
	// so the snow line crosses tile boundaries as a drift edge instead of
	// stepping along them. The band is wide on purpose: a hard cut is exactly
	// the staircase this replaces.
	float sn = fbm3(t * 0.78 + vec2(211.0, 17.0)) * 0.68 + fbm2(t * 0.11 + vec2(9.0)) * 0.32;
	float thr = 1.0 - depth * 1.22;
	float cover = smoothstep(thr - 0.22, thr + 0.20, sn + 0.06);
	cover *= smoothstep(0.0, 0.06, depth);

	float crest = clamp((sn - thr) * 2.6, 0.0, 1.0);
	vec3 snow_col = mix(snow_mid, snow_lit, crest);
	snow_col = mix(mix(snow_shadow, snow_mid, 0.55), snow_col, clamp(depth * 1.9, 0.35, 1.0));
	albedo = mix(albedo, snow_col, cover);

	// A rim of packed drift right at the edge of the cover reads as a real lip.
	float lip = cover * (1.0 - cover) * 4.0;
	albedo = mix(albedo, snow_lit, lip * 0.22);

	// ---- industrial soot ----------------------------------------------------
	float soot = texture(soot_tex, muv).r;
	float soot_mask = smoothstep(0.05, 0.62, soot) * (0.45 + 0.55 * fbm2(t * 1.35 + vec2(77.0)));
	albedo = mix(albedo, ash_col, clamp(soot_mask * 0.80, 0.0, 0.66));

	// Thawed, damp ground near a burning hearth.
	albedo = mix(albedo, albedo * vec3(1.16, 1.02, 0.88) + vec3(0.03, 0.012, 0.0), heat * 0.55);

	// ---- lighting -----------------------------------------------------------
	// Two extra fetches buy a real surface normal, which is the difference
	// between "the frame has been tinted orange" and "the low sun is raking
	// across a snowfield".
	float relief = mix(prm.a, 1.0, cover * 0.6);
	float e = 0.55;
	float hx = fbm2((t + vec2(e, 0.0)) * 0.62) - fbm2((t - vec2(e, 0.0)) * 0.62);
	float hy = fbm2((t + vec2(0.0, e)) * 0.62) - fbm2((t - vec2(0.0, e)) * 0.62);
	float amp = 2.6 * relief * (0.55 + 0.45 * detail);
	vec3 N = normalize(vec3(-hx * amp, -hy * amp, 1.0));
	vec3 L = normalize(vec3(sun_dir, 0.68));

	float ndl = clamp(dot(N, L) * 0.5 + 0.5, 0.0, 1.0);
	ndl = ndl * ndl * (3.0 - 2.0 * ndl);
	float city = texture(city_tex, muv).r;

	vec3 light = sun_col * (sun_energy * (0.12 + 1.05 * ndl));
	light += sky_col * (sky_energy * (0.72 + 0.28 * N.z));
	light += bounce_col * (bounce * clamp(city * 1.25, 0.0, 1.0) * 0.55);
	// Beyond the settlement the night is allowed to be a night.
	light *= mix(1.0 - wild, 1.0, clamp(city * 1.8, 0.0, 1.0));
	// Ground next to a fire is lit by the fire, in the fire's colour.
	light += warm_col * (heat * 0.55 * (0.35 + 0.65 * bounce));

	vec3 col = albedo * light;

	// Crystalline glint, only where snow is deep, only close in.
	float sp = n1(t * 17.0 + vec2(time_s * 0.05, 0.0));
	col += vec3(1.0, 1.0, 1.05) * step(0.9885, sp) * cover * prm.b * detail
		* (0.25 + sun_energy * 0.9);

	// Off the edge of the world.
	vec2 d = max(vec2(0.0) - muv, muv - vec2(1.0));
	col = mix(col, col * 0.22, clamp(max(d.x, d.y) * 10.0, 0.0, 1.0));

	COLOR = vec4(max(col, vec3(0.0)), 1.0);
}
