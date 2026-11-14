class_name RobotModel
extends Node3D

## PoseWrapper (this node: field position and yaw) -> CadUp (CAD Z-up to Y-up)
## -> imported robot.glb. Attaches the model when the Models service has it.

signal model_attached

@onready var cad_up: Node3D = $CadUp

var model: Node3D
var rig: RobotRig
var _pending_alliance: Variant = null


func _ready() -> void:
	var models := get_node_or_null("/root/Models") as ModelsService
	if models != null:
		models.when_ready("robot", attach)


func attach(scene: PackedScene) -> void:
	if model != null or not is_inside_tree():
		return
	model = scene.instantiate() as Node3D
	cad_up.add_child(model)
	rig = RobotRig.new(model)
	CadMaterials.apply(model, [rig.bumper])
	rig.set_alliance(_pending_alliance)
	model_attached.emit()


func is_loaded() -> bool:
	return rig != null


func apply_joints(solver: RigSolver, values: Dictionary) -> void:
	if rig != null:
		rig.apply(solver, values)


func set_alliance(is_red: Variant) -> void:
	_pending_alliance = is_red
	if rig != null:
		rig.set_alliance(is_red)


func set_field_pose(x: float, y: float, heading: float) -> void:
	transform = FieldFrame.robot_transform(x, y, heading)


func mesh_instances() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if model != null:
		out.assign(model.find_children("*", "MeshInstance3D", true, false))
	return out
