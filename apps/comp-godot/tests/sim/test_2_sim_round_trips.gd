extends TestCase

const AUTO_NAME := "Move Forward And Shoot Left"

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


func test_auto_selection_round_trip() -> void:
	if nt == null:
		return
	var t := Topics.selected_auto_topics(ConnectionSettings.DEFAULT_NT)
	var pub := nt.publisher(t["request"], "string")
	pub.set_value(AUTO_NAME)
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready(), 10.0)
	var el := await wait_until(func() -> bool: return nt.value(t["state"]) == AUTO_NAME and nt.value(Topics.PP_CURRENT_SELECTED_AUTO) == AUTO_NAME, 5.0)
	note("State and CurrentSelectedAuto = %s after %.3f s" % [AUTO_NAME, el])
	check(el >= 0.0, "State %s, CurrentSelectedAuto %s" % [nt.value(t["state"]), nt.value(Topics.PP_CURRENT_SELECTED_AUTO)])
	await wait_until(func() -> bool: return nt.value(Topics.PP_SELECTED_AUTO_VALID) == true, 2.0)
	check_eq(nt.value(Topics.PP_SELECTED_AUTO_VALID), true, "SelectedAutoValid")
	var names: Variant = nt.value(Topics.PP_VALID_AUTOS)
	check(names is PackedStringArray and names.has(AUTO_NAME), "ValidNames/Autos lists the auto: %s" % [names])


func test_intake_speed_round_trip() -> void:
	if nt == null:
		return
	var t := Topics.intake_speed_topics(ConnectionSettings.DEFAULT_NT)
	var pub := nt.publisher(t["request"], "double")
	pub.set_value(0.42)
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready(), 10.0)
	var el := await wait_until(func() -> bool: return is_equal_approx(nt.value(t["state"], -99.0), 0.42), 5.0)
	note("intake State 0.42 after %.3f s" % el)
	check(el >= 0.0, "intake State is %s" % [nt.value(t["state"])])
	pub.set_value(-1.0)
	var el2 := await wait_until(func() -> bool: return nt.value(t["state"], 0.42) != 0.42, 3.0)
	check(el2 >= 0.0, "reset request -1 returns State to the robot constant (%s)" % [nt.value(t["state"])])
	note("State after -1: %s" % [nt.value(t["state"])])
