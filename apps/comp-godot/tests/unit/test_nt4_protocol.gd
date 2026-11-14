extends TestCase


func test_type_numbers() -> void:
	check_eq(Nt4Protocol.type_num("boolean"), 0)
	check_eq(Nt4Protocol.type_num("double"), 1)
	check_eq(Nt4Protocol.type_num("int"), 2)
	check_eq(Nt4Protocol.type_num("float"), 3)
	check_eq(Nt4Protocol.type_num("string"), 4)
	check_eq(Nt4Protocol.type_num("json"), 4)
	check_eq(Nt4Protocol.type_num("raw"), 5)
	check_eq(Nt4Protocol.type_num("string[]"), 20)
	check_eq(Nt4Protocol.type_num("struct:Pose2d"), 5, "unknown types are raw")
	check_eq(Nt4Protocol.type_num("structschema"), 5)


func test_control_messages() -> void:
	var text := Nt4Protocol.encode_text([
		Nt4Protocol.subscribe_msg(3, PackedStringArray(["/matchhud/state/"]), {"prefix": true, "periodic": 0.02}),
		Nt4Protocol.publish_msg(7, "/Shared/X/Request", "string"),
	])
	var parsed: Variant = JSON.parse_string(text)
	check_eq(parsed[0]["method"], "subscribe")
	check_eq(parsed[0]["params"]["topics"], ["/matchhud/state/"])
	check_eq(parsed[0]["params"]["options"]["periodic"], 0.02)
	check_eq(parsed[0]["params"]["options"]["prefix"], true)
	check_eq(parsed[1]["params"]["name"], "/Shared/X/Request")
	check_eq(parsed[1]["params"]["type"], "string")
	check(text.contains("\"properties\":{}"), "publish carries empty properties object: " + text)


func test_parse_announce_converts_ids_to_int() -> void:
	var res := Nt4Protocol.parse_text('[{"method":"announce","params":{"name":"/a","id":12,"type":"double","pubuid":4,"properties":{"retained":true}}},{"method":"unannounce","params":{"name":"/b","id":3}}]')
	check_eq(res["error"], "")
	check_eq(res["messages"].size(), 2)
	check_eq(typeof(res["messages"][0]["params"]["id"]), TYPE_INT)
	check_eq(res["messages"][0]["params"]["id"], 12)
	check_eq(typeof(res["messages"][0]["params"]["pubuid"]), TYPE_INT)
	check_eq(res["messages"][1]["params"]["id"], 3)


func test_parse_bad_text() -> void:
	check(Nt4Protocol.parse_text("{nope")["error"] != "")
	check(Nt4Protocol.parse_text("{}")["error"] != "", "object at top level is rejected")
	check_eq(Nt4Protocol.parse_text('[1, {"x":1}, {"method":"announce","params":{"id":1,"name":"/a","type":"int"}}]')["messages"].size(), 1)


func test_rtt_frame() -> void:
	check_eq(MsgPack.decode(Nt4Protocol.rtt_frame(1234567))["value"], [-1, 0, 2, 1234567])


func test_value_frames_by_type() -> void:
	var cases := [
		["boolean", true, true],
		["double", 3, 3.0],
		["double", -1, -1.0],
		["int", 42, 42],
		["float", 1.5, 1.5],
		["string", "Move Forward", "Move Forward"],
		["raw", PackedByteArray([1, 2]), PackedByteArray([1, 2])],
		["struct:Pose2d", PackedByteArray([7]), PackedByteArray([7])],
		["double[]", [1, 2.5], [1.0, 2.5]],
		["int[]", [1, -2], [1, -2]],
		["boolean[]", [true, false], [true, false]],
		["string[]", PackedStringArray(["a", "b"]), ["a", "b"]],
	]
	for c: Array in cases:
		var frame := Nt4Protocol.value_frame(9, 1000, c[0], c[1])
		check(not frame.is_empty(), "encodes %s" % c[0])
		var v: Array = MsgPack.decode(frame)["value"]
		check_eq(v[0], 9)
		check_eq(v[1], 1000)
		check_eq(v[2], Nt4Protocol.type_num(c[0]), "type num for %s" % c[0])
		check_eq(v[3], c[2], "value for %s" % c[0])
	var dbl := Nt4Protocol.value_frame(1, 1, "double", 0)
	check_eq(dbl[dbl.size() - 9], 0xcb, "doubles always go out as float64")
	var flt := Nt4Protocol.value_frame(1, 1, "float", 0.5)
	check_eq(flt[flt.size() - 5], 0xca, "float topics go out as float32")


func test_unpublishable_values_rejected() -> void:
	check(Nt4Protocol.value_frame(1, 1, "double", NAN).is_empty(), "NaN")
	check(Nt4Protocol.value_frame(1, 1, "double", INF).is_empty(), "Inf")
	check(Nt4Protocol.value_frame(1, 1, "double", "x").is_empty(), "string as double")
	check(Nt4Protocol.value_frame(1, 1, "boolean", 1).is_empty(), "int as bool")
	check(Nt4Protocol.value_frame(1, 1, "double[]", [1, "a"]).is_empty(), "mixed array")
	check(Nt4Protocol.value_frame(1, 1, "string", 5).is_empty(), "int as string")


func test_coerce_to_announced_type() -> void:
	check_eq(Nt4Protocol.coerce(3, "double"), 3.0)
	check_eq(Nt4Protocol.coerce(2.0, "int"), 2)
	check_eq(Nt4Protocol.coerce(1, "boolean"), true)
	check_eq(Nt4Protocol.coerce([1, 2], "double[]"), PackedFloat64Array([1.0, 2.0]))
	check_eq(Nt4Protocol.coerce([1.0, 2], "int[]"), PackedInt64Array([1, 2]))
	check_eq(Nt4Protocol.coerce(["a"], "string[]"), PackedStringArray(["a"]))
	check_eq(Nt4Protocol.coerce(PackedByteArray([1]), "struct:Pose2d"), PackedByteArray([1]))
	check_eq(Nt4Protocol.coerce(PackedByteArray([104, 105]), "string"), "hi")
	check_eq(Nt4Protocol.coerce("x", "double"), null)
	check_eq(Nt4Protocol.coerce([true, 1], "boolean[]"), null)
