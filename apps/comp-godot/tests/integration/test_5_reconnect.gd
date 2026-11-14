extends TestCase

const AUTO_STATE := "/Shared/PathPlanner/SelectedPath/State"
const AUTO_REQUEST := "/Shared/PathPlanner/SelectedPath/Request"
const SEQ := "/matchhud/state/seq"

var robot: FakeRobotProc
var nt: NtService


func before_each() -> void:
	robot = FakeRobotProc.from_env()
	if robot == null:
		fail("PWRUP_FAKE_ROBOT_PORT not set; run tools/test/run_integration.sh")
		return
	nt = NtHarness.make_service(tree, robot.port)


func after_each() -> void:
	NtHarness.dispose(nt)
	await next_frame()
	if robot != null and not robot.is_listening():
		robot.restart()
		await wait_until(func() -> bool: return robot.is_listening(), 20.0)


func test_robot_restart_recovery() -> void:
	if nt == null:
		return
	nt.subscribe_groups(Topics.subscription_groups(ConnectionSettings.DEFAULT_NT))
	var pub := nt.publisher(AUTO_REQUEST, "string")
	pub.set_value("Climber Right Left")
	nt.start()
	check(await wait_until(func() -> bool: return nt.value(AUTO_STATE) == "Climber Right Left", 3.0) >= 0.0, "initial echo")
	var announces := [0]
	nt.client.topic_announced.connect(func(_i: Nt4Client.TopicInfo) -> void: announces[0] += 1)

	check(robot.kill(), "fake robot killed")
	var t_kill := now_s()
	var left := await wait_until(func() -> bool: return not nt.is_ready(), 5.0)
	note("left READY %.3f s after kill" % left)
	check(left >= 0.0 and left <= 3.0, "left READY within 3 s (%.3f)" % left)
	check_eq(nt.client.topic_id(SEQ), -1, "topic ids cleared")
	check(not nt.is_live(SEQ), "cached values marked stale")
	check(nt.has_value(SEQ), "last value kept while disconnected")
	var seq_before: int = nt.entry(SEQ)["updates"]

	await wait_s(maxf(0.0, 2.0 - (now_s() - t_kill)))
	announces[0] = 0
	check(robot.restart() > 0, "fake robot restarted")
	var up := await wait_until(func() -> bool: return robot.is_listening(), 20.0)
	check(up >= 0.0, "fake robot listening again")
	var t_listen := now_s()
	var ready := await wait_until(func() -> bool: return nt.is_ready(), 8.0)
	note("READY %.3f s after the restarted robot started listening" % ready)
	check(ready >= 0.0 and ready <= 6.0, "READY within 6 s of restart (%.3f)" % ready)
	var t_ready := now_s()
	var echo := await wait_until(func() -> bool: return nt.is_live(AUTO_STATE) and nt.value(AUTO_STATE) == "Climber Right Left", 3.0)
	note("State echo %.3f s after READY" % echo)
	check(echo >= 0.0 and echo <= 1.0, "desired request re-published with no caller action (%.3f s)" % echo)
	check(await wait_until(func() -> bool: return nt.entry(SEQ)["updates"] > seq_before + 10, 2.0) >= 0.0, "subscriptions deliver again")
	check(announces[0] > 0, "topics re-announced on the new connection")
	check(nt.client.topic_id(SEQ) >= 0, "seq id from the new announce")
	check_eq(nt.diagnostics()["unknown_id_drops"], 0)
	note("timeline: listen +%.2f s after kill, ready +%.2f s" % [t_listen - t_kill, t_ready - t_kill])


func test_liveness_watchdog_on_frozen_robot() -> void:
	if nt == null:
		return
	nt.subscribe(PackedStringArray([SEQ]), {"periodic": 0.02})
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready(), 3.0)
	check(robot.signal_process("STOP"), "fake robot frozen")
	var left := await wait_until(func() -> bool: return not nt.is_ready(), 6.0)
	robot.signal_process("CONT")
	note("left READY %.3f s after freezing the robot" % left)
	check(left >= 2.5 and left <= 4.0, "liveness watchdog fired after about 3 s (%.3f)" % left)
	check_eq(nt.client.diagnostics()["liveness_fires"], 1)
	check(await wait_until(func() -> bool: return nt.is_ready(), 8.0) >= 0.0, "READY again after the robot resumes")
