class_name FakeControlLink
extends ControlLink

## In-memory ControlLink: `up` is the connection, `values` the topics that
## arrived on it, `published` every publish in order.

var up := false
var values := {}
var published: Array = []
var desired := {}
var forgotten: PackedStringArray = []
var released: PackedStringArray = []


func connected() -> bool:
	return up


func live(topic: String) -> bool:
	return up and values.has(topic)


func value(topic: String, default: Variant = null) -> Variant:
	return values.get(topic, default)


func publish(topic: String, _type: String, v: Variant) -> bool:
	published.append([topic, v])
	desired[topic] = v
	return true


func forget(topic: String) -> void:
	forgotten.append(topic)
	desired.erase(topic)


func release(topic: String) -> void:
	released.append(topic)
	desired.erase(topic)


func count(topic: String) -> int:
	var n := 0
	for p: Array in published:
		if p[0] == topic:
			n += 1
	return n


func last(topic: String) -> Variant:
	for i in range(published.size() - 1, -1, -1):
		if published[i][0] == topic:
			return published[i][1]
	return null
