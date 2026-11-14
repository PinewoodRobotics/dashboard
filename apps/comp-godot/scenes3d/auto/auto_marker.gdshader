shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// Vertex colors are sRGB and written as given, like cad_material.gdshader's output.
void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
}
