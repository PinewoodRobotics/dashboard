class_name FrameGovernor
extends RefCounted

## Automatic quality fallback for a GPU that cannot hold the frame cap. Frame
## times are averaged over WINDOW_S while a 3D view renders; a window below
## SLOW_FRACTION of the target lowers quality one level (MSAA off, then render
## scale 0.75, then 0.5), skipping levels that change nothing on top of the
## saved settings. A level that does not raise the frame rate by
## MIN_GAIN_FPS is undone and the governor stops: the frame rate is then held
## back by something a lower resolution does not fix (CPU, a vsync pair
## running at half rate), and lowering further would only cost quality. It
## never raises quality again by itself; reset() starts over.

const LEVELS := [{}, {"msaa": 0}, {"msaa": 0, "render_scale": 0.75}, {"msaa": 0, "render_scale": 0.5}]
const WINDOW_S := 3.0
const WARMUP_S := 5.0
const SETTLE_S := 1.5
const SLOW_FRACTION := 0.92
const MIN_GAIN_FPS := 2.0

enum State { WATCHING, TRYING, HELD, GAVE_UP }

var level := 0
var state := State.WATCHING
var last_fps := 0.0
## Average fps of the window that triggered the current level.
var before_fps := 0.0
var history: Array = []
var _undo_level := 0
var _skip_s := WARMUP_S
var _sum_s := 0.0
var _frames := 0


func reset() -> void:
	level = 0
	_undo_level = 0
	state = State.WATCHING
	before_fps = 0.0
	history.clear()
	_restart(WARMUP_S)


## Caps on top of the saved visual settings, {} at full quality.
func caps() -> Dictionary:
	return LEVELS[level]


## One frame of dt seconds; target_fps is the frame cap (60 when uncapped);
## base holds the saved render_scale and msaa. Returns true when caps() changed.
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
			history.append({"level": level, "fps": last_fps, "undo": true})
			level = _undo_level
			state = State.GAVE_UP
			return true
		state = State.WATCHING
	if last_fps >= target_fps * SLOW_FRACTION:
		state = State.HELD if level > 0 else State.WATCHING
		return false
	var next := _next_effective_level(base)
	if next < 0:
		state = State.HELD
		return false
	before_fps = last_fps
	_undo_level = level
	level = next
	state = State.TRYING
	history.append({"level": level, "fps": last_fps})
	return true


func _next_effective_level(base: Dictionary) -> int:
	var now := applied(LEVELS[level], base)
	for l in range(level + 1, LEVELS.size()):
		if applied(LEVELS[l], base) != now:
			return l
	return -1


static func applied(c: Dictionary, base: Dictionary) -> Dictionary:
	var out := {}
	for k: String in ["render_scale", "msaa"]:
		var saved: float = float(base.get(k, INF))
		out[k] = minf(saved, float(c[k])) if c.has(k) else saved
	return out


func _restart(skip_s: float) -> void:
	_skip_s = skip_s
	_sum_s = 0.0
	_frames = 0


func status_text() -> String:
	var what := "full quality" if level == 0 else describe(LEVELS[level])
	match state:
		State.TRYING:
			return "lowered to %s at %.0f fps, measuring" % [what, before_fps]
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
	return ", ".join(parts)
