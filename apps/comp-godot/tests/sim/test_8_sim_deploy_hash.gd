extends TestCase

var nt: NtService


func before_each() -> void:
	if SimEnv.port() == 0:
		fail("PWRUP_SIM_PORT not set; run tools/test/run_sim_e2e.sh")
		return
	nt = NtHarness.make_service(tree, SimEnv.port())
	nt.subscribe_groups(Topics.subscription_groups(ConnectionSettings.DEFAULT_NT))


func after_each() -> void:
	NtHarness.dispose(nt)
	await next_frame()


func test_robot_deploy_hash_is_compared_with_the_export() -> void:
	if nt == null:
		return
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready(), 10.0)
	var el := await wait_until(func() -> bool: return str(nt.value(Topics.PP_DEPLOY_HASH, "")).length() == 64, 5.0)
	check(el >= 0.0, "the robot publishes PathPlanner/DeployHash: %s" % [nt.value(Topics.PP_DEPLOY_HASH)])
	var robot := str(nt.value(Topics.PP_DEPLOY_HASH, ""))
	var lib := AutoLibrary.load_best([AutoLibrary.BUILTIN_DIR])
	var f := ExportFreshness.check(lib.exported_at(), lib.exported_source_hash(), robot, Time.get_unix_time_from_system())
	note("robot %s, export %s: %s" % [robot.left(12), lib.exported_source_hash().left(12), f["text"]])
	check_eq(f["level"], ExportFreshness.Level.MATCHES_ROBOT if robot == lib.exported_source_hash() else ExportFreshness.Level.DIFFERS)
	check_eq(robot, AutoLibrary.source_hash("res://data/pathplanner"), "the robot's deploy folder is the one the export was made from")
