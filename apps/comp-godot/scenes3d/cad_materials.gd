class_name CadMaterials
extends RefCounted

## One shared opaque and one shared blended ShaderMaterial for every CAD mesh in
## every viewport, applied as surface overrides so imported Mesh resources stay shared.

const OPAQUE_SHADER := preload("res://scenes3d/cad_material.gdshader")
const BLEND_SHADER := preload("res://scenes3d/cad_material_blend.gdshader")

static var _opaque: ShaderMaterial
static var _blend: ShaderMaterial


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


## A per-instance opaque material whose tint can be changed (bumpers).
static func tintable() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = OPAQUE_SHADER
	return m


static func is_blend_surface(mesh: Mesh, surface: int) -> bool:
	var m := mesh.surface_get_material(surface)
	return m is BaseMaterial3D and (m as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED


## Overrides every surface below `root`, except the meshes listed in `skip`.
static func apply(root: Node, skip: Array = []) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if skip.has(mi) or mi.mesh == null:
			continue
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for i in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, blend() if is_blend_surface(mi.mesh, i) else opaque())
