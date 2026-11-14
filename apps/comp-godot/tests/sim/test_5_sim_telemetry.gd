extends TestCase

var nt: NtService
var telemetry: TelemetryService
var model: RobotModel


func before_each() -> void:
	if SimEnv.port() == 0:
		fail("PWRUP_SIM_PORT not set; run tools/test/run_sim_e2e.sh")
		return
	nt = NtHarness.make_service(tree, SimEnv.port())
	nt.subscribe_groups(Topics.subscription_groups(ConnectionSettings.DEFAULT_NT))
	telemetry = TelemetryService.new()
	telemetry.nt = nt
	tree.root.add_child(telemetry)
	model = (load("res://scenes3d/robot/robot_model.tscn") as PackedScene).instantiate()
	tree.root.add_child(model)
	if not model.is_loaded():
		model.attach(load(ModelsService.PATHS["robot"]))
	nt.start()


func after_each() -> void:
	if model != null:
		model.queue_free()
	if telemetry != null:
		telemetry.queue_free()
	NtHarness.dispose(nt)
	await next_frame()


func test_sim_pose_and_joints_reach_the_rig() -> void:
	if nt == null:
		return
	var live := func() -> bool:
		return nt.is_ready() and nt.is_live(Topics.JOINT_WRIST) and nt.is_live(Topics.JOINT_TURRET) and nt.is_live(TelemetryService.POSE_X)
	check(await wait_until(live, 15.0) >= 0.0, "wrist, turret and pose topics live from the sim")
	for i in 30:
		telemetry.step(1.0 / 60.0)
		var p := telemetry.smoothed_pose()
		model.set_field_pose(p.x, p.y, p.z)
		model.apply_joints(telemetry.rig, telemetry.joint_values)
		await next_frame()
	var raw_wrist: float = nt.value(Topics.JOINT_WRIST)
	var raw_turret: float = nt.value(Topics.JOINT_TURRET)
	note("sim pose %s valid=%s alliance_red=%s wrist=%.4f rot turret=%.4f rot" % [telemetry.pose_raw, telemetry.pose_valid, telemetry.alliance_red, raw_wrist, raw_turret])
	check(telemetry.has_pose, "pose received")
	check_near(telemetry.joint_targets["index_wrist"], RigSolver.transform_nt_value(telemetry.rig.joint("index_wrist"), raw_wrist), 1e-9, "wrist target from the live topic")
	check_near(telemetry.joint_targets["turret"], RigSolver.transform_nt_value(telemetry.rig.joint("turret"), raw_turret), 1e-9, "turret target from the live topic")
	check_eq(telemetry.joint_targets["climber_inner"], 0.0, "the FIR robot publishes no climber topic, so the default is used")
	var p := telemetry.smoothed_pose()
	check(model.transform.origin.distance_to(FieldFrame.to_world(p.x, p.y)) < 1e-4, "robot wrapper follows the sim pose")
	var wrist: Node3D = model.rig.nodes["IndexWristRControl"]
	check(wrist.transform.basis.is_equal_approx(model.rig.rest["IndexWristRControl"].basis * Basis(Vector3.RIGHT, telemetry.joint_values["index_wrist"])), "wrist node follows the sim value")
