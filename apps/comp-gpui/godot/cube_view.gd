class_name CubeView
extends SubViewport

var cube: MeshInstance3D


func _init(view_size: Vector2i) -> void:
	size = view_size
	own_world_3d = true
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.18, 0.27)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.35, 0.4)
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.6, 3.2)
	add_child(camera)
	camera.look_at_from_position(camera.position, Vector3.ZERO)

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


func set_time(seconds: float) -> void:
	cube.rotation = Vector3(seconds * 0.6, seconds * 1.4, 0.0)
