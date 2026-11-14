class_name AutoClock
extends RefCounted

## Playback time shared by every auto preview (touchscreen tab, HUD ghost).

signal changed

const SPEEDS: Array[float] = [0.5, 1.0, 2.0]

var t := 0.0
var duration := 0.0
var playing := false
var speed := 1.0
var loop := false


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
	changed.emit()


func set_speed(s: float) -> void:
	speed = s if s > 0.0 else 1.0
	changed.emit()


## Moves time forward by delta wall-clock seconds; returns true when t changed.
func advance(delta: float) -> bool:
	if not playing or duration <= 0.0:
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
