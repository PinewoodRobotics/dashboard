extends TestCase

var nt: NtService


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
	nt.subscribe(PackedStringArray([""]), {"prefix": true, "periodic": 0.02})
	Engine.max_fps = 60
	var poll := func() -> void: nt.poll()
	nt.start()
	await wait_until(func() -> bool: return nt.is_ready(), 10.0, poll)
	await wait_s(2.0, poll)
	var announced := nt.client.announced_topics().size()
	var v0: int = nt.client.values_total
	var times: Array[float] = []
	var t_start := now_s()
	while now_s() - t_start < 5.0:
		var t0 := Time.get_ticks_usec()
		nt.poll()
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
		await next_frame()
	var dt := now_s() - t_start
	times.sort()
	var mean := 0.0
	for x in times:
		mean += x
	mean /= times.size()
	var p99: float = times[int(times.size() * 0.99)]
	note("%d topics, %.0f values/s, poll mean %.3f ms, p99 %.3f ms, max %.3f ms" % [announced, (nt.client.values_total - v0) / dt, mean, p99, times[-1]])
	check(announced >= 400, "announced %d topics" % announced)
	check(p99 < 2.0, "p99 poll under 2 ms (%.3f)" % p99)
	check_eq(nt.client.decode_errors, 0)
	check_eq(nt.client.unknown_id_drops, 0)
	check_eq(nt.client.coerce_errors, 0)
