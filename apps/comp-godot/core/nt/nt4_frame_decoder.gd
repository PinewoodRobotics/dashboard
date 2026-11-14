class_name Nt4FrameDecoder
extends RefCounted

## Longest frame the fast path reads: 0x94, u16 id, u64 ts, fixint type, float64.
const FAST_PATH_BYTES := 23


## Decodes back-to-back msgpack [id, ts, typeNum, value] frames. Appends id, ts,
## value (flat, stride 3; typeNum is dropped because values are coerced to the
## announced type) to `out` and returns "" or the error that stopped decoding;
## everything decoded before the error is kept.
##
## The common ntcore encodings (fixint or u16 id, u32 or u64 timestamp, fixint
## type, float64/bool/fixint value) are decoded inline; anything else goes
## through the generic MsgPack.Reader. Big-endian fields are read from a
## byte-reversed copy with the native little-endian decoders: a big-endian
## field at [q, q+k) is the little-endian field at n-q-k in the reversed copy.
static func decode(b: PackedByteArray, out: Array) -> String:
	var n := b.size()
	if n == 0:
		return ""
	var rb := b.duplicate()
	rb.reverse()
	var reader: MsgPack.Reader = null
	var p := 0
	while p < n:
		if b[p] == 0x94 and p + FAST_PATH_BYTES <= n:
			var q := p + 1
			var t: int = b[q]
			var id := 0
			var ok := true
			if t < 0x80:
				id = t
				q += 1
			elif t == 0xcd:
				id = rb.decode_u16(n - q - 3)
				q += 3
			elif t == 0xff:
				id = -1
				q += 1
			else:
				ok = false
			var ts := 0
			if ok:
				t = b[q]
				if t == 0xcf:
					ts = rb.decode_s64(n - q - 9)
					q += 9
				elif t == 0xce:
					ts = rb.decode_u32(n - q - 5)
					q += 5
				elif t < 0x80:
					ts = t
					q += 1
				else:
					ok = false
			if ok:
				ok = b[q] < 0x80
				q += 1
			if ok:
				t = b[q]
				var value: Variant
				if t == 0xcb:
					value = rb.decode_double(n - q - 9)
					q += 9
				elif t == 0xc3:
					value = true
					q += 1
				elif t == 0xc2:
					value = false
					q += 1
				elif t < 0x80:
					value = t
					q += 1
				else:
					ok = false
				if ok:
					out.append(id)
					out.append(ts)
					out.append(value)
					p = q
					continue
		if reader == null:
			reader = MsgPack.Reader.new(b)
		var start := p
		reader.p = p
		var v: Variant = reader.read_value()
		if reader.err != "":
			return reader.err
		p = reader.p
		if typeof(v) == TYPE_ARRAY and v.size() == 4 and typeof(v[0]) == TYPE_INT and typeof(v[1]) == TYPE_INT and typeof(v[2]) == TYPE_INT:
			out.append(v[0])
			out.append(v[1])
			out.append(v[3])
		else:
			return "malformed value frame at %d" % start
	return ""
