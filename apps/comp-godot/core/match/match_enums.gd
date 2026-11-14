class_name MatchEnums
extends RefCounted

## Integer enums published by the robot (MatchStatusCalculator.java). Unknown
## or malformed values map to the first entry, as the web dashboard does.

enum Phase { PRE_MATCH, AUTONOMOUS, TRANSITION, SHIFT1, SHIFT2, SHIFT3, SHIFT4, ENDGAME, POST_MATCH }
enum Hub { NONE, BOTH, ACTIVE, WARNING, INACTIVE }
enum Header { HIDDEN, GREEN, YELLOW, PURPLE }
enum Aim { SHOOTER_DISABLED, GPS_AUTO, MANUAL_AIMING }

const PHASE_NAMES := ["pre_match", "autonomous", "transition", "shift1", "shift2", "shift3", "shift4", "endgame", "post_match"]
const HUB_NAMES := ["none", "both", "active", "warning", "inactive"]
const HEADER_NAMES := ["hidden", "green", "yellow", "purple"]
const AIM_NAMES := ["shooter_disabled", "gps_auto", "manual_aiming"]


static func _index(v: Variant, count: int) -> int:
	var i := -1
	if typeof(v) == TYPE_INT:
		i = v
	elif typeof(v) == TYPE_FLOAT and is_finite(v) and float(v) == floorf(v):
		i = int(v)
	return i if i >= 0 and i < count else 0


static func phase(v: Variant) -> Phase:
	return _index(v, PHASE_NAMES.size()) as Phase


static func hub(v: Variant) -> Hub:
	return _index(v, HUB_NAMES.size()) as Hub


static func header(v: Variant) -> Header:
	return _index(v, HEADER_NAMES.size()) as Header


static func aim(v: Variant) -> Aim:
	return _index(v, AIM_NAMES.size()) as Aim


static func is_both_hub_period(p: Phase) -> bool:
	return p == Phase.AUTONOMOUS or p == Phase.TRANSITION or p == Phase.ENDGAME
