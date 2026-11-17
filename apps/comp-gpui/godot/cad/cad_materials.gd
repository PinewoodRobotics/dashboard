class_name CadMaterials
extends RefCounted

## ShaderMaterials for the CAD meshes, built from each surface's imported glTF
## material and shared by every view with the same parameters, applied as
## surface overrides so imported Mesh resources stay shared.

const OPAQUE_SHADER := preload("res://cad/cad_material.gdshader")
const BLEND_SHADER := preload("res://cad/cad_material_blend.gdshader")

## Brightness of a robot whose pose is not current (robot_pose_valid false or no live data).
const DIM := 0.35

static var _shared := {}


static func is_blend(source: Material) -> bool:
	return source is BaseMaterial3D and (source as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED


## Godot's glTF importer stores baseColorFactor sRGB-encoded in albedo_color;
## the shader wants it linear again. matte drops metallic and roughness: the
## field export marks every opaque material metallic 1, roughness 0.21 (an
## exporter default, carpet included), which renders the floor as a mirror with
## a sun highlight, so the field is shaded matte like the web minimap does.
static func params(source: Material, matte: bool = false) -> Dictionary:
	var p := {"albedo": Color(1, 1, 1, 1), "metallic": 1.0, "roughness": 1.0}
	if source is BaseMaterial3D:
		var m := source as BaseMaterial3D
		var linear := m.albedo_color.srgb_to_linear()
		linear.a = m.albedo_color.a
		p = {"albedo": linear, "metallic": m.metallic, "roughness": m.roughness}
	if matte:
		p["metallic"] = 0.0
		p["roughness"] = 1.0
	return p


static func create(source: Material, dim: float = 1.0, matte: bool = false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = BLEND_SHADER if is_blend(source) else OPAQUE_SHADER
	var p := params(source, matte)
	for k: String in p:
		m.set_shader_parameter(k, vec4(p[k]) if p[k] is Color else p[k])
	m.set_shader_parameter("dim", dim)
	return m


## Shader colors go in as Vector4: the Forward+ renderer converts a Color set on
## any vec4 uniform from sRGB to linear, the Compatibility renderer does not.
static func vec4(c: Color) -> Vector4:
	return Vector4(c.r, c.g, c.b, c.a)


static func shared(source: Material, dimmed: bool, matte: bool = false) -> ShaderMaterial:
	var p := params(source, matte)
	var key := [p["albedo"], p["metallic"], p["roughness"], is_blend(source), dimmed]
	if not _shared.has(key):
		_shared[key] = create(source, DIM if dimmed else 1.0, matte)
	return _shared[key]


static func apply(root: Node, skip: Array = [], dimmed: bool = false, matte: bool = false) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if skip.has(mi) or mi.mesh == null:
			continue
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for i in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, shared(mi.mesh.surface_get_material(i), dimmed, matte))
