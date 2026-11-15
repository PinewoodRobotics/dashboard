// Fixed CAD lighting shared by every 3D view: a sky/ground hemisphere plus
// three directional lights (directions from the web minimap), evaluated per
// pixel on each surface's own glTF material (base color, metallic, roughness).
// Metals reflect the hemisphere, since the views have no environment map.
// The Compatibility renderer neither linearizes source_color uniforms nor
// encodes the output, so lighting is done on linear colors here and the result
// is sRGB-encoded explicitly (matching three.js linear workflow + sRGB output).
const vec3 SKY = vec3(1.0);
const vec3 GROUND = vec3(0.058);
const float HEMI = 0.35;
const vec3 KEY_DIR = vec3(0.408248, 0.816497, 0.408248);
const float KEY = 0.5;
const vec3 FILL_DIR = vec3(-0.514496, 0.685994, -0.514496);
const float FILL = 0.25;
const vec3 BACK_DIR = vec3(0.0, 0.707107, -0.707107);
const float BACK = 0.12;

uniform vec4 albedo = vec4(1.0);
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform vec4 tint : source_color = vec4(1.0);
uniform float use_tint : hint_range(0.0, 1.0) = 0.0;
uniform float dim : hint_range(0.0, 1.0) = 1.0;

vec3 cad_sky(vec3 d) {
	return mix(GROUND, SKY, 0.5 + 0.5 * d.y);
}

vec3 cad_irradiance(vec3 n) {
	float d = KEY * max(dot(n, KEY_DIR), 0.0) + FILL * max(dot(n, FILL_DIR), 0.0) + BACK * max(dot(n, BACK_DIR), 0.0);
	return cad_sky(n) * HEMI + vec3(d);
}

// Normalized Blinn-Phong, the exponent matched to the GGX alpha of the roughness.
float cad_lobe(vec3 n, vec3 v, vec3 l, float shininess) {
	vec3 h = normalize(l + v);
	return pow(max(dot(n, h), 0.0), shininess) * (shininess + 8.0) * 0.0397887 * max(dot(n, l), 0.0);
}

vec3 cad_linear_to_srgb(vec3 c) {
	c = clamp(c, vec3(0.0), vec3(1.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 cad_srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

// n and v in world space, n facing the viewer. Returns sRGB.
vec3 cad_shade(vec3 n, vec3 v) {
	vec3 base = mix(albedo.rgb, cad_srgb_to_linear(tint.rgb), use_tint);
	float a = max(roughness * roughness, 0.02);
	float shininess = max(2.0 / (a * a) - 2.0, 1.0);
	vec3 f0 = mix(vec3(0.04), base, metallic);
	float fresnel = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 5.0);
	vec3 f = f0 + (max(vec3(1.0 - roughness), f0) - f0) * fresnel;
	float direct = KEY * cad_lobe(n, v, KEY_DIR, shininess) + FILL * cad_lobe(n, v, FILL_DIR, shininess) + BACK * cad_lobe(n, v, BACK_DIR, shininess);
	vec3 c = base * (1.0 - metallic) * cad_irradiance(n) + f0 * direct + f * cad_sky(reflect(-v, n));
	return cad_linear_to_srgb(c * dim);
}

vec3 cad_world_normal(vec3 view_normal, mat4 inv_view) {
	return normalize((inv_view * vec4(view_normal, 0.0)).xyz);
}
