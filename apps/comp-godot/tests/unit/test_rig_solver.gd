extends TestCase

var rig: RigSolver


func before_each() -> void:
	rig = RigSolver.load_default()


func _resolve(live: Dictionary) -> Dictionary:
	return rig.compute_joint_values(live)


func test_loads_all_joints_in_order() -> void:
	var keys: Array = []
	for j in rig.joints:
		keys.append(j.key)
	check_eq(keys, ["index_wrist", "turret", "turret_gear", "climber_inner", "climber_outer"])
	check_eq(rig.bumper_nodes, PackedStringArray(["Plane"]))
	check_eq(rig.joint("turret").node_name, "TurretRControl")
	check_eq(rig.joint("climber_inner").revolute, false)


func test_wrist_goldens() -> void:
	check_near(_resolve({"index_wrist": 0.0})["index_wrist"], 0.02, 1e-9, "raw 0 clamps to the upper limit")
	check_near(_resolve({"index_wrist": 0.3})["index_wrist"], -1.8221, 1e-4, "raw 0.3")
	check_near(_resolve({"index_wrist": 1.0})["index_wrist"], -2.22, 1e-9, "clamped to the lower limit")


func test_turret_goldens_and_gear_link() -> void:
	var v := _resolve({"turret": 0.25})
	check_near(v["turret"], -PI / 2.0, 1e-9, "0.25 rot")
	check_near(v["turret_gear"], PI / 2.0, 1e-9, "gear = -turret")
	check_near(_resolve({"turret": 0.75})["turret"], PI / 2.0, 1e-9, "0.75 wraps to -0.25")
	check_near(_resolve({"turret": 0.5})["turret"], 3.14, 1e-9, "0.5 wraps to -0.5 then clamps")
	check_near(_resolve({"turret": 0.5})["turret_gear"], -3.14, 1e-9)
	check_near(_resolve({"turret": -1.25})["turret"], PI / 2.0, 1e-9, "multi-turn wrap")


func test_climber_goldens() -> void:
	var v := _resolve({"climber_inner": 0.0})
	check_near(v["climber_inner"], -0.31, 1e-9)
	check_near(v["climber_outer"], 0.31, 1e-9)
	check_near(_resolve({"climber_inner": 0.313})["climber_inner"], 0.0, 1e-3)


func test_not_live_uses_default_or_manual() -> void:
	var v := _resolve({})
	check_eq(v["index_wrist"], 0.0)
	check_eq(v["turret"], 0.0)
	check_eq(v["climber_inner"], 0.0, "default is 0, not -0.31 (web quirk kept)")
	check_eq(v["climber_outer"], 0.0)
	var m := rig.compute_joint_values({}, {"turret": 1.0, "index_wrist": -5.0})
	check_eq(m["turret"], 1.0, "manual value when not live")
	check_eq(m["turret_gear"], -1.0)
	check_eq(m["index_wrist"], -2.22, "manual clamped")
	var mixed := rig.compute_joint_values({"turret": 0.25}, {"turret": 1.0})
	check_near(mixed["turret"], -PI / 2.0, 1e-9, "live wins over manual")


func test_transform_nt_value_static() -> void:
	check_near(RigSolver.wrap_signed_unit_rotation(0.5), -0.5, 1e-12)
	check_near(RigSolver.wrap_signed_unit_rotation(-0.5), -0.5, 1e-12)
	check_near(RigSolver.wrap_signed_unit_rotation(1.2), 0.2, 1e-12)
	check_near(RigSolver.transform_nt_value(rig.joint("index_wrist"), 0.3), -1.8221, 1e-4)


func test_smoothing_first_step_snaps_then_approaches() -> void:
	var out := rig.step(_resolve({"turret": 0.0}), 0.016)
	check_eq(out["turret"], 0.0)
	var target := _resolve({"turret": -0.1})
	out = rig.step(target, 0.06)
	var expected: float = target["turret"] * (1.0 - exp(-1.0))
	check_near(out["turret"], expected, 1e-9, "one time constant")
	check_near(out["turret_gear"], -out["turret"], 1e-12, "linked joint follows the smoothed source")
	for i in 60:
		out = rig.step(target, 0.016)
	check_near(out["turret"], target["turret"], 1e-4, "converges")


func test_smoothing_snaps_across_the_turret_wrap() -> void:
	rig.step(_resolve({"turret": -0.49}), 0.016)
	var target := _resolve({"turret": 0.49})
	var out := rig.step(target, 0.016)
	check_near(out["turret"], target["turret"], 1e-9, "no long sweep through 0")


func test_zero_smoothing_is_immediate() -> void:
	var r := RigSolver.from_dict({"joints": {"a": {"nodeName": "A", "type": "revolute", "axis": [0, 1, 0], "limits": {"min": -1, "max": 1}, "ntTopic": "/a", "smoothing": 0}}})
	r.step({"a": 0.0}, 0.016)
	check_eq(r.step({"a": 0.5}, 0.016)["a"], 0.5)
	check_eq(r.nt_topics(), PackedStringArray(["/a"]))
