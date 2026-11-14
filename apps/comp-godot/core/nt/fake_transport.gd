class_name FakeTransport
extends NtTransport

var state := STATE_CLOSED
var url := ""
var offered := PackedStringArray()
var selected := ""
var open_result := OK
var sent_text: Array[String] = []
var sent_binary: Array[PackedByteArray] = []
var closed_by_client := false
var client_close_code := 0
var _inbound := []


func open(p_url: String, protocols: PackedStringArray) -> Error:
	url = p_url
	offered = protocols
	if open_result != OK:
		return open_result
	state = STATE_CONNECTING
	return OK


func get_state() -> int:
	return state


func send_text(text: String) -> Error:
	if state != STATE_OPEN:
		return ERR_UNAVAILABLE
	sent_text.append(text)
	return OK


func send_binary(bytes: PackedByteArray) -> Error:
	if state != STATE_OPEN:
		return ERR_UNAVAILABLE
	sent_binary.append(bytes)
	return OK


func take_packets() -> Array:
	var out := _inbound
	_inbound = []
	return out


func close(code: int = 1000, _reason: String = "") -> void:
	if state != STATE_CLOSED:
		closed_by_client = true
		client_close_code = code
	state = STATE_CLOSED


func selected_protocol() -> String:
	return selected


func server_accept(protocol: String = Nt4Protocol.PROTOCOL_V40) -> void:
	state = STATE_OPEN
	selected = protocol


func server_refuse() -> void:
	state = STATE_CLOSED


func server_close() -> void:
	state = STATE_CLOSED


func push_text(text: String) -> void:
	_inbound.append({"text": true, "data": text})


func push_messages(messages: Array) -> void:
	push_text(JSON.stringify(messages))


func push_binary(bytes: PackedByteArray) -> void:
	_inbound.append({"text": false, "data": bytes})


func push_values(frames: Array) -> void:
	var w := MsgPack.Writer.new()
	for f: Array in frames:
		w.write_value(f)
	push_binary(w.bytes())


func sent_messages() -> Array:
	var out := []
	for t in sent_text:
		out.append_array(Nt4Protocol.parse_text(t)["messages"])
	return out


func sent_frames() -> Array:
	var out := []
	for b in sent_binary:
		out.append_array(MsgPack.decode_all(b)["values"])
	return out
