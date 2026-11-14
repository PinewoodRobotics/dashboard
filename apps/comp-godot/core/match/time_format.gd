class_name TimeFormat
extends RefCounted

## Floor-based countdown formatting, clamped at 0. The epsilon keeps a value
## published as 12.29 from flooring to 12.28 through binary rounding.

const EPS := 1e-6


static func centis(t: float) -> int:
	if not is_finite(t) or t <= 0.0:
		return 0
	return int(floor(t * 100.0 + EPS))


## ["MM:SS", ".cc"]
static func mm_ss_cc(t: float) -> PackedStringArray:
	var cs := centis(t)
	var s := cs / 100
	return PackedStringArray(["%02d:%02d" % [s / 60, s % 60], ".%02d" % (cs % 100)])


## ["NN", ".dd"]
static func nn_dd(t: float) -> PackedStringArray:
	var cs := centis(t)
	return PackedStringArray(["%02d" % (cs / 100), ".%02d" % (cs % 100)])
