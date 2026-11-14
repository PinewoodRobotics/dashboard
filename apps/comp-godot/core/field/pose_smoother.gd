class_name PoseSmoother
extends RefCounted

## Port of the minimap pose smoothing: snap on jumps over 1.5 m, otherwise an
## adaptive frame-rate independent lerp with shortest-arc heading.

const SNAP_DISTANCE_M := 1.5

var x := 0.0
var y := 0.0
var heading := 0.0
var initialized := false


func snap(px: float, py: float, ph: float) -> void:
	x = px
	y = py
	heading = ph
	initialized = true


func step(px: float, py: float, ph: float, dt: float) -> void:
	if not initialized:
		snap(px, py, ph)
		return
	var dx := px - x
	var dy := py - y
	var dist := sqrt(dx * dx + dy * dy)
	if dist > SNAP_DISTANCE_M:
		snap(px, py, ph)
		return
	var t := Smoothing.dt_lerp(minf(0.15 + dist * 1.4, 0.95), dt)
	x += dx * t
	y += dy * t
	heading = Smoothing.lerp_angle(heading, ph, t)
