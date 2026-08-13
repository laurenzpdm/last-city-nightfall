shader_type canvas_item;
render_mode blend_disabled, unshaded;

// Full-screen grade + bloom + vignette + grain + cold chromatic split. [P13]
//
// Written for the GL Compatibility renderer: no textureLod on the screen
// texture, no derivatives, constant loop bounds, no dynamic branching on
// texture reads. Every effect is individually scalable to 0 so Settings.graphics
// can switch it off without swapping shaders.

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

uniform vec3 grade_lift = vec3(0.0);
uniform vec3 grade_gain = vec3(1.0);
uniform float saturation = 1.0;

uniform float bloom_strength = 1.0;
uniform float bloom_threshold = 0.52;

uniform float vignette_strength = 0.55;
uniform float grain_strength = 0.045;
uniform float chroma_strength = 0.4;

uniform vec3 fog_color = vec3(0.08, 0.12, 0.21);
uniform float fog_amount = 0.25;

uniform float time_s = 0.0;
uniform vec2 screen_px = vec2(1920.0, 1080.0);

// Heat shimmer. The ground's heat field, mapped through the visible world rect,
// so hot air over a hearth or a radiator bends what is behind it. Bound to a 1x1
// black texture until the world exists — an unbound sampler reads white and
// would shimmer the whole frame.
uniform sampler2D heat_tex : repeat_disable, filter_linear;
uniform vec2 view_origin = vec2(0.0);
uniform vec2 view_size = vec2(1920.0, 1080.0);
uniform vec2 map_px = vec2(8192.0, 8192.0);
uniform float shimmer_amount = 0.0;

const int RING_TAPS = 8;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 c = uv - vec2(0.5);
	float r2 = dot(c, c);

	// --- heat shimmer -------------------------------------------------------
	float haze = 0.0;
	if (shimmer_amount > 0.001) {
		vec2 wp = view_origin + uv * view_size;
		haze = texture(heat_tex, wp / map_px).r;
		if (haze > 0.01) {
			// Rising air: the horizontal wobble is the loud one, and both terms
			// climb as the air leaves the source, which is what makes it read as
			// convection rather than as a wet lens.
			float rise = time_s * 2.6;
			float w1 = sin(wp.y * 0.085 - rise * 1.7 + wp.x * 0.021);
			float w2 = sin(wp.x * 0.130 + rise * 1.1);
			float w3 = sin(wp.y * 0.240 - rise * 2.9);
			vec2 push = vec2(w1 * 0.66 + w3 * 0.24, w2 * 0.28 - 0.35);
			uv += push * haze * haze * shimmer_amount / screen_px * 3.4;
		}
	}

	// Cold split: at low temperature the blue channel is pushed outward, which
	// gives the frame a faint ache without touching the colour grade itself.
	vec2 off = c * chroma_strength * 0.0042 * (0.30 + r2 * 1.6);
	vec3 col;
	col.r = texture(screen_tex, uv - off).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv + off).b;
	// The air over a fire is warmer than the air beside it, and warm air scatters.
	col += vec3(0.055, 0.028, 0.010) * haze * haze * min(shimmer_amount, 1.6);

	if (bloom_strength > 0.001) {
		vec2 px = vec2(1.0) / screen_px;
		vec3 bloom = vec3(0.0);
		for (int i = 0; i < RING_TAPS; i++) {
			float a = 6.2831853 * float(i) / float(RING_TAPS);
			vec2 d = vec2(cos(a), sin(a));
			vec3 s1 = texture(screen_tex, uv + d * px * 4.0).rgb;
			vec3 s2 = texture(screen_tex, uv + d * px * 12.0).rgb;
			vec3 s3 = texture(screen_tex, uv + d * px * 26.0).rgb;
			bloom += max(s1 - vec3(bloom_threshold), vec3(0.0)) * 0.50;
			bloom += max(s2 - vec3(bloom_threshold), vec3(0.0)) * 0.31;
			bloom += max(s3 - vec3(bloom_threshold), vec3(0.0)) * 0.17;
		}
		bloom /= float(RING_TAPS);
		// Warm sources flare; cold highlights such as snow stay crisp.
		float warmth = clamp(bloom.r - bloom.b, 0.0, 1.0);
		col += bloom * bloom_strength * (0.55 + warmth * 2.1);
	}

	// Low haze that thickens toward the bottom of the frame — reads as cold air
	// pooling on the ground and pushes the horizon away.
	col = mix(col, fog_color, fog_amount * smoothstep(0.05, 0.95, uv.y) * 0.55);

	col = col * grade_gain + grade_lift;

	float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(l), col, saturation);

	float v = smoothstep(1.05, 0.10, r2 * 2.2);
	col *= mix(1.0, v, vignette_strength);

	if (grain_strength > 0.001) {
		vec2 g = uv * screen_px + vec2(time_s * 17.3, time_s * 11.9);
		float n = fract(sin(dot(g, vec2(12.9898, 78.233))) * 43758.5453);
		// Grain lives in the shadows, where film grain actually lives.
		float shadow_mask = 1.0 - smoothstep(0.0, 0.65, l);
		col += vec3(n - 0.5) * grain_strength * (0.35 + shadow_mask);
	}

	COLOR = vec4(max(col, vec3(0.0)), 1.0);
}
