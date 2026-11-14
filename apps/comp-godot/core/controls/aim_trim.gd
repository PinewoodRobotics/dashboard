class_name AimTrim
extends RefCounted

## Turret aim trim (useShooterTuningNetworkTable.ts). Writes the absolute
## /Tuning/Turret/AimTrimDeg (clamped to +-10 deg, rounded to 0.01) and
## confirms against /AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg,
## which the M1 sim run showed follows a held publisher within one robot loop
## (tests/golden/sim_aimtrim_readback.json). Not persisted: the trim lives in
## the robot, and a pending request is dropped when the connection drops, so
## it is never re-sent to a rebooted robot.

const LIMIT_DEG := 10.0
const STEP_DEG := 0.25
const CONFIRM_EPS := 0.005

const STATUS_DISCONNECTED := "Robot not connected"
const STATUS_WAITING := "Waiting for the robot to confirm"
const STATUS_CONFIRMED := "Robot confirmed this trim"
const STATUS_UNKNOWN := "No trim reported by the robot yet"

var link: ControlLink
var publish_topic := Topics.AIM_TRIM_PUBLISH
var readback_topic := Topics.AIM_TRIM_READBACK
var requested: Variant = null
var last_sent: Variant = null
var publishes := 0
var _was_connected := false


func _init(p_link: ControlLink) -> void:
	link = p_link


static func clamp_trim(deg: float) -> float:
	return roundf(clampf(deg, -LIMIT_DEG, LIMIT_DEG) * 100.0) / 100.0


## "0°", "2.5° L" (positive aims left, CCW), "1.25° R".
static func format(deg: float) -> String:
	var mag := snappedf(absf(deg), 0.01)
	if mag == 0.0:
		return "0°"
	var s := String.num(mag, 2)
	if s.contains("."):
		s = s.rstrip("0").trim_suffix(".")
	return "%s° %s" % [s, "L" if deg > 0.0 else "R"]


func connected() -> bool:
	return link.connected()


func robot_trim() -> Variant:
	if not link.connected() or not link.live(readback_topic):
		return null
	var v: Variant = link.value(readback_topic)
	return float(v) if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v)) else null


## Returns true when a value was published.
func set_trim(deg: float) -> bool:
	if not connected():
		return false
	var v := clamp_trim(deg)
	requested = v
	var target: Variant = last_sent if last_sent != null else robot_trim()
	if target != null and absf(float(target) - v) < CONFIRM_EPS:
		return false
	last_sent = v
	publishes += 1
	link.publish(publish_topic, "double", v)
	return true


func center() -> bool:
	return set_trim(0.0)


func update() -> void:
	var c := connected()
	if not c:
		if _was_connected or requested != null or last_sent != null:
			link.forget(publish_topic)
		requested = null
		last_sent = null
	_was_connected = c
	if requested != null:
		var r: Variant = robot_trim()
		if r != null and absf(float(r) - float(requested)) < CONFIRM_EPS:
			requested = null
			last_sent = null


func slider_value() -> float:
	if requested != null:
		return requested
	var r: Variant = robot_trim()
	return r if r != null else 0.0


func status() -> String:
	if not connected():
		return STATUS_DISCONNECTED
	if requested != null:
		return STATUS_WAITING
	if robot_trim() != null:
		return STATUS_CONFIRMED
	return STATUS_UNKNOWN


func snapshot() -> Dictionary:
	return {"requested": requested, "robot": robot_trim(), "slider": slider_value(), "status": status(),
		"connected": connected(), "publishes": publishes, "last_sent": last_sent}
