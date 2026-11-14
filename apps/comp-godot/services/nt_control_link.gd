class_name NtControlLink
extends ControlLink

## ControlLink over an NtService: one desired-state publisher per topic.

var nt: NtService
var _pubs := {}


func _init(p_nt: NtService) -> void:
	nt = p_nt


func connected() -> bool:
	return nt.is_ready()


func live(topic: String) -> bool:
	return nt.is_live(topic)


func value(topic: String, default: Variant = null) -> Variant:
	return nt.value(topic, default)


func publish(topic: String, type: String, v: Variant) -> bool:
	var pub: NtPublisher = _pubs.get(topic)
	if pub == null or pub.type != type:
		if pub != null:
			pub.remove()
		pub = nt.publisher(topic, type)
		_pubs[topic] = pub
	return pub.set_value(v)


func forget(topic: String) -> void:
	var pub: NtPublisher = _pubs.get(topic)
	if pub != null:
		pub.clear()


func release(topic: String) -> void:
	var pub: NtPublisher = _pubs.get(topic)
	if pub != null:
		pub.remove()
		_pubs.erase(topic)


func desired(topic: String) -> Variant:
	var pub: NtPublisher = _pubs.get(topic)
	return pub.desired_value() if pub != null else null
