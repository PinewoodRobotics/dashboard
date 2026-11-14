class_name RobotRig
extends RefCounted

## Applies RigSolver joint values to the imported robot nodes, relative to the
## rest transforms cached at load. Revolute axes are in the node's local frame,
## prismatic axes in its parent frame (same conventions as the web viewers).

const BUMPER_NODE := "BumperPlane"
const RED := Color("#dd1111")
const BLUE := Color("#1111dd")

var nodes := {}
var rest := {}
var bumper: MeshInstance3D
var bumper_material: ShaderMaterial
var _alliance: Variant = null
var _alliance_applied := false


func _init(model_root: Node) -> void:
	_index(model_root)
	bumper = nodes.get(BUMPER_NODE) as MeshInstance3D


func _index(n: Node) -> void:
	if n is Node3D:
		nodes[String(n.name)] = n
		rest[String(n.name)] = (n as Node3D).transform
	for c in n.get_children():
		_index(c)


static func joint_transform(rest_xf: Transform3D, revolute: bool, axis: Vector3, value: float) -> Transform3D:
	if revolute:
		return Transform3D(rest_xf.basis * Basis(axis, value), rest_xf.origin)
	return Transform3D(rest_xf.basis, rest_xf.origin + axis * value)


func apply(solver: RigSolver, values: Dictionary) -> void:
	for j in solver.joints:
		var n: Node3D = nodes.get(j.node_name)
		if n == null:
			continue
		n.transform = joint_transform(rest[j.node_name], j.revolute, j.axis, values.get(j.key, j.default_value))


## Gives the bumper its own material instance so recoloring one robot never
## touches another; the shared mesh is left alone.
func ensure_bumper_material() -> void:
	if bumper == null or bumper_material != null:
		return
	bumper_material = CadMaterials.tintable()
	for i in bumper.mesh.get_surface_count():
		bumper.set_surface_override_material(i, bumper_material)


func set_dim(factor: float) -> void:
	ensure_bumper_material()
	if bumper_material != null:
		bumper_material.set_shader_parameter("dim", factor)


## true = red, false = blue, null = unknown (model color).
func set_alliance(is_red: Variant) -> void:
	ensure_bumper_material()
	if bumper_material == null or (_alliance_applied and is_red == _alliance):
		return
	_alliance = is_red
	_alliance_applied = true
	if is_red == null:
		bumper_material.set_shader_parameter("use_tint", 0.0)
	else:
		bumper_material.set_shader_parameter("use_tint", 1.0)
		bumper_material.set_shader_parameter("tint", RED if is_red else BLUE)
