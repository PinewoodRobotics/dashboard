shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_lambert, specular_schlick_ggx;

#include "res://cad/cad_surface.gdshaderinc"

void fragment() {
	cad_surface(ALBEDO, METALLIC, ROUGHNESS, SPECULAR);
	RADIANCE = vec4(vec3(0.0), 1.0 - metallic);
}
