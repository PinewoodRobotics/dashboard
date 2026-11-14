extends TestCase

## Poll cost with a prefix subscription to all 438 topics of the fake robot,
## polled once per frame at 60 fps like the app. The 2 ms criterion is gated
## at the load the FIR sim sends for the same subscription (about 1k values/s):
## mean and median-window p99 under 2 ms, median-window max under
## MAX_FRAME_MS (see PollPerf for why the median window). Four times that load
## (the fake robot's default) and twenty times it are recorded as stress checks
## with looser timing bounds and the same no-drop checks.

const MAX_FRAME_MS := 8.0
const STRESS_P99_MS := 4.0

const SEQ := "/matchhud/state/seq"
const LOAD_HZ := "/fake/control/load_hz"

var robot: FakeRobotProc
var nt: NtService
var seqs: Array[int] = []


func before_each() -> void:
	robot = FakeRobotProc.from_env()
	if robot == null:
		fail("PWRUP_FAKE_ROBOT_PORT not set; run tools/test/run_integration.sh")
		return
	nt = NtHarness.make_service(tree, robot.port)
	nt.set_process(false)
	nt.on_value(SEQ, func(v: Variant) -> void: seqs.append(v))
	nt.subscribe(PackedStringArray([""]), {"prefix": true, "periodic": 0.02})
	nt.subscribe(PackedStringArray([SEQ]), {"all": true})
	Engine.max_fps = 60


func after_each() -> void:
	Engine.max_fps = 0
	NtHarness.dispose(nt)
	await next_frame()


func _poll() -> void:
	nt.poll()


func _run_at_load(load_hz: float, timing_ok: Callable) -> Dictionary:
	nt.publisher(LOAD_HZ, "double").set_value(load_hz)
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready() and nt.client.announced_topics().size() >= 438, 5.0, _poll)
	check(nt.client.announced_topics().size() >= 438, "announced topics %d >= 438" % nt.client.announced_topics().size())
	await wait_s(1.0, _poll)
	var r := await PollPerf.measure_until(self, nt, seqs, timing_ok)
	for i in r["attempts"].size():
		note("%.0f Hz load, attempt %d: %s" % [load_hz, i + 1, r["attempts"][i]])
	return r


func _sim_gate(r: Dictionary) -> bool:
	return r["mean_ms"] < 2.0 and r["p99_ms"] < 2.0 and r["max_ms"] < MAX_FRAME_MS


func _stress_gate(r: Dictionary) -> bool:
	return r["mean_ms"] < 2.0 and r["p99_ms"] < STRESS_P99_MS and r["max_ms"] < MAX_FRAME_MS


func _check_no_drops(r: Dictionary) -> void:
	check(r["seq_values"] > 400, "seq values received (%d)" % r["seq_values"])
	check_eq(r["seq_gaps"], 0, "no dropped seq values")
	check_eq(nt.client.decode_errors, 0, "decode errors")
	check_eq(nt.client.unknown_id_drops, 0, "unknown id drops")
	check_eq(nt.client.coerce_errors, 0, "coerce errors")
	check_eq(nt.client.reconnects, 0, "no reconnects")


func test_poll_cost_at_sim_load() -> void:
	if nt == null:
		return
	var r := await _run_at_load(2.0, _sim_gate)
	check(r["values_per_s"] > 700 and r["values_per_s"] < 2500, "sim-like load delivered (%.0f values/s)" % r["values_per_s"])
	check(r["mean_ms"] < 2.0, "mean poll %.3f ms < 2 ms" % r["mean_ms"])
	check(r["p99_ms"] < 2.0, "median-window p99 poll %.3f ms < 2 ms" % r["p99_ms"])
	check(r["max_ms"] < MAX_FRAME_MS, "median-window max poll %.3f ms < %.0f ms" % [r["max_ms"], MAX_FRAME_MS])
	_check_no_drops(r)


func test_stress_4x_sim_load() -> void:
	if nt == null:
		return
	var r := await _run_at_load(10.0, _stress_gate)
	check(r["values_per_s"] > 3000, "4x load delivered (%.0f values/s)" % r["values_per_s"])
	check(r["mean_ms"] < 2.0, "mean poll %.3f ms < 2 ms" % r["mean_ms"])
	check(r["p99_ms"] < STRESS_P99_MS, "median-window p99 poll %.3f ms < %.0f ms" % [r["p99_ms"], STRESS_P99_MS])
	check(r["max_ms"] < MAX_FRAME_MS, "median-window max poll %.3f ms < %.0f ms" % [r["max_ms"], MAX_FRAME_MS])
	_check_no_drops(r)


## Every filler topic at 50 Hz (about 21k values/s, twenty times the sim). The
## poll budget keeps single frames short; this checks nothing is lost and the
## backlog stays bounded, and records the timing.
func test_stress_all_topics_at_50hz() -> void:
	if nt == null:
		return
	var r := await _run_at_load(50.0, func(_r: Dictionary) -> bool: return true)
	check(r["values_per_s"] > 15000, "stress load delivered (%.0f values/s)" % r["values_per_s"])
	check(r["max_backlog"] < 400, "backlog stays bounded (%d packets)" % r["max_backlog"])
	_check_no_drops(r)
