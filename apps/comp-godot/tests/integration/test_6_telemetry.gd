extends TestCase

## Pose, alliance and joints from the fake robot (real ntcore) drive Telemetry
## and the robot model nodes.

var robot: FakeRobotProc
var nt: NtService
var telemetry: TelemetryService
var model: RobotModel
var pubs := {}


func before_each() -> void:
	robot = FakeRobotProc.from_env()
	if robot == null:
		fail("PWRUP_FAKE_ROBOT_PORT not set; run tools/test/run_integration.sh")
		return
	nt = NtHarness.make_service(tree, robot.port)
	nt.subscribe_groups(Topics.subscription_groups(ConnectionSettings.DEFAULT_NT))
	pubs = {
		"pose": nt.publisher("/fake/control/pose", "double[]"),
		"wrist": nt.publisher("/fake/control/wrist", "double"),
		"turret": nt.publisher("/fake/control/turret", "double"),
		"alliance": nt.publisher("/fake/control/alliance", "string"),
	}
	telemetry = TelemetryService.new()
	telemetry.nt = nt
	tree.root.add_child(telemetry)
	model = (load("res://scenes3d/robot/robot_model.tscn") as PackedScene).instantiate()
	tree.root.add_child(model)
	if not model.is_loaded():
		model.attach(load(ModelsService.PATHS["robot"]))
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready() and nt.is_live(Topics.JOINT_TURRET), 5.0)


func after_each() -> void:
	if model != null:
		model.queue_free()
	if telemetry != null:
		telemetry.queue_free()
	NtHarness.dispose(nt)
	await next_frame()


func _drive() -> void:
	telemetry.step(1.0 / 60.0)
	var p := telemetry.smoothed_pose()
	model.set_field_pose(p.x, p.y, p.z)
	model.apply_joints(telemetry.rig, telemetry.joint_values)
	model.set_alliance(telemetry.alliance_red)


func _settled(pose: Vector3, turret_rad: float) -> Callable:
	return func() -> bool:
		_drive()
		var p := telemetry.smoothed_pose()
		return Vector3(p.x, p.y, p.z).distance_to(pose) < 1e-3 and absf(telemetry.joint_values.get("turret", 99.0) - turret_rad) < 1e-3


func test_pose_joints_and_alliance_follow_the_fake_robot() -> void:
	if nt == null:
		return
	pubs["pose"].set_value(PackedFloat64Array([2.0, 4.03, 0.0]))
	pubs["wrist"].set_value(0.3)
	pubs["turret"].set_value(0.25)
	pubs["alliance"].set_value("red")
	var el := await wait_until(_settled(Vector3(2.0, 4.03, 0.0), -PI / 2.0), 5.0)
	check(el >= 0.0, "telemetry settles on the published pose and turret")
	check(telemetry.has_pose and telemetry.pose_valid, "pose received and valid")
	check_eq(telemetry.alliance_red, true, "alliance red")
	check_near(telemetry.joint_targets["index_wrist"], -1.8221, 1e-4, "wrist golden through NT")
	check_near(telemetry.joint_values["turret_gear"], PI / 2.0, 1e-3)
	check(model.transform.is_equal_approx(FieldFrame.robot_transform(2.0, 4.03, 0.0)) or model.transform.origin.distance_to(FieldFrame.to_world(2.0, 4.03)) < 1e-3, "robot wrapper at the field pose")
	check(model.transform.origin.x > 0.0, "on the blue half")
	var turret: Node3D = model.rig.nodes["TurretRControl"]
	check(turret.transform.basis.is_equal_approx(model.rig.rest["TurretRControl"].basis * Basis(Vector3.UP, telemetry.joint_values["turret"])), "turret node follows")
	check_eq(model.rig.bumper_material.get_shader_parameter("tint"), RobotRig.RED, "bumpers red")

	pubs["pose"].set_value(PackedFloat64Array([2.5, 4.03, PI / 2.0]))
	pubs["turret"].set_value(0.75)
	pubs["alliance"].set_value("blue")
	el = await wait_until(_settled(Vector3(2.5, 4.03, PI / 2.0), PI / 2.0), 5.0)
	check(el >= 0.0, "a 0.5 m move and a turret change are followed (smoothed, not snapped)")
	check_eq(telemetry.alliance_red, false, "alliance blue")
	check_eq(model.rig.bumper_material.get_shader_parameter("tint"), RobotRig.BLUE, "bumpers blue")
	check(FieldFrame.forward(telemetry.smoothed_pose().z).distance_to(Vector3(0, 0, 1)) < 1e-3, "heading +90 deg faces world +Z")


func test_joints_fall_back_to_defaults_when_disconnected() -> void:
	if nt == null:
		return
	pubs["turret"].set_value(0.25)
	var turret_live := func() -> bool:
		_drive()
		return absf(telemetry.joint_values.get("turret", 99.0) + PI / 2.0) < 1e-3
	check(await wait_until(turret_live, 5.0) >= 0.0, "turret live")
	nt.stop()
	await wait_until(func() -> bool: return not nt.is_ready(), 3.0)
	for i in 30:
		_drive()
	check_eq(telemetry.alliance_red, null, "alliance unknown while disconnected")
	check_near(telemetry.joint_targets["turret"], 0.0, 1e-9, "turret target falls back to its default")
	check(telemetry.has_pose, "last pose kept (stale) like the web minimap")
