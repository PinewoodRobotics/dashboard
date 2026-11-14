extends TestCase

const GOLDEN_FRAMES := 20
const GOLDEN_VALUE_FRAMES := 5

var nt: NtService


func before_each() -> void:
	if SimEnv.port() == 0:
		fail("PWRUP_SIM_PORT not set; run tools/test/run_sim_e2e.sh")
		return
	nt = NtHarness.make_service(tree, SimEnv.port())


func after_each() -> void:
	NtHarness.dispose(nt)
	await next_frame()


func test_handshake_and_golden_capture() -> void:
	if nt == null:
		return
	var frames: Array = []
	var continuation: Array = []
	var value_frames := [0]
	nt.client.frame_tap = func(is_text: bool, data: Variant) -> void:
		var entry := {"text": data} if is_text else {"binary_b64": Marshalls.raw_to_base64(data)}
		if frames.size() < GOLDEN_FRAMES:
			frames.append(entry)
		elif value_frames[0] < GOLDEN_VALUE_FRAMES:
			continuation.append(entry)
			if not is_text and data.size() > 1 and data[1] != 0xff:
				value_frames[0] += 1
	var groups := Topics.subscription_groups(ConnectionSettings.DEFAULT_NT)
	nt.subscribe_groups(groups)
	nt.start()
	var ready := await wait_until(func() -> bool: return nt.is_ready(), 10.0)
	check(ready >= 0.0, "READY against the sim")
	note("READY in %.3f s, protocol %s, rtt %d us" % [ready, nt.client.selected_protocol(), nt.client.rtt_us()])
	check_eq(nt.client.selected_protocol(), Nt4Protocol.PROTOCOL_V40, "4.0 accepted by the alpha-8 server")
	await wait_until(func() -> bool: return value_frames[0] >= GOLDEN_VALUE_FRAMES, 5.0)
	check_eq(frames.size(), GOLDEN_FRAMES, "captured frames")
	var d := nt.diagnostics()
	check_eq(d["decode_errors"], 0)
	check_eq(d["coerce_errors"], 0)
	if SimEnv.capture_golden() and frames.size() == GOLDEN_FRAMES:
		SimEnv.write_json(SimEnv.GOLDEN_HANDSHAKE, {
			"source": "FIR 2026Rebuilt robot sim, WPILib 2027.0.0-alpha-8 ntcore, captured by tests/sim/test_1_sim_handshake.gd",
			"captured": Time.get_datetime_string_from_system(true),
			"protocol": nt.client.selected_protocol(),
			"subscriptions": groups.map(func(g: Dictionary) -> Dictionary: return {"topics": Array(g["topics"]), "options": g["options"]}),
			"frames": frames,
			"continuation_note": "every frame after the first 20, up to the fifth binary value frame",
			"continuation": continuation,
		})
		note("wrote " + SimEnv.GOLDEN_HANDSHAKE)


func test_match_state_topics_match_registry() -> void:
	if nt == null:
		return
	var announced := {}
	nt.client.topic_announced.connect(func(info: Nt4Client.TopicInfo) -> void:
		if info.name.begins_with(Topics.MATCH_STATE_PREFIX):
			announced[info.name.substr(Topics.MATCH_STATE_PREFIX.length())] = info.type)
	nt.subscribe(PackedStringArray([Topics.MATCH_STATE_PREFIX]), {"prefix": true, "periodic": 0.02})
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready(), 10.0)
	await wait_s(2.0)
	for key: String in Topics.MATCH_STATE:
		if Topics.MATCH_STATE_OPTIONAL.has(key):
			check(not announced.has(key), "%s is not published by the robot (expected absent)" % key)
			continue
		check(announced.has(key), "robot announces " + key)
		if announced.has(key):
			check_eq(announced[key], Topics.MATCH_STATE[key], "type of " + key)
	for key: String in announced:
		check(Topics.MATCH_STATE.has(key), "registry knows " + key)
	note("%d /matchhud/state topics announced" % announced.size())

	var seq := Topics.match_topic("seq")
	var s0: int = nt.value(seq, 0)
	var u0: int = nt.entry(seq).get("updates", 0)
	await wait_s(3.0)
	var s1: int = nt.value(seq, 0)
	var u1: int = nt.entry(seq).get("updates", 0)
	check(s1 > s0, "seq increases (%d -> %d)" % [s0, s1])
	note("robot seq %.1f/s, received %.1f updates/s with periodic 0.02" % [(s1 - s0) / 3.0, (u1 - u0) / 3.0])
