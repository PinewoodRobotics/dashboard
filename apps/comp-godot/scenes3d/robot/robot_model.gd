class_name RobotModel
extends Node3D

## PoseWrapper (this node: field position and yaw) -> CadUp (CAD Z-up to Y-up)
## -> imported robot.glb. Attaches the model when the Models service has it.

signal model_attached

@onready var cad_up: Node3D = $CadUp

var model: Node3D
var rig: RobotRig
var _pending_alliance: Variant = null
var dimmed := false


var lite := false
var _generation := 0
var _models: ModelsService


func _ready() -> void:
	_models = get_node_or_null("/root/Models") as ModelsService
	if _models != null:
		_models.when_ready(_key(), _attach_if_current.bind(_key()))
		_models.model_ready.connect(_on_model_ready)


func _key() -> String:
	return ModelsService.key_for("robot", lite)


func _on_model_ready(key: String) -> void:
	if key == _key() and model != null and int(_models.generation.get(key, 0)) != _generation:
		_detach()
		attach(_models.scenes[key])


func _detach() -> void:
	if model == null:
		return
	var old := model
	model = null
	rig = null
	old.free()


func _attach_if_current(scene: PackedScene, key: String) -> void:
	if key == _key():
		attach(scene)


func set_lite(on: bool) -> void:
	if on == lite:
		return
	lite = on
	if _models == null or not is_inside_tree():
		return
	_detach()
	_models.when_ready(_key(), _attach_if_current.bind(_key()))


func attach(scene: PackedScene) -> void:
	if model != null or not is_inside_tree():
		return
	if _models != null:
		_generation = int(_models.generation.get(_key(), 0))
	model = scene.instantiate() as Node3D
	cad_up.add_child(model)
	rig = RobotRig.new(model)
	CadMaterials.apply(model, [rig.bumper], dimmed)
	rig.set_alliance(_pending_alliance)
	rig.set_dim(CadMaterials.DIM if dimmed else 1.0)
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


func set_dimmed(on: bool) -> void:
	if on == dimmed:
		return
	dimmed = on
	if rig != null:
		CadMaterials.apply(model, [rig.bumper], on)
		rig.set_dim(CadMaterials.DIM if on else 1.0)


func set_field_pose(x: float, y: float, heading: float) -> void:
	transform = FieldFrame.robot_transform(x, y, heading)


func mesh_instances() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if model != null:
		out.assign(model.find_children("*", "MeshInstance3D", true, false))
	return out
