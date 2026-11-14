extends TestCase


func _b(arr: Array) -> PackedByteArray:
	return PackedByteArray(arr)


func _dec(arr: Array) -> Variant:
	var r := MsgPack.decode(_b(arr))
	check_eq(r["error"], "", "decode error for %s" % [arr])
	return r["value"]


func test_nil_and_bool() -> void:
	check_eq(_dec([0xc0]), null)
	check_eq(_dec([0xc2]), false)
	check_eq(_dec([0xc3]), true)


func test_fixints() -> void:
	check_eq(_dec([0x00]), 0)
	check_eq(_dec([0x7f]), 127)
	check_eq(_dec([0xff]), -1)
	check_eq(_dec([0xe0]), -32)


func test_unsigned_ints() -> void:
	check_eq(_dec([0xcc, 0xff]), 255)
	check_eq(_dec([0xcd, 0x01, 0x00]), 256)
	check_eq(_dec([0xcd, 0xff, 0xff]), 65535)
	check_eq(_dec([0xce, 0xff, 0xff, 0xff, 0xff]), 4294967295)
	check_eq(_dec([0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]), 4294967296)
	check_eq(_dec([0xcf, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), 9223372036854775807)
	check_eq(_dec([0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), MsgPack.INT64_MAX, "uint64 max clamps")


func test_signed_ints() -> void:
	check_eq(_dec([0xd0, 0x80]), -128)
	check_eq(_dec([0xd0, 0x7f]), 127)
	check_eq(_dec([0xd1, 0x80, 0x00]), -32768)
	check_eq(_dec([0xd2, 0x80, 0x00, 0x00, 0x00]), -2147483648)
	check_eq(_dec([0xd2, 0xff, 0xff, 0xff, 0xfe]), -2)
	check_eq(_dec([0xd3, 0x80, 0, 0, 0, 0, 0, 0, 0]), -9223372036854775807 - 1)
	check_eq(_dec([0xd3, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), 9223372036854775807)
	check_eq(_dec([0xd3, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), -1)


func test_floats() -> void:
	check_eq(_dec([0xca, 0x3f, 0xc0, 0x00, 0x00]), 1.5)
	check_eq(_dec([0xca, 0xc0, 0x20, 0x00, 0x00]), -2.5)
	check_eq(_dec([0xcb, 0x40, 0x09, 0x21, 0xfb, 0x54, 0x44, 0x2d, 0x18]), PI)
	check_eq(_dec([0xcb, 0xbf, 0xf0, 0, 0, 0, 0, 0, 0]), -1.0)


func test_strings() -> void:
	check_eq(_dec([0xa0]), "")
	check_eq(_dec([0xa3, 0x61, 0x62, 0x63]), "abc")
	var long := "x".repeat(40)
	var arr := [0xd9, 40]
	arr.append_array(long.to_utf8_buffer())
	check_eq(_dec(arr), long)
	var utf := "Höhe°"
	var raw := utf.to_utf8_buffer()
	var arr2 := [0xa0 | raw.size()]
	arr2.append_array(raw)
	check_eq(_dec(arr2), utf)
	var big := "y".repeat(300)
	var arr3 := [0xda, 0x01, 0x2c]
	arr3.append_array(big.to_utf8_buffer())
	check_eq(_dec(arr3), big)


func test_bin() -> void:
	check_eq(_dec([0xc4, 0x03, 1, 2, 3]), PackedByteArray([1, 2, 3]))
	check_eq(_dec([0xc4, 0x00]), PackedByteArray())
	var arr := [0xc5, 0x01, 0x00]
	for i in 256:
		arr.append(i)
	var v: PackedByteArray = _dec(arr)
	check_eq(v.size(), 256)
	check_eq(v[255], 255)


func test_arrays_and_maps() -> void:
	check_eq(_dec([0x90]), [])
	check_eq(_dec([0x93, 0x01, 0xc3, 0xa1, 0x7a]), [1, true, "z"])
	check_eq(_dec([0x92, 0x91, 0x01, 0x90]), [[1], []])
	var arr := [0xdc, 0x00, 0x11]
	for i in 17:
		arr.append(i)
	check_eq((_dec(arr) as Array).size(), 17)
	check_eq(_dec([0x81, 0xa1, 0x61, 0x02]), {"a": 2})


func test_nt_value_frame_shape() -> void:
	# [5, 123456789, 1, 2.5] as ntcore sends it.
	var arr := [0x94, 0x05, 0xce, 0x07, 0x5b, 0xcd, 0x15, 0x01, 0xcb, 0x40, 0x04, 0, 0, 0, 0, 0, 0]
	check_eq(_dec(arr), [5, 123456789, 1, 2.5])


func test_concatenated_values() -> void:
	var w := MsgPack.Writer.new()
	w.write_value([1, 100, 2, 7])
	w.write_value([2, 101, 0, true])
	w.write_value([3, 102, 4, "hello"])
	w.write_value([-1, 5000, 2, 4000])
	var res := MsgPack.decode_all(w.bytes())
	check_eq(res["error"], "")
	check_eq(res["values"].size(), 4)
	check_eq(res["values"][2], [3, 102, 4, "hello"])
	check_eq(res["values"][3], [-1, 5000, 2, 4000])
	check_eq(res["offset"], w.bytes().size())


func test_corrupt_tail_keeps_prefix() -> void:
	var w := MsgPack.Writer.new()
	w.write_value([1, 100, 1, 1.25])
	w.write_value([2, 200, 4, "ok"])
	var good := w.bytes()
	var truncated := good.duplicate()
	truncated.append_array(PackedByteArray([0x94, 0x03, 0xcd, 0x01]))
	var res := MsgPack.decode_all(truncated)
	check_eq(res["values"].size(), 2, "prefix values")
	check_eq(res["values"][0], [1, 100, 1, 1.25])
	check_eq(res["error"], "truncated")
	check_eq(res["offset"], good.size())
	var invalid := good.duplicate()
	invalid.append(0xc1)
	var res2 := MsgPack.decode_all(invalid)
	check_eq(res2["values"].size(), 2)
	check(res2["error"].begins_with("invalid byte"), "invalid byte error: " + res2["error"])
	var huge := good.duplicate()
	huge.append_array(PackedByteArray([0xdd, 0x7f, 0xff, 0xff, 0xff]))
	var res3 := MsgPack.decode_all(huge)
	check_eq(res3["values"].size(), 2, "huge array header does not allocate")
	check_eq(res3["error"], "truncated")


func test_truncated_scalars() -> void:
	for arr: Array in [[0xcd, 0x01], [0xcb, 0x40, 0x09], [0xa5, 0x61], [0xc4, 0x05, 1], [0xd3, 0, 0]]:
		var r := MsgPack.decode(_b(arr))
		check_eq(r["error"], "truncated", "for %s" % [arr])


func test_encoder_int_widths() -> void:
	check_eq(MsgPack.encode(5), _b([0x05]))
	check_eq(MsgPack.encode(-1), _b([0xff]))
	check_eq(MsgPack.encode(200), _b([0xcc, 200]))
	check_eq(MsgPack.encode(-100), _b([0xd0, 0x9c]))
	check_eq(MsgPack.encode(70000), _b([0xce, 0x00, 0x01, 0x11, 0x70]))
	for v: int in [0, 1, 127, 128, 255, 256, 65535, 65536, 4294967295, 4294967296, 9223372036854775807, -1, -32, -33, -128, -129, -32768, -32769, -2147483648, -2147483649, -9223372036854775807 - 1]:
		check_eq(MsgPack.decode(MsgPack.encode(v))["value"], v, "round trip %d" % v)


func test_encoder_doubles_always_float64() -> void:
	check_eq(MsgPack.encode(0.0), _b([0xcb, 0, 0, 0, 0, 0, 0, 0, 0]))
	check_eq(MsgPack.encode(-1.0)[0], 0xcb)
	var w := MsgPack.Writer.new()
	w.write_float32(1.5)
	check_eq(w.bytes(), _b([0xca, 0x3f, 0xc0, 0x00, 0x00]))
	check_eq(MsgPack.decode(MsgPack.encode(0.1))["value"], 0.1)


func test_encoder_round_trip_mixed() -> void:
	var v := [1, -2, 3.25, "s", true, null, PackedByteArray([9, 8]), [1, [2, "x".repeat(70000)]], {"k": 1}]
	var r := MsgPack.decode(MsgPack.encode(v))
	check_eq(r["error"], "")
	check_eq(r["value"], v)
