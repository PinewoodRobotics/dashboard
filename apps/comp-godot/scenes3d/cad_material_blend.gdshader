shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

#include "res://scenes3d/cad_lighting.gdshaderinc"

void fragment() {
	ALBEDO = cad_shade(cad_world_normal(NORMAL, INV_VIEW_MATRIX), cad_world_normal(VIEW, INV_VIEW_MATRIX));
	ALPHA = albedo.a;
}
