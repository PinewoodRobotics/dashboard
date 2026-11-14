class_name MsgPack
extends RefCounted

const INT64_MAX := 9223372036854775807


static func encode(value: Variant) -> PackedByteArray:
	var w := Writer.new()
	w.write_value(value)
	return w.bytes()


static func decode(bytes: PackedByteArray) -> Dictionary:
	var r := Reader.new(bytes)
	var v: Variant = r.read_value()
	if r.err == "" and r.p != r.n:
		r.err = "trailing bytes"
	return {"value": v if r.err == "" else null, "error": r.err}


## Decodes back-to-back values. On a corrupt or truncated tail, returns the
## values decoded before it, the byte offset where decoding stopped and the error.
static func decode_all(bytes: PackedByteArray) -> Dictionary:
	var r := Reader.new(bytes)
	var values := []
	while r.p < r.n:
		var start := r.p
		var v: Variant = r.read_value()
		if r.err != "":
			return {"values": values, "error": r.err, "offset": start}
		values.append(v)
	return {"values": values, "error": "", "offset": r.p}


class Reader:
	var b: PackedByteArray
	var p := 0
	var n := 0
	var err := ""
	var _spb: StreamPeerBuffer

	func _init(bytes: PackedByteArray) -> void:
		b = bytes
		n = bytes.size()

	func _need(k: int) -> bool:
		if p + k > n:
			err = "truncated"
			return false
		return true

	func _uint(k: int) -> int:
		if not _need(k):
			return 0
		var v := 0
		for i in k:
			v = (v << 8) | b[p + i]
		p += k
		return v

	func _sint(k: int) -> int:
		var v := _uint(k)
		if k < 8:
			var sign_bit := 1 << (k * 8 - 1)
			if v & sign_bit:
				v -= sign_bit << 1
		return v

	func _float(k: int) -> float:
		if not _need(k):
			return 0.0
		if _spb == null:
			_spb = StreamPeerBuffer.new()
			_spb.big_endian = true
			_spb.data_array = b
		_spb.seek(p)
		p += k
		return _spb.get_double() if k == 8 else _spb.get_float()

	func _str(length: int) -> String:
		if not _need(length):
			return ""
		var s := b.slice(p, p + length).get_string_from_utf8()
		p += length
		return s

	func _bin(length: int) -> PackedByteArray:
		if not _need(length):
			return PackedByteArray()
		var out := b.slice(p, p + length)
		p += length
		return out

	func _array(length: int) -> Array:
		if length > n - p:
			err = "truncated"
			return []
		var a := []
		a.resize(length)
		for i in length:
			a[i] = read_value()
			if err != "":
				return []
		return a

	func _map(length: int) -> Dictionary:
		if length * 2 > n - p:
			err = "truncated"
			return {}
		var d := {}
		for i in length:
			var k: Variant = read_value()
			if err != "":
				return {}
			var v: Variant = read_value()
			if err != "":
				return {}
			d[k] = v
		return d

	func _ext(length: int) -> Dictionary:
		var t := _sint(1)
		var data := _bin(length)
		return {"ext_type": t, "data": data}

	func read_value() -> Variant:
		if p >= n:
			err = "truncated"
			return null
		var t: int = b[p]
		p += 1
		if t <= 0x7f:
			return t
		if t >= 0xe0:
			return t - 256
		if t >= 0xa0 and t <= 0xbf:
			return _str(t & 0x1f)
		if t >= 0x90 and t <= 0x9f:
			return _array(t & 0x0f)
		if t >= 0x80 and t <= 0x8f:
			return _map(t & 0x0f)
		match t:
			0xc0:
				return null
			0xc2:
				return false
			0xc3:
				return true
			0xcc:
				return _uint(1)
			0xcd:
				return _uint(2)
			0xce:
				return _uint(4)
			0xcf:
				var v := _uint(8)
				# uint64 above INT64_MAX does not fit a GDScript int.
				return INT64_MAX if v < 0 else v
			0xd0:
				return _sint(1)
			0xd1:
				return _sint(2)
			0xd2:
				return _sint(4)
			0xd3:
				return _sint(8)
			0xca:
				return _float(4)
			0xcb:
				return _float(8)
			0xd9:
				return _str(_uint(1))
			0xda:
				return _str(_uint(2))
			0xdb:
				return _str(_uint(4))
			0xc4:
				return _bin(_uint(1))
			0xc5:
				return _bin(_uint(2))
			0xc6:
				return _bin(_uint(4))
			0xdc:
				return _array(_uint(2))
			0xdd:
				return _array(_uint(4))
			0xde:
				return _map(_uint(2))
			0xdf:
				return _map(_uint(4))
			0xd4:
				return _ext(1)
			0xd5:
				return _ext(2)
			0xd6:
				return _ext(4)
			0xd7:
				return _ext(8)
			0xd8:
				return _ext(16)
			0xc7:
				return _ext(_uint(1))
			0xc8:
				return _ext(_uint(2))
			0xc9:
				return _ext(_uint(4))
		err = "invalid byte 0x%02x at %d" % [t, p - 1]
		return null


class Writer:
	var _s := StreamPeerBuffer.new()

	func _init() -> void:
		_s.big_endian = true

	func bytes() -> PackedByteArray:
		return _s.data_array

	func write_nil() -> void:
		_s.put_u8(0xc0)

	func write_bool(v: bool) -> void:
		_s.put_u8(0xc3 if v else 0xc2)

	func write_int(v: int) -> void:
		if v >= 0:
			if v <= 0x7f:
				_s.put_u8(v)
			elif v <= 0xff:
				_s.put_u8(0xcc)
				_s.put_u8(v)
			elif v <= 0xffff:
				_s.put_u8(0xcd)
				_s.put_u16(v)
			elif v <= 0xffffffff:
				_s.put_u8(0xce)
				_s.put_u32(v)
			else:
				_s.put_u8(0xcf)
				_s.put_u64(v)
		else:
			if v >= -32:
				_s.put_u8(v + 256)
			elif v >= -128:
				_s.put_u8(0xd0)
				_s.put_8(v)
			elif v >= -32768:
				_s.put_u8(0xd1)
				_s.put_16(v)
			elif v >= -2147483648:
				_s.put_u8(0xd2)
				_s.put_32(v)
			else:
				_s.put_u8(0xd3)
				_s.put_64(v)

	func write_float64(v: float) -> void:
		_s.put_u8(0xcb)
		_s.put_double(v)

	func write_float32(v: float) -> void:
		_s.put_u8(0xca)
		_s.put_float(v)

	func write_str(v: String) -> void:
		var raw := v.to_utf8_buffer()
		var length := raw.size()
		if length <= 31:
			_s.put_u8(0xa0 | length)
		elif length <= 0xff:
			_s.put_u8(0xd9)
			_s.put_u8(length)
		elif length <= 0xffff:
			_s.put_u8(0xda)
			_s.put_u16(length)
		else:
			_s.put_u8(0xdb)
			_s.put_u32(length)
		_s.put_data(raw)

	func write_bin(v: PackedByteArray) -> void:
		var length := v.size()
		if length <= 0xff:
			_s.put_u8(0xc4)
			_s.put_u8(length)
		elif length <= 0xffff:
			_s.put_u8(0xc5)
			_s.put_u16(length)
		else:
			_s.put_u8(0xc6)
			_s.put_u32(length)
		_s.put_data(v)

	func write_array_header(length: int) -> void:
		if length <= 15:
			_s.put_u8(0x90 | length)
		elif length <= 0xffff:
			_s.put_u8(0xdc)
			_s.put_u16(length)
		else:
			_s.put_u8(0xdd)
			_s.put_u32(length)

	func write_map_header(length: int) -> void:
		if length <= 15:
			_s.put_u8(0x80 | length)
		elif length <= 0xffff:
			_s.put_u8(0xde)
			_s.put_u16(length)
		else:
			_s.put_u8(0xdf)
			_s.put_u32(length)

	func write_value(v: Variant) -> void:
		match typeof(v):
			TYPE_NIL:
				write_nil()
			TYPE_BOOL:
				write_bool(v)
			TYPE_INT:
				write_int(v)
			TYPE_FLOAT:
				write_float64(v)
			TYPE_STRING, TYPE_STRING_NAME:
				write_str(str(v))
			TYPE_PACKED_BYTE_ARRAY:
				write_bin(v)
			TYPE_DICTIONARY:
				write_map_header(v.size())
				for k: Variant in v:
					write_value(k)
					write_value(v[k])
			TYPE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY:
				write_array_header(v.size())
				for e: Variant in v:
					write_value(e)
			_:
				push_error("MsgPack: unsupported type %s" % type_string(typeof(v)))
				write_nil()
