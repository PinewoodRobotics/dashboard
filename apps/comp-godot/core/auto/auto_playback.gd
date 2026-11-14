class_name AutoPlayback
extends RefCounted

## One exported auto (data/autos/<name>.json): poses on a fixed dt grid for both
## alliances, plus the timeline (segments, events, warnings). sample() is a pure
## function of t, so scrubbing in any order gives the same pose.

const RED := &"red"
const BLUE := &"blue"
const CHANNELS: Array[StringName] = [&"x", &"y", &"heading", &"vx", &"vy", &"omega"]

var name := ""
var folder := ""
var dt := 0.02
var duration_s := 0.0
var nominal_duration_s := 0.0
var auto_length_s := 20.0
var ends_by_itself := false
var sample_count := 0
var paths: PackedStringArray = []
var segments: Array = []
var events: Array = []
var warnings: Array = []
var start_pose := {}
var end_pose := {}
var _channels := {}


static func from_dict(d: Dictionary) -> AutoPlayback:
	var p := AutoPlayback.new()
	p.name = str(d.get("name", ""))
	p.folder = str(d["folder"]) if d.get("folder") != null else ""
	p.dt = float(d.get("dt", 0.02))
	p.duration_s = float(d.get("duration_s", 0.0))
	p.nominal_duration_s = float(d.get("nominal_duration_s", p.duration_s))
	p.auto_length_s = float(d.get("auto_length_s", 20.0))
	p.ends_by_itself = bool(d.get("ends_by_itself", false))
	p.paths = PackedStringArray(d.get("paths", []))
	p.segments = d.get("segments", [])
	p.events = d.get("events", [])
	p.warnings = d.get("warnings", [])
	for side: StringName in [RED, BLUE]:
		if d.get("start_pose") is Dictionary:
			p.start_pose[side] = _vec3(d["start_pose"][side])
			p.end_pose[side] = _vec3(d["end_pose"][side])
		var raw = d.get("samples", {}).get(side) if d.get("samples") is Dictionary else null
		if raw is Dictionary:
			var ch := {}
			for k: StringName in CHANNELS:
				ch[k] = PackedFloat64Array(raw[String(k)])
			p._channels[side] = ch
	p.sample_count = (p._channels[RED][&"x"] as PackedFloat64Array).size() if p._channels.has(RED) else 0
	return p


## Why d cannot be played back, or "" when it can. from_dict() trusts its
## input, so every export goes through this first.
static func validate(d: Variant) -> String:
	if not d is Dictionary:
		return "not a JSON object"
	for k in ["dt", "duration_s"]:
		if not _is_num(d.get(k)) or float(d[k]) < 0.0:
			return "bad %s" % k
	if float(d["dt"]) <= 0.0:
		return "bad dt"
	for k in ["segments", "events", "warnings"]:
		if d.has(k) and not d[k] is Array:
			return "bad %s" % k
	for e: Variant in d.get("events", []):
		if not e is Dictionary or not _is_num(e.get("t0")) or not _is_num(e.get("t1")):
			return "bad event"
	for s: Variant in d.get("segments", []):
		if not s is Dictionary or not _is_num(s.get("t1")):
			return "bad segment"
	for w: Variant in d.get("warnings", []):
		if not w is Dictionary or not w.has("code"):
			return "bad warning"
	var samples: Variant = d.get("samples")
	var path := samples is Dictionary and samples.get(String(RED)) != null
	if not path:
		return ""
	var n := -1
	for side: StringName in [RED, BLUE]:
		var raw: Variant = samples.get(String(side))
		if not raw is Dictionary:
			return "no %s samples" % side
		for k: StringName in CHANNELS:
			var a: Variant = raw.get(String(k))
			if not a is Array or (a as Array).is_empty():
				return "missing %s samples: %s" % [side, k]
			if n < 0:
				n = (a as Array).size()
			if (a as Array).size() != n:
				return "%s %s has %d samples, expected %d" % [side, k, (a as Array).size(), n]
			for v: Variant in a:
				if not _is_num(v):
					return "non-numeric %s %s sample" % [side, k]
		for k in ["start_pose", "end_pose"]:
			var pose: Variant = d.get(k)
			if not pose is Dictionary or not pose.get(String(side)) is Array or (pose[String(side)] as Array).size() != 3:
				return "bad %s" % k
			for v: Variant in pose[String(side)]:
				if not _is_num(v):
					return "bad %s" % k
	return ""


static func _is_num(v: Variant) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v))


static func _vec3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func has_path() -> bool:
	return sample_count > 0


## Length of the preview timeline: until the auto ends by itself, otherwise
## the whole auto period, because its never-ending commands run until then.
func timeline_s() -> float:
	return maxf(nominal_duration_s if ends_by_itself else auto_length_s, duration_s)


## Pose and field-relative velocity at t seconds (blue-origin meters, radians),
## clamped to [0, duration_s]. Empty when the auto has no path.
func sample(t: float, alliance: StringName) -> Dictionary:
	if sample_count == 0:
		return {}
	var ch: Dictionary = _channels[alliance]
	var u := clampf(t, 0.0, duration_s) / dt
	var i := clampi(floori(u), 0, sample_count - 1)
	var j := mini(i + 1, sample_count - 1)
	var f := clampf(u - i, 0.0, 1.0) if j != i else 0.0
	var out := {}
	for k: StringName in CHANNELS:
		var a: PackedFloat64Array = ch[k]
		out[k] = lerp_angle(a[i], a[j], f) if k == &"heading" else lerpf(a[i], a[j], f)
	return out


## (x, y, heading) at t; Vector3.ZERO when the auto has no path.
func sample_pose(t: float, alliance: StringName) -> Vector3:
	var s := sample(t, alliance)
	if s.is_empty():
		return Vector3.ZERO
	return Vector3(s[&"x"], s[&"y"], s[&"heading"])


func sample_at(index: int, alliance: StringName) -> Vector3:
	var ch: Dictionary = _channels[alliance]
	return Vector3(ch[&"x"][index], ch[&"y"][index], ch[&"heading"][index])


func channel(key: StringName, alliance: StringName) -> PackedFloat64Array:
	return _channels[alliance][key] if _channels.has(alliance) else PackedFloat64Array()


## Events whose interval contains t (instant events only at their own time).
func events_at(t: float) -> Array:
	var out: Array = []
	for e: Dictionary in events:
		if float(e["t0"]) <= t and (t < float(e["t1"]) or (e["t0"] == e["t1"] and is_equal_approx(t, float(e["t0"])))):
			out.append(e)
	return out


func segment_at(t: float) -> Dictionary:
	for s: Dictionary in segments:
		if t <= float(s["t1"]):
			return s
	return segments.back() if not segments.is_empty() else {}


func warning_codes() -> PackedStringArray:
	var out := PackedStringArray()
	for w: Dictionary in warnings:
		if not out.has(str(w["code"])):
			out.append(str(w["code"]))
	return out
