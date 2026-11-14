class_name NtService
extends Node

signal connection_changed(connected: bool)
signal state_changed(state: int)

var client := Nt4Client.new()
var nt_settings := ConnectionSettings.DEFAULT_NT.duplicate()

var _slots := {}
var _ready_flag := false
var _poll_now_us := 0

# Per-topic cache in parallel arrays indexed by slot; the hot path writes here.
var _names: PackedStringArray = []
var _values: Array = []
var _has: PackedByteArray = []
var _fresh: PackedByteArray = []
var _types: PackedStringArray = []
var _server_ts: PackedInt64Array = []
var _local_ts: PackedInt64Array = []
var _updates: PackedInt64Array = []
var _callbacks: Array = []


func _init() -> void:
	process_priority = -1000
	client.value_handler = _on_values
	client.state_changed.connect(_on_state_changed)
	client.topic_announced.connect(_on_announced)


func configure(host: String, port: int, connect_timeout_s: float = 10.0) -> void:
	client.configure(host, port, connect_timeout_s)


func start() -> void:
	client.start()


func stop() -> void:
	client.stop()


func _process(_delta: float) -> void:
	poll()


func poll() -> void:
	_poll_now_us = Time.get_ticks_usec()
	client.poll()


func _exit_tree() -> void:
	client.stop()


func is_ready() -> bool:
	return _ready_flag


func subscribe(topics: PackedStringArray, options: Dictionary = {}) -> int:
	return client.subscribe(topics, options)


func unsubscribe(subuid: int) -> void:
	client.unsubscribe(subuid)


func subscribe_groups(groups: Array) -> void:
	for g: Dictionary in groups:
		client.subscribe(g["topics"], g["options"])


func publisher(topic: String, type: String, properties: Dictionary = {}) -> NtPublisher:
	return NtPublisher.new(client, topic, type, properties)


## Latest value even when disconnected (stale); default when never received.
func value(topic: String, default: Variant = null) -> Variant:
	var slot: int = _slots.get(topic, -1)
	return _values[slot] if slot >= 0 and _has[slot] else default


func has_value(topic: String) -> bool:
	var slot: int = _slots.get(topic, -1)
	return slot >= 0 and _has[slot] == 1


## True when connected and the topic delivered a value on this connection.
func is_live(topic: String) -> bool:
	var slot: int = _slots.get(topic, -1)
	return _ready_flag and slot >= 0 and _fresh[slot] == 1


## {value, has_value, type, server_ts, local_ts, fresh, updates} or {} when unknown.
func entry(topic: String) -> Dictionary:
	var slot: int = _slots.get(topic, -1)
	if slot < 0:
		return {}
	return {
		"value": _values[slot],
		"has_value": _has[slot] == 1,
		"type": _types[slot],
		"server_ts": _server_ts[slot],
		"local_ts": _local_ts[slot],
		"fresh": _fresh[slot] == 1,
		"updates": _updates[slot],
	}


func topic_names() -> PackedStringArray:
	return _names


func on_value(topic: String, callback: Callable) -> void:
	var slot := _slot_for(topic)
	if _callbacks[slot] == null:
		_callbacks[slot] = []
	_callbacks[slot].append(callback)


func off_value(topic: String, callback: Callable) -> void:
	var slot: int = _slots.get(topic, -1)
	if slot >= 0 and _callbacks[slot] != null:
		_callbacks[slot].erase(callback)


func diagnostics() -> Dictionary:
	var d := client.diagnostics()
	d["cached_topics"] = _names.size()
	return d


func _slot_for(topic: String) -> int:
	var slot: int = _slots.get(topic, -1)
	if slot >= 0:
		return slot
	slot = _names.size()
	_slots[topic] = slot
	_names.append(topic)
	_values.append(null)
	_has.append(0)
	_fresh.append(0)
	_types.append("")
	_server_ts.append(0)
	_local_ts.append(0)
	_updates.append(0)
	_callbacks.append(null)
	return slot


func _on_announced(info: Nt4Client.TopicInfo) -> void:
	var slot := _slot_for(info.name)
	_types[slot] = info.type
	info.user = slot


func _on_values(batch: Array) -> void:
	var now := _poll_now_us
	var n := batch.size()
	var i := 0
	while i < n:
		var info: Nt4Client.TopicInfo = batch[i]
		var slot: int = info.user
		var v: Variant = batch[i + 1]
		_values[slot] = v
		_server_ts[slot] = batch[i + 2]
		_local_ts[slot] = now
		_updates[slot] += 1
		_has[slot] = 1
		_fresh[slot] = 1
		var cbs: Variant = _callbacks[slot]
		if cbs != null:
			for cb: Callable in cbs:
				cb.call(v)
		i += 3


func _on_state_changed(s: int, _prev: int) -> void:
	var now_ready := s == Nt4Client.State.READY
	if s != Nt4Client.State.READY and s != Nt4Client.State.SYNCING:
		_fresh.fill(0)
	state_changed.emit(s)
	if now_ready != _ready_flag:
		_ready_flag = now_ready
		connection_changed.emit(now_ready)
