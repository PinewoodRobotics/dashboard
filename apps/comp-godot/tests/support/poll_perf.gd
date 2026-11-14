class_name PollPerf
extends RefCounted

## Frame-time statistics for NtService.poll() at 60 fps, measured in several
## windows. Gates use the median window, and a measurement whose timing misses
## the gate is retried, so OS scheduling noise on a loaded dev machine (single
## frames of 2 to 11 ms while decoding one small packet, or a whole window
## slowed when the main thread lands on an efficiency core) cannot fail a run,
## while a cost that is really there fails every attempt.

const WINDOWS := 5
const WINDOW_S := 2.0
const ATTEMPTS := 3


## timing_ok(r) -> bool decides whether an attempt meets the timing gate. The
## result is the first passing attempt, or the last one, with every attempt's
## description under "attempts" and seq gaps summed over all attempts.
static func measure_until(tc: TestCase, nt: NtService, seqs: Array, timing_ok: Callable) -> Dictionary:
	var r := {}
	var attempts: Array[String] = []
	var gaps := 0
	for a in ATTEMPTS:
		r = await measure(tc, nt, seqs)
		attempts.append(describe(r))
		gaps += r["seq_gaps"]
		if timing_ok.call(r):
			break
	r["attempts"] = attempts
	r["seq_gaps"] = gaps
	return r


static func measure(tc: TestCase, nt: NtService, seqs: Array) -> Dictionary:
	var window_p99: Array[float] = []
	var window_max: Array[float] = []
	var all_times: Array[float] = []
	var slowest: Array = []
	var max_backlog := 0
	var seq_start := seqs.size()
	var v0 := nt.client.values_total
	var d0 := nt.client.deferred_packets
	var t_start := tc.now_s()
	for w in WINDOWS:
		var times: Array[float] = []
		var w_start := tc.now_s()
		while tc.now_s() - w_start < WINDOW_S:
			var vb := nt.client.values_total
			var bin0 := nt.client.binary_frames
			var t0 := Time.get_ticks_usec()
			nt.poll()
			var el := (Time.get_ticks_usec() - t0) / 1000.0
			times.append(el)
			slowest.append([snappedf(el, 0.001), nt.client.values_total - vb, nt.client.binary_frames - bin0])
			max_backlog = maxi(max_backlog, nt.client.diagnostics()["pending_packets"])
			await tc.next_frame()
		times.sort()
		window_p99.append(times[int(times.size() * 0.99)])
		window_max.append(times[-1])
		all_times.append_array(times)
	var dt := tc.now_s() - t_start
	slowest.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var mean := 0.0
	for x in all_times:
		mean += x
	mean /= all_times.size()
	var window := seqs.slice(seq_start)
	var gaps := 0
	for i in range(1, window.size()):
		if window[i] != window[i - 1] + 1:
			gaps += 1
	return {
		"frames": all_times.size(),
		"fps": all_times.size() / dt,
		"values_per_s": (nt.client.values_total - v0) / dt,
		"mean_ms": mean,
		"p99_ms": _median(window_p99),
		"max_ms": _median(window_max),
		"window_p99_ms": window_p99.map(func(x: float) -> float: return snappedf(x, 0.001)),
		"window_max_ms": window_max.map(func(x: float) -> float: return snappedf(x, 0.001)),
		"worst_ms": all_times.max(),
		"slowest": slowest.slice(0, 6),
		"deferred": nt.client.deferred_packets - d0,
		"max_backlog": max_backlog,
		"seq_values": window.size(),
		"seq_gaps": gaps,
	}


static func describe(r: Dictionary) -> String:
	return ("%d frames (%.0f fps), %.0f values/s, poll mean %.3f ms, median-window p99 %.3f ms and max %.3f ms, worst frame %.3f ms, window p99 %s, window max %s, slowest [ms, values, packets] %s, deferred packets %d, max backlog %d, seq %d values %d gaps" % [
		r["frames"], r["fps"], r["values_per_s"], r["mean_ms"], r["p99_ms"], r["max_ms"], r["worst_ms"],
		r["window_p99_ms"], r["window_max_ms"], r["slowest"], r["deferred"], r["max_backlog"], r["seq_values"], r["seq_gaps"]])


static func _median(xs: Array[float]) -> float:
	var s := xs.duplicate()
	s.sort()
	return s[s.size() / 2]
