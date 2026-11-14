class_name MatchModel
extends RefCounted

## Typed view of /matchhud/state/* plus the lane-alignment signal, fed one value
## at a time (ingest) and stepped once per frame. No engine or NT access, so it
## runs under a fake clock in tests.

signal phase_changed(phase: MatchEnums.Phase)
signal link_changed(link_ok: bool)
signal toast_fired(on: bool)

const STALE_AFTER_S := 1.0

enum Banner { NONE, DISCONNECTED, NO_DATA, STALE }

const COUNTDOWN_KEYS := [
	"total_time_remaining_s",
	"period_time_remaining_s",
	"shift_time_remaining_s",
	"shift_time_with_buffer_s",
	"buffer_remaining_s",
]

var nt_ready := false
var seq := 0
var connected_flag := false
var phase := MatchEnums.Phase.PRE_MATCH
var hub := MatchEnums.Hub.NONE
var header := MatchEnums.Header.HIDDEN
var aim := MatchEnums.Aim.SHOOTER_DISABLED
var show_shift_indicator := false
var show_buffer := false
var is_red_alliance: Variant = null
## null until the robot publishes it; only an explicit false counts as invalid.
var pose_valid: Variant = null
var countdowns := {}
var toast := LaneToast.new()

var _fresh := {}
var _last_seq_change_us := 0
var _link_ok := false
var _now_us := 0


func _init() -> void:
	for k: String in COUNTDOWN_KEYS:
		countdowns[k] = Countdown.new()


func set_nt_ready(ready: bool, now_us: int) -> void:
	if ready == nt_ready:
		return
	nt_ready = ready
	_fresh.clear()
	if ready:
		_last_seq_change_us = now_us
	step(now_us)


func ingest(key: String, v: Variant, now_us: int) -> void:
	if v == null:
		return
	_fresh[key] = true
	match key:
		"seq":
			var s := int(v) if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT else 0
			if s != seq:
				seq = s
				_last_seq_change_us = now_us
				for c: Countdown in countdowns.values():
					c.on_seq()
		"connected":
			connected_flag = v == true
		"match_phase":
			var p := MatchEnums.phase(v)
			if p != phase:
				phase = p
				if p == MatchEnums.Phase.PRE_MATCH:
					toast.reset()
				phase_changed.emit(p)
		"hub_status":
			hub = MatchEnums.hub(v)
		"header_color":
			header = MatchEnums.header(v)
		"aim_mode":
			aim = MatchEnums.aim(v)
		"show_shift_indicator":
			show_shift_indicator = v == true
		"show_buffer":
			show_buffer = v == true
		"is_red_alliance":
			is_red_alliance = v == true
		"robot_pose_valid":
			pose_valid = v == true
		"lane_alignment":
			if toast.observe(v == true, now_us):
				toast_fired.emit(v == true)
		_:
			if countdowns.has(key) and (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT):
				(countdowns[key] as Countdown).update(float(v), now_us)


func is_fresh(key: String) -> bool:
	return _fresh.has(key)


## Robot data arrived on this connection: seq > 0 or the DS-attached flag.
func has_data() -> bool:
	return (is_fresh("seq") and seq > 0) or (is_fresh("connected") and connected_flag)


func connected() -> bool:
	return nt_ready and has_data()


func stale(now_us: int = -1) -> bool:
	var t := _now_us if now_us < 0 else now_us
	return connected() and t - _last_seq_change_us >= int(STALE_AFTER_S * 1_000_000.0)


func link_ok() -> bool:
	return _link_ok


func banner() -> Banner:
	if not nt_ready:
		return Banner.DISCONNECTED
	if not has_data():
		return Banner.NO_DATA
	if stale():
		return Banner.STALE
	return Banner.NONE


func step(now_us: int) -> void:
	_now_us = now_us
	var ok := connected() and not stale(now_us)
	if ok != _link_ok:
		_link_ok = ok
		if not ok:
			for c: Countdown in countdowns.values():
				c.on_link_lost()
		link_changed.emit(ok)


func countdown(key: String, now_us: int) -> float:
	return (countdowns[key] as Countdown).display(now_us, _link_ok)


func total_display(now_us: int) -> float:
	return countdown("total_time_remaining_s", now_us)


## {main: float, buffer: float or null} as ShiftIndicator.tsx picks them.
static func select_shift(p: MatchEnums.Phase, h: MatchEnums.Hub, period: float, shift: float, with_buffer: float, buffer_rem: float, buffer_shown: bool) -> Dictionary:
	var main: float
	if MatchEnums.is_both_hub_period(p):
		main = maxf(0.0, period)
	elif h == MatchEnums.Hub.WARNING:
		main = 0.0
	else:
		main = maxf(0.0, shift)
	var buffer: Variant = null
	if buffer_shown:
		buffer = maxf(0.0, buffer_rem if h == MatchEnums.Hub.WARNING else with_buffer)
	return {"main": main, "buffer": buffer}


func shift_display(now_us: int) -> Dictionary:
	return select_shift(phase, hub, countdown("period_time_remaining_s", now_us), countdown("shift_time_remaining_s", now_us), countdown("shift_time_with_buffer_s", now_us), countdown("buffer_remaining_s", now_us), show_buffer)


## Dim the robot when its pose is not current: the robot says so, or no live data.
func pose_trusted() -> bool:
	return pose_valid != false and _link_ok
