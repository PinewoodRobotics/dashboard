class_name MatchService
extends Node

## Binds MatchModel to NT: one callback per /matchhud/state topic plus the
## lane-alignment signal, the NT ready flag, and a per-frame step. Offline
## fixtures freeze the clock so countdowns show exactly the fixture values.

const LANE_TOPIC := Topics.LANE_ADJUSTING_VELOCITY

var nt: NtService
var clock := Clock.new()
var model := MatchModel.new()


func _init() -> void:
	process_priority = -950


func _ready() -> void:
	var dev := get_node_or_null("/root/Dev") as DevService
	if dev != null and dev.offline_fixture():
		clock.freeze()
	if nt == null:
		nt = get_node_or_null("/root/NT") as NtService
	if nt != null:
		bind(nt)


func bind(service: NtService) -> void:
	nt = service
	for key: String in Topics.MATCH_STATE:
		nt.on_value(Topics.match_topic(key), _ingest.bind(key))
	nt.on_value(LANE_TOPIC, _ingest.bind("lane_alignment"))
	nt.connection_changed.connect(_on_connection_changed)
	model.set_nt_ready(nt.is_ready(), clock.now_us())


func _ingest(v: Variant, key: String) -> void:
	model.ingest(key, v, clock.now_us())


func _on_connection_changed(ready: bool) -> void:
	model.set_nt_ready(ready, clock.now_us())


func _process(_delta: float) -> void:
	model.step(clock.now_us())


func now_us() -> int:
	return clock.now_us()
