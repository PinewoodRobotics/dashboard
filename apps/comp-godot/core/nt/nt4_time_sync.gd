class_name Nt4TimeSync
extends RefCounted

const WINDOW := 10

var best_rtt_us := -1
var offset_us := 0
var sample_count := 0
var _samples: Array = []


func reset() -> void:
	best_rtt_us = -1
	offset_us = 0
	sample_count = 0
	_samples.clear()


func has_sync() -> bool:
	return best_rtt_us >= 0


## offset = now - rtt/2 - server, taken from the lowest-RTT sample of the last WINDOW.
func add_sample(local_now_us: int, sent_local_us: int, server_us: int) -> bool:
	var rtt := local_now_us - sent_local_us
	if rtt < 0 or server_us <= 0:
		return false
	_samples.append([rtt, local_now_us - rtt / 2 - server_us])
	if _samples.size() > WINDOW:
		_samples.pop_front()
	sample_count += 1
	var best: Array = _samples[0]
	for s: Array in _samples:
		if s[0] < best[0]:
			best = s
	best_rtt_us = best[0]
	offset_us = best[1]
	return true


func server_now_us(local_now_us: int) -> int:
	return local_now_us - offset_us
