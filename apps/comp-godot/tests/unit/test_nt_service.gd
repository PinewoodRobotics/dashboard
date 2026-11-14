extends TestCase

var nt: NtService
var clock: Clock
var transports: Array[FakeTransport] = []


func before_each() -> void:
	nt = NtService.new()
	clock = Clock.new()
	clock.freeze(1_000_000)
	nt.client.clock = clock
	nt.client.transport_factory = func() -> NtTransport:
		var t := FakeTransport.new()
		transports.append(t)
		return t
	nt.configure("127.0.0.1", 5810, 10)


func after_each() -> void:
	nt.free()
	nt = null
	transports.clear()


func _connect() -> void:
	nt.start()
	nt.poll()
	transports[-1].server_accept()
	nt.poll()
	var probe: Array = transports[-1].sent_frames()[0]
	clock.advance_us(1000)
	transports[-1].push_values([[-1, 9_000_000, 2, probe[3]]])
	transports[-1].push_messages([
		{"method": "announce", "params": {"name": "/m/seq", "id": 1, "type": "int", "properties": {}}},
		{"method": "announce", "params": {"name": "/m/x", "id": 2, "type": "double", "properties": {}}},
	])
	nt.poll()


func test_cache_and_live_flags() -> void:
	var seen: Array = []
	nt.on_value("/m/x", func(v: Variant) -> void: seen.append(v))
	check(not nt.has_value("/m/x"))
	check_eq(nt.value("/m/x", -1.0), -1.0, "default before any value")
	_connect()
	check(nt.is_ready())
	transports[-1].push_values([[1, 100, 2, 5], [2, 101, 1, 2.5], [2, 102, 2, 3]])
	nt.poll()
	check_eq(nt.value("/m/seq"), 5)
	check_eq(nt.value("/m/x"), 3.0, "latest value, coerced to double")
	check(nt.is_live("/m/x"))
	check_eq(seen, [2.5, 3.0], "callback per value")
	var e := nt.entry("/m/x")
	check_eq(e["server_ts"], 102)
	check_eq(e["updates"], 2)
	check_eq(e["type"], "double")
	transports[-1].server_close()
	nt.poll()
	check(not nt.is_ready())
	check(not nt.is_live("/m/x"), "stale after disconnect")
	check_eq(nt.value("/m/x"), 3.0, "last value kept while disconnected")


func test_connection_signal() -> void:
	var events: Array = []
	nt.connection_changed.connect(func(c: bool) -> void: events.append(c))
	_connect()
	transports[-1].server_close()
	nt.poll()
	check_eq(events, [true, false])


func test_publisher_handle() -> void:
	var pub := nt.publisher("/Shared/Intake/Speed/Request", "double")
	check(pub.set_value(0.42))
	check_eq(pub.desired_value(), 0.42)
	check(not pub.set_value("x"), "wrong type rejected")
	_connect()
	var sent: Array = transports[-1].sent_frames().filter(func(f: Array) -> bool: return f[0] == pub.pubuid())
	check_eq(sent.size(), 1)
	check_eq(sent[0][3], 0.42)
	pub.clear()
	check_eq(pub.desired_value(), null)
