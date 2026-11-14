extends TestCase

## The Controls stack (ControlsService over NtControlLink) against the fake
## robot: auto selection and intake round trips, recovery after a robot
## restart, a second client fighting over the request, the lock, and the
## shared connection file driving the NT client.

const AUTO := "Ball Shooter Left"
const OTHER := "Stay And Shoot"
const STATE := "/Shared/PathPlanner/SelectedPath/State"
const REQUEST := "/Shared/PathPlanner/SelectedPath/Request"
const INTAKE_STATE := "/Shared/Intake/Speed/State"
const CONNECTIONS := "/fake/connections"

var robot: FakeRobotProc
var nt: NtService
var settings: SettingsService
var controls: ControlsService
var extra: Array[Node] = []
var dir := ""
var _env_before := ""


func before_each() -> void:
	robot = FakeRobotProc.from_env()
	if robot == null:
		fail("PWRUP_FAKE_ROBOT_PORT not set; run tools/test/run_integration.sh")
		return
	dir = ProjectSettings.globalize_path("res://.scratch/integration/controls_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	_env_before = OS.get_environment(ConnectionSettings.ENV_PATH)
	OS.set_environment(ConnectionSettings.ENV_PATH, dir.path_join("connection-settings.json"))
	_write_connection("127.0.0.1", robot.port)
	settings = SettingsService.new()
	settings.persist = false
	tree.root.add_child(settings)
	nt = NtService.new()
	tree.root.add_child(nt)
	nt.apply_connection(settings.connection())
	settings.changed.connect(func(section: String) -> void:
		if section == "connection":
			nt.apply_connection(settings.connection()))


func after_each() -> void:
	for n: Node in extra:
		if n is NtService:
			(n as NtService).stop()
		if is_instance_valid(n):
			n.queue_free()
	extra.clear()
	for n: Node in [controls, settings]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	controls = null
	NtHarness.dispose(nt)
	OS.set_environment(ConnectionSettings.ENV_PATH, _env_before)
	await next_frame()
	if robot != null and not robot.is_listening():
		robot.restart()
		await wait_until(func() -> bool: return robot.is_listening(), 20.0)


func _write_connection(host: String, port: int) -> void:
	var store := SharedSettingsStore.new()
	store.reload()
	var conn := ConnectionSettings.defaults()
	conn["nt"]["host"] = host
	conn["nt"]["port"] = port
	conn["reconnectTimeoutSeconds"] = 2
	store.save(conn)


func _start_controls(stored: Dictionary = {}) -> void:
	settings.set_controls(stored)
	controls = ControlsService.new()
	controls.nt = nt
	controls.settings = settings
	tree.root.add_child(controls)
	nt.start()


func _observer() -> NtService:
	var o := NtHarness.make_service(tree, robot.port)
	o.subscribe(PackedStringArray([STATE, CONNECTIONS, REQUEST]), {"periodic": 0.02})
	o.start()
	extra.append(o)
	return o


func test_select_reaches_robot_state_within_1s() -> void:
	if robot == null:
		return
	_start_controls()
	check(await wait_until(func() -> bool: return nt.is_ready() and nt.is_live(STATE), 5.0) >= 0.0, "connected")
	var t0 := now_s()
	check(controls.sync.select(AUTO))
	var el := await wait_until(func() -> bool: return nt.value(STATE) == AUTO, 2.0)
	note("State = %s %.3f s after Select" % [AUTO, el])
	check(el >= 0.0 and el <= 1.0, "State follows within 1 s (%.3f)" % el)
	check(await wait_until(func() -> bool: return controls.sync.button_for(AUTO)["text"] == "Selected", 1.0) >= 0.0, "button reads Selected")
	check_eq(controls.sync.validity(AUTO), AutoSelectionSync.Validity.OK, "robot lists and loaded the auto")
	check_eq(settings.controls()["selected_auto"], AUTO)
	controls.sync.select(AutoSelectionSync.NONE)
	check(await wait_until(func() -> bool: return nt.value(STATE) == "NONE", 1.0) >= 0.0, "No Auto publishes NONE")
	check_eq(now_s() - t0 < 5.0, true)


func test_intake_round_trip_and_reset() -> void:
	if robot == null:
		return
	_start_controls()
	await wait_until(func() -> bool: return nt.is_ready() and nt.is_live(INTAKE_STATE), 5.0)
	check_eq(controls.intake.status(), IntakeSpeed.STATUS_CONSTANT)
	controls.intake.set_speed(0.42)
	var el := await wait_until(func() -> bool: return controls.intake.status() == IntakeSpeed.STATUS_CONFIRMED, 2.0)
	note("intake 0.42 confirmed after %.3f s" % el)
	check(el >= 0.0, "robot confirmed 0.42 (State %s)" % [nt.value(INTAKE_STATE)])
	controls.intake.reset()
	check(await wait_until(func() -> bool: return is_equal_approx(float(nt.value(INTAKE_STATE, 0.0)), 0.5), 2.0) >= 0.0, "-1 returns the robot to its constant")
	check_eq(controls.intake.status(), IntakeSpeed.STATUS_CONSTANT)
	check_eq(settings.controls()["intake_speed"], null)


func test_robot_restart_restores_selection_and_intake() -> void:
	if robot == null:
		return
	_start_controls({"selected_auto": OTHER, "intake_speed": 0.33})
	var first := await wait_until(func() -> bool: return nt.value(STATE) == OTHER and is_equal_approx(float(nt.value(INTAKE_STATE, 0.0)), 0.33), 5.0)
	check(first >= 0.0, "stored choices published on the first connect with no user action")
	check(robot.kill(), "fake robot killed")
	await wait_until(func() -> bool: return not nt.is_ready(), 5.0)
	check_eq(controls.intake.status(), IntakeSpeed.STATUS_DISCONNECTED)
	await wait_s(1.0)
	check(robot.restart() > 0, "fake robot restarted")
	await wait_until(func() -> bool: return robot.is_listening(), 20.0)
	var ready := await wait_until(func() -> bool: return nt.is_ready(), 8.0)
	check(ready >= 0.0, "READY again")
	var t_ready := now_s()
	var el := await wait_until(func() -> bool: return nt.is_live(STATE) and nt.value(STATE) == OTHER \
		and nt.is_live(INTAKE_STATE) and is_equal_approx(float(nt.value(INTAKE_STATE)), 0.33), 3.0)
	note("selection and intake restored %.3f s after READY" % el)
	check(el >= 0.0 and el <= 1.0, "restored within 1 s of READY (%.3f)" % el)
	check_eq(controls.sync.selected, OTHER)
	check(now_s() - t_ready < 4.0)


func test_fighting_client_raises_conflict() -> void:
	if robot == null:
		return
	_start_controls({"selected_auto": AUTO})
	await wait_until(func() -> bool: return nt.value(STATE) == AUTO, 5.0)
	var rival := NtHarness.make_service(tree, robot.port)
	extra.append(rival)
	var pub := rival.publisher(REQUEST, "string")
	rival.start()
	await wait_until(func() -> bool: return rival.is_ready(), 5.0)
	var t0 := now_s()
	var next := 0.0
	var robot_values := {}
	while now_s() - t0 < 20.0 and not controls.sync.conflict:
		if now_s() - t0 >= next:
			pub.set_value(OTHER)
			next += 0.3
		robot_values[str(nt.value(STATE))] = true
		await next_frame()
	var el := now_s() - t0
	note("conflict raised after %.2f s of fighting; State took %s" % [el, robot_values.keys()])
	check(controls.sync.conflict, "conflict popup after a second client fights over the request")
	check(robot_values.has(AUTO) and robot_values.has(OTHER), "State flipped between both choices")
	rival.stop()
	controls.sync.resync()
	check(not controls.sync.conflict)
	check(await wait_until(func() -> bool: return nt.value(STATE) == AUTO, 2.0) >= 0.0, "Resync restores the choice once the rival is gone")


func test_lock_while_enabled_blocks_publishing() -> void:
	if robot == null:
		return
	_start_controls({"selected_auto": AUTO})
	await wait_until(func() -> bool: return nt.value(STATE) == AUTO, 5.0)
	var ctl := NtHarness.make_service(tree, robot.port)
	extra.append(ctl)
	var pin := ctl.publisher("/fake/control/enabled", "int")
	pin.set_value(1)
	ctl.start()
	check(await wait_until(func() -> bool: return controls.sync.locked(), 3.0) >= 0.0, "locked while /matchhud/state/enabled is true")
	var before := controls.sync.publishes
	check(not controls.sync.select(OTHER), "Select refused")
	check_eq(controls.sync.button_for(OTHER)["text"], "Locked During Match")
	await wait_s(1.5)
	check_eq(controls.sync.publishes, before, "no publishes while locked")
	check_eq(nt.value(STATE), AUTO)
	pin.set_value(0)
	check(await wait_until(func() -> bool: return not controls.sync.locked(), 3.0) >= 0.0, "unlocked")


func test_external_settings_edit_moves_the_connection() -> void:
	if robot == null:
		return
	_start_controls()
	var obs := _observer()
	check(await wait_until(func() -> bool: return nt.is_ready() and obs.is_ready(), 5.0) >= 0.0, "both connected")
	check(await wait_until(func() -> bool: return obs.value(CONNECTIONS) == 2, 3.0) >= 0.0, "fake robot sees 2 clients (%s)" % [obs.value(CONNECTIONS)])
	var connects_before: int = nt.client.diagnostics()["connects"]
	_write_connection("127.0.0.2", robot.port)
	var t0 := now_s()
	var picked := await wait_until(func() -> bool: return settings.connection()["nt"]["host"] == "127.0.0.2", 3.5)
	note("external edit applied after %.2f s" % picked)
	check(picked >= 0.0 and picked <= 3.0, "external edit picked up within 3 s")
	check(nt.client.url().contains("127.0.0.2"), "client points at the new host: " + nt.client.url())
	var closed := await wait_until(func() -> bool: return obs.value(CONNECTIONS) == 1, 4.0)
	note("old socket gone from the server %.2f s after the edit" % (now_s() - t0))
	check(closed >= 0.0, "old socket closed (server sees %s clients)" % [obs.value(CONNECTIONS)])
	check(not nt.is_ready())
	_write_connection("127.0.0.1", robot.port)
	var back := await wait_until(func() -> bool: return nt.is_ready(), 6.0)
	note("READY on the edited-back host after %.2f s" % back)
	check(back >= 0.0, "connects to the new address")
	check(nt.client.diagnostics()["connects"] > connects_before, "a new connection was opened")
	check(await wait_until(func() -> bool: return obs.value(CONNECTIONS) == 2, 3.0) >= 0.0, "server sees exactly one socket from the dashboard again")


func test_settings_header_status_and_reconnect() -> void:
	if robot == null:
		return
	_start_controls()
	await wait_until(func() -> bool: return nt.is_ready(), 5.0)
	var tab := SettingsTab.new()
	tab.settings = settings
	tab.nt = nt
	tab.size = Vector2(1752, 515)
	tree.root.add_child(tab)
	extra.append(tab)
	tab._update_status()
	check_eq(tab.status_label.text, "Connected")
	check(not tab.reconnect.visible, "Reconnect hidden while connected")
	check(tab.diag.text.contains("READY"))
	var connects: int = nt.client.diagnostics()["connects"]
	tab.reconnect.pressed.emit()
	tab._update_status()
	check_eq(tab.status_label.text, "Disconnected", "client restarted")
	check(tab.reconnect.visible)
	check(await wait_until(func() -> bool: return nt.is_ready(), 5.0) >= 0.0, "READY again after Reconnect")
	check_eq(nt.client.diagnostics()["connects"], connects + 1, "one new connection")
	tab._update_status()
	check_eq(tab.status_label.text, "Connected")
