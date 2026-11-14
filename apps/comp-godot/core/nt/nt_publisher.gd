class_name NtPublisher
extends RefCounted

var topic := ""
var type := ""
var _client: Nt4Client
var _pubuid := -1


func _init(client: Nt4Client, p_topic: String, p_type: String, properties: Dictionary = {}) -> void:
	_client = client
	topic = p_topic
	type = p_type
	_pubuid = client.add_publisher(p_topic, p_type, properties)


func pubuid() -> int:
	return _pubuid


## Desired value: sent now when connected and again after every reconnect.
func set_value(value: Variant) -> bool:
	return _client.set_value(_pubuid, value)


func clear() -> void:
	_client.clear_value(_pubuid)


func desired_value() -> Variant:
	return _client.publisher_value(_pubuid)


func remove() -> void:
	_client.remove_publisher(_pubuid)
