extends TestCase


func _frames() -> Array:
	return [
		[3, 1794644876875594, 1, 447.074],
		[-1, 123, 2, 4567],
		[300, 4_000_000_000, 2, -9223372036854775807 - 1],
		[70000, 5, 0, true],
		[1, 6, 0, false],
		[2, 7, 4, "fixstr"],
		[4, 8, 4, "long string ".repeat(5)],
		[5, 9, 2, -5],
		[6, 10, 2, 200],
		[7, 11, 2, -300],
		[8, 12, 2, 70000],
		[9, 13, 2, -70000],
		[10, 14, 5, PackedByteArray([1, 2, 3])],
		[11, 15, 17, [1.0, 2.5]],
		[12, 16, 20, ["a", "b"]],
		[13, 17, 2, 9223372036854775807],
	]


func _encode(frames: Array) -> PackedByteArray:
	var w := MsgPack.Writer.new()
	for f: Variant in frames:
		w.write_value(f)
	return w.bytes()


func test_matches_generic_decoder() -> void:
	var bytes := _encode(_frames())
	var w := MsgPack.Writer.new()
	w.write_array_header(4)
	w.write_int(14)
	w.write_int(18)
	w.write_int(3)
	w.write_float32(0.25)
	bytes.append_array(w.bytes())
	var out := []
	check_eq(Nt4FrameDecoder.decode(bytes, out), "")
	var generic: Array = MsgPack.decode_all(bytes)["values"]
	check_eq(out.size(), generic.size() * 3)
	for i in generic.size():
		var g: Array = generic[i]
		check_eq(out.slice(i * 3, i * 3 + 3), [g[0], g[1], g[3]], "frame %d" % i)


func test_truncated_tail_keeps_prefix() -> void:
	var good := _encode(_frames().slice(0, 3))
	for cut in range(1, 12):
		var tail := _encode([[9, 1794644876875594, 1, 1.5]])
		var bytes := good.duplicate()
		bytes.append_array(tail.slice(0, tail.size() - cut))
		var out := []
		var err := Nt4FrameDecoder.decode(bytes, out)
		check_eq(err, "truncated", "cut %d" % cut)
		check_eq(out.size(), 9, "prefix kept for cut %d" % cut)


func test_non_frame_values_rejected() -> void:
	var bytes := _encode([[1, 2, 1, 0.5], "not a frame", [3, 4, 1, 1.5]])
	var out := []
	check(Nt4FrameDecoder.decode(bytes, out).begins_with("malformed"))
	check_eq(out, [1, 2, 0.5])


func test_empty() -> void:
	var out := []
	check_eq(Nt4FrameDecoder.decode(PackedByteArray(), out), "")
	check_eq(out.size(), 0)
