extends TestCase

var link: FakeControlLink


func before_each() -> void:
	link = FakeControlLink.new()


func _rows() -> Dictionary:
	var out := {}
	for r: Array in ShooterReadouts.rows(link):
		out[r[0]] = r[1]
	return out


func test_ten_rows_in_web_order() -> void:
	var labels: Array = []
	for r: Array in ShooterReadouts.rows(link):
		labels.append(r[0])
	check_eq(labels, ["Mode", "Distance", "RPM target", "RPM actual", "Leader", "Follower", "Spun up", "Shooting", "Turret", "Turret cmd"])
	check_eq(PackedStringArray(Topics.READOUT_TOPICS.keys()).size(), ShooterReadouts.topics().size())
	for t in ShooterReadouts.topics():
		check(Topics.READOUT_TOPICS.has(t), "subscribed: " + t)


func test_missing_values_are_dashes() -> void:
	for v: String in _rows().values():
		check_eq(v, "--")
	link.values["/AdvantageKit/RealOutputs/Turret/DistanceToTarget"] = 3.0
	check_eq(_rows()["Distance"], "--", "not shown while disconnected")
	link.up = true
	link.values["/AdvantageKit/RealOutputs/Shooter/VelocityRPM"] = INF
	check_eq(_rows()["RPM actual"], "--", "non-finite")
	link.values["/AdvantageKit/RealOutputs/Shooter/IsSpunUp"] = 1.0
	check_eq(_rows()["Spun up"], "--", "wrong type")


func test_formats() -> void:
	link.up = true
	var o := "/AdvantageKit/RealOutputs"
	link.values[o + "/ShooterSubsystem/GPSAssistFeaturesEnabled"] = false
	link.values[o + "/Turret/DistanceToTarget"] = 3.456
	link.values[o + "/Shooter/RequestedVelocityRPM"] = 3200.0
	link.values[o + "/Shooter/VelocityRPM"] = 3187.6
	link.values[o + "/Shooter/LeaderVelocityRPM"] = 3190
	link.values[o + "/Shooter/FollowerVelocityRPM"] = 0.4
	link.values[o + "/Shooter/IsSpunUp"] = true
	link.values[o + "/MatchStatus/isShooting"] = false
	link.values[o + "/Turret/PositionDeg"] = -42.37
	link.values[o + "/Turret/Angle"] = PI / 2.0
	check_eq(_rows(), {"Mode": "Manual shooter", "Distance": "3.46 m", "RPM target": "3200", "RPM actual": "3188",
		"Leader": "3190", "Follower": "0", "Spun up": "Yes", "Shooting": "No", "Turret": "-42.4°", "Turret cmd": "90.0°"})
	link.values[o + "/ShooterSubsystem/GPSAssistFeaturesEnabled"] = true
	link.values[o + "/Turret/DistanceToTarget"] = 2.0
	check_eq(_rows()["Mode"], "Auto shooter")
	check_eq(_rows()["Distance"], "2.00 m", "toFixed pads")
