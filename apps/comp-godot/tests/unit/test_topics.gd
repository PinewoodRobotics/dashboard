extends TestCase


func test_nt_path_trims_slashes() -> void:
	check_eq(Topics.nt_path("Shared", "PathPlanner/SelectedPath"), "/Shared/PathPlanner/SelectedPath")
	check_eq(Topics.nt_path(" /Shared/ ", "//Intake/Speed/"), "/Shared/Intake/Speed")


func test_request_state_topics() -> void:
	var t := Topics.selected_auto_topics(ConnectionSettings.DEFAULT_NT)
	check_eq(t["request"], "/Shared/PathPlanner/SelectedPath/Request")
	check_eq(t["state"], "/Shared/PathPlanner/SelectedPath/State")
	var i := Topics.intake_speed_topics({"sharedTable": "Other"})
	check_eq(i["request"], "/Other/Intake/Speed/Request")


func test_match_state_registry() -> void:
	check_eq(Topics.MATCH_STATE.size(), 28)
	check_eq(Topics.match_topic("seq"), "/matchhud/state/seq")
	check_eq(Topics.MATCH_STATE["seq"], "int")
	check_eq(Topics.MATCH_STATE["robot_heading_rad"], "double")
	check(Topics.MATCH_STATE_OPTIONAL.has("camera_topic"))


func test_subscription_groups() -> void:
	var g := Topics.subscription_groups(ConnectionSettings.DEFAULT_NT)
	check_eq(g.size(), 3)
	check_eq(g[0]["topics"], PackedStringArray(["/matchhud/state/"]))
	check_eq(g[0]["options"], {"prefix": true, "periodic": 0.02})
	check_eq(g[1]["options"]["periodic"], 0.02)
	check(g[1]["topics"].has(Topics.JOINT_TURRET))
	check_eq(g[2]["options"]["periodic"], 0.1)
	check(g[2]["topics"].has("/Shared/PathPlanner/SelectedPath/State"))
	check(g[2]["topics"].has(Topics.AIM_TRIM_READBACK))


func test_connection_settings_normalization() -> void:
	check_eq(ConnectionSettings.normalize_reconnect_timeout(1), 10)
	check_eq(ConnectionSettings.normalize_reconnect_timeout(2), 2)
	check_eq(ConnectionSettings.normalize_reconnect_timeout(59.6), 60)
	check_eq(ConnectionSettings.normalize_reconnect_timeout("5"), 10)
	var nt := ConnectionSettings.normalize_nt({"host": " 127.0.0.1 ", "port": 5811.0, "sharedTable": ""})
	check_eq(nt["host"], "127.0.0.1")
	check_eq(nt["port"], 5811)
	check_eq(nt["sharedTable"], "Shared")
	check_eq(ConnectionSettings.normalize_nt(null)["host"], "10.47.65.2")
