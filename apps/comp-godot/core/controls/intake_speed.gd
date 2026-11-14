class_name IntakeSpeed
extends RefCounted

## Intake speed override (useIntakeSpeedNetworkTable.ts). The requested duty
## cycle is persisted and published to <shared>/Intake/Speed/Request, again on
## every reconnect so a robot reboot keeps it; Reset publishes the -1
## sentinel ("use the compiled constant") and clears the stored value. The
## robot reports the speed it applies on .../State.

signal requested_changed(requested: Variant)

const RESET_SENTINEL := -1.0
const FALLBACK_SPEED := 0.15
const CONFIRM_EPS := 0.005

const STATUS_DISCONNECTED := "Robot not connected - value is sent when it reconnects"
const STATUS_CONSTANT := "Using the robot's compiled constant"
const STATUS_CONFIRMED := "Robot confirmed this speed"
const STATUS_WAITING := "Waiting for the robot to confirm"

var link: ControlLink
var request_topic := ""
var state_topic := ""
## null = no override.
var requested: Variant = null
var publishes := 0
var last_published: Variant = null
var _was_connected := false


func _init(p_link: ControlLink, topics: Dictionary, stored: Variant = null) -> void:
	link = p_link
	request_topic = topics["request"]
	state_topic = topics["state"]
	requested = round_speed(stored) if _finite(stored) else null


static func _finite(v: Variant) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v))


static func round_speed(v: float) -> float:
	return roundf(clampf(v, 0.0, 1.0) * 100.0) / 100.0


func set_topics(topics: Dictionary) -> void:
	if topics["request"] == request_topic and topics["state"] == state_topic:
		return
	link.release(request_topic)
	request_topic = topics["request"]
	state_topic = topics["state"]
	if requested != null:
		_publish(requested)


func set_speed(v: float) -> void:
	requested = round_speed(v)
	requested_changed.emit(requested)
	_publish(requested)


func reset() -> void:
	requested = null
	requested_changed.emit(null)
	_publish(RESET_SENTINEL)


func _publish(v: float) -> void:
	publishes += 1
	last_published = v
	link.publish(request_topic, "double", v)


func update() -> void:
	var c := link.connected()
	if c and not _was_connected and requested != null:
		_publish(requested)
	_was_connected = c


## The speed the robot reports on this connection, or null.
func robot_speed() -> Variant:
	if not link.connected() or not link.live(state_topic):
		return null
	var v: Variant = link.value(state_topic)
	return float(v) if _finite(v) else null


func slider_value() -> float:
	if requested != null:
		return requested
	var r: Variant = robot_speed()
	return r if r != null else FALLBACK_SPEED


func status() -> String:
	if not link.connected():
		return STATUS_DISCONNECTED
	if requested == null:
		return STATUS_CONSTANT
	var r: Variant = robot_speed()
	if r != null and absf(float(r) - float(requested)) < CONFIRM_EPS:
		return STATUS_CONFIRMED
	return STATUS_WAITING


func snapshot() -> Dictionary:
	return {"requested": requested, "robot": robot_speed(), "slider": slider_value(), "status": status(),
		"publishes": publishes, "last_published": last_published, "request_topic": request_topic}
