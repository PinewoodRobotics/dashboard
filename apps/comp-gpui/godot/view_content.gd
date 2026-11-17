class_name ViewContent
extends Node3D

## What one host view shows, built inside its SubViewport. Subclasses place the
## camera every Godot frame in step() and react to host pointers.

var camera: Camera3D
var models: Models


func step(_dt: float, _visible: bool) -> void:
	pass


func handle_pointer(_p: Dictionary, _logical_size: Vector2) -> void:
	pass


func on_model_ready(_key: String) -> void:
	pass


## robot_model.tscn's CadUp: CAD Z-up to Godot Y-up.
static func cad_up() -> Node3D:
	var n := Node3D.new()
	n.name = "CadUp"
	n.transform = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), Vector3.ZERO)
	return n
