// HUD minimap frame (MiniMap3D.tsx): rounded top corners (border-radius 30% 30% 0 0,
// elliptical) and the inset black box-shadow (blur 5vw, spread 3.5vw), evaluated
// analytically on the SubViewportContainer so it costs no extra pass.
shader_type canvas_item;

uniform vec2 rect_size = vec2(840.0, 619.2);
uniform vec2 radius = vec2(252.0, 185.76);
uniform float blur = 96.0;
uniform float spread = 67.2;

// Signed distance to an ellipse centered at the origin, positive outside (iq's approximation).
float sd_ellipse(vec2 p, vec2 r) {
	float k0 = length(p / r);
	float k1 = length(p / (r * r));
	return k0 * (k0 - 1.0) / max(k1, 1e-6);
}

// Distance from p to the boundary of a size-sized box with elliptical top corners, positive inside.
float inside_dist(vec2 p, vec2 size, vec2 r) {
	float d = min(min(p.x, size.x - p.x), min(p.y, size.y - p.y));
	if (p.y < r.y) {
		if (p.x < r.x) {
			d = -sd_ellipse(p - r, r);
		} else if (p.x > size.x - r.x) {
			d = -sd_ellipse(p - vec2(size.x - r.x, r.y), r);
		}
	}
	return d;
}

// Abramowitz-Stegun 7.1.26 erf, max error 1.5e-7.
float erf_as(float x) {
	float s = sign(x);
	float a = abs(x);
	float t = 1.0 / (1.0 + 0.3275911 * a);
	float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-a * a);
	return s * y;
}

void fragment() {
	vec2 p = UV * rect_size;
	float mask = clamp(inside_dist(p, rect_size, radius) + 0.5, 0.0, 1.0);
	vec2 inner_size = rect_size - 2.0 * spread;
	vec2 inner_r = max(radius - spread, vec2(1e-3));
	float d_in = inside_dist(p - spread, inner_size, inner_r);
	float sigma = blur * 0.5;
	float shadow = 0.5 * (1.0 - erf_as(d_in / (sigma * 1.41421356)));
	COLOR.rgb *= 1.0 - shadow;
	COLOR.a *= mask;
}
