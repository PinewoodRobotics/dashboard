// Fixed CAD lighting shared by every 3D view: hemisphere sky/ground plus three
// directional lights (directions from the web minimap), evaluated per vertex.
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

vec3 cad_irradiance(vec3 n) {
	vec3 hemi = mix(GROUND, SKY, 0.5 + 0.5 * n.y) * HEMI;
	float d = KEY * max(dot(n, KEY_DIR), 0.0) + FILL * max(dot(n, FILL_DIR), 0.0) + BACK * max(dot(n, BACK_DIR), 0.0);
	return hemi + vec3(d);
}

vec3 cad_linear_to_srgb(vec3 c) {
	c = clamp(c, vec3(0.0), vec3(1.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 cad_srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
