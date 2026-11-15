shader_type canvas_item;

// One pass of a separable gaussian over the back buffer, edge-clamped to the
// node's rect. Taps are paired into single bilinear reads.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform vec2 dir = vec2(1.0, 0.0);
uniform float sigma_px = 4.0;
uniform vec2 rect_px = vec2(1.0);

float g(float x) {
	return exp(-x * x / (2.0 * sigma_px * sigma_px));
}

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE;
	vec2 lo = SCREEN_UV - UV * rect_px * px + 0.5 * px;
	vec2 hi = lo + rect_px * px - px;
	int r = int(ceil(sigma_px * 3.0));
	vec3 acc = texture(screen_tex, clamp(SCREEN_UV, lo, hi)).rgb;
	float wsum = 1.0;
	for (int i = 1; i <= r; i += 2) {
		float w1 = g(float(i));
		float w2 = g(float(i + 1));
		float w = w1 + w2;
		vec2 o = dir * px * ((float(i) * w1 + float(i + 1) * w2) / w);
		acc += (texture(screen_tex, clamp(SCREEN_UV + o, lo, hi)).rgb + texture(screen_tex, clamp(SCREEN_UV - o, lo, hi)).rgb) * w;
		wsum += 2.0 * w;
	}
	COLOR = vec4(acc / wsum, 1.0);
}
