extends TestCase

## The Controls stack against the real robot code in the WPILib sim: auto
## selection and intake speed round-trip to the robot's State topics, and the
## validity data the auto selector shows comes from PathPlannerSubsystem.

const AUTO := "Move Forward And Shoot Left"
const STATE := "/Shared/PathPlanner/SelectedPath/State"
const INTAKE_STATE := "/Shared/Intake/Speed/State"

var nt: NtService
var settings: SettingsService
var controls: ControlsService


func before_each() -> void:
	if SimEnv.port() == 0:
		fail("PWRUP_SIM_PORT not set; run tools/test/run_sim_e2e.sh")
		return
	settings = SettingsService.new()
	settings.persist = false
	settings.connection_store = SharedSettingsStore.new("", true)
	tree.root.add_child(settings)
	nt = NtService.new()
	tree.root.add_child(nt)
	nt.apply_connection(settings.connection(), "127.0.0.1", SimEnv.port())
	controls = ControlsService.new()
	controls.nt = nt
	controls.settings = settings
	tree.root.add_child(controls)
	nt.start()


func after_each() -> void:
	for n: Node in [controls, settings]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	NtHarness.dispose(nt)
	await next_frame()


func test_auto_selection_round_trip_through_robot_code() -> void:
	if nt == null:
		return
	check(await wait_until(func() -> bool: return nt.is_ready() and nt.is_live(STATE), 10.0) >= 0.0, "connected to the sim")
	check(not controls.sync.locked(), "sim robot is disabled, selector unlocked")
	controls.sync.select(AUTO)
	var el := await wait_until(func() -> bool: return nt.value(STATE) == AUTO and nt.value(Topics.PP_CURRENT_SELECTED_AUTO) == AUTO, 3.0)
	note("robot State and CurrentSelectedAuto = %s %.3f s after Select" % [AUTO, el])
	check(el >= 0.0 and el <= 1.0, "State follows within 1 s (%.3f)" % el)
	check(await wait_until(func() -> bool: return controls.sync.validity(AUTO) == AutoSelectionSync.Validity.OK and nt.is_live(Topics.PP_SELECTED_AUTO_VALID), 2.0) >= 0.0,
		"robot lists and loaded the auto")
	check_eq(controls.sync.button_for(AUTO)["text"], "Selected")
	var names: Variant = nt.value(Topics.PP_VALID_AUTOS)
	for n in controls.autos.library.names():
		check(names is PackedStringArray and (names as PackedStringArray).has(n), "exported auto %s is on the robot" % n)
	controls.sync.select(AutoSelectionSync.NONE)
	check(await wait_until(func() -> bool: return str(nt.value(STATE)).to_upper() == "NONE", 2.0) >= 0.0, "No Auto reaches the robot as NONE (%s)" % [nt.value(STATE)])


func test_intake_speed_round_trip_through_robot_code() -> void:
	if nt == null:
		return
	await wait_until(func() -> bool: return nt.is_ready() and nt.is_live(INTAKE_STATE), 10.0)
	var constant: Variant = nt.value(INTAKE_STATE)
	note("robot's compiled intake constant: %s" % [constant])
	check_eq(controls.intake.status(), IntakeSpeed.STATUS_CONSTANT)
	controls.intake.set_speed(0.37)
	var el := await wait_until(func() -> bool: return controls.intake.status() == IntakeSpeed.STATUS_CONFIRMED, 3.0)
	note("intake 0.37 confirmed by the robot after %.3f s" % el)
	check(el >= 0.0 and el <= 1.0, "robot confirmed 0.37 (State %s)" % [nt.value(INTAKE_STATE)])
	controls.intake.reset()
	check(await wait_until(func() -> bool: return is_equal_approx(float(nt.value(INTAKE_STATE, -9.0)), float(constant)), 2.0) >= 0.0,
		"Reset (-1) returns the robot to its constant")
