extends TestCase

var cam: OrbitCamera


func before_each() -> void:
	cam = OrbitCamera.new(OrbitCamera.load_presets("res://data/rig/camera-poses.json"))


func test_four_presets_from_camera_poses() -> void:
	check_eq(cam.presets.size(), 4)
	check_eq(cam.presets.map(func(p: Dictionary) -> String: return p["label"]), ["Overview", "Intake", "Turret", "Side"])
	check(cam.position().distance_to(Vector3(1.38, 0.45, 1.38)) < 1e-4, "starts at Overview")


func test_preset_tween_is_400ms_ease_out_cubic_on_the_short_arc() -> void:
	var from_theta := cam.theta
	cam.select_preset(2)
	var to: Dictionary = cam.presets[2]
	var dtheta := wrapf(float(to["theta"]) - from_theta, -PI, PI)
	cam.step(0.2)
	check_near(cam.theta, from_theta + dtheta * Easing.out_cubic(0.5), 1e-6, "halfway at 200 ms")
	check(cam.is_tweening())
	cam.step(0.2)
	check(not cam.is_tweening(), "done at 400 ms")
	check(cam.position().distance_to(Vector3(-0.92, 0.6, 0.62)) < 1e-4, "at the Turret pose")
	check(absf(dtheta) <= PI)


func test_orbit_limits() -> void:
	cam.orbit(0, 100000)
	check_eq(cam.phi, OrbitCamera.MIN_POLAR)
	cam.orbit(0, -100000)
	check_eq(cam.phi, OrbitCamera.MAX_POLAR)
	check_near(OrbitCamera.MAX_POLAR, PI / 2.0 - 0.05, 1e-9)
	cam.zoom(100)
	check_eq(cam.dist, 0.5)
	cam.zoom(-100)
	check_eq(cam.dist, 4.0)


func test_idle_return_after_1s_over_600ms() -> void:
	var home := cam.position()
	cam.begin_interaction()
	cam.orbit(200, 0)
	cam.step(5.0)
	check(cam.position().distance_to(home) > 0.1, "no return while the finger is down")
	cam.end_interaction()
	cam.step(0.99)
	check(not cam.is_tweening(), "still waiting at 990 ms")
	cam.step(0.02)
	check(cam.is_tweening(), "returns after 1000 ms")
	cam.step(0.3)
	check(cam.is_tweening(), "600 ms tween")
	cam.step(0.31)
	check(not cam.is_tweening())
	check(cam.position().distance_to(home) < 1e-4, "back at the selected preset")


func test_user_input_cancels_the_return() -> void:
	cam.orbit(100, 0)
	cam.step(1.1)
	check(cam.is_tweening())
	cam.orbit(5, 0)
	check(not cam.is_tweening(), "a drag cancels the idle return")
	cam.idle_return = false
	cam.step(5.0)
	check(not cam.is_tweening())
