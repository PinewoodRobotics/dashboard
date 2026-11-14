class_name WebSocketTransport
extends NtTransport

const INBOUND_BUFFER_BYTES := 4 * 1024 * 1024
const OUTBOUND_BUFFER_BYTES := 1024 * 1024
const MAX_QUEUED_PACKETS := 8192

var _ws: WebSocketPeer


func open(url: String, protocols: PackedStringArray) -> Error:
	_ws = WebSocketPeer.new()
	_ws.supported_protocols = protocols
	_ws.inbound_buffer_size = INBOUND_BUFFER_BYTES
	_ws.outbound_buffer_size = OUTBOUND_BUFFER_BYTES
	_ws.max_queued_packets = MAX_QUEUED_PACKETS
	return _ws.connect_to_url(url)


func poll() -> void:
	if _ws != null:
		_ws.poll()


func get_state() -> int:
	if _ws == null:
		return STATE_CLOSED
	match _ws.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			return STATE_CONNECTING
		WebSocketPeer.STATE_OPEN:
			return STATE_OPEN
		WebSocketPeer.STATE_CLOSING:
			return STATE_CLOSING
	return STATE_CLOSED


func send_text(text: String) -> Error:
	if _ws == null:
		return ERR_UNCONFIGURED
	return _ws.send_text(text)


func send_binary(bytes: PackedByteArray) -> Error:
	if _ws == null:
		return ERR_UNCONFIGURED
	return _ws.send(bytes, WebSocketPeer.WRITE_MODE_BINARY)


func take_packets() -> Array:
	var out := []
	if _ws == null:
		return out
	while _ws.get_available_packet_count() > 0:
		var data := _ws.get_packet()
		if _ws.was_string_packet():
			out.append({"text": true, "data": data.get_string_from_utf8()})
		else:
			out.append({"text": false, "data": data})
	return out


func close(code: int = 1000, reason: String = "") -> void:
	if _ws != null:
		_ws.close(code, reason)
		_ws.poll()


func selected_protocol() -> String:
	return _ws.get_selected_protocol() if _ws != null else ""


func close_code() -> int:
	return _ws.get_close_code() if _ws != null else -1


func close_reason() -> String:
	return _ws.get_close_reason() if _ws != null else ""
