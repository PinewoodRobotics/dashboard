class_name ShooterReadouts
extends RefCounted

## The ten shooter rows under the aim trim (AimTrimSection.tsx). A value shows
## only when it arrived on the current connection and is a bool or a finite
## number; anything else is "--". Turret cmd is published in radians.

const MISSING := "--"
const OUT := "/AdvantageKit/RealOutputs"

## [label, topic, kind, decimals or [yes, no], unit]
const ROWS := [
	["Mode", OUT + "/ShooterSubsystem/GPSAssistFeaturesEnabled", "bool", ["Auto shooter", "Manual shooter"], ""],
	["Distance", OUT + "/Turret/DistanceToTarget", "num", 2, " m"],
	["RPM target", OUT + "/Shooter/RequestedVelocityRPM", "num", 0, ""],
	["RPM actual", OUT + "/Shooter/VelocityRPM", "num", 0, ""],
	["Leader", OUT + "/Shooter/LeaderVelocityRPM", "num", 0, ""],
	["Follower", OUT + "/Shooter/FollowerVelocityRPM", "num", 0, ""],
	["Spun up", OUT + "/Shooter/IsSpunUp", "bool", ["Yes", "No"], ""],
	["Shooting", OUT + "/MatchStatus/isShooting", "bool", ["Yes", "No"], ""],
	["Turret", OUT + "/Turret/PositionDeg", "num", 1, "°"],
	["Turret cmd", OUT + "/Turret/Angle", "rad", 1, "°"],
]


## JavaScript toFixed for the magnitudes shown here (half away from zero).
static func to_fixed(v: float, decimals: int) -> String:
	if decimals <= 0:
		return str(int(roundf(v)))
	var s := String.num(v, decimals)
	if not s.contains("."):
		s += "." + "0".repeat(decimals)
	else:
		var frac := s.get_slice(".", 1).length()
		if frac < decimals:
			s += "0".repeat(decimals - frac)
	return s


static func format_row(row: Array, v: Variant) -> String:
	var kind: String = row[2]
	if kind == "bool":
		if typeof(v) != TYPE_BOOL:
			return MISSING
		return row[3][0] if v else row[3][1]
	if not ((typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v))):
		return MISSING
	var x := float(v)
	if kind == "rad":
		x = x * 180.0 / PI
	return to_fixed(x, int(row[3])) + str(row[4])


static func rows(link: ControlLink) -> Array:
	var out: Array = []
	for row: Array in ROWS:
		var v: Variant = link.value(row[1]) if link.connected() and link.live(row[1]) else null
		out.append([row[0], format_row(row, v)])
	return out


static func topics() -> PackedStringArray:
	var out := PackedStringArray()
	for row: Array in ROWS:
		out.append(row[1])
	return out
