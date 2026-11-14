class_name PerfGovernor
extends Node

## Runs FrameGovernor on the real frame times and hands its caps to Settings,
## which applies them to every 3D view on top of the saved Visual settings.
## Off when the Visual tab's Auto Quality is off, with --auto-quality=off, with
## a --render-scale override, and in offline fixture runs unless
## --auto-quality=on. Test-only: --simulate-gpu-ms=N stalls each frame for
## N ms times the 3D pixel load (render scale squared, 0.8 with MSAA off), a
## stand-in for a GPU that is too slow for the full-quality scene.
## Every LOG_EVERY_S it logs the frame rate and the slowest frame, so a
## driver station log shows how the laptop held up during a match.

const GROUP := "perf_governor"
const LOG_EVERY_S := 60.0

var args := {}
var governor := FrameGovernor.new()
var settings: SettingsService
var _simulate_ms := 0.0
var _log_s := 0.0
var _log_frames := 0
var _log_worst_s := 0.0


func _init() -> void:
	add_to_group(GROUP)
	process_priority = 1000


func _ready() -> void:
	if settings == null:
		settings = get_node_or_null("/root/Settings") as SettingsService
	_simulate_ms = CliArgs.get_float(args, "simulate_gpu_ms", 0.0)
	governor.reset()
	if settings != null:
		settings.changed.connect(_on_settings_changed)


func enabled() -> bool:
	if settings == null:
		return false
	var flag := str(args.get("auto_quality", ""))
	if flag == "off" or settings.visual_overrides.has("render_scale"):
		return false
	if flag != "on":
		var dev := get_node_or_null("/root/Dev") as DevService
		if dev != null and dev.offline_fixture():
			return false
	return bool(settings.visual().get("auto_quality", true))


func _on_settings_changed(section: String) -> void:
	if section == "visual" and not enabled() and not settings.perf_caps.is_empty():
		governor.reset()
		settings.set_perf_caps({})


## The user changed a Visual setting: start over from full quality.
func restart() -> void:
	governor.reset()
	if settings != null and not settings.perf_caps.is_empty():
		settings.set_perf_caps({})


func _process(delta: float) -> void:
	if _simulate_ms > 0.0 and settings != null:
		var v := settings.effective_visual()
		var pixel_load := float(v["render_scale"]) * float(v["render_scale"]) * (1.0 if int(v["msaa"]) > 0 else 0.8)
		OS.delay_usec(int(_simulate_ms * pixel_load * 1000.0))
	_log_frame(delta)
	if not enabled():
		return
	var target := float(Engine.max_fps) if Engine.max_fps > 0 else 60.0
	if governor.feed(delta, target, not CadView.rendering_views(get_tree()).is_empty()):
		settings.set_perf_caps(governor.caps())
		print("perf: %s" % governor.status_text())


func _log_frame(delta: float) -> void:
	_log_s += delta
	_log_frames += 1
	_log_worst_s = maxf(_log_worst_s, delta)
	if _log_s >= LOG_EVERY_S:
		print("perf: %.1f fps over %.0f s, slowest frame %.0f ms, auto quality %s" % [_log_frames / _log_s, _log_s, _log_worst_s * 1000.0, status_text()])
		_log_s = 0.0
		_log_frames = 0
		_log_worst_s = 0.0


func status_text() -> String:
	if not enabled():
		return "off"
	return governor.status_text()


func snapshot() -> Dictionary:
	return {"enabled": enabled(), "level": governor.level, "state": FrameGovernor.State.keys()[governor.state],
		"caps": governor.caps().duplicate(), "last_fps": governor.last_fps, "history": governor.history.duplicate(true),
		"status": status_text()}
