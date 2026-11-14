class_name CadMaterials
extends RefCounted

## One shared opaque and one shared blended ShaderMaterial for every CAD mesh in
## every viewport, applied as surface overrides so imported Mesh resources stay shared.

const OPAQUE_SHADER := preload("res://scenes3d/cad_material.gdshader")
const BLEND_SHADER := preload("res://scenes3d/cad_material_blend.gdshader")

## Brightness of a robot whose pose is not current (robot_pose_valid false or no live data).
const DIM := 0.35

static var _opaque: ShaderMaterial
static var _blend: ShaderMaterial
static var _opaque_dim: ShaderMaterial
static var _blend_dim: ShaderMaterial


static func opaque() -> ShaderMaterial:
	if _opaque == null:
		_opaque = ShaderMaterial.new()
		_opaque.shader = OPAQUE_SHADER
	return _opaque


static func blend() -> ShaderMaterial:
	if _blend == null:
		_blend = ShaderMaterial.new()
		_blend.shader = BLEND_SHADER
	return _blend


static func opaque_dim() -> ShaderMaterial:
	if _opaque_dim == null:
		_opaque_dim = ShaderMaterial.new()
		_opaque_dim.shader = OPAQUE_SHADER
		_opaque_dim.set_shader_parameter("dim", DIM)
	return _opaque_dim


static func blend_dim() -> ShaderMaterial:
	if _blend_dim == null:
		_blend_dim = ShaderMaterial.new()
		_blend_dim.shader = BLEND_SHADER
		_blend_dim.set_shader_parameter("dim", DIM)
	return _blend_dim


static func tintable() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = OPAQUE_SHADER
	return m


static func is_blend_surface(mesh: Mesh, surface: int) -> bool:
	var m := mesh.surface_get_material(surface)
	return m is BaseMaterial3D and (m as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED


static func apply(root: Node, skip: Array = [], dimmed: bool = false) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if skip.has(mi) or mi.mesh == null:
			continue
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for i in mi.mesh.get_surface_count():
			var blended := is_blend_surface(mi.mesh, i)
			if dimmed:
				mi.set_surface_override_material(i, blend_dim() if blended else opaque_dim())
			else:
				mi.set_surface_override_material(i, blend() if blended else opaque())
