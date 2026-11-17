class_name CubeContent
extends ViewContent

## Phase 1's spinning cube: a scene with no assets, for bring-up and probes.

var cube: MeshInstance3D
var _t := 0.0


func _ready() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.18, 0.27)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.35, 0.4)
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	camera = Camera3D.new()
	add_child(camera)
	camera.look_at_from_position(Vector3(0, 1.6, 3.2), Vector3.ZERO)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	add_child(light)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.95, 0.55, 0.1)
	var mesh := BoxMesh.new()
	mesh.material = material
	cube = MeshInstance3D.new()
	cube.mesh = mesh
	add_child(cube)


func step(dt: float, _visible: bool) -> void:
	set_time(_t + dt)


func set_time(seconds: float) -> void:
	_t = seconds
	cube.rotation = Vector3(seconds * 0.6, seconds * 1.4, 0.0)
