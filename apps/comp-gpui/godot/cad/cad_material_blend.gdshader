shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never, diffuse_lambert, specular_schlick_ggx;

#include "res://cad/cad_surface.gdshaderinc"

void fragment() {
	cad_surface(ALBEDO, METALLIC, ROUGHNESS, SPECULAR);
	RADIANCE = vec4(vec3(0.0), 1.0 - metallic);
	ALPHA = albedo.a;
}
