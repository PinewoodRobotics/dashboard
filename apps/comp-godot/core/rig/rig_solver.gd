class_name RigSolver
extends RefCounted

## Port of transformNtValue / computeJointValues (apps/comp useRobotJoints.ts)
## plus optional per-joint smoothing of the resolved values.

const DEFAULT_RIG_PATH := "res://data/rig/robot-rig.json"
const DEFAULT_SMOOTHING_S := 0.06


class Joint:
	extends RefCounted
	var key := ""
	var node_name := ""
	var revolute := true
	var axis := Vector3.RIGHT
	var min_value := 0.0
	var max_value := 0.0
	var default_value := 0.0
	var nt_topic := ""
	var wrap_signed_unit := false
	var has_transform := false
	var scale := 1.0
	var offset := 0.0
	var link_source := ""
	var link_scale := 1.0
	var link_offset := 0.0
	var smoothing_s := DEFAULT_SMOOTHING_S
	## debugSlider: label and step for the Robot 3D tab; "" = no slider.
	var debug_label := ""
	var debug_step := 0.01

	func clamp_value(v: float) -> float:
		return clampf(v, min_value, max_value)


var joints: Array[Joint] = []
var bumper_nodes: PackedStringArray = []
## Smoothed output, joint key -> value. Empty until the first step().
var values := {}
var _by_key := {}


static func load_default() -> RigSolver:
	return from_file(DEFAULT_RIG_PATH)


static func from_file(path: String) -> RigSolver:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert(typeof(parsed) == TYPE_DICTIONARY, "rig json unreadable: " + path)
	return from_dict(parsed)


static func from_dict(rig: Dictionary) -> RigSolver:
	var s := RigSolver.new()
	s.bumper_nodes = PackedStringArray(rig.get("bumperNodes", []))
	var src: Dictionary = rig.get("joints", {})
	for key: String in src:
		var j: Dictionary = src[key]
		var joint := Joint.new()
		joint.key = key
		joint.node_name = j.get("nodeName", "")
		joint.revolute = j.get("type", "revolute") == "revolute"
		var a: Array = j.get("axis", [1, 0, 0])
		joint.axis = Vector3(a[0], a[1], a[2]).normalized()
		var lim: Dictionary = j.get("limits", {})
		joint.min_value = float(lim.get("min", -INF))
		joint.max_value = float(lim.get("max", INF))
		joint.default_value = float(j.get("defaultValue", 0.0))
		joint.nt_topic = j.get("ntTopic", "")
		joint.wrap_signed_unit = j.get("inputWrap", "") == "signedUnitRotation"
		if j.has("inputTransform"):
			joint.has_transform = true
			joint.scale = float(j["inputTransform"].get("scale", 1.0))
			joint.offset = float(j["inputTransform"].get("offset", 0.0))
		if j.has("link"):
			joint.link_source = j["link"].get("source", "")
			joint.link_scale = float(j["link"].get("scale", 1.0))
			joint.link_offset = float(j["link"].get("offset", 0.0))
		if j.has("debugSlider"):
			joint.debug_label = str(j["debugSlider"].get("label", key))
			joint.debug_step = float(j["debugSlider"].get("step", 0.01))
		if j.has("smoothing"):
			joint.smoothing_s = maxf(0.0, float(j["smoothing"]))
		s.joints.append(joint)
		s._by_key[key] = joint
	return s


func joint(key: String) -> Joint:
	return _by_key.get(key)


func nt_topics() -> PackedStringArray:
	var out := PackedStringArray()
	for j in joints:
		if j.nt_topic != "":
			out.append(j.nt_topic)
	return out


static func wrap_signed_unit_rotation(v: float) -> float:
	return v - floorf(v + 0.5)


static func transform_nt_value(j: Joint, raw: float) -> float:
	var v := raw
	if j.wrap_signed_unit:
		v = wrap_signed_unit_rotation(v)
	if j.has_transform:
		v = v * j.scale + j.offset
	return j.clamp_value(v)


## live_raw: joint key -> raw NT value, only for joints whose topic is live.
## manual: joint key -> value used when the topic is not live.
## Returns joint key -> resolved value (unsmoothed).
func compute_joint_values(live_raw: Dictionary, manual: Dictionary = {}) -> Dictionary:
	var resolved := {}
	for j in joints:
		if j.link_source != "":
			continue
		var live := j.nt_topic != "" and live_raw.has(j.key)
		var v: float = transform_nt_value(j, float(live_raw[j.key])) if live else float(manual.get(j.key, j.default_value))
		resolved[j.key] = j.clamp_value(v)
	_resolve_links(resolved)
	return resolved


func _resolve_links(resolved: Dictionary) -> void:
	for j in joints:
		if j.link_source == "":
			continue
		var src: float = resolved.get(j.link_source, 0.0)
		resolved[j.key] = j.clamp_value(src * j.link_scale + j.link_offset)


## Moves the smoothed values toward `targets` (from compute_joint_values).
## Linked joints follow their smoothed source so they stay exactly coupled.
## A revolute jump over PI (wrap across the limit) snaps instead of sweeping.
func step(targets: Dictionary, dt: float) -> Dictionary:
	var first := values.is_empty()
	for j in joints:
		if j.link_source != "":
			continue
		var target: float = targets.get(j.key, j.default_value)
		if first or j.smoothing_s <= 0.0 or not values.has(j.key):
			values[j.key] = target
			continue
		var cur: float = values[j.key]
		if j.revolute and absf(target - cur) > PI:
			values[j.key] = target
			continue
		var k := 1.0 - exp(-dt / j.smoothing_s)
		values[j.key] = cur + (target - cur) * k
	_resolve_links(values)
	return values


func snap(targets: Dictionary) -> void:
	values = {}
	step(targets, 0.0)
