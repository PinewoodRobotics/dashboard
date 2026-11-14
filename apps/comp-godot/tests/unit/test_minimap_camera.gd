extends TestCase

## robot3d.md 5.1: targetPhi, targetDist, target point, theta per mode, orbit position.

const DT := 1.0 / 60.0


func test_angle_and_zoom_map_linearly() -> void:
	for a: float in [0.0, 0.25, 0.3, 0.5, 1.0]:
		check_near(MinimapCamera.target_phi(a), 1.35 - a * (1.35 - 0.08), 1e-12, "phi(angle %s)" % a)
	for z: float in [0.0, 0.5, 1.0]:
		check_near(MinimapCamera.target_dist(z), 11.05 + z * (2.0 - 11.05), 1e-12, "dist(zoom %s)" % z)


func test_target_follows_robot_x_and_blends_z_with_zoom() -> void:
	var w := Vector3(-3.0, 0.0, 2.0)
	check(MinimapCamera.desired_target(w, 0.0).is_equal_approx(Vector3(-3.0, 0.3, 0.0)), "zoom 0: centered on the short axis")
	check(MinimapCamera.desired_target(w, 1.0).is_equal_approx(Vector3(-3.0, 0.3, 2.0)), "zoom 1: on the robot")


func test_settled_camera_matches_the_formula_for_every_mode() -> void:
	var robot := Vector3(-2.0, 0.0, 1.5)
	for mode: String in ["follow", "driver"]:
		for red: Variant in [null, false, true]:
			var settings := {"mode": mode, "angle": 0.7, "zoom": 0.25}
			var cam := MinimapCamera.new()
			cam.step(DT, robot, 0.4, {"mode": "follow", "angle": 0.0, "zoom": 1.0}, null)
			for i in 900:
				cam.step(DT, robot, 0.4, settings, red)
			var phi := MinimapCamera.target_phi(0.7)
			var r := MinimapCamera.target_dist(0.25)
			var theta := MinimapCamera.desired_theta(mode, 0.4, red)
			var target := MinimapCamera.desired_target(robot, 0.25)
			var want := target + r * Vector3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
			check(cam.position().distance_to(want) < 1e-4, "%s red=%s: %s vs %s" % [mode, red, cam.position(), want])


func test_driver_mode_views_from_the_alliance_wall() -> void:
	var cam := MinimapCamera.new()
	cam.step(DT, Vector3.ZERO, 1.0, {"mode": "driver", "angle": 0.3, "zoom": 0.5}, false)
	check(cam.position().x > 0.5, "blue: camera on the +X (blue) side")
	cam = MinimapCamera.new()
	cam.step(DT, Vector3.ZERO, 1.0, {"mode": "driver", "angle": 0.3, "zoom": 0.5}, true)
	check(cam.position().x < -0.5, "red: camera on the -X (red) side")


func test_theta_takes_the_short_arc() -> void:
	var cam := MinimapCamera.new()
	cam.step(DT, Vector3.ZERO, PI - 0.1 - PI / 2.0, {"mode": "follow"}, null)
	var start := cam.theta
	cam.step(DT, Vector3.ZERO, -PI + 0.1 - PI / 2.0, {"mode": "follow"}, null)
	check(cam.theta > start, "wraps forward across +-PI instead of swinging back")
	check_near(cam.theta - start, 0.2 * Smoothing.dt_lerp(0.1, DT), 1e-6)
