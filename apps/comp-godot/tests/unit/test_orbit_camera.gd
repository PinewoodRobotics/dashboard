extends TestCase

var cam: OrbitCamera


func before_each() -> void:
	cam = OrbitCamera.new(OrbitCamera.load_presets("res://data/rig/camera-poses.json"))


func _settle(c: OrbitCamera, seconds: float = 3.0) -> void:
	for i in int(seconds * 60.0):
		c.step(1.0 / 60.0)


func test_four_presets_from_camera_poses() -> void:
	check_eq(cam.presets.size(), 4)
	check_eq(cam.presets.map(func(p: Dictionary) -> String: return p["label"]), ["Overview", "Intake", "Turret", "Side"])
	check(cam.position().distance_to(Vector3(1.38, 0.45, 1.38)) < 1e-4, "starts at Overview")


func test_driver_tuning_is_the_web_s() -> void:
	check_eq(cam.rotate_speed, 0.5)
	check_eq(cam.zoom_speed, 0.8)
	check(not cam.enable_pan)
	check_eq(OrbitCamera.DAMPING, 0.08)
	check_near(cam.max_polar, PI / 2.0 - 0.05, 1e-9)
	check_eq([cam.min_polar, cam.min_dist, cam.max_dist], [0.1, 0.5, 4.0])


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


func test_side_pose_rests_at_the_polar_limit() -> void:
	check(float(cam.presets[3]["phi"]) > cam.max_polar, "the Side pose lies below the limit")
	cam.select_preset(3)
	_settle(cam, 0.5)
	check_near(cam.phi, cam.max_polar, 1e-9, "the per-frame update clamps it like controls.update()")


func test_drag_rotates_2pi_rotate_speed_per_view_height_with_glide() -> void:
	cam.idle_return = false
	var theta0 := cam.theta
	cam.begin_interaction()
	cam.rotate(-100.0, 0.0, 515.0)
	var total := TAU * 100.0 * 0.5 / 515.0
	check_near(cam.theta - theta0, total * 0.08, 1e-9, "one update per move applies 8% of the pool")
	cam.end_interaction()
	check(cam.is_gliding())
	cam.step(1.0 / 60.0)
	check_near(cam.theta - theta0, total * (0.08 + 0.92 * 0.08), 1e-9, "each 60 fps frame applies 8% of the rest")
	_settle(cam, 2.0)
	check_near(cam.theta - theta0, total, total * 1e-3, "the glide delivers the whole drag")


func test_frame_damping_is_rate_independent() -> void:
	var a := OrbitCamera.new(cam.presets)
	var b := OrbitCamera.new(cam.presets)
	a.rotate(50.0, 0.0, 515.0)
	b.rotate(50.0, 0.0, 515.0)
	for i in 6:
		a.step(1.0 / 60.0)
	for i in 3:
		b.step(1.0 / 30.0)
	check_near(a.theta, b.theta, 1e-9)


func test_limits() -> void:
	cam.rotate(0, 100000, 515.0)
	_settle(cam, 0.5)
	check_eq(cam.phi, cam.min_polar)
	cam.rotate(0, -100000, 515.0)
	_settle(cam, 0.5)
	check_eq(cam.phi, cam.max_polar)
	cam.wheel(-100000.0)
	check_eq(cam.dist, 0.5)
	cam.wheel(100000.0)
	check_eq(cam.dist, 4.0)


func test_wheel_and_pinch_zoom_like_orbit_controls() -> void:
	var d := cam.dist
	cam.wheel(100.0)
	check_near(cam.dist, d / pow(0.95, 0.8), 1e-9, "a 100 px notch away zooms out by 0.95^0.8 at once")
	d = cam.dist
	cam.wheel(-100.0)
	check_near(cam.dist, d * pow(0.95, 0.8), 1e-9)
	d = cam.dist
	cam.pinch(1.25)
	check_near(cam.dist, d / pow(1.25, 0.8), 1e-9, "spreading the fingers by 25% zooms in by 1.25^0.8")
	d = cam.dist
	cam.magnify(1.1)
	check_near(cam.dist, d * pow(0.95, 0.8 * 10.0 * log(1.1)), 1e-9, "a trackpad pinch is a ctrl wheel of -100 ln(f), times 10")


func test_driver_never_pans() -> void:
	var t := cam.target
	cam.pan(200.0, 100.0, 515.0)
	_settle(cam, 0.5)
	check_eq(cam.target, t)


func test_robot_viewer_tuning() -> void:
	var rv := OrbitCamera.robot_viewer()
	check(rv.position().distance_to(Vector3(1.5, 1.0, 1.5)) < 1e-6)
	check_eq(rv.target, Vector3.ZERO)
	check_eq([rv.rotate_speed, rv.zoom_speed, rv.min_dist, rv.max_dist, rv.enable_pan], [1.0, 1.0, 0.2, 6.0, true])
	var theta0 := rv.theta
	rv.rotate(-100.0, 0.0, 499.0)
	_drain(rv)
	check_near(rv.theta - theta0, TAU * 100.0 / 499.0, 1e-4, "0.0126 rad per px at 499 px")
	var right := rv.view_basis().x
	var t0 := rv.target
	rv.pan(100.0, 0.0, 499.0)
	_drain(rv)
	var expect := -right * 2.0 * 100.0 * rv.dist * tan(deg_to_rad(25.0)) / 499.0
	check((rv.target - t0).distance_to(expect) < 1e-3, "drag right moves the target left by the screen-space amount")
	rv.rotate(0.0, -100000.0, 499.0)
	_drain(rv)
	check(rv.phi > 3.1, "no polar limit but the pole")


func _drain(c: OrbitCamera) -> void:
	for i in 400:
		c.rotate(0.0, 0.0, 499.0)


func test_robot_viewer_stops_dead_on_release() -> void:
	var rv := OrbitCamera.robot_viewer()
	var theta0 := rv.theta
	rv.begin_interaction()
	for i in 10:
		rv.rotate(-10.0, 0.0, 499.0)
	rv.end_interaction()
	var total := TAU * 100.0 / 499.0
	var moved := rv.theta - theta0
	check_near(moved / total, 1.0 - (1.0 - pow(0.92, 10)) / 0.08 * 0.92 / 10.0, 1e-6, "a 10-move flick delivers about 35%")
	check(moved / total > 0.3 and moved / total < 0.4)
	for i in 120:
		rv.step(1.0 / 60.0)
	check_eq(rv.theta - theta0, moved, "no per-frame update: no glide")
	check(rv.is_gliding(), "the rest waits in the pool")
	rv.wheel(-1.0)
	check_near(rv.theta - theta0, moved + (total - moved) * 0.08, 1e-9, "the next input event applies 8% of it")


func test_two_finger_move_is_one_update() -> void:
	var rv := OrbitCamera.robot_viewer()
	var t0 := rv.target
	var d0 := rv.dist
	var right := rv.view_basis().x
	rv.pinch_pan(1.25, 100.0, 0.0, 499.0)
	check_near(rv.dist, d0 / 1.25, 1e-9, "the pinch applies at once")
	var full := -right * 2.0 * 100.0 * d0 * tan(deg_to_rad(25.0)) / 499.0
	check((rv.target - t0).distance_to(full * 0.08) < 1e-6, "8% of the pan, not 8% plus 8% of the rest")
	cam.pinch_pan(1.25, 100.0, 0.0, 515.0)
	check_eq(cam.target, Vector3(0, 0.25, 0), "the driver view never pans")


func test_tapping_the_selected_preset_does_nothing() -> void:
	cam.rotate(200.0, 0.0, 515.0)
	_settle(cam, 0.5)
	cam.select_preset(0)
	cam.step(1.0 / 60.0)
	check(not cam.is_tweening(), "same stateIndex: the web's effect does not fire")
	_settle(cam, 0.6)
	check(cam.is_tweening(), "the idle return brings it back")


func test_idle_returns_to_the_last_completed_tween() -> void:
	var home := cam.position()
	cam.select_preset(2)
	cam.step(0.2)
	cam.begin_interaction()
	check(not cam.is_tweening())
	cam.rotate(50.0, 0.0, 515.0)
	cam.end_interaction()
	check_eq(cam.preset, 2, "the bar keeps the tapped preset")
	_settle(cam, 1.1)
	check(cam.is_tweening())
	_settle(cam, 0.7)
	check(not cam.is_tweening())
	check(cam.position().distance_to(home) < 1e-3, "back to Overview, where the last tween ended")
	cam.select_preset(1)
	_settle(cam, 0.5)
	cam.rotate(50.0, 0.0, 515.0)
	_settle(cam, 2.0)
	var intake := OrbitCamera.new(cam.presets)
	intake.select_preset(1, false)
	check(cam.position().distance_to(intake.position()) < 1e-3, "a finished preset tween is the new idle target")


func test_covered_view_holds_still_and_resumes() -> void:
	var home := cam.position()
	cam.rotate(200.0, 0.0, 515.0)
	var theta := cam.theta
	for i in 120:
		cam.step_hidden(1.0 / 60.0)
	check_eq(cam.theta, theta, "frameloop never: no glide")
	check(not cam.is_tweening())
	cam.step(1.0 / 60.0)
	check(cam.is_tweening(), "the idle wait ran on the wall clock, the return starts on the first visible frame")
	_settle(cam, 0.7)
	check(cam.position().distance_to(home) < 0.05, "home, plus what is left of the held glide")
	cam.select_preset(2)
	cam.step_hidden(1.0)
	check(cam.is_tweening())
	cam.step(1.0 / 60.0)
	check(not cam.is_tweening(), "a tween that ran out while covered snaps to its end")


func test_idle_return_after_1s_over_600ms() -> void:
	var home := cam.position()
	cam.begin_interaction()
	cam.rotate(200, 0, 515.0)
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
	check(cam.position().distance_to(home) < 1e-3, "back at the selected preset")


func test_user_input_cancels_the_return() -> void:
	cam.rotate(100, 0, 515.0)
	_settle(cam, 1.1)
	check(cam.is_tweening())
	cam.begin_interaction()
	check(not cam.is_tweening(), "a press cancels the idle return")
	cam.end_interaction()
	_settle(cam, 1.1)
	check(cam.is_tweening(), "a return cut short starts again after the next release")
	cam.wheel(-50.0)
	check(not cam.is_tweening(), "so does the wheel")
	cam.idle_return = false
	_settle(cam, 5.0)
	check(not cam.is_tweening())


func test_orbit_input_mouse_and_touch() -> void:
	var view := Control.new()
	view.size = Vector2(1920, 515)
	var input := OrbitInput.new(cam)
	var theta0 := cam.theta
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = Vector2(500, 200)
	input.handle(down, view)
	check(cam.is_interacting())
	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(501, 200)
	input.handle(mm, view)
	check(cam.theta < theta0, "rotates from the first pixel")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	var d := cam.dist
	input.handle(wheel, view)
	check_eq(cam.dist, d, "the wheel does nothing while a button is held")
	down.pressed = false
	input.handle(down, view)
	check(not cam.is_interacting())
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	input.handle(right, view)
	check_eq(input.state, OrbitInput.State.NONE, "right drag pans, and the driver view has no pan")
	right.pressed = false
	input.handle(right, view)
	var t1 := InputEventScreenTouch.new()
	t1.index = 0
	t1.pressed = true
	t1.position = Vector2(800, 200)
	input.handle(t1, view)
	var t2 := InputEventScreenTouch.new()
	t2.index = 1
	t2.pressed = true
	t2.position = Vector2(1000, 200)
	input.handle(t2, view)
	check_eq(input.state, OrbitInput.State.TOUCH_DOLLY_PAN)
	d = cam.dist
	var drag := InputEventScreenDrag.new()
	drag.index = 1
	drag.position = Vector2(1100, 200)
	input.handle(drag, view)
	check_near(cam.dist, d / pow(1.5, 0.8), 1e-6, "pinch out by 1.5 zooms in by 1.5^0.8")
	t2.pressed = false
	input.handle(t2, view)
	check_eq(input.state, OrbitInput.State.TOUCH_ROTATE, "lifting one finger rotates with the other")
	t1.pressed = false
	input.handle(t1, view)
	check(not cam.is_interacting())
	view.free()
