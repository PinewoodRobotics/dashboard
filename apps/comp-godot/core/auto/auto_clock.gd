class_name AutoClock
extends RefCounted

## Playback time shared by every auto preview (touchscreen tab, HUD ghost).
## Time moves with the wall clock passed to tick(), not with frame deltas, so a
## slow or capped frame rate never stretches playback. Scrubbing holds t where
## the finger is and keeps the play state for when the finger lifts.

signal changed

const SPEEDS: Array[float] = [0.5, 1.0, 2.0]

var t := 0.0
var duration := 0.0
var playing := false
var speed := 1.0
var loop := false
var scrubbing := false
## The last run that played to the end untouched (no seek, speed change or
## scrub on the way): {"from_t", "wall_s", "speed"}; wall_s spans from the
## first tick after play() to the tick that reached the end.
var last_run := {}
## Wall-clock microseconds of the last tick; -1 until the first one.
var _last_us := -1
var _run_start_us := -1
var _run_from_t := 0.0
var _run_clean := false


func set_duration(seconds: float) -> void:
	duration = maxf(seconds, 0.0)
	t = clampf(t, 0.0, duration)
	changed.emit()


func play() -> void:
	if duration <= 0.0:
		return
	if t >= duration:
		t = 0.0
	playing = true
	_last_us = -1
	_run_start_us = -1
	_run_from_t = t
	_run_clean = true
	changed.emit()


func pause() -> void:
	playing = false
	changed.emit()


func toggle() -> void:
	if playing:
		pause()
	else:
		play()


func seek(seconds: float) -> void:
	t = clampf(seconds, 0.0, duration)
	_run_clean = false
	changed.emit()


func set_speed(s: float) -> void:
	speed = s if s > 0.0 else 1.0
	_run_clean = false
	changed.emit()


func set_loop(on: bool) -> void:
	loop = on
	changed.emit()


func begin_scrub() -> void:
	scrubbing = true
	_run_clean = false
	changed.emit()


func end_scrub() -> void:
	scrubbing = false
	changed.emit()


func active() -> bool:
	return playing or scrubbing


## Advances by the wall time since the previous tick (the first tick only
## records the time). Returns true when t changed.
func tick(now_us: int) -> bool:
	var dt := 0.0 if _last_us < 0 else maxf(float(now_us - _last_us) / 1_000_000.0, 0.0)
	_last_us = now_us
	if playing and _run_start_us < 0:
		_run_start_us = now_us
	var was_playing := playing
	var moved := advance(dt)
	if was_playing and not playing and _run_clean and t >= duration:
		last_run = {"from_t": _run_from_t, "wall_s": float(now_us - _run_start_us) / 1_000_000.0, "speed": speed}
	return moved


## Moves time forward by delta wall-clock seconds; returns true when t changed.
func advance(delta: float) -> bool:
	if not playing or scrubbing or duration <= 0.0:
		return false
	t += delta * speed
	if t >= duration:
		if loop:
			t = fmod(t, duration)
		else:
			t = duration
			playing = false
	changed.emit()
	return true
