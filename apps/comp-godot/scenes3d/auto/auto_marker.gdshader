shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled;

#include "res://scenes3d/auto/overlay_color.gdshaderinc"

// Vertex colors are sRGB.
void fragment() {
	ALBEDO = overlay_color(COLOR.rgb, COLOR.a, SCREEN_UV);
	ALPHA = overlay_alpha(COLOR.a, SCREEN_UV);
}
