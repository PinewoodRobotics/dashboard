shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// Colors are written as given (sRGB), like cad_material.gdshader's output.
// UV.x is the playback time of the vertex, UV.y runs across the strip.
uniform float progress = 0.0;
uniform vec4 done_color = vec4(0.439, 0.804, 0.208, 1.0);
uniform vec4 todo_color = vec4(1.0, 1.0, 1.0, 0.6);

void fragment() {
	vec4 c = UV.x <= progress ? done_color : todo_color;
	float edge = 1.0 - smoothstep(0.7, 1.0, abs(UV.y * 2.0 - 1.0));
	ALBEDO = c.rgb;
	ALPHA = c.a * mix(0.35, 1.0, edge);
}
