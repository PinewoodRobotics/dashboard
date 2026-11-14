extends TestCase

## Checks the committed PathPlanner export in res://data/autos against the raw
## copy it was made from and against the robot's command semantics.

const RAW_DIR := "res://data/pathplanner"
const COMMANDS_PATH := "res://data/auto_commands.json"
const FLIP_X := 16.54
const FLIP_Y := 8.07

## Durations from robotpy-pathplannerlib 2026.1.2; the robot's Java library differs on three paths.
const PYTHON_PATH_DURATIONS := {
	"Ball Shooter Left": 15.95, "Ball Shooter Right": 15.95, "Climber Left Close": 5.63,
	"Climber Left": 3.01, "Climber Middle": 1.48, "Climber Right Close": 3.33,
	"Climber Right Left": 7.53, "Climber Right Middle": 7.14, "Climber Right Right": 7.95,
	"Move Forward Center": 2.46, "Move Forward Left": 2.94, "Move Forward Right": 2.56,
}

var lib: AutoLibrary


func before_each() -> void:
	lib = AutoLibrary.new()
	check(lib.load_dir(AutoLibrary.BUILTIN_DIR), "builtin export loads: " + lib.error)


func _commands() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(COMMANDS_PATH))


func _wrist_command_s() -> float:
	var c := _commands()
	if c["wrist"]["at_setpoint_check"] == "always_true":
		return float(c["robot_loop_s"])
	return float(c["wrist"]["travel_s"])


func _path_entry(path_name: String) -> Dictionary:
	for p: Dictionary in lib.index["paths"]:
		if p["name"] == path_name:
			return p
	return {}


func _events(a: AutoPlayback, ev_name: String) -> Array:
	return a.events.filter(func(e: Dictionary) -> bool: return e["name"] == ev_name)


func test_export_matches_raw_pathplanner_files() -> void:
	var raw := AutoLibrary.source_hash(RAW_DIR)
	check_eq(raw, str(lib.index["source_hash"]), "data/pathplanner changed without a re-export (run scripts/sync-pathplanner-from-fir.sh --godot-only --apply, or uv run --script tools/pathplanner/export_autos.py)")
	check_eq(AutoLibrary.source_hash(RAW_DIR.path_join("paths")), str(lib.index["paths_hash"]), "paths hash")
	check_eq(FileAccess.get_sha256(COMMANDS_PATH), str(lib.index["commands_hash"]), "data/auto_commands.json changed without a re-export")


func test_source_hash_sees_every_raw_change() -> void:
	var tmp := ProjectSettings.globalize_path("res://.scratch/unit/pp_hash_%d" % Time.get_ticks_usec())
	_copy_tree(ProjectSettings.globalize_path(RAW_DIR), tmp)
	var base := AutoLibrary.source_hash(tmp)
	check_eq(base, AutoLibrary.source_hash(RAW_DIR), "a copy hashes the same")
	var f := FileAccess.open(tmp.path_join(".DS_Store"), FileAccess.WRITE)
	f.store_string("x")
	f.close()
	check_eq(AutoLibrary.source_hash(tmp), base, "dotfiles are ignored")
	var path_file := tmp.path_join("paths/Move Forward Center.path")
	var text := FileAccess.get_file_as_string(path_file)
	f = FileAccess.open(path_file, FileAccess.WRITE)
	f.store_string(text.replace("\"maxVelocity\": 1.0", "\"maxVelocity\": 1.1"))
	f.close()
	var edited := AutoLibrary.source_hash(tmp)
	check(edited != base, "an edited .path changes the hash")
	f = FileAccess.open(tmp.path_join("autos/New.auto"), FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	check(AutoLibrary.source_hash(tmp) != edited, "an added .auto changes the hash")
	DirAccess.rename_absolute(tmp.path_join("settings.json"), tmp.path_join("settings2.json"))
	check(AutoLibrary.source_hash(tmp) != edited, "a renamed file changes the hash")


func _copy_tree(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	var d := DirAccess.open(from)
	for f in d.get_files():
		DirAccess.copy_absolute(from.path_join(f), to.path_join(f))
	for sub in d.get_directories():
		_copy_tree(from.path_join(sub), to.path_join(sub))


func test_nine_autos_and_twelve_paths() -> void:
	var autos := lib.names()
	check_eq(autos.size(), 9)
	for n in ["Ball Shooter Left", "Ball Shooter Right", "Climber Right Left", "Climber Right Middle", "Climber Right Right", "Move Forward And Shoot Center", "Move Forward And Shoot Left", "Move Forward And Shoot Right", "Stay And Shoot"]:
		check(autos.has(n), "auto " + n)
		check(lib.get_auto(n) != null, "auto file loads: " + n)
	check_eq(lib.index["paths"].size(), 12)
	for p: Dictionary in lib.index["paths"]:
		check(PYTHON_PATH_DURATIONS.has(p["name"]), "known path " + p["name"])
		check_near(float(p["python_duration_s"]), float(PYTHON_PATH_DURATIONS.get(p["name"], -1.0)), 0.02, p["name"] + " python duration")
	check_eq(lib.index["dt"], 0.02)
	check_eq(lib.index["field"]["length_m"], FLIP_X)
	check_eq(lib.index["field"]["width_m"], FLIP_Y)
	check_near(FieldFrame.PP_FIELD_SIZE.x, FLIP_X, 1e-5, "FieldFrame flip size x")
	check_near(FieldFrame.PP_FIELD_SIZE.y, FLIP_Y, 1e-5, "FieldFrame flip size y")


func test_java_parity_table_and_contingency() -> void:
	var parity: Dictionary = lib.index["parity"]
	check(parity is Dictionary and not parity.is_empty(), "parity block present")
	check_eq(parity["java_library"]["version"], "2027.0.0-alpha-4.1")
	check_eq(parity["stale"], false, "Java dump matches the current paths")
	check_eq(parity["rows"].size(), 12)
	var failing := PackedStringArray()
	for row: Dictionary in parity["rows"]:
		var ok := float(row["duration_rel_diff"]) <= 0.02 and float(row["end_pose_diff_m"]) <= 0.02
		check_eq(row["ok"], ok, row["name"] + " ok flag")
		if not ok:
			failing.append(row["name"])
		var p := _path_entry(row["name"])
		check_near(float(p["duration_s"]), float(row["java_duration_s"]) if lib.index["trajectory_library"]["provider"] == "java" else float(row["python_duration_s"]), 1e-6, row["name"] + " exported duration")
	check_eq(parity["ok"], failing.is_empty())
	if not failing.is_empty():
		note("Python/Java parity fails for " + ", ".join(failing) + "; exporting the robot's Java trajectories")
		check_eq(lib.index["trajectory_library"]["provider"], "java", "parity failure must switch to the Java trajectories")
		check_eq(lib.index["trajectory_library"]["version"], "2027.0.0-alpha-4.1")


func test_samples_grid_endpoints_flip_and_speed() -> void:
	for n in lib.names():
		var a := lib.get_auto(n)
		var e := lib.entry(n)
		if not a.has_path():
			continue
		check_eq(a.sample_count, floori(a.duration_s / a.dt + 1e-9) + 1, n + " sample count")
		check_eq(a.sample_count, int(e["sample_count"]), n + " index sample count")
		var first := _path_entry(a.paths[0])
		var last := _path_entry(a.paths[a.paths.size() - 1])
		for side: StringName in [AutoPlayback.RED, AutoPlayback.BLUE]:
			var p0 := a.sample_at(0, side)
			var p1 := a.sample_at(a.sample_count - 1, side)
			check(Vector2(p0.x, p0.y).distance_to(Vector2(a.start_pose[side].x, a.start_pose[side].y)) <= 0.001, "%s %s first sample is the start pose" % [n, side])
			check(Vector2(p1.x, p1.y).distance_to(Vector2(a.end_pose[side].x, a.end_pose[side].y)) <= 0.001, "%s %s last sample is the end pose" % [n, side])
		var sp: Array = first["start_pose"]
		var ep: Array = last["end_pose"]
		check(Vector2(a.channel(&"x", &"red")[0] - sp[0], a.channel(&"y", &"red")[0] - sp[1]).length() <= 0.001, n + " starts at the first path's start")
		var k := a.sample_count - 1
		check(Vector2(a.channel(&"x", &"red")[k] - ep[0], a.channel(&"y", &"red")[k] - ep[1]).length() <= 0.001, n + " ends at the last path's end")
		var worst := 0.0
		for i in a.sample_count:
			var rx := a.channel(&"x", &"red")[i]
			var ry := a.channel(&"y", &"red")[i]
			var rh := a.channel(&"heading", &"red")[i]
			worst = maxf(worst, absf(a.channel(&"x", &"blue")[i] - (FLIP_X - rx)))
			worst = maxf(worst, absf(a.channel(&"y", &"blue")[i] - (FLIP_Y - ry)))
			worst = maxf(worst, absf(angle_difference(a.channel(&"heading", &"blue")[i], rh + PI)))
			worst = maxf(worst, absf(a.channel(&"vx", &"blue")[i] + a.channel(&"vx", &"red")[i]))
			worst = maxf(worst, absf(a.channel(&"vy", &"blue")[i] + a.channel(&"vy", &"red")[i]))
		check(worst <= 1e-6, "%s blue is the rotational flip of red (worst %s)" % [n, worst])
		for seg: Dictionary in a.segments:
			if seg["type"] != "path":
				continue
			var vmax := float(seg["max_velocity_mps"]) * 1.01
			for i in range(ceili(float(seg["t0"]) / a.dt - 1e-9), mini(a.sample_count - 1, floori(float(seg["t1"]) / a.dt + 1e-9)) + 1):
				var v := Vector2(a.channel(&"vx", &"red")[i], a.channel(&"vy", &"red")[i]).length()
				if v > vmax:
					fail("%s: %.3f m/s at %.2f s over %s's max %s" % [n, v, i * a.dt, seg["name"], seg["max_velocity_mps"]])
					break


func test_climber_right_left_timeline() -> void:
	var a := lib.get_auto("Climber Right Left")
	var p1 := float(_path_entry("Climber Right Left")["duration_s"])
	var p2 := float(_path_entry("Climber Right Close")["duration_s"])
	var wrist := _wrist_command_s()
	check_near(p1, 7.53, 0.02, "first path")
	check_eq(a.segments[0]["name"], "Climber Right Left")
	check_near(float(a.segments[0]["t1"]), p1, 1e-6, "deadline group ends with its path")
	for n in ["ContinuousAimCommand", "ContinuousShooterCommand"]:
		var ev: Dictionary = _events(a, n)[0]
		check_near(float(ev["t1"]), p1, 1e-6, n + " cut by the deadline")
		check_eq(ev["end_reason"], "deadline")
	var bottom: Dictionary = _events(a, "IntakeBottomCommand")[0]
	check_near(float(bottom["t1"]) - float(bottom["t0"]), wrist, 1e-6, "IntakeBottomCommand ends at the wrist setpoint")
	var top: Dictionary = _events(a, "IntakeTopCommand")[0]
	check_near(float(top["t0"]), p1, 1e-6, "IntakeTopCommand starts after the deadline group")
	check_near(float(top["t1"]) - float(top["t0"]), wrist, 1e-6, "IntakeTopCommand runs the modeled wrist travel")
	check_eq(a.segments[1]["type"], "hold")
	check_eq(a.segments[2]["name"], "Climber Right Close")
	check_near(float(a.segments[2]["t0"]), p1 + wrist, 1e-6, "second path starts after the wrist")
	check_near(a.nominal_duration_s, p1 + wrist + p2, 1e-6, "nominal duration")
	check_near(a.duration_s, ceilf((p1 + wrist + p2) / 0.02 - 1e-9) * 0.02, 1e-6, "grid duration")
	check(a.ends_by_itself, "climber auto ends by itself")
	var down: Dictionary = _events(a, "MoveClimberDown")[0]
	check_near(float(down["t0"]), p1 + wrist + p2, 1e-6, "MoveClimberDown after the second path")
	check_eq(down["kind"], "noop")


func test_move_forward_and_shoot_runs_to_auto_end() -> void:
	for side in ["Center", "Left", "Right"]:
		var a := lib.get_auto("Move Forward And Shoot " + side)
		var path_end := float(_path_entry("Move Forward " + side)["duration_s"])
		check(not a.ends_by_itself, side + " never ends by itself")
		for n in ["ContinuousAimCommand", "ContinuousShooterCommand"]:
			var ev: Dictionary = _events(a, n)[0]
			check_near(float(ev["t0"]), path_end, 1e-6, side + " " + n + " starts after the path")
			check_eq(float(ev["t1"]), 20.0, side + " " + n + " active until 20 s")
			check_eq(ev["end_reason"], "auto_end")
		var mid: Dictionary = _events(a, "IntakeMiddleCommand")[0]
		check_near(float(mid["t0"]), path_end, 1e-6)
		check_near(float(mid["t1"]) - float(mid["t0"]), _wrist_command_s(), 1e-6)
		check_eq(a.warnings, [], side + " has no warnings")


func test_stay_and_shoot_has_no_path() -> void:
	var a := lib.get_auto("Stay And Shoot")
	check(not a.has_path(), "no path")
	check_eq(lib.entry("Stay And Shoot")["has_path"], false)
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/autos/Stay And Shoot.json"))
	check(raw["start_pose"] == null, "start pose is null")
	check(raw["samples"]["red"] == null, "no samples")
	check_eq(a.sample(1.0, AutoPlayback.RED), {})
	check_eq(a.events.size(), 3)
	for ev: Dictionary in a.events:
		check_eq([ev["t0"], ev["t1"], ev["end_reason"]], [0.0, 20.0, "auto_end"], ev["name"])


func test_ball_shooter_intake_zone() -> void:
	for side in ["Left", "Right"]:
		var a := lib.get_auto("Ball Shooter " + side)
		var zones := _events(a, "IntakeCommand")
		check_eq(zones.size(), 1, side + " zone count")
		var z: Dictionary = zones[0]
		check_eq(z["kind"], "zone_marker")
		check_eq(z["source"], "path:Ball Shooter " + side)
		check(0.0 < float(z["t0"]) and float(z["t0"]) < float(z["t1"]) and float(z["t1"]) < a.duration_s, "%s zone 0 < %s < %s < %s" % [side, z["t0"], z["t1"], a.duration_s])
		check_eq(z["trigger_bound"], false, "the robot binds no EventTrigger for the zone")
		check(a.warning_codes().has("unbound_marker"), side + " warns that the zone runs nothing")


func test_unregistered_climber_commands_warn_only_on_climber_autos() -> void:
	var expected := {
		"Climber Right Left": ["MoveClimberDown", "MoveClimberUp"],
		"Climber Right Right": ["MoveClimberDown", "MoveClimberUp"],
		"Climber Right Middle": ["ClimberL1Command"],
	}
	for n in lib.names():
		var a := lib.get_auto(n)
		var names: Array = []
		for w: Dictionary in a.warnings:
			if w["code"] == "unregistered_command":
				names.append(w["name"])
		names.sort()
		check_eq(names, expected.get(n, []), n + " unregistered warnings")
		for ev: Dictionary in a.events:
			check_eq(ev["registered"], not ["MoveClimberUp", "MoveClimberDown", "ClimberL1Command"].has(ev["name"]), "%s %s registered flag" % [n, ev["name"]])
		check_eq(lib.entry(n)["warnings"].has("unregistered_command"), expected.has(n), n + " index warnings")


func test_events_stay_inside_the_auto() -> void:
	for n in lib.names():
		var a := lib.get_auto(n)
		for ev: Dictionary in a.events:
			check(0.0 <= float(ev["t0"]) and float(ev["t0"]) <= float(ev["t1"]) and float(ev["t1"]) <= a.auto_length_s, "%s %s interval" % [n, ev["name"]])
			if ev["end_reason"] != "auto_end":
				check(float(ev["t1"]) <= a.duration_s + 1e-6, "%s %s ends inside the timeline" % [n, ev["name"]])
		if a.has_path():
			check_eq(float(a.segments[0]["t0"]), 0.0)
			check_near(float(a.segments.back()["t1"]), a.duration_s, 1e-6, n + " segments cover the timeline")
