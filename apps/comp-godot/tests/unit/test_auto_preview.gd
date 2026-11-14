extends TestCase

const DETERMINISM_AUTOS := ["Ball Shooter Left", "Climber Right Left", "Move Forward And Shoot Center"]

var lib: AutoLibrary
var config: Dictionary
var rig: RigSolver


func before_each() -> void:
	lib = AutoLibrary.new()
	lib.load_dir(AutoLibrary.BUILTIN_DIR)
	config = AutoMechanisms.load_config()
	rig = RigSolver.load_default()


func _mech(auto_name: String) -> AutoMechanisms:
	return AutoMechanisms.new(lib.get_auto(auto_name), config)


func _synthetic(events: Array, duration := 10.0) -> AutoMechanisms:
	var p := AutoPlayback.from_dict({"name": "synthetic", "dt": 0.02, "duration_s": 0.0, "nominal_duration_s": duration,
		"ends_by_itself": true, "events": events})
	return AutoMechanisms.new(p, config)


static func _cmd(n: String, t0: float, t1: float, registered := true) -> Dictionary:
	return {"name": n, "kind": "command", "t0": t0, "t1": t1, "registered": registered}


func _service() -> AutosService:
	var s := AutosService.new()
	s.time_source.freeze(1_000_000)
	tree.root.add_child(s)
	return s


func test_timeline_covers_the_auto_period_unless_the_auto_ends() -> void:
	check_near(lib.get_auto("Ball Shooter Left").timeline_s(), 20.0, 1e-9, "never-ending commands run to 20 s")
	check_near(lib.get_auto("Stay And Shoot").timeline_s(), 20.0, 1e-9)
	check_near(lib.get_auto("Climber Right Left").timeline_s(), 10.9, 1e-9, "ends by itself")


func test_wrist_moves_at_intake_command_boundaries() -> void:
	var m := _synthetic([_cmd("IntakeBottomCommand", 2.0, 5.0), _cmd("IntakeTopCommand", 7.0, 7.02)])
	var stowed := m.wrist_default
	check_near(stowed, 0.338, 1e-9, "default command holds MIDDLE")
	check_near(m.wrist_raw(1.99), stowed, 1e-12, "before the first command")
	check_near(m.wrist_raw(2.0), stowed, 1e-12, "starts from where it was")
	check(m.wrist_raw(2.2) < stowed - 0.05, "moving down right after the boundary")
	check_near(m.wrist_raw(2.6), 0.0, 1e-12, "at BOTTOM after the travel time")
	check(m.rollers_on(3.0), "IntakeBottomCommand runs the rollers")
	check_near(m.wrist_target_raw(5.0), stowed, 1e-12, "default takes over at the end")
	check(m.wrist_raw(5.2) > 0.05, "moving back up after the end boundary")
	check(not m.rollers_on(5.2))
	check_near(m.wrist_raw(6.0), stowed, 1e-12)


func test_stay_and_shoot_lowers_the_wrist_and_runs_everything() -> void:
	var m := _mech("Stay And Shoot")
	check(not m.playback.has_path())
	check_near(m.wrist_raw(0.0), m.wrist_default, 1e-12, "stowed at the start")
	check_near(m.wrist_raw(0.6), 0.0, 1e-12, "IntakeCommand drops the wrist to BOTTOM")
	var s := m.state_at(10.0, AutoPlayback.BLUE)
	check(s["aim"] and s["shooter"] and s["rollers"], "aim, shooter and rollers on mid-auto")
	check_eq(m.pose_at(0.0, AutoPlayback.BLUE), m.pose_at(19.0, AutoPlayback.BLUE), "stationary")
	check_eq(m.pose_at(5.0, AutoPlayback.RED), FieldFrame.flip(AutoMechanisms.NO_PATH_POSE_BLUE))
	var bar := AutoScrubBar.new()
	bar.size = Vector2(700, 100)
	bar.set_auto(m)
	check_eq(bar.spans.size(), 3, "its command spans still appear on the bar")
	bar.free()


func test_unregistered_climber_commands_are_noops() -> void:
	var m := _mech("Climber Right Left")
	var noops := m.items.filter(func(it: Dictionary) -> bool: return it["kind"] == AutoMechanisms.Kind.NOOP)
	check_eq(noops.map(func(it: Dictionary) -> String: return it["name"]), ["MoveClimberUp", "MoveClimberDown"])
	for it: Dictionary in noops:
		check(not it["runs"] and it["instant"], "%s is an instant no-op" % it["name"])
		check_eq(it["note"], "no-op on robot")
	var first := rig.compute_joint_values(m.state_at(0.0, AutoPlayback.RED)["raw"])
	for t in [7.5, 7.54, 9.0, 10.886, 10.9]:
		var j := rig.compute_joint_values(m.state_at(t, AutoPlayback.RED)["raw"])
		check_eq(j["climber_inner"], first["climber_inner"], "climber still at %s" % t)
		check_eq(j["climber_outer"], first["climber_outer"])


func test_unbound_marker_moves_nothing() -> void:
	var m := _mech("Ball Shooter Left")
	var zone: Array = m.items.filter(func(it: Dictionary) -> bool: return it["name"] == "IntakeCommand")
	check_eq(zone.size(), 1)
	check(not zone[0]["runs"], "the IntakeCommand zone has no command and no bound trigger")
	check_eq(zone[0]["note"], "marker only, nothing bound on robot")
	check_near(m.wrist_raw(10.0), m.wrist_default, 1e-12)
	check(not m.rollers_on(10.0))


func test_aim_point_port() -> void:
	check_eq(AimPoint.hub(false), Vector2(0.28 * FieldFrame.FIELD_LENGTH_M, 0.5 * FieldFrame.FIELD_WIDTH_M))
	check_eq(AimPoint.hub(true), Vector2(0.72 * FieldFrame.FIELD_LENGTH_M, 0.5 * FieldFrame.FIELD_WIDTH_M))
	check_eq(AimPoint.zone(Vector2(2.0, 4.0), false)["name"], "FRONT_OF_HUB")
	check_eq(AimPoint.zone(Vector2(14.5, 4.0), true)["name"], "FRONT_OF_HUB")
	check_eq(AimPoint.zone(Vector2(6.0, 1.0), false)["name"], "LEFT_CENTER")
	check_eq(AimPoint.zone(Vector2(16.541 - 6.0, 1.0), true)["name"], "LEFT_CENTER", "red mirrors X only")
	check_eq(AimPoint.zone(Vector2(12.0, 4.0), false)["name"], "MIDDLE_CENTER", "outside every zone: nearest center")
	check_near(AimPoint.turret_angle(Vector3(1, 1, 0), Vector2(2, 2)), PI / 4, 1e-6)
	check_near(AimPoint.turret_angle(Vector3(1, 1, PI / 2), Vector2(2, 2)), -PI / 4, 1e-6)


func test_turret_points_at_the_alliance_hub_while_aiming() -> void:
	var checked := 0
	for auto_name: String in DETERMINISM_AUTOS:
		var m := _mech(auto_name)
		for side: StringName in [AutoPlayback.RED, AutoPlayback.BLUE]:
			var red := side == AutoPlayback.RED
			for i in 400:
				var t := m.duration * i / 399.0
				if not m.aim_command_on(t):
					continue
				var s := m.state_at(t, side)
				var p: Vector3 = s["pose"]
				var world := p.z + float(s["turret_rad"])
				var zone := AimPoint.zone(Vector2(p.x, p.y), red)
				var aim_at := AimPoint.hub(red) if zone["name"] == AimPoint.FRONT_OF_HUB else AimPoint.target(Vector2(p.x, p.y), red)
				var bearing := (aim_at - Vector2(p.x, p.y)).angle()
				if not check(absf(rad_to_deg(angle_difference(world, bearing))) <= 2.0, "%s %s t=%.2f off by %.2f deg" % [auto_name, side, t, rad_to_deg(angle_difference(world, bearing))]):
					return
				if zone["name"] == AimPoint.FRONT_OF_HUB:
					checked += 1
				var joints := rig.compute_joint_values(s["raw"])
				check_near(angle_difference(joints["turret"], -float(s["turret_rad"])), 0.0, 0.0021, "rig turret = -angle (clamped at 3.14)")
	check(checked > 500, "hub checks: %d" % checked)


func test_ribbon_starts_at_the_field_frame_of_the_start_pose() -> void:
	for auto_name: String in ["Ball Shooter Left", "Climber Right Left", "Move Forward And Shoot Right"]:
		var p := lib.get_auto(auto_name)
		for side: StringName in [AutoPlayback.RED, AutoPlayback.BLUE]:
			var line := PathRibbon.centerline(p, side)
			var pts: PackedVector3Array = line["points"]
			var sp: Vector3 = p.start_pose[side]
			var want := FieldFrame.to_world(sp.x, sp.y) + Vector3.UP * PathRibbon.LIFT
			check(pts[0].distance_to(want) < 1e-6, "%s %s first point %s vs %s" % [auto_name, side, pts[0], want])
			var ep: Vector3 = p.end_pose[side]
			check(pts[pts.size() - 1].distance_to(FieldFrame.to_world(ep.x, ep.y) + Vector3.UP * PathRibbon.LIFT) < 1e-3, "last point at the end pose")
			var times: PackedFloat32Array = line["times"]
			for i in range(1, times.size()):
				if not check(times[i] > times[i - 1], "times increase"):
					break
			var mesh := PathRibbon.strip_mesh(pts, times)
			var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			check(((verts[0] + verts[1]) * 0.5).distance_to(want) < 1e-6, "strip centered on the first point")
			check_near(verts[0].distance_to(verts[1]), PathRibbon.WIDTH, 1e-5)
	var red_x: float = PathRibbon.centerline(lib.get_auto("Ball Shooter Left"), AutoPlayback.RED)["points"][0].x
	check(red_x < 0.0, "red-authored path starts on the red half (world -X)")


func test_jumping_and_playing_to_t_agree() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 71065
	for auto_name: String in DETERMINISM_AUTOS:
		var times: Array[float] = []
		var d := lib.get_auto(auto_name).timeline_s()
		for i in 50:
			times.append(rng.randf_range(0.0, d))
		times.sort()
		var player := _service()
		player.set_preview(auto_name)
		player.clock.play()
		var played := {}
		for target in times:
			while player.clock.t < target and player.clock.playing:
				var step := minf(rng.randf_range(0.004, 0.05), (target - player.clock.t) / player.clock.speed)
				player.time_source.advance_us(maxi(int(ceil(step * 1_000_000.0)), 1))
				player.step()
			played[player.clock.t] = player.frame.duplicate(true)
		var jumper := _service()
		jumper.set_preview(auto_name)
		var keys := played.keys()
		keys.shuffle()
		for t: float in keys:
			jumper.clock.seek(t)
			jumper.step()
			var a: Dictionary = played[t]
			var b: Dictionary = jumper.frame
			check_eq(b["pose"], a["pose"], "%s pose at %.3f" % [auto_name, t])
			check_eq(b["joints"], a["joints"], "%s joints at %.3f" % [auto_name, t])
			check_eq([b["aim"], b["shooter"], b["rollers"]], [a["aim"], a["shooter"], a["rollers"]])
		check_eq(played.size(), 50, auto_name + " distinct sample times")
		player.free()
		jumper.free()


func test_playback_time_scales_with_the_wall_clock() -> void:
	var s := _service()
	s.set_preview("Climber Right Middle")
	check_near(s.clock.duration, 7.16, 1e-9)
	for speed in AutoClock.SPEEDS:
		s.clock.seek(0.0)
		s.clock.set_speed(speed)
		s.clock.play()
		s.step()
		s.time_source.advance_s(1.5)
		s.step()
		check_near(s.clock.t, 1.5 * speed, 1e-9, "speed %s" % speed)
		var wall := 0.0
		while s.clock.playing:
			s.time_source.advance_s(0.01)
			wall += 0.01
			s.step()
		check_near(1.5 + wall, 7.16 / speed, 0.011, "full duration at %sx" % speed)
		check_near(s.clock.t, 7.16, 1e-9, "stops at the end")
		check_near(float(s.clock.last_run.get("wall_s", -1.0)), 1.5 + wall, 1e-6, "run recorded")
	s.clock.set_speed(1.0)
	s.clock.set_loop(true)
	s.clock.seek(7.0)
	s.clock.play()
	s.step()
	s.time_source.advance_s(0.5)
	s.step()
	check(s.clock.playing, "loop keeps playing")
	check_near(s.clock.t, 0.34, 1e-6, "wraps")
	s.clock.begin_scrub()
	s.clock.seek(3.0)
	s.time_source.advance_s(1.0)
	s.step()
	check_near(s.clock.t, 3.0, 1e-12, "a scrub holds t")
	s.clock.end_scrub()
	s.time_source.advance_s(0.25)
	s.step()
	check_near(s.clock.t, 3.25, 1e-9, "and play resumes after it")
	s.free()


func test_scrub_bar_positions_are_proportional() -> void:
	var m := _mech("Climber Right Right")
	var bar := AutoScrubBar.new()
	bar.size = Vector2(700, 100)
	bar.set_auto(m)
	var r := bar.report()
	var w: float = r["x1"] - r["x0"]
	var instants := m.items.filter(func(it: Dictionary) -> bool: return it["instant"])
	var intervals := m.items.filter(func(it: Dictionary) -> bool: return not it["instant"])
	check_eq(r["ticks"].size(), instants.size(), "a tick per instant event")
	check_eq(r["spans"].size(), intervals.size(), "a span per interval event")
	for k: Dictionary in r["ticks"]:
		check_near(k["x"], r["x0"] + k["t"] / m.duration * w, 1e-3, "tick " + k["name"])
	for sp: Dictionary in r["spans"]:
		check_near(sp["x0"], r["x0"] + sp["t0"] / m.duration * w, 1e-3, "span start " + sp["name"])
		check_near(sp["x1"], r["x0"] + sp["t1"] / m.duration * w, 1e-3, "span end " + sp["name"])
	check_near(bar.x_to_t(bar.t_to_x(5.0)), 5.0, 1e-9)
	bar.free()


func test_hud_state() -> void:
	check_eq(AutosService.hud_state(true, "Ball Shooter Left", "", false), {"auto": "Ball Shooter Left", "mirror": false})
	check_eq(AutosService.hud_state(true, "Ball Shooter Left", "Stay And Shoot", true), {"auto": "Stay And Shoot", "mirror": true})
	check_eq(AutosService.hud_state(true, "Ball Shooter Left", "Stay And Shoot", false), {"auto": "Ball Shooter Left", "mirror": false})
	check_eq(AutosService.hud_state(true, "", "", false), {"auto": "", "mirror": false})
	check_eq(AutosService.hud_state(false, "Ball Shooter Left", "Stay And Shoot", true), {"auto": "", "mirror": false}, "gone outside pre-match")


func test_turret_angle_turns_the_turret_node_ccw_about_world_up() -> void:
	var wrapper := (load("res://scenes3d/robot/robot_model.tscn") as PackedScene).instantiate() as Node3D
	var model := (load(ModelsService.PATHS["robot"]) as PackedScene).instantiate() as Node3D
	wrapper.get_node("CadUp").add_child(model)
	tree.root.add_child(wrapper)
	var robot_rig := RobotRig.new(model)
	var turret := robot_rig.nodes["TurretRControl"] as Node3D
	for heading in [0.0, 1.0, -2.5]:
		wrapper.transform = FieldFrame.robot_transform(3.0, 4.0, heading)
		robot_rig.apply(rig, rig.compute_joint_values({"turret": 0.0}))
		var rest := turret.global_basis
		for theta in [0.5, -1.2, 2.8]:
			robot_rig.apply(rig, rig.compute_joint_values({"turret": theta / TAU}))
			var delta := (turret.global_basis * rest.inverse()).orthonormalized()
			var q := delta.get_rotation_quaternion()
			var axis := q.get_axis()
			var angle := q.get_angle()
			if axis.y < 0.0:
				axis = -axis
				angle = -angle
			check(axis.distance_to(Vector3.UP) < 1e-3, "rotation axis is world up, got %s" % axis)
			check_near(angle_difference(angle, theta), 0.0, 1e-3, "world yaw +%s (field CCW) at heading %s" % [theta, heading])
	wrapper.queue_free()
	await tree.process_frame
