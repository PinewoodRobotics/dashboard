class_name ThreadedTransport
extends NtTransport

## Runs an inner transport (normally WebSocketTransport) on a worker thread.
## The worker owns the socket: it sends queued frames, polls, stamps receive
## times, parses text frames and decodes binary value frames, so the main
## thread only applies already-decoded values. Packets from take_packets()
## carry extra keys: "rx_us", and "messages"/"error" (text) or "flat"/"error"
## (binary, see Nt4FrameDecoder.decode).
##
## The main thread only ever try_lock()s the shared state. A blocking lock can
## park it behind a descheduled worker for milliseconds, so on contention it
## keeps outgoing frames staged and reads the last known state instead.

const IDLE_SLEEP_US := 1000

var _inner_factory: Callable
var _thread: Thread
var _mutex := Mutex.new()
var _url := ""
var _protocols := PackedStringArray()

# Main thread only.
var _staged: Array = []
var _state_seen := STATE_CLOSED
var _selected_seen := ""
var _close_code_seen := -1
var _close_reason_seen := ""

# Guarded by _mutex.
var _running := false
var _close_request := 0
var _outbox: Array = []
var _inbox: Array = []
var _state := STATE_CLOSED
var _selected := ""
var _close_code := -1
var _close_reason := ""


func _init(inner_factory: Callable) -> void:
	_inner_factory = inner_factory


func open(url: String, protocols: PackedStringArray) -> Error:
	_url = url
	_protocols = protocols
	_running = true
	_state = STATE_CONNECTING
	_state_seen = STATE_CONNECTING
	_thread = Thread.new()
	return _thread.start(_run, Thread.PRIORITY_HIGH)


func poll() -> void:
	if _mutex.try_lock():
		_sync_locked()
		_mutex.unlock()


func get_state() -> int:
	return _state_seen


func send_text(text: String) -> Error:
	return _enqueue([true, text])


func send_binary(bytes: PackedByteArray) -> Error:
	return _enqueue([false, bytes])


## Stamped by the worker when the probe is actually written to the socket, so
## queueing delay does not make the server time estimate run ahead.
func send_rtt_probe(_local_now_us: int) -> Error:
	return _enqueue([false, null])


func take_packets() -> Array:
	if not _mutex.try_lock():
		return []
	_sync_locked()
	var out := _inbox
	_inbox = []
	_mutex.unlock()
	return out


func close(code: int = 1000, _reason: String = "") -> void:
	if _thread == null:
		return
	_mutex.lock()
	_running = false
	_close_request = code
	_mutex.unlock()
	_thread.wait_to_finish()
	_thread = null
	_staged.clear()
	_state_seen = STATE_CLOSED


func selected_protocol() -> String:
	return _selected_seen


func close_code() -> int:
	return _close_code_seen


func close_reason() -> String:
	return _close_reason_seen


func _enqueue(item: Array) -> Error:
	if _state_seen != STATE_OPEN:
		return ERR_UNAVAILABLE
	_staged.append(item)
	if _mutex.try_lock():
		_sync_locked()
		_mutex.unlock()
	return OK


## Caller holds _mutex: hands staged frames to the worker and refreshes the
## main thread's view of the socket.
func _sync_locked() -> void:
	if not _staged.is_empty():
		_outbox.append_array(_staged)
		_staged.clear()
	_state_seen = _state
	_selected_seen = _selected
	_close_code_seen = _close_code
	_close_reason_seen = _close_reason


func _run() -> void:
	var inner: NtTransport = _inner_factory.call()
	if inner.open(_url, _protocols) != OK:
		_mutex.lock()
		_state = STATE_CLOSED
		_mutex.unlock()
		return
	while true:
		_mutex.lock()
		var running := _running
		var close_request := _close_request
		var outgoing := _outbox
		_outbox = []
		_mutex.unlock()
		if not running:
			inner.close(close_request)
			return
		for item: Array in outgoing:
			if item[0]:
				inner.send_text(item[1])
			elif item[1] == null:
				inner.send_rtt_probe(Time.get_ticks_usec())
			else:
				inner.send_binary(item[1])
		inner.poll()
		var st := inner.get_state()
		var packets := inner.take_packets()
		var rx_us := Time.get_ticks_usec()
		for pkt: Dictionary in packets:
			pkt["rx_us"] = rx_us
			if pkt["text"]:
				var parsed := Nt4Protocol.parse_text(pkt["data"])
				pkt["messages"] = parsed["messages"]
				pkt["error"] = parsed["error"]
			else:
				var flat := []
				pkt["error"] = Nt4FrameDecoder.decode(pkt["data"], flat)
				pkt["flat"] = flat
		var selected := inner.selected_protocol()
		var code := inner.close_code()
		var reason := inner.close_reason()
		_mutex.lock()
		_state = st
		_selected = selected
		_close_code = code
		_close_reason = reason
		if not packets.is_empty():
			_inbox.append_array(packets)
		_mutex.unlock()
		if st == STATE_CLOSED:
			return
		if packets.is_empty() and outgoing.is_empty():
			OS.delay_usec(IDLE_SLEEP_US)
