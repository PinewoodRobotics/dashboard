class_name Clock
extends RefCounted

var _frozen := false
var _frozen_us := 0


func now_us() -> int:
	return _frozen_us if _frozen else Time.get_ticks_usec()


func now_s() -> float:
	return now_us() / 1_000_000.0


func freeze(at_us: int = -1) -> void:
	_frozen_us = Time.get_ticks_usec() if at_us < 0 else at_us
	_frozen = true


func unfreeze() -> void:
	_frozen = false


func is_frozen() -> bool:
	return _frozen


func advance_us(us: int) -> void:
	assert(_frozen, "Clock.advance_us requires a frozen clock")
	_frozen_us += us


func advance_s(seconds: float) -> void:
	advance_us(int(round(seconds * 1_000_000.0)))
