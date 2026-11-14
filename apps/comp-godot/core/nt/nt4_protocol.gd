class_name Nt4Protocol
extends RefCounted

const PROTOCOL_V40 := "networktables.first.wpi.edu"
const PROTOCOL_V41 := "v4.1.networktables.first.wpi.edu"

const RTT_ID := -1

const TYPE_BOOLEAN := 0
const TYPE_DOUBLE := 1
const TYPE_INT := 2
const TYPE_FLOAT := 3
const TYPE_STRING := 4
const TYPE_RAW := 5
const TYPE_BOOLEAN_ARRAY := 16
const TYPE_DOUBLE_ARRAY := 17
const TYPE_INT_ARRAY := 18
const TYPE_FLOAT_ARRAY := 19
const TYPE_STRING_ARRAY := 20

const TYPE_NUMS := {
	"boolean": TYPE_BOOLEAN,
	"double": TYPE_DOUBLE,
	"int": TYPE_INT,
	"float": TYPE_FLOAT,
	"string": TYPE_STRING,
	"json": TYPE_STRING,
	"raw": TYPE_RAW,
	"rpc": TYPE_RAW,
	"msgpack": TYPE_RAW,
	"protobuf": TYPE_RAW,
	"boolean[]": TYPE_BOOLEAN_ARRAY,
	"double[]": TYPE_DOUBLE_ARRAY,
	"int[]": TYPE_INT_ARRAY,
	"float[]": TYPE_FLOAT_ARRAY,
	"string[]": TYPE_STRING_ARRAY,
}

const NUM_TO_TYPE := {
	TYPE_BOOLEAN: "boolean",
	TYPE_DOUBLE: "double",
	TYPE_INT: "int",
	TYPE_FLOAT: "float",
	TYPE_STRING: "string",
	TYPE_RAW: "raw",
	TYPE_BOOLEAN_ARRAY: "boolean[]",
	TYPE_DOUBLE_ARRAY: "double[]",
	TYPE_INT_ARRAY: "int[]",
	TYPE_FLOAT_ARRAY: "float[]",
	TYPE_STRING_ARRAY: "string[]",
}


## Unknown type strings (struct:*, structschema, proto:*, ...) travel as raw bytes.
static func type_num(type_str: String) -> int:
	return TYPE_NUMS.get(type_str, TYPE_RAW)


static func subscribe_msg(subuid: int, topics: PackedStringArray, options: Dictionary = {}) -> Dictionary:
	return {"method": "subscribe", "params": {"topics": Array(topics), "subuid": subuid, "options": options}}


static func unsubscribe_msg(subuid: int) -> Dictionary:
	return {"method": "unsubscribe", "params": {"subuid": subuid}}


static func publish_msg(pubuid: int, name: String, type_str: String, properties: Dictionary = {}) -> Dictionary:
	return {"method": "publish", "params": {"name": name, "pubuid": pubuid, "type": type_str, "properties": properties}}


static func unpublish_msg(pubuid: int) -> Dictionary:
	return {"method": "unpublish", "params": {"pubuid": pubuid}}


static func setproperties_msg(name: String, update: Dictionary) -> Dictionary:
	return {"method": "setproperties", "params": {"name": name, "update": update}}


static func encode_text(messages: Array) -> String:
	return JSON.stringify(messages)


## Returns {"messages": [...], "error": ""}. JSON numbers parse as floats in
## Godot, so ids are converted back to int here.
static func parse_text(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"messages": [], "error": "json: %s" % json.get_error_message()}
	var data: Variant = json.data
	if typeof(data) != TYPE_ARRAY:
		return {"messages": [], "error": "json: top level is not an array"}
	var out := []
	for m: Variant in data:
		if typeof(m) != TYPE_DICTIONARY or typeof(m.get("method")) != TYPE_STRING:
			continue
		var params: Variant = m.get("params", {})
		if typeof(params) != TYPE_DICTIONARY:
			params = {}
		for key: String in ["id", "pubuid", "subuid"]:
			if params.has(key) and typeof(params[key]) == TYPE_FLOAT:
				params[key] = int(params[key])
		if not params.has("properties") or typeof(params["properties"]) != TYPE_DICTIONARY:
			if m["method"] == "announce":
				params["properties"] = {}
		out.append({"method": m["method"], "params": params})
	return {"messages": out, "error": ""}


static func rtt_frame(local_now_us: int) -> PackedByteArray:
	var w := MsgPack.Writer.new()
	w.write_array_header(4)
	w.write_int(RTT_ID)
	w.write_int(0)
	w.write_int(TYPE_INT)
	w.write_int(local_now_us)
	return w.bytes()


## Appends one [id, ts, typeNum, value] frame. Returns false (and writes
## nothing) when the value cannot be represented as the given NT type.
static func write_value_frame(w: MsgPack.Writer, id: int, ts_us: int, type_str: String, value: Variant) -> bool:
	if not is_publishable(value, type_str):
		return false
	var num := type_num(type_str)
	w.write_array_header(4)
	w.write_int(id)
	w.write_int(ts_us)
	w.write_int(num)
	match num:
		TYPE_BOOLEAN:
			w.write_bool(bool(value))
		TYPE_DOUBLE:
			w.write_float64(float(value))
		TYPE_FLOAT:
			w.write_float32(float(value))
		TYPE_INT:
			w.write_int(int(value))
		TYPE_STRING:
			w.write_str(str(value))
		TYPE_RAW:
			w.write_bin(value if typeof(value) == TYPE_PACKED_BYTE_ARRAY else str(value).to_utf8_buffer())
		TYPE_BOOLEAN_ARRAY:
			w.write_array_header(value.size())
			for e: Variant in value:
				w.write_bool(bool(e))
		TYPE_DOUBLE_ARRAY:
			w.write_array_header(value.size())
			for e: Variant in value:
				w.write_float64(float(e))
		TYPE_FLOAT_ARRAY:
			w.write_array_header(value.size())
			for e: Variant in value:
				w.write_float32(float(e))
		TYPE_INT_ARRAY:
			w.write_array_header(value.size())
			for e: Variant in value:
				w.write_int(int(e))
		TYPE_STRING_ARRAY:
			w.write_array_header(value.size())
			for e: Variant in value:
				w.write_str(str(e))
	return true


static func value_frame(id: int, ts_us: int, type_str: String, value: Variant) -> PackedByteArray:
	var w := MsgPack.Writer.new()
	if not write_value_frame(w, id, ts_us, type_str, value):
		return PackedByteArray()
	return w.bytes()


static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or (typeof(v) == TYPE_FLOAT and is_finite(v))


static func _is_list(v: Variant) -> bool:
	return typeof(v) in [TYPE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY]


static func is_publishable(value: Variant, type_str: String) -> bool:
	match type_num(type_str):
		TYPE_BOOLEAN:
			return typeof(value) == TYPE_BOOL
		TYPE_DOUBLE, TYPE_FLOAT, TYPE_INT:
			return _is_number(value)
		TYPE_STRING:
			return typeof(value) in [TYPE_STRING, TYPE_STRING_NAME]
		TYPE_RAW:
			return typeof(value) in [TYPE_PACKED_BYTE_ARRAY, TYPE_STRING]
		TYPE_BOOLEAN_ARRAY:
			if not _is_list(value):
				return false
			for e: Variant in value:
				if typeof(e) != TYPE_BOOL:
					return false
			return true
		TYPE_DOUBLE_ARRAY, TYPE_FLOAT_ARRAY, TYPE_INT_ARRAY:
			if not _is_list(value):
				return false
			for e: Variant in value:
				if not _is_number(e):
					return false
			return true
		TYPE_STRING_ARRAY:
			if not _is_list(value):
				return false
			for e: Variant in value:
				if typeof(e) not in [TYPE_STRING, TYPE_STRING_NAME]:
					return false
			return true
	return false


## Variant type a decoded value has when it already matches the NT type
## (no coercion needed), or -1 for types that always go through coerce().
static func pass_type(type_str: String) -> int:
	match type_str:
		"double", "float":
			return TYPE_FLOAT
		"int":
			return TYPE_INT
		"boolean":
			return TYPE_BOOL
		"string", "json":
			return TYPE_STRING
	if TYPE_NUMS.has(type_str) and type_num(type_str) != TYPE_RAW:
		return -1
	return TYPE_PACKED_BYTE_ARRAY


## Coerces a decoded value to the announced type. Returns null when the value
## cannot represent that type (the caller counts it as a decode error).
static func coerce(value: Variant, type_str: String) -> Variant:
	var t := typeof(value)
	match type_str:
		"boolean":
			if t == TYPE_BOOL:
				return value
			if t == TYPE_INT:
				return value != 0
			return null
		"double", "float":
			if t == TYPE_FLOAT:
				return value
			if t == TYPE_INT:
				return float(value)
			return null
		"int":
			if t == TYPE_INT:
				return value
			if t == TYPE_FLOAT and is_finite(value):
				return int(value)
			return null
		"string", "json":
			if t == TYPE_STRING:
				return value
			if t == TYPE_PACKED_BYTE_ARRAY:
				return value.get_string_from_utf8()
			return null
		"double[]", "float[]":
			if t != TYPE_ARRAY:
				return null
			var out := PackedFloat64Array()
			out.resize(value.size())
			for i in value.size():
				var e: Variant = value[i]
				if typeof(e) == TYPE_FLOAT or typeof(e) == TYPE_INT:
					out[i] = float(e)
				else:
					return null
			return out
		"int[]":
			if t != TYPE_ARRAY:
				return null
			var out := PackedInt64Array()
			out.resize(value.size())
			for i in value.size():
				var e: Variant = value[i]
				if typeof(e) == TYPE_INT:
					out[i] = e
				elif typeof(e) == TYPE_FLOAT and is_finite(e):
					out[i] = int(e)
				else:
					return null
			return out
		"boolean[]":
			if t != TYPE_ARRAY:
				return null
			for e: Variant in value:
				if typeof(e) != TYPE_BOOL:
					return null
			return value
		"string[]":
			if t != TYPE_ARRAY:
				return null
			var out := PackedStringArray()
			for e: Variant in value:
				if typeof(e) != TYPE_STRING:
					return null
				out.append(e)
			return out
	if t == TYPE_PACKED_BYTE_ARRAY:
		return value
	if t == TYPE_STRING:
		return value.to_utf8_buffer()
	return value
