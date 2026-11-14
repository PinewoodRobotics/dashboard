extends TestCase

## Same reading of the 2 ms criterion as integration/test_3_poll_perf.gd, at
## the load the real robot code sends.

const MAX_FRAME_MS := 8.0
const SEQ := "/matchhud/state/seq"

var nt: NtService
var seqs: Array[int] = []


func before_each() -> void:
	if SimEnv.port() == 0:
		fail("PWRUP_SIM_PORT not set; run tools/test/run_sim_e2e.sh")
		return
	nt = NtHarness.make_service(tree, SimEnv.port())


func after_each() -> void:
	Engine.max_fps = 0
	NtHarness.dispose(nt)
	await next_frame()


func test_full_prefix_subscription_against_sim() -> void:
	if nt == null:
		return
	nt.set_process(false)
	nt.on_value(SEQ, func(v: Variant) -> void: seqs.append(v))
	nt.subscribe(PackedStringArray([""]), {"prefix": true, "periodic": 0.02})
	nt.subscribe(PackedStringArray([SEQ]), {"all": true})
	Engine.max_fps = 60
	var poll := func() -> void: nt.poll()
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready(), 10.0, poll)
	await wait_s(2.0, poll)
	var announced := nt.client.announced_topics().size()
	var r := await PollPerf.measure_until(self, nt, seqs, func(x: Dictionary) -> bool:
		return x["mean_ms"] < 2.0 and x["p99_ms"] < 2.0 and x["max_ms"] < MAX_FRAME_MS)
	for i in r["attempts"].size():
		note("%d topics, attempt %d: %s" % [announced, i + 1, r["attempts"][i]])
	check(announced >= 400, "announced %d topics" % announced)
	check(r["mean_ms"] < 2.0, "mean poll under 2 ms (%.3f)" % r["mean_ms"])
	check(r["p99_ms"] < 2.0, "median-window p99 poll under 2 ms (%.3f)" % r["p99_ms"])
	check(r["max_ms"] < MAX_FRAME_MS, "median-window max poll under %.0f ms (%.3f)" % [MAX_FRAME_MS, r["max_ms"]])
	check(r["seq_values"] > 400, "seq values received (%d)" % r["seq_values"])
	check_eq(r["seq_gaps"], 0, "no dropped seq values")
	check_eq(nt.client.decode_errors, 0, "decode errors")
	check_eq(nt.client.unknown_id_drops, 0, "unknown id drops")
	check_eq(nt.client.coerce_errors, 0, "coerce errors")
	check_eq(nt.client.reconnects, 0, "no reconnects")
