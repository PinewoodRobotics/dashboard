extends TestCase

const PUB := "/Tuning/Turret/AimTrimDeg"
const READ := "/AdvantageKit/NetworkInputs/Tuning/Turret/AimTrimDeg"

var link: FakeControlLink


func before_each() -> void:
	link = FakeControlLink.new()


func test_confirmation_topic_follows_the_m1_finding() -> void:
	var t := AimTrim.new(link)
	check_eq(t.publish_topic, PUB)
	check_eq(t.readback_topic, READ, "confirmed on the AdvantageKit NetworkInputs mirror")
	var golden: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/golden/sim_aimtrim_readback.json"))
	check_eq(golden["readback_topic"], READ)
	check(float(golden["first_match_s"]) >= 0.0 and int(golden["frames_not_matching_after_first_match"]) == 0, "recorded readback follows a held publisher")


func test_disabled_when_not_connected() -> void:
	var t := AimTrim.new(link)
	check(not t.set_trim(2.0))
	check(not t.center())
	check_eq(link.published.size(), 0)
	check_eq(t.status(), "Robot not connected")
	check_eq(t.slider_value(), 0.0)


func test_clamp_round_and_dedupe() -> void:
	var t := AimTrim.new(link)
	link.up = true
	check(t.set_trim(12.0))
	check_eq(link.last(PUB), 10.0)
	check(t.set_trim(-3.456))
	check_eq(link.last(PUB), -3.46)
	check(not t.set_trim(-3.458), "within 0.005 of the last sent value")
	check_eq(link.count(PUB), 2)
	check(t.set_trim(-3.45))
	check_eq(link.count(PUB), 3)


func test_dedupe_against_robot_readback_and_confirmation() -> void:
	var t := AimTrim.new(link)
	link.up = true
	link.values[READ] = 1.5
	check_eq(t.status(), "Robot confirmed this trim")
	check_eq(t.slider_value(), 1.5)
	check(not t.set_trim(1.5), "already what the robot reports")
	check_eq(link.count(PUB), 0)
	check(t.set_trim(2.25))
	check_eq(t.status(), "Waiting for the robot to confirm")
	check_eq(t.slider_value(), 2.25)
	link.values[READ] = 2.25
	t.update()
	check_eq(t.requested, null, "request cleared once the readback matches")
	check_eq(t.status(), "Robot confirmed this trim")
	check(t.center())
	check_eq(link.last(PUB), 0.0, "Center publishes 0")


func test_no_readback_yet() -> void:
	var t := AimTrim.new(link)
	link.up = true
	check_eq(t.status(), "No trim reported by the robot yet")


func test_not_persisted_and_dropped_on_disconnect() -> void:
	var t := AimTrim.new(link)
	link.up = true
	t.update()
	t.set_trim(4.0)
	link.up = false
	t.update()
	check_eq(t.requested, null)
	check_eq(t.last_sent, null)
	check(link.forgotten.has(PUB), "publisher stops re-sending after a reconnect")
	check(not link.desired.has(PUB))
	link.up = true
	t.update()
	check_eq(link.count(PUB), 1, "nothing re-sent on reconnect")


func test_format_labels() -> void:
	check_eq(AimTrim.format(0.0), "0°")
	check_eq(AimTrim.format(0.001), "0°")
	check_eq(AimTrim.format(2.5), "2.5° L")
	check_eq(AimTrim.format(-1.25), "1.25° R")
	check_eq(AimTrim.format(10.0), "10° L")
	check_eq(AimTrim.format(-0.75), "0.75° R")
