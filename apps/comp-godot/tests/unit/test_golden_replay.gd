extends TestCase

var golden: Dictionary


func before_each() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/golden/sim_handshake.json"))
	golden = data if typeof(data) == TYPE_DICTIONARY else {}


func _packets(key: String) -> Array:
	var out := []
	for f: Dictionary in golden.get(key, []):
		if f.has("text"):
			out.append({"text": true, "data": f["text"]})
		else:
			out.append({"text": false, "data": Marshalls.base64_to_raw(f["binary_b64"])})
	return out


func test_golden_file_shape() -> void:
	check(not golden.is_empty(), "golden file parses")
	check_eq(golden.get("protocol"), Nt4Protocol.PROTOCOL_V40)
	check_eq(golden.get("frames", []).size(), 20)
	check(golden.get("continuation", []).size() > 0, "continuation frames captured")


func test_replay_reaches_ready_and_decodes() -> void:
	var first := _packets("frames")
	var rest := _packets("continuation")
	if first.is_empty():
		fail("no golden frames")
		return
	var echo := -1
	var server_ts := -1
	for p: Dictionary in first:
		if not p["text"]:
			var v: Variant = MsgPack.decode_all(p["data"])["values"][0]
			if v[0] == -1:
				echo = v[3]
				server_ts = v[1]
	check(echo > 0, "golden contains the RTT reply")

	var clock := Clock.new()
	clock.freeze(echo)
	var transports: Array[FakeTransport] = []
	var client := Nt4Client.new()
	client.clock = clock
	client.transport_factory = func() -> NtTransport:
		var t := FakeTransport.new()
		transports.append(t)
		return t
	var values := {}
	client.value_handler = func(batch: Array) -> void:
		for i in range(0, batch.size(), 3):
			values[batch[i].name] = batch[i + 1]
	for g: Dictionary in golden.get("subscriptions", []):
		client.subscribe(PackedStringArray(g["topics"]), g["options"])
	client.configure("127.0.0.1", 5810, 10)
	client.start()
	client.poll()
	transports[0].server_accept(golden["protocol"])
	client.poll()
	clock.advance_us(1500)
	for p: Dictionary in first + rest:
		if p["text"]:
			transports[0].push_text(p["data"])
		else:
			transports[0].push_binary(p["data"])
	for i in 20:
		client.poll()
	check_eq(client.get_state(), Nt4Client.State.READY, "READY from the recorded RTT reply")
	check_eq(client.rtt_us(), 1500)
	check_eq(client.server_time_us(), server_ts + 750 + 0, "server time from the recorded reply")
	check_eq(client.decode_errors, 0)
	check_eq(client.coerce_errors, 0)
	check_eq(client.unknown_id_drops, 0)
	check(client.announced_topics().size() >= 19, "announces registered (%d)" % client.announced_topics().size())
	check(values.has("/matchhud/state/seq"), "seq decoded from the recorded value frames")
	check_eq(typeof(values.get("/matchhud/state/seq")), TYPE_INT)
	var expected_types := {"double": TYPE_FLOAT, "int": TYPE_INT, "boolean": TYPE_BOOL, "string": TYPE_STRING}
	var checked := 0
	for info: Nt4Client.TopicInfo in client.announced_topics():
		if values.has(info.name) and expected_types.has(info.type):
			check_eq(typeof(values[info.name]), expected_types[info.type], "value type of " + info.name)
			checked += 1
	check(checked >= 5, "typed values checked (%d)" % checked)
	note("decoded %d topics from %d recorded frames" % [values.size(), first.size() + rest.size()])
