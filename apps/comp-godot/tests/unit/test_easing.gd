extends TestCase


func test_css_ease_matches_browsers() -> void:
	check_near(Easing.css(0.5), 0.802, 0.005, "cubic-bezier(0.25,0.1,0.25,1) at 0.5")
	check_eq(Easing.css(0.0), 0.0)
	check_eq(Easing.css(1.0), 1.0)
	check_eq(Easing.css(-1.0), 0.0)
	check_eq(Easing.css(2.0), 1.0)
	var prev := 0.0
	for i in range(1, 101):
		var y := Easing.css(i / 100.0)
		check(y >= prev, "monotonic at %d" % i)
		prev = y


func test_linear_bezier_is_identity_and_ease_out_cubic() -> void:
	for t in [0.1, 0.33, 0.5, 0.9]:
		check_near(Easing.cubic_bezier(0.0, 0.0, 1.0, 1.0, t), t, 1e-5, "linear bezier at %s" % t)
	check_near(Easing.out_cubic(0.5), 0.875, 1e-9)
	check_eq(Easing.out_cubic(1.0), 1.0)
	check_eq(Easing.out_cubic(0.0), 0.0)


func test_ui_anim_runs_for_its_duration() -> void:
	var a := UiAnim.new(0.0)
	a.start(100.0, 0.2)
	check(a.running)
	a.step(0.1)
	check_near(a.value, 100.0 * Easing.css(0.5), 1e-4, "halfway uses the css curve")
	check(not a.step(0.09), "not finished at 190 ms")
	check(a.step(0.011), "finishes at 200 ms")
	check_eq(a.value, 100.0)
	check(not a.running)
