// Overlays keep their exact sRGB colors on screen although the views tone map:
// the color is blended over the tone-mapped scene behind it in display space,
// then sent through the inverse of the tone mapping. Matches CadLighting's
// Environment (Godot's ACES at EXPOSURE, WHITE making the fit's normalization 1).
const float OVERLAY_EXPOSURE = 0.925926;
const mat3 OVERLAY_RGB_TO_RRT = mat3(
		vec3(0.59719, 0.35458, 0.04823) * 1.8,
		vec3(0.07600, 0.90834, 0.01566) * 1.8,
		vec3(0.02840, 0.13383, 0.83777) * 1.8);
const mat3 OVERLAY_ODT_TO_RGB = mat3(
		vec3(1.60475, -0.53108, -0.07367),
		vec3(-0.10208, 1.10813, -0.00605),
		vec3(-0.00327, -0.07276, 1.07602));

uniform sampler2D overlay_scene : hint_screen_texture, filter_nearest;

vec3 overlay_srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 overlay_tonemap(vec3 hdr) {
	vec3 x = max(hdr * OVERLAY_EXPOSURE, vec3(0.0)) * OVERLAY_RGB_TO_RRT;
	vec3 y = (x * (x + 0.0245786) - 0.000090537) / (x * (0.983729 * x + 0.432951) + 0.238081);
	return clamp(y * OVERLAY_ODT_TO_RGB, vec3(0.0), vec3(1.0));
}

vec3 overlay_untonemap(vec3 display_linear) {
	vec3 z = clamp(display_linear * inverse(OVERLAY_ODT_TO_RGB), vec3(0.0), vec3(1.0));
	vec3 a = vec3(1.0) - 0.983729 * z;
	vec3 b = vec3(0.0245786) - 0.432951 * z;
	vec3 c = -(vec3(0.000090537) + 0.238081 * z);
	vec3 x = (-b + sqrt(b * b - 4.0 * a * c)) / (2.0 * a);
	return max(x * inverse(OVERLAY_RGB_TO_RRT) / OVERLAY_EXPOSURE, vec3(0.0));
}

// srgb: the overlay color as it should appear, alpha its coverage. Returns the
// HDR color to write with ALPHA = overlay_alpha(...).
vec3 overlay_color(vec3 srgb, float alpha, vec2 screen_uv) {
	vec4 behind = textureLod(overlay_scene, screen_uv, 0.0);
	vec3 shown = overlay_srgb_to_linear(srgb);
	if (behind.a > 0.5) {
		shown = mix(overlay_tonemap(behind.rgb), shown, alpha);
	}
	return overlay_untonemap(shown);
}

float overlay_alpha(float alpha, vec2 screen_uv) {
	return textureLod(overlay_scene, screen_uv, 0.0).a > 0.5 ? 1.0 : alpha;
}
