class_name ControlLink
extends RefCounted

## The slice of NetworkTables the robot controls need. NtControlLink binds it
## to the NT autoload; tests use FakeControlLink.


func connected() -> bool:
	return false


## True when the topic delivered a value on the current connection.
func live(_topic: String) -> bool:
	return false


func value(_topic: String, default: Variant = null) -> Variant:
	return default


## Desired-state publish: sent now when connected, and again after every
## reconnect until forget() is called.
func publish(_topic: String, _type: String, _value: Variant) -> bool:
	return false


func forget(_topic: String) -> void:
	pass


## Stops publishing the topic altogether (its name changed with the settings).
func release(_topic: String) -> void:
	pass
