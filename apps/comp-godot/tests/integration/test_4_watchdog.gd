extends TestCase


func test_connect_watchdog_closes_and_retries() -> void:
	var server := TCPServer.new()
	check_eq(server.listen(0, "127.0.0.1"), OK, "listen")
	var port := server.get_local_port()
	var nt := NtHarness.make_service(tree, port, 2.0)
	nt.start()
	var accepted: Array[StreamPeerTCP] = []
	var accept_times: Array[float] = []
	var first_closed_at := -1.0
	var t_start := now_s()
	while now_s() - t_start < 8.0 and accepted.size() < 3:
		while server.is_connection_available():
			accepted.append(server.take_connection())
			accept_times.append(now_s())
		if accepted.size() >= 1 and first_closed_at < 0.0:
			var c := accepted[0]
			c.poll()
			var r := c.get_partial_data(1)
			if c.get_status() != StreamPeerTCP.STATUS_CONNECTED or r[0] != OK:
				first_closed_at = now_s()
		await next_frame()
	NtHarness.dispose(nt)
	server.stop()
	check(accepted.size() >= 2, "client retried (%d connections)" % accepted.size())
	if accepted.size() < 2:
		return
	var retry := accept_times[1] - accept_times[0]
	var closed := first_closed_at - accept_times[0]
	note("first socket closed after %.3f s, retry after %.3f s" % [closed, retry])
	check(first_closed_at > 0.0, "first socket was closed")
	check(closed >= 1.9 and closed <= 3.0, "closed within 2..3 s (%.3f)" % closed)
	check(retry >= 2.0 and retry <= 3.0, "retried within 2..3 s (%.3f)" % retry)
	check_eq(nt.client.diagnostics()["connect_watchdog_fires"] >= 1, true, "watchdog fired")
