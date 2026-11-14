class_name AutosService
extends Node

## Owner of the exported auto library, the shared preview clock and the
## preview frame every view draws (touchscreen Auto tab, HUD minimap). Also
## decides what the HUD shows: the robot-confirmed auto's path in pre-match,
## and the preview ghost while the preview plays.

signal library_changed
signal preview_changed(auto_name: String)

## The turret's default command is ContinuousAimCommand whenever
## TurretSubsystem.isGpsAssistEnabled is true; it starts true and the robot
## code never changes it, so the preview turret aims for the whole auto.
const TURRET_DEFAULT_AIMS := true

var library := AutoLibrary.new()
var clock := AutoClock.new()
var time_source := Clock.new()
var preview_name := ""
var config := AutoMechanisms.load_config()
var rig := RigSolver.load_default()
## Alliance used while the robot does not report one.
var manual_red := true
## Current preview state (AutoMechanisms.state_at plus "joints"), {} when no
## auto is previewed. Recomputed once per frame.
var frame := {}
## {"auto": name or "", "mirror": bool, "red": bool}
var hud := {"auto": "", "mirror": false, "red": true}

var telemetry: TelemetryService
var match_service: MatchService
var controls: ControlsService
var _mechanisms := {}


func _init() -> void:
	process_priority = -800


func _ready() -> void:
	var dev := get_node_or_null("/root/Dev") as DevService
	if dev != null and dev.offline_fixture() and not bool(dev.fixture.get("preview", {}).get("realtime", false)):
		time_source.freeze()
	reload()


func reload() -> void:
	library = AutoLibrary.load_default()
	_mechanisms.clear()
	if not library.is_loaded():
		push_warning("autos: " + library.error)
	if preview_name != "" and library.get_auto(preview_name) == null:
		set_preview("")
	library_changed.emit()


func preview() -> AutoPlayback:
	return library.get_auto(preview_name) if preview_name != "" else null


func mechanisms(auto_name: String) -> AutoMechanisms:
	if auto_name == "":
		return null
	if not _mechanisms.has(auto_name):
		var p := library.get_auto(auto_name)
		_mechanisms[auto_name] = AutoMechanisms.new(p, config) if p != null else null
	return _mechanisms[auto_name]


func preview_mechanisms() -> AutoMechanisms:
	return mechanisms(preview_name)


func set_preview(auto_name: String) -> void:
	preview_name = auto_name
	var m := preview_mechanisms()
	clock.pause()
	clock.end_scrub()
	clock.set_duration(m.duration if m != null else 0.0)
	clock.seek(0.0)
	_update_frame()
	preview_changed.emit(auto_name)


func alliance_known() -> bool:
	return _robot_alliance() != null


func _robot_alliance() -> Variant:
	return telemetry.alliance_red if telemetry != null else null


func alliance_red() -> bool:
	var r: Variant = _robot_alliance()
	return bool(r) if r != null else manual_red


func alliance() -> StringName:
	return AutoPlayback.RED if alliance_red() else AutoPlayback.BLUE


func toggle_manual_alliance() -> void:
	if not alliance_known():
		manual_red = not manual_red
		_update_frame()


func frame_at(m: AutoMechanisms, t: float, side: StringName) -> Dictionary:
	var f := m.state_at(t, side, TURRET_DEFAULT_AIMS)
	f["joints"] = rig.compute_joint_values(f["raw"])
	f["auto"] = m.playback.name
	f["alliance"] = side
	return f


func _process(_delta: float) -> void:
	step()


func step() -> void:
	_bind()
	clock.tick(time_source.now_us())
	_update_frame()
	_update_hud()


func _bind() -> void:
	if telemetry == null:
		telemetry = get_node_or_null("/root/Telemetry") as TelemetryService
	if match_service == null:
		match_service = get_node_or_null("/root/Match") as MatchService
	if controls == null:
		controls = get_node_or_null("/root/Controls") as ControlsService


func _update_frame() -> void:
	var m := preview_mechanisms()
	frame = frame_at(m, clock.t, alliance()) if m != null else {}


## The auto the robot reports in its State, when it names a library auto.
func robot_auto() -> String:
	if controls == null or controls.sync == null or not controls.sync.robot_known():
		return ""
	var r := controls.sync.robot_auto()
	if r == AutoSelectionSync.NONE:
		return ""
	return AutoSelectionSync.find_match(r, library.names())


static func hud_state(pre_match: bool, confirmed: String, preview_auto: String, preview_active: bool) -> Dictionary:
	if not pre_match:
		return {"auto": "", "mirror": false}
	if preview_active and preview_auto != "":
		return {"auto": preview_auto, "mirror": true}
	return {"auto": confirmed, "mirror": false}


func _update_hud() -> void:
	var pre := match_service == null or match_service.model.phase == MatchEnums.Phase.PRE_MATCH
	hud = hud_state(pre, robot_auto(), preview_name if frame.size() > 0 else "", clock.active())
	hud["red"] = alliance_red()


## Dev fixture "preview": {"auto", "t", "playing", "speed", "loop", "alliance": "red"|"blue", "realtime"}.
func apply_fixture(fx: Dictionary) -> void:
	if fx.has("auto"):
		set_preview(str(fx["auto"]))
	if fx.has("alliance"):
		manual_red = str(fx["alliance"]) == "red"
	if fx.has("speed"):
		clock.set_speed(float(fx["speed"]))
	if fx.has("loop"):
		clock.set_loop(bool(fx["loop"]))
	if fx.has("t"):
		clock.seek(float(fx["t"]))
	if bool(fx.get("playing", false)):
		var t := clock.t
		clock.play()
		clock.seek(t)
	_update_frame()
	_update_hud()


func snapshot() -> Dictionary:
	var out := {"auto": preview_name, "t": clock.t, "duration": clock.duration, "playing": clock.playing,
		"scrubbing": clock.scrubbing, "speed": clock.speed, "loop": clock.loop, "alliance": String(alliance()),
		"alliance_known": alliance_known(), "hud": hud.duplicate(), "last_run": clock.last_run.duplicate()}
	if not frame.is_empty():
		var p: Vector3 = frame["pose"]
		out["frame"] = {"t": frame["t"], "pose": [p.x, p.y, p.z], "turret_rad": frame["turret_rad"],
			"wrist_raw": frame["raw"][AutoMechanisms.WRIST_JOINT], "aim": frame["aim"], "shooter": frame["shooter"],
			"rollers": frame["rollers"]}
	return out
