class_name Countdown
extends RefCounted

## One robot-published countdown (seconds remaining) shown at frame rate.
## - Every received update re-anchors (ntcore drops repeated identical values,
##   so "no update" can mean "value unchanged").
## - Between updates it counts down locally, at most EXTRAPOLATE_CAP_S.
## - Once seq has advanced HOLD_AFTER_SEQ times without a new value, the robot
##   is holding it (pre/post match, disabled gap): show it exactly.
## - With the link down, a running timer keeps dead-reckoning (uncapped) and a
##   held one stays put; the HUD dims it.

const EXTRAPOLATE_CAP_S := 0.1
const HOLD_AFTER_SEQ := 2

var value := 0.0
var has_value := false
var anchor_us := 0
var seq_since_anchor := 0
var _held_at_link_loss := false


func update(v: float, now_us: int) -> void:
	value = v
	has_value = true
	anchor_us = now_us
	seq_since_anchor = 0


func on_seq() -> void:
	if has_value:
		seq_since_anchor += 1


func is_held() -> bool:
	return seq_since_anchor >= HOLD_AFTER_SEQ


func on_link_lost() -> void:
	_held_at_link_loss = is_held()


func reset() -> void:
	value = 0.0
	has_value = false
	anchor_us = 0
	seq_since_anchor = 0
	_held_at_link_loss = false


func display(now_us: int, link_ok: bool) -> float:
	if not has_value:
		return 0.0
	var elapsed := maxf(0.0, (now_us - anchor_us) / 1_000_000.0)
	var shown: float
	if link_ok:
		shown = value if is_held() else value - minf(elapsed, EXTRAPOLATE_CAP_S)
	else:
		shown = value if _held_at_link_loss else value - elapsed
	return maxf(0.0, shown)
