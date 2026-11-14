extends TestCase

const AUTO_STATE := "/Shared/PathPlanner/SelectedPath/State"
const AUTO_REQUEST := "/Shared/PathPlanner/SelectedPath/Request"
const LOG := "/fake/request_log"

var robot: FakeRobotProc
var nt: NtService
var pub: NtPublisher


func before_each() -> void:
	robot = FakeRobotProc.from_env()
	if robot == null:
		fail("PWRUP_FAKE_ROBOT_PORT not set; run tools/test/run_integration.sh")
		return
	nt = NtHarness.make_service(tree, robot.port)
	nt.subscribe(PackedStringArray([AUTO_STATE, LOG, "/fake/uptime_s"]), {"periodic": 0.02})
	pub = nt.publisher(AUTO_REQUEST, "string")
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready() and nt.has_value("/fake/uptime_s"), 5.0)


func after_each() -> void:
	NtHarness.dispose(nt)
	await next_frame()


func _state_is(v: String) -> Callable:
	return func() -> bool: return nt.value(AUTO_STATE) == v


func test_publish_after_30s_uptime_is_seen() -> void:
	if nt == null:
		return
	var up: float = nt.value("/fake/uptime_s", 0.0)
	if up < 30.5:
		note("waiting %.1f s for server uptime 30 s" % (30.5 - up))
		await wait_until(func() -> bool: return nt.value("/fake/uptime_s", 0.0) >= 30.5, 45.0)
	up = nt.value("/fake/uptime_s", 0.0)
	check(up >= 30.0, "server up >= 30 s (%.1f)" % up)
	pub.set_value("Ball Shooter Left")
	var el := await wait_until(_state_is("Ball Shooter Left"), 2.0)
	check(el >= 0.0, "State echo equals published value at uptime %.1f s" % up)
	note("echo after %.0f ms at server uptime %.1f s" % [el * 1000.0, up])


func test_two_consecutive_publishes_both_land() -> void:
	if nt == null:
		return
	pub.set_value("Consecutive A")
	pub.set_value("Consecutive B")
	var landed := func() -> bool:
		var log: PackedStringArray = nt.value(LOG, PackedStringArray())
		return log.size() >= 2 and log[-1] == "Consecutive B"
	check(await wait_until(landed, 2.0) >= 0.0, "second publish landed")
	var log: PackedStringArray = nt.value(LOG, PackedStringArray())
	check(log.size() >= 2 and log[-2] == "Consecutive A", "first publish landed before the second: %s" % [log])
	check(await wait_until(_state_is("Consecutive B"), 1.0) >= 0.0, "State follows the last publish")


func test_stale_timestamp_is_rejected() -> void:
	if nt == null:
		return
	pub.set_value("Fresh 1")
	check(await wait_until(_state_is("Fresh 1"), 2.0) >= 0.0, "fresh value accepted")
	var server_now := nt.client.server_time_us()
	check(nt.client.debug_send_value_at(pub.pubuid(), "Stale old", server_now - 2_000_000), "stale send")
	check(nt.client.debug_send_value_at(pub.pubuid(), "Stale zero", 1), "stamp 1 send")
	await wait_s(0.6)
	check_eq(nt.value(AUTO_STATE), "Fresh 1", "server kept the fresher value")
	var log: PackedStringArray = nt.value(LOG, PackedStringArray())
	check(not log.has("Stale old") and not log.has("Stale zero"), "stale values never reached the robot: %s" % [log])
	pub.set_value("Fresh 2")
	check(await wait_until(_state_is("Fresh 2"), 2.0) >= 0.0, "a correctly stamped publish still lands afterwards")
