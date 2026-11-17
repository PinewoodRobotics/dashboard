// One glTF material (base color, metallic, roughness) under the view's lights.
// Colors arrive linear, as Vector4, from CadMaterials.
uniform vec4 albedo = vec4(1.0);
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform vec4 tint = vec4(1.0);
uniform float use_tint : hint_range(0.0, 1.0) = 0.0;
uniform float dim : hint_range(0.0, 1.0) = 1.0;

void cad_surface(out vec3 out_albedo, out float out_metallic, out float out_roughness, out float out_specular) {
	out_albedo = mix(albedo.rgb, tint.rgb, use_tint) * dim;
	out_metallic = metallic;
	out_roughness = roughness;
	out_specular = 0.5 * dim;
}
