extends TestCase

## Records how the robot echoes /Tuning/Turret/AimTrimDeg into
## /AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg while one client holds
## a publisher for 30 s, and what a second client sees after the writer
## disconnects. The expectations below are the recorded behavior of the FIR
## sim; M6 picks the aim trim confirmation source from them.

const TRIM := 2.5
const HOLD_S := 30.0
const DEFAULT_TRIM := 0.0

## Recorded against the FIR sim (WPILib 2027.0.0-alpha-8, AdvantageKit 27.0.0-alpha-7):
## the readback follows within one robot loop and holds for the whole 30 s.
## Unlike the Shared request topics, the trim does not fall back when the
## writer disconnects: LoggedNetworkNumber calls setDefault() on an entry, so
## the robot itself stays a publisher of /Tuning/Turret/AimTrimDeg and the
## last written value sticks until someone writes again or the robot restarts.
const EXPECT_FOLLOWS := true
const EXPECT_HELD_WHOLE_TIME := true
const EXPECT_REVERTS_AFTER_WRITER_LEAVES := false

var writer: NtService
var observer: NtService


func before_each() -> void:
	if SimEnv.port() == 0:
		fail("PWRUP_SIM_PORT not set; run tools/test/run_sim_e2e.sh")
		return
	writer = NtHarness.make_service(tree, SimEnv.port())
	observer = NtHarness.make_service(tree, SimEnv.port())


func after_each() -> void:
	NtHarness.dispose(writer)
	NtHarness.dispose(observer)
	await next_frame()


func _readback() -> Variant:
	return observer.value(Topics.AIM_TRIM_READBACK)


func test_aimtrim_readback_with_held_publisher() -> void:
	if writer == null:
		return
	observer.subscribe(PackedStringArray([Topics.AIM_TRIM_READBACK]), {"periodic": 0.02})
	var pub := writer.publisher(Topics.AIM_TRIM_PUBLISH, "double")
	observer.start()
	writer.start()
	await wait_until(func() -> bool: return writer.is_ready() and observer.is_ready() and observer.has_value(Topics.AIM_TRIM_READBACK), 10.0)
	var before: Variant = _readback()

	var t0 := now_s()
	pub.set_value(TRIM)
	var first_match := -1.0
	var mismatches_after_match := 0
	var samples: Array = []
	var next_sample := 0.0
	while now_s() - t0 < HOLD_S:
		var v: Variant = _readback()
		var el := now_s() - t0
		var matches: bool = v is float and is_equal_approx(v, TRIM)
		if first_match < 0.0 and matches:
			first_match = el
		elif first_match >= 0.0 and not matches:
			mismatches_after_match += 1
		if el >= next_sample:
			samples.append([snappedf(el, 0.01), v])
			next_sample += 5.0
		await next_frame()
	var held_s := now_s() - t0
	var after_hold: Variant = _readback()

	writer.stop()
	var t_leave := now_s()
	var reverted := await wait_until(func() -> bool:
		var v: Variant = _readback()
		return v is float and is_equal_approx(v, DEFAULT_TRIM), 3.0)

	var outcome := {
		"readback_topic": Topics.AIM_TRIM_READBACK,
		"publish_topic": Topics.AIM_TRIM_PUBLISH,
		"published": TRIM,
		"readback_before": before,
		"first_match_s": snappedf(first_match, 0.001),
		"held_s": snappedf(held_s, 0.01),
		"readback_after_hold": after_hold,
		"frames_not_matching_after_first_match": mismatches_after_match,
		"reverted_to_default_after_writer_left_s": snappedf(reverted, 0.001),
		"samples": samples,
		"conclusion": "",
	}
	var follows := first_match >= 0.0
	var held := follows and mismatches_after_match == 0
	var reverts := reverted >= 0.0
	outcome["conclusion"] = "readback %s, %s for the %.0f s hold, %s after the writer disconnected" % [
		"follows the publisher after %.0f ms" % (first_match * 1000.0) if follows else "never follows the publisher",
		"stays equal" if held else "does not stay equal",
		HOLD_S,
		"falls back to the default %.1f" % DEFAULT_TRIM if reverts else "does not fall back",
	]
	note(outcome["conclusion"])
	if SimEnv.capture_golden():
		outcome["recorded"] = Time.get_datetime_string_from_system(true)
		SimEnv.write_json(SimEnv.GOLDEN_AIMTRIM, outcome)
		note("wrote " + SimEnv.GOLDEN_AIMTRIM)
	check(held_s >= HOLD_S, "publisher held %.1f s" % held_s)
	check_eq(follows, EXPECT_FOLLOWS, "readback follows the publisher")
	check_eq(held, EXPECT_HELD_WHOLE_TIME, "readback stays at the published value for the whole hold")
	check_eq(reverts, EXPECT_REVERTS_AFTER_WRITER_LEAVES, "readback falls back to the default after the writer leaves")
