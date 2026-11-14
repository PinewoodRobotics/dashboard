class_name NtTransport
extends RefCounted

enum { STATE_CONNECTING, STATE_OPEN, STATE_CLOSING, STATE_CLOSED }


func open(_url: String, _protocols: PackedStringArray) -> Error:
	return ERR_UNAVAILABLE


func poll() -> void:
	pass


func get_state() -> int:
	return STATE_CLOSED


func send_text(_text: String) -> Error:
	return ERR_UNAVAILABLE


func send_binary(_bytes: PackedByteArray) -> Error:
	return ERR_UNAVAILABLE


## Sends the time-sync probe [-1, 0, 2, local_now_us]. Transports that delay
## sending re-stamp it at the moment it actually goes out.
func send_rtt_probe(local_now_us: int) -> Error:
	return send_binary(Nt4Protocol.rtt_frame(local_now_us))


## Returns [{"text": bool, "data": String or PackedByteArray}, ...] received since the last call.
func take_packets() -> Array:
	return []


## code -1 drops the socket without a close handshake.
func close(_code: int = 1000, _reason: String = "") -> void:
	pass


func selected_protocol() -> String:
	return ""


func close_code() -> int:
	return -1


func close_reason() -> String:
	return ""
