shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

#include "res://scenes3d/cad_lighting.gdshaderinc"

uniform float dim : hint_range(0.0, 1.0) = 1.0;

varying vec4 v_front;
varying vec4 v_back;

void vertex() {
	vec3 n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 base = COLOR.rgb * dim;
	v_front = vec4(cad_linear_to_srgb(base * cad_irradiance(n)), COLOR.a);
	v_back = vec4(cad_linear_to_srgb(base * cad_irradiance(-n)), COLOR.a);
}

void fragment() {
	vec4 c = FRONT_FACING ? v_front : v_back;
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
