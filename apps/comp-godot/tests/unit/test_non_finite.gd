extends TestCase

var nt: NtService
var tel: TelemetryService


func before_each() -> void:
	nt = NtService.new()
	tel = TelemetryService.new()
	tel.nt = nt


func after_each() -> void:
	tel.free()
	nt.free()


func _pose(x: Variant, y: Variant, h: Variant) -> void:
	nt.inject({TelemetryService.POSE_X: x, TelemetryService.POSE_Y: y, TelemetryService.POSE_HEADING: h})


func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


func test_smoother_ignores_non_finite_samples() -> void:
	var s := PoseSmoother.new()
	s.step(2.0, 4.0, 0.0, 0.016)
	s.step(NAN, 4.0, 0.0, 0.016)
	s.step(2.0, INF, 0.0, 0.016)
	s.step(2.0, 4.0, NAN, 0.016)
	check_eq([s.x, s.y, s.heading], [2.0, 4.0, 0.0])
	s.step(2.5, 4.0, 0.1, 0.016)
	check(s.x > 2.0 and s.x < 2.5, "valid samples keep smoothing: %s" % s.x)


func test_smoother_resnaps_from_a_poisoned_state() -> void:
	var s := PoseSmoother.new()
	s.snap(NAN, 4.0, 0.0)
	s.step(3.0, 5.0, 1.0, 0.016)
	check_eq([s.x, s.y, s.heading], [3.0, 5.0, 1.0])


func test_rig_holds_the_last_value_through_a_nan_target() -> void:
	var rig := RigSolver.load_default()
	rig.step(rig.compute_joint_values({"turret": 0.25}), 0.016)
	var before: float = rig.values["turret"]
	rig.step({"turret": NAN}, 0.016)
	check_eq(rig.values["turret"], before)
	rig.values["index_wrist"] = NAN
	var out := rig.step(rig.compute_joint_values({"turret": 0.0, "index_wrist": 0.3}), 0.016)
	check_near(out["index_wrist"], -1.8221, 1e-4, "a NaN state snaps to the next target")
	for k: String in out:
		check(is_finite(out[k]), "%s finite" % k)


func test_telemetry_keeps_the_last_good_pose() -> void:
	_pose(2.0, 4.0, 0.5)
	tel.step(0.016)
	_pose(NAN, 4.0, 0.5)
	tel.step(0.016)
	check_eq(tel.pose_raw, Vector3(2.0, 4.0, 0.5))
	_pose(2.0, 4.0, INF)
	tel.step(0.016)
	_pose("x", 4.0, 0.5)
	tel.step(0.016)
	check(_finite(tel.smoothed_pose()), "smoothed pose stays finite: %s" % tel.smoothed_pose())
	_pose(2.2, 4.1, 0.6)
	for i in 120:
		tel.step(0.016)
	check_near(tel.smoother.x, 2.2, 1e-3, "follows valid samples again")
	check_near(tel.smoother.y, 4.1, 1e-3)


func test_telemetry_drops_non_finite_joint_samples() -> void:
	var topic := tel.rig.joint("turret").nt_topic
	nt.inject({topic: 0.25})
	tel.step(0.016)
	var want: float = tel.joint_targets["turret"]
	nt.inject({topic: NAN})
	tel.step(0.016)
	check_eq(tel.joint_targets["turret"], want, "NaN keeps the last good sample")
	for k: String in tel.joint_values:
		check(is_finite(tel.joint_values[k]), "%s finite" % k)
	nt.inject({topic: 0.0})
	tel.step(0.016)
	check_near(tel.joint_targets["turret"], 0.0, 1e-9)
