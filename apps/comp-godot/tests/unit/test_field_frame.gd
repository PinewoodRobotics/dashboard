extends TestCase


func _vec_near(a: Vector3, b: Vector3, tol: float, msg: String) -> void:
	check(a.distance_to(b) <= tol, "%s: expected %s, got %s" % [msg, b, a])


func test_corners_map_to_world() -> void:
	_vec_near(FieldFrame.to_world(0.0, 0.0), Vector3(8.2705, 0, -4.0345), 1e-5, "blue-right corner")
	_vec_near(FieldFrame.to_world(16.541, 8.069), Vector3(-8.2705, 0, 4.0345), 1e-5, "red-left corner")
	_vec_near(FieldFrame.to_world(8.2705, 4.0345), Vector3.ZERO, 1e-5, "center")
	var p := FieldFrame.from_world(FieldFrame.to_world(2.0, 4.03))
	check_near(p.x, 2.0, 1e-5)
	check_near(p.y, 4.03, 1e-5)


func test_heading_zero_faces_world_minus_x() -> void:
	_vec_near(FieldFrame.forward(0.0), Vector3(-1, 0, 0), 1e-5, "heading 0 faces the red wall")
	_vec_near(FieldFrame.forward(PI / 2.0), Vector3(0, 0, 1), 1e-5, "heading +90 deg faces +y = world +Z")
	check_near(FieldFrame.yaw(0.0), -PI / 2.0, 1e-12)
	var xf := FieldFrame.robot_transform(2.0, 4.03, 0.0)
	_vec_near(xf.origin, Vector3(6.2705, 0, -0.0045), 1e-5, "robot at (2, 4.03) is on the blue +X half")
	_vec_near(xf.basis * Vector3.BACK, Vector3(-1, 0, 0), 1e-5, "model +Z maps to forward")


func test_field_motion_is_a_proper_rotation() -> void:
	var a := FieldFrame.to_world(1.0, 0.0) - FieldFrame.to_world(0.0, 0.0)
	var b := FieldFrame.to_world(0.0, 1.0) - FieldFrame.to_world(0.0, 0.0)
	check_near(a.cross(b).dot(Vector3.UP), 1.0, 1e-5, "x cross y = up, no mirroring")


func test_pathplanner_flip() -> void:
	var f := FieldFrame.flip(Vector3(1.0, 2.0, 0.25))
	check_near(f.x, 15.54, 1e-5)
	check_near(f.y, 6.07, 1e-5)
	check_near(f.z, 0.25 + PI - TAU, 1e-5)
	var back := FieldFrame.flip(f)
	check_near(back.x, 1.0, 1e-5)
	check_near(back.y, 2.0, 1e-5)
	check_near(back.z, 0.25, 1e-5)


func test_dt_lerp() -> void:
	check_near(Smoothing.dt_lerp(0.15, 1.0 / 60.0), 0.15, 1e-5, "one 60 Hz frame equals the rate")
	check_near(Smoothing.dt_lerp(0.15, 2.0 / 60.0), 1.0 - 0.85 * 0.85, 1e-5, "two frames compound")
	check_eq(Smoothing.dt_lerp(0.5, 0.0), 0.0)


func test_lerp_angle_short_arc() -> void:
	check_near(Smoothing.lerp_angle(0.0, 1.0, 0.5), 0.5, 1e-5)
	check_near(Smoothing.lerp_angle(3.0, -3.0, 0.5), 3.0 + (TAU - 6.0) / 2.0, 1e-5, "crosses +-PI the short way")
	check_near(Smoothing.lerp_angle(-3.0, 3.0, 1.0), -3.0 - (TAU - 6.0), 1e-5)
	check_near(Smoothing.lerp_angle(0.0, 7.0, 1.0), 7.0 - TAU, 1e-5, "wraps targets beyond TAU")


func test_pose_smoother_snaps_above_1_5_m() -> void:
	var s := PoseSmoother.new()
	s.step(1.0, 1.0, 0.0, 0.016)
	check_eq(s.x, 1.0, "first sample snaps")
	s.step(2.6, 1.0, 1.0, 1.0 / 60.0)
	check_eq(s.x, 2.6, "1.6 m jump snaps")
	check_eq(s.heading, 1.0)
	s.step(3.6, 1.0, 1.0, 1.0 / 60.0)
	var t := minf(0.15 + 1.0 * 1.4, 0.95)
	check_near(s.x, 2.6 + 1.0 * t, 1e-5, "1.0 m step lerps with the adaptive rate")
	var s2 := PoseSmoother.new()
	s2.snap(0.0, 0.0, 3.0)
	s2.step(0.1, 0.0, -3.0, 1.0 / 60.0)
	var t2 := 0.15 + 0.1 * 1.4
	check_near(s2.heading, 3.0 + (TAU - 6.0) * t2, 1e-5, "heading takes the short arc")
	check_near(s2.x, 0.1 * t2, 1e-5)


func test_minimap_camera_math() -> void:
	check_near(MinimapCamera.target_phi(0.0), 1.35, 1e-12)
	check_near(MinimapCamera.target_phi(1.0), 0.08, 1e-12)
	check_near(MinimapCamera.target_dist(0.0), 11.05, 1e-12)
	check_near(MinimapCamera.target_dist(1.0), 2.0, 1e-12)
	check_near(MinimapCamera.desired_theta("follow", 0.3, null), 0.3 + PI / 2.0, 1e-12)
	check_near(MinimapCamera.desired_theta("driver", 0.3, true), -PI / 2.0, 1e-12)
	check_near(MinimapCamera.desired_theta("driver", 0.3, false), PI / 2.0, 1e-12)
	check_near(MinimapCamera.desired_theta("driver", 0.3, null), PI / 2.0, 1e-12, "unknown alliance = blue")
	var t := MinimapCamera.desired_target(Vector3(6.0, 0.0, -2.0), 0.5)
	check(t.is_equal_approx(Vector3(6.0, 0.3, -1.0)), "target z blends toward the robot with zoom")

	var cam := MinimapCamera.new()
	var settings := {"mode": "follow", "angle": 0.3, "zoom": 0.5}
	cam.step(0.016, Vector3(6.0, 0, 0), 0.0, settings, null)
	var pos := cam.position()
	check_near(pos.distance_to(cam.target), MinimapCamera.target_dist(0.5), 1e-5, "distance")
	check(pos.x > cam.target.x + 1.0, "follow camera at heading 0 sits behind the robot (+X)")
	check_near(acos((pos.y - cam.target.y) / cam.dist), MinimapCamera.target_phi(0.3), 1e-5, "polar angle")
	settings["zoom"] = 1.0
	cam.step(1.0 / 60.0, Vector3(6.0, 0, 0), 0.0, settings, null)
	check_near(cam.dist, 6.525 + (2.0 - 6.525) * 0.1, 1e-6, "distance eases at dt_lerp(0.1)")
