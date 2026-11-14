extends TestCase


func test_on_the_start_pose() -> void:
	var c := StartPoseCheck.compare(Vector3(3.37, 4.03, 2.36), Vector3(3.40, 4.10, 2.40))
	check_near(c["dist_m"], Vector2(0.03, 0.07).length(), 1e-5)
	check_near(c["heading_deg"], rad_to_deg(0.04), 1e-4)
	check_eq(c["level"], StartPoseCheck.Level.OK)
	check_eq(StartPoseCheck.text(c), "On start pose (0.08 m / 2°)")


func test_off_by_distance_or_heading() -> void:
	var far := StartPoseCheck.compare(Vector3(1.0, 2.0, 0.0), Vector3(3.0, 2.0, 0.0))
	check_eq(far["level"], StartPoseCheck.Level.OFF)
	check_eq(StartPoseCheck.text(far), "Start pose off by 2.00 m / 0°")
	var turned := StartPoseCheck.compare(Vector3(3.0, 2.0, deg_to_rad(20.0)), Vector3(3.0, 2.0, 0.0))
	check_eq(turned["level"], StartPoseCheck.Level.OFF, "position alone is not enough")
	check_eq(StartPoseCheck.text(turned), "Start pose off by 0.00 m / 20°")
	var edge := StartPoseCheck.compare(Vector3.ZERO, Vector3(StartPoseCheck.OK_M - 1e-4, 0.0, deg_to_rad(StartPoseCheck.OK_DEG - 0.01)))
	check_eq(edge["level"], StartPoseCheck.Level.OK, "just inside both tolerances")
	check_eq(StartPoseCheck.distance_text(12.345), "12.3 m")


func test_heading_wraps() -> void:
	var c := StartPoseCheck.compare(Vector3(1, 1, deg_to_rad(179.0)), Vector3(1, 1, deg_to_rad(-179.0)))
	check_near(c["heading_deg"], 2.0, 1e-4)
	check_eq(c["level"], StartPoseCheck.Level.OK)


func test_invalid_pose() -> void:
	var c := StartPoseCheck.compare(Vector3(1, 1, 0), Vector3(1, 1, 0), false)
	check_eq(c["level"], StartPoseCheck.Level.INVALID)
	check_eq(StartPoseCheck.text(c), "Start pose unknown: robot pose not valid")
	check_eq(StartPoseCheck.text({}), "")
