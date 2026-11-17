shader_type sky;

// Never drawn (the views clear to transparent); it only feeds ambient light
// and metal reflections.
uniform vec3 sky_color = vec3(1.0);
uniform vec3 ground_color = vec3(0.0);

void sky() {
	COLOR = mix(ground_color, sky_color, smoothstep(-0.02, 0.02, EYEDIR.y));
}
