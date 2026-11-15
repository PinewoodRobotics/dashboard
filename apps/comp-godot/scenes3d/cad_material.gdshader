shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

#include "res://scenes3d/cad_lighting.gdshaderinc"

void fragment() {
	ALBEDO = cad_shade(cad_world_normal(NORMAL, INV_VIEW_MATRIX), cad_world_normal(VIEW, INV_VIEW_MATRIX));
}
