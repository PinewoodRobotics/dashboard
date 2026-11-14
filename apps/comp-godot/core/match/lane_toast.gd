class_name LaneToast
extends RefCounted

## Lane-alignment toast (MatchHUD.tsx): the first value after start or after a
## match returns to pre-match is stored silently; afterwards every change fires
## a toast that replaces the visible one and lasts DURATION_S.

const DURATION_S := 1.8

var seen := false
var last := false
var visible_on := false
var fired_us := -1
var fire_count := 0


func reset() -> void:
	seen = false
	last = false


## Returns true when this value fired a toast.
func observe(v: bool, now_us: int) -> bool:
	if not seen:
		seen = true
		last = v
		return false
	if v == last:
		return false
	last = v
	visible_on = v
	fired_us = now_us
	fire_count += 1
	return true


func is_visible(now_us: int) -> bool:
	return fired_us >= 0 and now_us - fired_us < int(DURATION_S * 1_000_000.0)


## 0..1 of the toast lifetime, or -1 when hidden.
func progress(now_us: int) -> float:
	if not is_visible(now_us):
		return -1.0
	return (now_us - fired_us) / (DURATION_S * 1_000_000.0)
