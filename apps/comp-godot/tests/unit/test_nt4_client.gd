extends TestCase

const SERVER_T0 := 40_000_000

var clock: Clock
var client: Nt4Client
var transports: Array[FakeTransport] = []
var values: Array = []
var states: Array[int] = []


func before_each() -> void:
	clock = Clock.new()
	clock.freeze(1_000_000)
	client = Nt4Client.new()
	client.clock = clock
	client.transport_factory = func() -> NtTransport:
		var t := FakeTransport.new()
		transports.append(t)
		return t
	client.value_handler = func(batch: Array) -> void:
		for i in range(0, batch.size(), 3):
			values.append([batch[i].name, batch[i + 1], batch[i + 2], batch[i].type])
	client.state_changed.connect(func(s: int, _p: int) -> void: states.append(s))
	client.configure("127.0.0.1", 5810, 2.0)


func after_each() -> void:
	client = null
	transports.clear()


func t() -> FakeTransport:
	return transports[-1]


func connect_ready() -> void:
	client.start()
	client.poll()
	t().server_accept()
	client.poll()
	var probe: Array = t().sent_frames()[0]
	clock.advance_us(2000)
	t().push_values([[-1, SERVER_T0 + 1000, 2, probe[3]]])
	client.poll()


func test_url_and_protocol_offer() -> void:
	client.start()
	check_eq(client.get_state(), Nt4Client.State.CONNECTING)
	check(t().url.begins_with("ws://127.0.0.1:5810/nt/pwrup-godot-"), t().url)
	check_eq(t().offered, PackedStringArray(["networktables.first.wpi.edu"]))


func test_open_sends_rtt_then_batched_subscriptions() -> void:
	client.subscribe(PackedStringArray(["/matchhud/state/"]), {"prefix": true, "periodic": 0.02})
	client.subscribe(PackedStringArray(["/a", "/b"]), {"periodic": 0.1})
	client.start()
	client.poll()
	t().server_accept()
	client.poll()
	check_eq(client.get_state(), Nt4Client.State.SYNCING)
	check_eq(client.selected_protocol(), "networktables.first.wpi.edu")
	var frames := t().sent_frames()
	check_eq(frames.size(), 1, "one RTT probe")
	check_eq(frames[0], [-1, 0, 2, clock.now_us()])
	check_eq(t().sent_text.size(), 1, "subscriptions batched into one text frame")
	var msgs := t().sent_messages()
	check_eq(msgs.size(), 2)
	check_eq(msgs[0]["method"], "subscribe")
	check_eq(msgs[1]["params"]["topics"], ["/a", "/b"])


func test_ready_on_first_rtt_reply_and_offset() -> void:
	connect_ready()
	check_eq(client.get_state(), Nt4Client.State.READY)
	check_eq(client.rtt_us(), 2000)
	check_eq(client.server_time_us(), SERVER_T0 + 2000)
	clock.advance_s(1.0)
	check_eq(client.server_time_us(), SERVER_T0 + 1_002_000)


func test_rtt_probe_every_second() -> void:
	connect_ready()
	var n := t().sent_binary.size()
	clock.advance_us(990_000)
	client.poll()
	check_eq(t().sent_binary.size(), n, "no probe before 1 s")
	clock.advance_us(10_000)
	t().push_values([[-1, SERVER_T0 + 2_000_000, 2, 0]])
	client.poll()
	check_eq(t().sent_binary.size(), n + 1, "probe after 1 s")
	check_eq(t().sent_frames()[-1][0], -1)


func test_values_decode_with_announced_type() -> void:
	connect_ready()
	t().push_messages([
		{"method": "announce", "params": {"name": "/matchhud/state/seq", "id": 3, "type": "int", "properties": {}}},
		{"method": "announce", "params": {"name": "/x/d", "id": 4, "type": "double", "properties": {}}},
		{"method": "announce", "params": {"name": "/x/s", "id": 5, "type": "struct:Pose2d", "properties": {}}},
	])
	t().push_values([[3, 100, 2, 17], [4, 101, 2, 5], [5, 102, 5, PackedByteArray([1, 2])], [99, 103, 1, 1.0]])
	client.poll()
	check_eq(values.size(), 3)
	check_eq(values[0], ["/matchhud/state/seq", 17, 100, "int"])
	check_eq(values[1][1], 5.0, "int on a double topic is coerced")
	check_eq(typeof(values[1][1]), TYPE_FLOAT)
	check_eq(values[2][1], PackedByteArray([1, 2]))
	check_eq(client.diagnostics()["unknown_id_drops"], 1)


func test_publishers_are_desired_state() -> void:
	var pub := client.add_publisher("/Shared/PathPlanner/SelectedPath/Request", "string")
	check(client.set_value(pub, "Auto A"))
	check(not client.set_value(pub, 3), "type mismatch is rejected")
	connect_ready()
	var msgs := t().sent_messages()
	var publish: Array = msgs.filter(func(m: Dictionary) -> bool: return m["method"] == "publish")
	check_eq(publish.size(), 1)
	check_eq(publish[0]["params"]["pubuid"], pub)
	var vals: Array = t().sent_frames().filter(func(f: Array) -> bool: return f[0] == pub)
	check_eq(vals.size(), 1, "desired value sent on READY")
	check_eq(vals[0][3], "Auto A")
	check_eq(vals[0][1], client.server_time_us(), "stamped with the server time estimate")


func test_publish_stamps_monotonic_and_not_ahead() -> void:
	var pub := client.add_publisher("/Shared/Intake/Speed/Request", "double")
	connect_ready()
	client.set_value(pub, 0.1)
	client.set_value(pub, 0.2)
	clock.advance_us(10)
	client.set_value(pub, 0.3)
	var vals: Array = t().sent_frames().filter(func(f: Array) -> bool: return f[0] == pub)
	check_eq(vals.size(), 3)
	var now_est := client.server_time_us()
	check_eq(vals[0][1], now_est - 10)
	check_eq(vals[1][1], vals[0][1] + 1, "same-instant publish gets last+1")
	check_eq(vals[2][1], now_est, "later publish uses the estimate again")
	check_eq(vals[2][3], 0.3)


func test_reconnect_republishes_without_caller_action() -> void:
	var pub := client.add_publisher("/Shared/PathPlanner/SelectedPath/Request", "string")
	client.subscribe(PackedStringArray(["/Shared/PathPlanner/SelectedPath/State"]), {})
	client.set_value(pub, "First")
	connect_ready()
	client.set_value(pub, "Second")
	t().push_messages([{"method": "announce", "params": {"name": "/Shared/PathPlanner/SelectedPath/State", "id": 7, "type": "string", "properties": {}}}])
	client.poll()
	check_eq(client.topic_id("/Shared/PathPlanner/SelectedPath/State"), 7)
	t().server_close()
	client.poll()
	check_eq(client.get_state(), Nt4Client.State.BACKOFF)
	check_eq(client.topic_id("/Shared/PathPlanner/SelectedPath/State"), -1, "ids cleared on close")
	clock.advance_s(1.0)
	client.poll()
	check_eq(transports.size(), 2, "reconnect after 1 s backoff")
	check_eq(client.get_state(), Nt4Client.State.CONNECTING)
	t().server_accept()
	client.poll()
	check_eq(t().sent_messages().size(), 1, "subscription re-sent on open")
	var probe: Array = t().sent_frames()[0]
	clock.advance_us(1000)
	t().push_values([[-1, 5_000, 2, probe[3]]])
	client.poll()
	check_eq(client.get_state(), Nt4Client.State.READY)
	var vals: Array = t().sent_frames().filter(func(f: Array) -> bool: return f[0] == pub)
	check_eq(vals.size(), 1)
	check_eq(vals[0][3], "Second", "latest desired value re-published")
	check_eq(vals[0][1], 5_500, "stamp follows the new server clock (robot reboot)")


func test_cleared_value_not_republished() -> void:
	var pub := client.add_publisher("/x", "double")
	client.set_value(pub, 1.0)
	client.clear_value(pub)
	connect_ready()
	check_eq(t().sent_frames().filter(func(f: Array) -> bool: return f[0] == pub).size(), 0)
	check_eq(t().sent_messages().filter(func(m: Dictionary) -> bool: return m["method"] == "publish").size(), 1, "publisher still announced")


func test_backoff_sequence() -> void:
	client.start()
	var delays: Array[float] = []
	for i in 6:
		t().server_refuse()
		client.poll()
		check_eq(client.get_state(), Nt4Client.State.BACKOFF)
		var n := transports.size()
		var waited := 0.0
		while transports.size() == n and waited < 10.0:
			clock.advance_us(100_000)
			waited += 0.1
			client.poll()
		delays.append(snappedf(waited, 0.1))
	check_eq(delays, [1.0, 2.0, 4.0, 5.0, 5.0, 5.0] as Array[float])


func test_backoff_resets_after_ready() -> void:
	client.start()
	t().server_refuse()
	client.poll()
	clock.advance_s(1.0)
	client.poll()
	t().server_refuse()
	client.poll()
	clock.advance_s(2.0)
	client.poll()
	t().server_accept()
	client.poll()
	var probe: Array = t().sent_frames()[0]
	t().push_values([[-1, SERVER_T0, 2, probe[3]]])
	client.poll()
	check_eq(client.get_state(), Nt4Client.State.READY)
	t().server_close()
	client.poll()
	var n := transports.size()
	clock.advance_s(1.0)
	client.poll()
	check_eq(transports.size(), n + 1, "first retry after READY waits 1 s again")


func test_connect_watchdog() -> void:
	client.start()
	client.poll()
	clock.advance_s(1.99)
	client.poll()
	check_eq(client.get_state(), Nt4Client.State.CONNECTING)
	clock.advance_s(0.02)
	client.poll()
	check(transports[0].closed_by_client, "stuck socket closed")
	check_eq(client.diagnostics()["connect_watchdog_fires"], 1)
	client.poll()
	check_eq(transports.size(), 2, "retried immediately")
	check_eq(client.get_state(), Nt4Client.State.CONNECTING)


func test_liveness_watchdog() -> void:
	connect_ready()
	clock.advance_s(2.9)
	client.poll()
	check_eq(client.get_state(), Nt4Client.State.READY)
	t().push_values([[-1, SERVER_T0 + 3_000_000, 2, 0]])
	client.poll()
	clock.advance_s(2.9)
	client.poll()
	check_eq(client.get_state(), Nt4Client.State.READY, "inbound frame reset the watchdog")
	clock.advance_s(0.2)
	client.poll()
	check_eq(client.get_state(), Nt4Client.State.BACKOFF)
	check(transports[0].closed_by_client)
	check_eq(client.diagnostics()["liveness_fires"], 1)


func test_syncing_keeps_probing_without_reply() -> void:
	client.start()
	client.poll()
	t().server_accept()
	client.poll()
	t().push_text("[]")
	clock.advance_s(1.0)
	client.poll()
	check_eq(client.get_state(), Nt4Client.State.SYNCING)
	check_eq(t().sent_frames().size(), 2, "second probe after 1 s")


func test_host_change_closes_old_socket() -> void:
	connect_ready()
	var old := t()
	client.configure("10.47.65.2", 5810, 2.0)
	check(old.closed_by_client, "old socket closed")
	check_eq(transports.size(), 2)
	check(t().url.begins_with("ws://10.47.65.2:5810/"))


func test_unannounce_and_properties() -> void:
	connect_ready()
	t().push_messages([
		{"method": "announce", "params": {"name": "/p", "id": 1, "type": "double", "properties": {"retained": true}}},
		{"method": "properties", "params": {"name": "/p", "update": {"unit": "m", "retained": null}}},
	])
	client.poll()
	var info: Nt4Client.TopicInfo = client.announced_topics()[0]
	check_eq(info.properties, {"unit": "m"})
	t().push_messages([{"method": "unannounce", "params": {"name": "/p", "id": 1}}])
	t().push_values([[1, 5, 1, 1.0]])
	client.poll()
	check_eq(client.announced_topics().size(), 0)
	check_eq(values.size(), 0)


func test_stop_goes_idle() -> void:
	connect_ready()
	client.stop()
	check_eq(client.get_state(), Nt4Client.State.IDLE)
	check(transports[0].closed_by_client)
	clock.advance_s(10)
	client.poll()
	check_eq(transports.size(), 1)
