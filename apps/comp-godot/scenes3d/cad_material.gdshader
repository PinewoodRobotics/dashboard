shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

#include "res://scenes3d/cad_lighting.gdshaderinc"

uniform vec4 tint : source_color = vec4(1.0);
uniform float use_tint : hint_range(0.0, 1.0) = 0.0;
uniform float dim : hint_range(0.0, 1.0) = 1.0;

varying vec3 v_front;
varying vec3 v_back;

void vertex() {
	vec3 n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 base = mix(COLOR.rgb, cad_srgb_to_linear(tint.rgb), use_tint) * dim;
	v_front = cad_linear_to_srgb(base * cad_irradiance(n));
	v_back = cad_linear_to_srgb(base * cad_irradiance(-n));
}

void fragment() {
	ALBEDO = FRONT_FACING ? v_front : v_back;
}
