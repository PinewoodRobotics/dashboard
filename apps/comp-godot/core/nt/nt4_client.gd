class_name Nt4Client
extends RefCounted

enum State { IDLE, CONNECTING, SYNCING, READY, BACKOFF }

const STATE_NAMES := ["IDLE", "CONNECTING", "SYNCING", "READY", "BACKOFF"]
const BACKOFF_S: Array[float] = [1.0, 2.0, 4.0, 5.0]
const RTT_PERIOD_US := 1_000_000
const LIVENESS_TIMEOUT_US := 3_000_000
const DEFAULT_POLL_BUDGET_US := 500
## Past the budget, packets keep being processed while more than this many
## wait, so a sustained overload raises frame time instead of growing latency.
const MAX_DEFERRED_PACKETS := 64
const MIN_CONNECT_TIMEOUT_S := 2.0
const MAX_CONNECT_TIMEOUT_S := 60.0

signal state_changed(state: int, previous: int)
signal topic_announced(info: TopicInfo)
signal topic_unannounced(name: String, id: int)
signal topic_properties(name: String, update: Dictionary)

class TopicInfo:
	var id := 0
	var name := ""
	var type := ""
	## Variant type a decoded value already has when it needs no coercion, or -1.
	var pass_type := -1
	var properties := {}
	var pubuid := -1
	## Free slot for the owner of the client (NtService keeps its cache slot here).
	var user: Variant = null


var clock := Clock.new()
## The socket and frame decoding run on a worker thread by default.
var transport_factory: Callable = func() -> NtTransport:
	return ThreadedTransport.new(func() -> NtTransport: return WebSocketTransport.new())
## 4.0 only: keeps RTT time sync on the data socket and avoids 4.1's server
## pings, which drop a client that stalls. Accepted by the 2027 alpha-8 server.
var protocols := PackedStringArray([Nt4Protocol.PROTOCOL_V40])
## Called once per binary packet as value_handler.call(batch) where batch is
## flat [info: TopicInfo, value, server_ts_us, ...] (stride 3), already coerced
## to each topic's type. The array is reused; copy what must outlive the call.
var value_handler: Callable
## Called as frame_tap.call(is_text, data) for every inbound packet.
var frame_tap: Callable

var host := ""
var port := 5810
var connect_timeout_s := 10.0
var client_name := ""
## Inbound packets are processed until this much time has passed in one poll;
## the rest wait for the next poll, so one burst cannot stall a frame.
var poll_budget_us := DEFAULT_POLL_BUDGET_US

var _state := State.IDLE
var _transport: NtTransport
var _state_since_us := 0
var _attempt := 0
var _backoff_until_us := 0
var _last_rx_us := 0
var _next_rtt_us := 0
var _sync := Nt4TimeSync.new()
var _subs := {}
var _next_subuid := 1
var _pubs := {}
var _next_pubuid := 1
var _topics := {}
var _selected_protocol := ""
var _rate_window_start_us := 0
var _rate_window_count := 0
var _pending: Array = []
var _pending_index := 0
var _flat: Array = []
var _batch: Array = []

var values_total := 0
var values_per_s := 0.0
var unknown_id_drops := 0
var decode_errors := 0
var coerce_errors := 0
var text_frames := 0
var binary_frames := 0
var rtt_samples := 0
var connects := 0
var reconnects := 0
var connect_watchdog_fires := 0
var liveness_fires := 0
var send_errors := 0
var deferred_packets := 0
var last_close := ""


func _init() -> void:
	client_name = "pwrup-godot-%d-%d" % [OS.get_process_id(), randi() % 100000]


func configure(p_host: String, p_port: int, p_connect_timeout_s: float = 10.0) -> void:
	var changed := p_host != host or p_port != port
	host = p_host
	port = p_port
	connect_timeout_s = clampf(p_connect_timeout_s, MIN_CONNECT_TIMEOUT_S, MAX_CONNECT_TIMEOUT_S)
	if changed and _state != State.IDLE:
		_drop_transport(1000)
		_reset_connection_state()
		_attempt = 0
		_open(clock.now_us())


func start() -> void:
	if _state != State.IDLE:
		return
	_attempt = 0
	_open(clock.now_us())


func stop() -> void:
	_drop_transport(1000)
	_reset_connection_state()
	_set_state(State.IDLE)


func restart() -> void:
	stop()
	start()


func get_state() -> int:
	return _state


func state_name() -> String:
	return STATE_NAMES[_state]


func is_ready() -> bool:
	return _state == State.READY


func is_open() -> bool:
	return _state == State.SYNCING or _state == State.READY


func url() -> String:
	return "ws://%s:%d/nt/%s" % [host, port, client_name]


func selected_protocol() -> String:
	return _selected_protocol


func has_time_sync() -> bool:
	return _sync.has_sync()


func server_time_us() -> int:
	if not _sync.has_sync():
		return -1
	return _sync.server_now_us(clock.now_us())


func rtt_us() -> int:
	return _sync.best_rtt_us


func offset_us() -> int:
	return _sync.offset_us


func announced_topics() -> Array:
	return _topics.values()


func topic_id(name: String) -> int:
	for id: int in _topics:
		if _topics[id].name == name:
			return id
	return -1


func diagnostics() -> Dictionary:
	var d := {
		"values_total": values_total,
		"values_per_s": values_per_s,
		"unknown_id_drops": unknown_id_drops,
		"decode_errors": decode_errors,
		"coerce_errors": coerce_errors,
		"text_frames": text_frames,
		"binary_frames": binary_frames,
		"rtt_samples": rtt_samples,
		"connects": connects,
		"reconnects": reconnects,
		"connect_watchdog_fires": connect_watchdog_fires,
		"liveness_fires": liveness_fires,
		"send_errors": send_errors,
		"deferred_packets": deferred_packets,
		"pending_packets": _pending.size() - _pending_index,
		"last_close": last_close,
	}
	d["state"] = state_name()
	d["protocol"] = _selected_protocol
	d["url"] = url()
	d["rtt_us"] = _sync.best_rtt_us
	d["offset_us"] = _sync.offset_us
	d["server_time_us"] = server_time_us()
	d["announced"] = _topics.size()
	d["subscriptions"] = _subs.size()
	d["publishers"] = _pubs.size()
	d["attempt"] = _attempt
	return d


func subscribe(topics: PackedStringArray, options: Dictionary = {}) -> int:
	var subuid := _next_subuid
	_next_subuid += 1
	_subs[subuid] = {"topics": topics, "options": options}
	if is_open():
		_send_text([Nt4Protocol.subscribe_msg(subuid, topics, options)])
	return subuid


func unsubscribe(subuid: int) -> void:
	if not _subs.erase(subuid):
		return
	if is_open():
		_send_text([Nt4Protocol.unsubscribe_msg(subuid)])


func add_publisher(name: String, type_str: String, properties: Dictionary = {}) -> int:
	var pubuid := _next_pubuid
	_next_pubuid += 1
	_pubs[pubuid] = {"name": name, "type": type_str, "properties": properties, "has_value": false, "value": null, "last_ts": 0}
	if _state == State.READY:
		_send_text([Nt4Protocol.publish_msg(pubuid, name, type_str, properties)])
	return pubuid


func remove_publisher(pubuid: int) -> void:
	if not _pubs.erase(pubuid):
		return
	if _state == State.READY:
		_send_text([Nt4Protocol.unpublish_msg(pubuid)])


## Stores the desired value and sends it now when READY. Returns false when
## the value is not representable as the publisher's type (it is not stored).
func set_value(pubuid: int, value: Variant) -> bool:
	var pub: Dictionary = _pubs.get(pubuid, {})
	if pub.is_empty() or not Nt4Protocol.is_publishable(value, pub["type"]):
		return false
	pub["value"] = value
	pub["has_value"] = true
	if _state == State.READY:
		var w := MsgPack.Writer.new()
		_write_pub_value(w, pubuid, pub)
		_send_binary(w.bytes())
	return true


## Forgets the desired value so it is not re-sent on the next connection.
func clear_value(pubuid: int) -> void:
	var pub: Dictionary = _pubs.get(pubuid, {})
	if not pub.is_empty():
		pub["has_value"] = false
		pub["value"] = null


func publisher_value(pubuid: int) -> Variant:
	var pub: Dictionary = _pubs.get(pubuid, {})
	return pub.get("value") if pub.get("has_value", false) else null


## Test hook: sends a value with an explicit timestamp, bypassing time sync.
func debug_send_value_at(pubuid: int, value: Variant, ts_us: int) -> bool:
	var pub: Dictionary = _pubs.get(pubuid, {})
	if pub.is_empty() or _state != State.READY:
		return false
	var frame := Nt4Protocol.value_frame(pubuid, ts_us, pub["type"], value)
	if frame.is_empty():
		return false
	return _send_binary(frame)


func _write_pub_value(w: MsgPack.Writer, pubuid: int, pub: Dictionary) -> void:
	var ts := maxi(_sync.server_now_us(clock.now_us()), int(pub["last_ts"]) + 1)
	pub["last_ts"] = ts
	Nt4Protocol.write_value_frame(w, pubuid, ts, pub["type"], pub["value"])


func poll() -> void:
	var now := clock.now_us()
	match _state:
		State.IDLE:
			return
		State.BACKOFF:
			if now >= _backoff_until_us:
				_open(now)
			return
		State.CONNECTING:
			_transport.poll()
			var ts := _transport.get_state()
			if ts == NtTransport.STATE_OPEN:
				_on_open(now)
			elif ts == NtTransport.STATE_CLOSED or ts == NtTransport.STATE_CLOSING:
				_on_closed(now, "connect failed (%d)" % _transport.close_code())
				return
			elif now - _state_since_us >= int(connect_timeout_s * 1_000_000.0):
				connect_watchdog_fires += 1
				# The watchdog already waited the full timeout, so retry at once.
				_on_closed(now, "connect timeout", true)
				return
			else:
				return
	_poll_open(now)


func _poll_open(now: int) -> void:
	_transport.poll()
	_drain(now)
	if _transport == null:
		return
	var ts := _transport.get_state()
	if ts == NtTransport.STATE_CLOSED or ts == NtTransport.STATE_CLOSING:
		_on_closed(now, "closed by server (%d %s)" % [_transport.close_code(), _transport.close_reason()])
		return
	if now - _last_rx_us > LIVENESS_TIMEOUT_US:
		liveness_fires += 1
		_on_closed(now, "liveness timeout")
		return
	if now >= _next_rtt_us:
		_send_rtt(now)
	if now - _rate_window_start_us >= 1_000_000:
		values_per_s = _rate_window_count * 1_000_000.0 / (now - _rate_window_start_us)
		_rate_window_start_us = now
		_rate_window_count = 0


func _open(now: int) -> void:
	_reset_connection_state()
	if host.strip_edges() == "":
		last_close = "no host"
		_enter_backoff(now, false)
		return
	_transport = transport_factory.call()
	var err := _transport.open(url(), protocols)
	_state_since_us = now
	if err != OK:
		_transport = null
		last_close = "open error %s" % error_string(err)
		_enter_backoff(now, false)
		return
	_set_state(State.CONNECTING)


func _on_open(now: int) -> void:
	connects += 1
	_selected_protocol = _transport.selected_protocol()
	_last_rx_us = now
	_rate_window_start_us = now
	_rate_window_count = 0
	_set_state(State.SYNCING)
	_send_rtt(now)
	if not _subs.is_empty():
		var msgs := []
		for subuid: int in _subs:
			msgs.append(Nt4Protocol.subscribe_msg(subuid, _subs[subuid]["topics"], _subs[subuid]["options"]))
		_send_text(msgs)


func _enter_ready() -> void:
	_attempt = 0
	_set_state(State.READY)
	if _pubs.is_empty():
		return
	var msgs := []
	for pubuid: int in _pubs:
		var pub: Dictionary = _pubs[pubuid]
		msgs.append(Nt4Protocol.publish_msg(pubuid, pub["name"], pub["type"], pub["properties"]))
	_send_text(msgs)
	var w := MsgPack.Writer.new()
	var any := false
	for pubuid: int in _pubs:
		var pub: Dictionary = _pubs[pubuid]
		if pub["has_value"]:
			_write_pub_value(w, pubuid, pub)
			any = true
	if any:
		_send_binary(w.bytes())


func _on_closed(now: int, reason: String, immediate: bool = false) -> void:
	var was_open := is_open()
	last_close = reason
	if was_open:
		reconnects += 1
	_drop_transport(-1)
	_reset_connection_state()
	_enter_backoff(now, immediate)


func _enter_backoff(now: int, immediate: bool) -> void:
	var delay_s := 0.0 if immediate else BACKOFF_S[mini(_attempt, BACKOFF_S.size() - 1)]
	_attempt += 1
	_backoff_until_us = now + int(delay_s * 1_000_000.0)
	_set_state(State.BACKOFF)


func _drop_transport(code: int) -> void:
	if _transport != null:
		_transport.close(code)
		_transport = null


func _reset_connection_state() -> void:
	var had_topics := not _topics.is_empty()
	var old := _topics
	_topics = {}
	_pending = []
	_pending_index = 0
	_sync.reset()
	_selected_protocol = ""
	for pubuid: int in _pubs:
		_pubs[pubuid]["last_ts"] = 0
	if had_topics:
		for id: int in old:
			topic_unannounced.emit(old[id].name, id)


func _set_state(s: int) -> void:
	if s == _state:
		return
	var prev := _state
	_state = s
	_state_since_us = clock.now_us()
	state_changed.emit(s, prev)


func _send_rtt(now: int) -> void:
	_next_rtt_us = now + RTT_PERIOD_US
	if _transport == null or _transport.get_state() != NtTransport.STATE_OPEN:
		return
	if _transport.send_rtt_probe(now) != OK:
		send_errors += 1


func _send_text(msgs: Array) -> bool:
	if _transport == null or _transport.get_state() != NtTransport.STATE_OPEN:
		return false
	if _transport.send_text(Nt4Protocol.encode_text(msgs)) != OK:
		send_errors += 1
		return false
	return true


func _send_binary(bytes: PackedByteArray) -> bool:
	if _transport == null or _transport.get_state() != NtTransport.STATE_OPEN:
		return false
	if _transport.send_binary(bytes) != OK:
		send_errors += 1
		return false
	return true


func _drain(now: int) -> void:
	var fresh := _transport.take_packets()
	if not fresh.is_empty():
		_last_rx_us = now
		if _pending_index >= _pending.size():
			_pending = fresh
			_pending_index = 0
		else:
			_pending.append_array(fresh)
	var deadline := Time.get_ticks_usec() + poll_budget_us
	while _pending_index < _pending.size():
		var pkt: Dictionary = _pending[_pending_index]
		_pending_index += 1
		if frame_tap.is_valid():
			frame_tap.call(pkt["text"], pkt["data"])
		if pkt["text"]:
			text_frames += 1
			_handle_text(pkt)
		else:
			binary_frames += 1
			_handle_binary(pkt, now)
		if _transport == null:
			return
		if Time.get_ticks_usec() >= deadline and _pending_index < _pending.size() and _pending.size() - _pending_index <= MAX_DEFERRED_PACKETS:
			deferred_packets += _pending.size() - _pending_index
			break
	if _pending_index >= _pending.size():
		_pending = []
		_pending_index = 0


func _handle_text(pkt: Dictionary) -> void:
	var res: Dictionary = pkt if pkt.has("messages") else Nt4Protocol.parse_text(pkt["data"])
	if res["error"] != "":
		decode_errors += 1
		return
	for m: Dictionary in res["messages"]:
		var p: Dictionary = m["params"]
		match m["method"]:
			"announce":
				var id: Variant = p.get("id")
				if typeof(id) != TYPE_INT or typeof(p.get("name")) != TYPE_STRING:
					decode_errors += 1
					continue
				var info := TopicInfo.new()
				info.id = id
				info.name = p["name"]
				info.type = str(p.get("type", "raw"))
				info.pass_type = Nt4Protocol.pass_type(info.type)
				info.properties = p["properties"]
				info.pubuid = int(p.get("pubuid", -1))
				_topics[id] = info
				topic_announced.emit(info)
			"unannounce":
				var id: Variant = p.get("id")
				if typeof(id) == TYPE_INT and _topics.erase(id):
					topic_unannounced.emit(str(p.get("name", "")), id)
			"properties":
				var update: Variant = p.get("update", {})
				if typeof(update) != TYPE_DICTIONARY:
					update = {}
				var name := str(p.get("name", ""))
				for id: int in _topics:
					var info: TopicInfo = _topics[id]
					if info.name == name:
						for k: String in update:
							if update[k] == null:
								info.properties.erase(k)
							else:
								info.properties[k] = update[k]
				topic_properties.emit(name, update)


func _handle_binary(pkt: Dictionary, now: int) -> void:
	var flat: Array
	if pkt.has("flat"):
		flat = pkt["flat"]
		if pkt["error"] != "":
			decode_errors += 1
		now = pkt["rx_us"]
	else:
		flat = _flat
		flat.clear()
		if Nt4FrameDecoder.decode(pkt["data"], flat) != "":
			decode_errors += 1
	var batch := _batch
	batch.clear()
	var topics := _topics
	var delivered := 0
	var i := 0
	var count := flat.size()
	while i < count:
		var id: int = flat[i]
		if id == Nt4Protocol.RTT_ID:
			var echoed: Variant = flat[i + 2]
			if typeof(echoed) == TYPE_INT and _sync.add_sample(now, echoed, flat[i + 1]):
				rtt_samples += 1
				if _state == State.SYNCING:
					_enter_ready()
			i += 3
			continue
		var info: TopicInfo = topics.get(id)
		if info == null:
			unknown_id_drops += 1
			i += 3
			continue
		var value: Variant = flat[i + 2]
		if typeof(value) != info.pass_type:
			value = Nt4Protocol.coerce(value, info.type)
			if value == null:
				coerce_errors += 1
				i += 3
				continue
		batch.append(info)
		batch.append(value)
		batch.append(flat[i + 1])
		delivered += 1
		i += 3
	values_total += delivered
	_rate_window_count += delivered
	if delivered > 0 and value_handler.is_valid():
		value_handler.call(batch)
