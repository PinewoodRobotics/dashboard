class_name FrameGovernor
extends RefCounted

## Automatic quality fallback for a GPU that cannot hold the frame cap. Frame
## times are averaged over WINDOW_S while a 3D view renders; a window below
## SLOW_FRACTION of the target tries the next step: MSAA off, light models
## (fewer vertices), render scale 0.75, then 0.5. Steps that change nothing on
## top of the saved settings are skipped. A step that does not raise the frame
## rate by MIN_GAIN_FPS is undone and every later step on the same knob is
## skipped, so a vertex-bound GPU still gets the light models after MSAA off
## did nothing, and a fill-bound one still gets the lower render scale after
## the light models did nothing. When no step is left to try the governor
## stops; if nothing helped, the frame rate is held back by something these
## knobs do not fix (CPU, a vsync pair running at half rate). It never raises
## quality again by itself; reset() starts over.

const STEPS := [{"msaa": 0}, {"models": "lite"}, {"render_scale": 0.75}, {"render_scale": 0.5}]
const WINDOW_S := 3.0
const WARMUP_S := 5.0
const SETTLE_S := 1.5
const SLOW_FRACTION := 0.92
const MIN_GAIN_FPS := 2.0

enum State { WATCHING, TRYING, HELD, GAVE_UP }

## Indices into STEPS that raised the frame rate, in the order they were kept.
var kept: Array[int] = []
var trying := -1
var state := State.WATCHING
var last_fps := 0.0
var before_fps := 0.0
var history: Array = []
var _next := 0
var _dead_knobs := {}
var _skip_s := WARMUP_S
var _sum_s := 0.0
var _frames := 0


func reset() -> void:
	kept.clear()
	trying = -1
	_next = 0
	_dead_knobs.clear()
	state = State.WATCHING
	before_fps = 0.0
	history.clear()
	_restart(WARMUP_S)


func caps() -> Dictionary:
	return _caps_with(trying)


func _caps_with(extra: int) -> Dictionary:
	var out := {}
	for i in kept:
		out.merge(STEPS[i], true)
	if extra >= 0:
		out.merge(STEPS[extra], true)
	return out


## base holds the saved render_scale and msaa; true when caps() changed.
func feed(dt: float, target_fps: float, rendering_3d: bool, base: Dictionary = {}) -> bool:
	if state == State.GAVE_UP or not rendering_3d or dt <= 0.0:
		return false
	if _skip_s > 0.0:
		_skip_s -= dt
		return false
	_sum_s += dt
	_frames += 1
	if _sum_s < WINDOW_S:
		return false
	last_fps = _frames / _sum_s
	_restart(SETTLE_S)
	if state == State.TRYING:
		if last_fps < before_fps + MIN_GAIN_FPS:
			history.append({"step": trying, "fps": last_fps, "undo": true})
			for k: String in STEPS[trying]:
				_dead_knobs[k] = true
			trying = -1
			if not _try_next(base):
				state = State.GAVE_UP if kept.is_empty() else State.HELD
			return true
		kept.append(trying)
		trying = -1
		state = State.WATCHING
	if last_fps >= target_fps * SLOW_FRACTION:
		state = State.HELD if not kept.is_empty() else State.WATCHING
		return false
	before_fps = last_fps
	if not _try_next(base):
		state = State.HELD
		return false
	return true


func _try_next(base: Dictionary) -> bool:
	var now := applied(caps(), base)
	for i in range(_next, STEPS.size()):
		if STEPS[i].keys().any(func(k: String) -> bool: return _dead_knobs.has(k)):
			continue
		if applied(_caps_with(i), base) == now:
			continue
		trying = i
		_next = i + 1
		state = State.TRYING
		history.append({"step": i, "fps": before_fps})
		return true
	_next = STEPS.size()
	return false


static func applied(c: Dictionary, base: Dictionary) -> Dictionary:
	var out := {}
	for k: String in ["render_scale", "msaa"]:
		var saved: float = float(base.get(k, INF))
		out[k] = minf(saved, float(c[k])) if c.has(k) else saved
	out["models"] = str(c.get("models", base.get("models", "full")))
	return out


func _restart(skip_s: float) -> void:
	_skip_s = skip_s
	_sum_s = 0.0
	_frames = 0


func status_text() -> String:
	var what := "full quality" if caps().is_empty() else describe(caps())
	match state:
		State.TRYING:
			return "trying %s at %.0f fps, measuring" % [describe(STEPS[trying]), before_fps]
		State.GAVE_UP:
			return "%s; lowering did not help (%.0f fps)" % [what, last_fps]
		State.HELD:
			return "%s, %.0f fps" % [what, last_fps]
	return "%s, watching" % what if last_fps <= 0.0 else "%s, %.0f fps" % [what, last_fps]


static func describe(c: Dictionary) -> String:
	var parts := PackedStringArray()
	if c.has("render_scale"):
		parts.append("%sx scale" % str(c["render_scale"]))
	if c.has("msaa"):
		parts.append("MSAA off")
	if c.has("models"):
		parts.append("light models")
	return ", ".join(parts)
