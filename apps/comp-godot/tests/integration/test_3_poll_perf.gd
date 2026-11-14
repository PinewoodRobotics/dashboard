extends TestCase

## Poll cost with a prefix subscription to all 438 topics of the fake robot,
## polled once per frame at 60 fps like the app. The baseline load (390 filler
## doubles at 10 Hz, the match table at 50 Hz, about 4k values/s) is about four
## times what the FIR sim sends for the same subscription (about 1k values/s).
## "Under 2 ms per frame" is asserted as mean and p99 under 2 ms. The single
## slowest frame includes OS scheduling noise (up to 2.7 ms seen against the
## sim), so it only has to stay under MAX_FRAME_MS, which still catches stalls.

const MAX_FRAME_MS := 5.0

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


func _measure(seconds: float) -> Dictionary:
	var times: Array[float] = []
	var max_backlog := 0
	var seq_start := seqs.size()
	var v0 := nt.client.values_total
	var d0 := nt.client.deferred_packets
	var t_start := now_s()
	var detail: Array = []
	while now_s() - t_start < seconds:
		var vb := nt.client.values_total
		var bin0 := nt.client.binary_frames
		var t0 := Time.get_ticks_usec()
		nt.poll()
		var el := (Time.get_ticks_usec() - t0) / 1000.0
		times.append(el)
		detail.append([snappedf(el, 0.001), nt.client.values_total - vb, nt.client.binary_frames - bin0])
		max_backlog = maxi(max_backlog, nt.client.diagnostics()["pending_packets"])
		await next_frame()
	var dt := now_s() - t_start
	detail.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	print("      slowest frames [ms, values, packets]: ", detail.slice(0, 6))
	times.sort()
	var mean := 0.0
	for x in times:
		mean += x
	mean /= times.size()
	var window := seqs.slice(seq_start)
	var gaps := 0
	for i in range(1, window.size()):
		if window[i] != window[i - 1] + 1:
			gaps += 1
	return {
		"frames": times.size(),
		"fps": times.size() / dt,
		"values_per_s": (nt.client.values_total - v0) / dt,
		"mean_ms": mean,
		"p99_ms": times[int(times.size() * 0.99)],
		"max_ms": times[-1],
		"deferred": nt.client.deferred_packets - d0,
		"max_backlog": max_backlog,
		"seq_values": window.size(),
		"seq_gaps": gaps,
	}


func _describe(r: Dictionary) -> String:
	return "%d frames (%.0f fps), %.0f values/s, poll mean %.3f ms, p99 %.3f ms, max %.3f ms, deferred packets %d, max backlog %d, seq %d values %d gaps" % [
		r["frames"], r["fps"], r["values_per_s"], r["mean_ms"], r["p99_ms"], r["max_ms"], r["deferred"], r["max_backlog"], r["seq_values"], r["seq_gaps"]]


func _check_no_drops(r: Dictionary) -> void:
	check(r["seq_values"] > 200, "seq values received (%d)" % r["seq_values"])
	check_eq(r["seq_gaps"], 0, "no dropped seq values")
	check_eq(nt.client.decode_errors, 0, "decode errors")
	check_eq(nt.client.unknown_id_drops, 0, "unknown id drops")
	check_eq(nt.client.coerce_errors, 0, "coerce errors")
	check_eq(nt.client.reconnects, 0, "no reconnects")


func test_poll_cost_with_full_prefix_subscription() -> void:
	if nt == null:
		return
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready() and nt.client.announced_topics().size() >= 438, 5.0, _poll)
	check(nt.client.announced_topics().size() >= 438, "announced topics %d >= 438" % nt.client.announced_topics().size())
	await wait_s(1.0, _poll)
	var r := await _measure(5.0)
	note(_describe(r))
	check(r["values_per_s"] > 3000, "baseline load delivered (%.0f values/s)" % r["values_per_s"])
	check(r["mean_ms"] < 2.0, "mean poll %.3f ms < 2 ms" % r["mean_ms"])
	check(r["p99_ms"] < 2.0, "p99 poll %.3f ms < 2 ms" % r["p99_ms"])
	check(r["max_ms"] < MAX_FRAME_MS, "max poll %.3f ms < %.0f ms" % [r["max_ms"], MAX_FRAME_MS])
	_check_no_drops(r)


## Every filler topic at 50 Hz (about 21k values/s, twenty times the sim). The
## poll budget keeps single frames short; this checks nothing is lost and the
## backlog stays bounded, and records the timing.
func test_stress_all_topics_at_50hz() -> void:
	if nt == null:
		return
	var ctl := nt.publisher(LOAD_HZ, "double")
	ctl.set_value(50.0)
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready() and nt.client.announced_topics().size() >= 438, 5.0, _poll)
	await wait_s(1.0, _poll)
	var r := await _measure(5.0)
	note("stress: " + _describe(r))
	check(r["values_per_s"] > 15000, "stress load delivered (%.0f values/s)" % r["values_per_s"])
	check(r["max_backlog"] < 400, "backlog stays bounded (%d packets)" % r["max_backlog"])
	check(r["max_ms"] < 2.0 * MAX_FRAME_MS, "stress max poll %.3f ms < %.0f ms" % [r["max_ms"], 2.0 * MAX_FRAME_MS])
	_check_no_drops(r)
