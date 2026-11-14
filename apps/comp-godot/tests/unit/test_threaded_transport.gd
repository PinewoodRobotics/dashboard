extends TestCase


class StuckOpenTransport:
	extends NtTransport

	var block_ms := 0

	func open(_url: String, _protocols: PackedStringArray) -> Error:
		OS.delay_msec(block_ms)
		return OK

	func get_state() -> int:
		return STATE_CONNECTING


func _stuck_transport(block_ms: int) -> ThreadedTransport:
	return ThreadedTransport.new(func() -> NtTransport:
		var t := StuckOpenTransport.new()
		t.block_ms = block_ms
		return t)


func test_close_does_not_wait_for_a_blocked_worker() -> void:
	var tr := _stuck_transport(400)
	check_eq(tr.open("ws://example.invalid:5810/nt/x", PackedStringArray()), OK)
	await wait_s(0.02)
	var t0 := Time.get_ticks_usec()
	tr.close(1000)
	var close_ms := (Time.get_ticks_usec() - t0) / 1000.0
	note("close() with the worker stuck in open(): %.3f ms" % close_ms)
	check(close_ms < 5.0, "close returned in %.3f ms" % close_ms)
	check_eq(tr.get_state(), NtTransport.STATE_CLOSED)
	check(ThreadedTransport.pending_closes() >= 1, "worker parked until it returns")
	var reaped := await wait_until(func() -> bool:
		ThreadedTransport.reap()
		return ThreadedTransport.pending_closes() == 0, 2.0)
	check(reaped >= 0.0, "worker joined after open() returned")


func test_reconnect_during_a_blocked_connect_does_not_stall_the_caller() -> void:
	var client := Nt4Client.new()
	client.transport_factory = func() -> NtTransport: return _stuck_transport(300)
	client.configure("example.invalid", 5810, 1.0)
	client.start()
	await wait_s(0.02)
	var worst_ms := 0.0
	for i in 3:
		var t0 := Time.get_ticks_usec()
		client.reconnect()
		worst_ms = maxf(worst_ms, (Time.get_ticks_usec() - t0) / 1000.0)
	check(worst_ms < 5.0, "reconnect() returned in %.3f ms" % worst_ms)
	check_eq(client.get_state(), Nt4Client.State.CONNECTING)
	client.stop()
	ThreadedTransport.join_all()
	check_eq(ThreadedTransport.pending_closes(), 0)
