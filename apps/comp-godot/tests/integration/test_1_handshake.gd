extends TestCase

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


func test_handshake_protocol_and_ready_time() -> void:
	if nt == null:
		return
	var t0 := now_s()
	nt.start()
	var elapsed := await wait_until(func() -> bool: return nt.is_ready(), 5.0)
	check(elapsed >= 0.0, "READY reached")
	check(elapsed < 1.0, "READY within 1 s of connect (took %.3f s)" % elapsed)
	note("READY after %.1f ms, rtt %d us" % [(now_s() - t0) * 1000.0, nt.client.rtt_us()])
	check_eq(nt.client.selected_protocol(), Nt4Protocol.PROTOCOL_V40)


func test_seq_rate() -> void:
	if nt == null:
		return
	nt.subscribe_groups(Topics.subscription_groups(ConnectionSettings.DEFAULT_NT))
	nt.start()
	await wait_until(func() -> bool: return nt.has_value(Topics.match_topic("seq")), 5.0)
	var seq_topic := Topics.match_topic("seq")
	var u0: int = nt.entry(seq_topic)["updates"]
	var s0: int = nt.value(seq_topic)
	var t0 := now_s()
	await wait_s(3.0)
	var dt := now_s() - t0
	var rate: float = (nt.entry(seq_topic)["updates"] - u0) / dt
	var seq_rate: float = (nt.value(seq_topic) - s0) / dt
	note("seq updates %.1f/s, robot seq %.1f/s" % [rate, seq_rate])
	check(rate >= 40.0, "seq arrives at >= 40/s (got %.1f)" % rate)
	for key: String in Topics.MATCH_STATE:
		if Topics.MATCH_STATE_OPTIONAL.has(key):
			continue
		var e := nt.entry(Topics.match_topic(key))
		check(not e.is_empty(), "received " + key)
		if not e.is_empty():
			check_eq(e["type"], Topics.MATCH_STATE[key], "type of " + key)


func test_type_decode() -> void:
	if nt == null:
		return
	nt.subscribe(PackedStringArray(["/fake/types/"]), {"prefix": true})
	nt.start()
	var expected := {
		"bool": true,
		"int": 1234567890123,
		"int_min": -9223372036854775807 - 1,
		"int_max": 9223372036854775807,
		"double": 3.141592653589793,
		"float": 1.5,
		"string": "Höhe 4765",
		"raw": PackedByteArray([0, 1, 2, 254, 255]),
		"bool_array": [true, false, true],
		"double_array": PackedFloat64Array([1.5, -2.25, 1e300]),
		"int_array": PackedInt64Array([1, -2, 1099511627776]),
		"float_array": PackedFloat64Array([0.5, -0.25]),
		"string_array": PackedStringArray(["a", "", "Move Forward And Shoot Left"]),
	}
	var all_in := func() -> bool:
		for k: String in expected:
			if not nt.has_value("/fake/types/" + k):
				return false
		return true
	check(await wait_until(all_in, 5.0) >= 0.0, "all typed topics arrived")
	for k: String in expected:
		check_eq(nt.value("/fake/types/" + k), expected[k], k)
	check_eq(nt.entry("/fake/types/float")["type"], "float")
	check_eq(nt.entry("/fake/types/raw")["type"], "raw")
	var d := nt.diagnostics()
	check_eq(d["decode_errors"], 0, "decode errors")
	check_eq(d["coerce_errors"], 0, "coerce errors")
