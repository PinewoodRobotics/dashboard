extends TestCase


func _synthetic(n: int, dt := 0.5) -> AutoPlayback:
	var red := {"x": [], "y": [], "heading": [], "vx": [], "vy": [], "omega": []}
	var blue := {"x": [], "y": [], "heading": [], "vx": [], "vy": [], "omega": []}
	for i in n:
		var h := 3.0 if i % 2 == 0 else -3.0
		for side in [red, blue]:
			side["x"].append(float(i))
			side["y"].append(2.0 * i)
			side["heading"].append(h)
			side["vx"].append(1.0)
			side["vy"].append(0.0)
			side["omega"].append(0.0)
	return AutoPlayback.from_dict({
		"name": "synthetic", "dt": dt, "duration_s": (n - 1) * dt,
		"start_pose": {"red": [0, 0, 3.0], "blue": [0, 0, 3.0]},
		"end_pose": {"red": [n - 1, 2 * (n - 1), 0], "blue": [n - 1, 2 * (n - 1), 0]},
		"samples": {"red": red, "blue": blue},
	})


func test_sample_at_start_mid_and_end() -> void:
	var a := _synthetic(5)
	check_eq(a.sample_count, 5)
	var s0 := a.sample(0.0, AutoPlayback.RED)
	check_eq([s0[&"x"], s0[&"y"], s0[&"heading"]], [0.0, 0.0, 3.0])
	check_near(a.sample(1.0, AutoPlayback.RED)[&"x"], 2.0, 1e-12, "grid point")
	check_near(a.sample(1.25, AutoPlayback.RED)[&"x"], 2.5, 1e-12, "between grid points")
	check_near(a.sample(1.25, AutoPlayback.RED)[&"y"], 5.0, 1e-12)
	var s_end := a.sample(2.0, AutoPlayback.RED)
	check_eq([s_end[&"x"], s_end[&"y"]], [4.0, 8.0])


func test_sample_clamps_outside_the_range() -> void:
	var a := _synthetic(5)
	check_eq(a.sample(-3.0, AutoPlayback.RED), a.sample(0.0, AutoPlayback.RED))
	check_eq(a.sample(99.0, AutoPlayback.RED), a.sample(2.0, AutoPlayback.RED))
	check_eq(a.sample(INF, AutoPlayback.BLUE), a.sample(2.0, AutoPlayback.BLUE))


func test_heading_takes_the_short_arc_across_pi() -> void:
	var a := _synthetic(3)
	var h: float = a.sample(0.25, AutoPlayback.RED)[&"heading"]
	check_near(absf(h), PI, 1e-9, "3.0 -> -3.0 passes through +-PI, not 0")
	var q: float = a.sample(0.125, AutoPlayback.RED)[&"heading"]
	check_near(angle_difference(q, 3.0 + (TAU - 6.0) * 0.25), 0.0, 1e-9, "quarter of the short arc")


func test_sample_is_independent_of_call_order() -> void:
	var lib := AutoLibrary.new()
	check(lib.load_dir(AutoLibrary.BUILTIN_DIR), lib.error)
	var a := lib.get_auto("Ball Shooter Left")
	var times: Array[float] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 4765
	for i in 400:
		times.append(rng.randf_range(-1.0, a.duration_s + 1.0))
	var forward := {}
	for t in times:
		forward[t] = a.sample(t, AutoPlayback.BLUE)
	var shuffled := times.duplicate()
	shuffled.shuffle()
	shuffled.reverse()
	for t in shuffled:
		if a.sample(t, AutoPlayback.BLUE) != forward[t]:
			fail("sample(%s) depends on call order" % t)
			return
	var fresh := AutoLibrary.new()
	fresh.load_dir(AutoLibrary.BUILTIN_DIR)
	check_eq(fresh.get_auto("Ball Shooter Left").sample(times[7], AutoPlayback.BLUE), forward[times[7]], "fresh instance")


func test_grid_points_return_exported_samples() -> void:
	var lib := AutoLibrary.new()
	lib.load_dir(AutoLibrary.BUILTIN_DIR)
	var a := lib.get_auto("Climber Right Left")
	for k in [0, 1, 100, 376, 377, a.sample_count - 1]:
		var s := a.sample(k * a.dt, AutoPlayback.RED)
		check_near(s[&"x"], a.channel(&"x", AutoPlayback.RED)[k], 1e-9, "x at %d" % k)
		check_near(angle_difference(s[&"heading"], a.channel(&"heading", AutoPlayback.RED)[k]), 0.0, 1e-9, "heading at %d" % k)


func test_sample_cost_is_constant() -> void:
	var small := _synthetic(10, 0.02)
	var big := _synthetic(100_000, 0.02)
	var calls := 20_000
	var cost := func(a: AutoPlayback) -> float:
		var t0 := Time.get_ticks_usec()
		for i in calls:
			a.sample(fmod(i * 0.37, a.duration_s), AutoPlayback.RED)
		return float(Time.get_ticks_usec() - t0)
	cost.call(small)
	var best_small := INF
	var best_big := INF
	for r in 3:
		best_small = minf(best_small, cost.call(small))
		best_big = minf(best_big, cost.call(big))
	note("sample(): %.2f us with 10 samples, %.2f us with 100k" % [best_small / calls, best_big / calls])
	check(best_big < best_small * 2.0, "sample cost does not grow with the sample count")


func test_events_at_and_segment_at() -> void:
	var lib := AutoLibrary.new()
	lib.load_dir(AutoLibrary.BUILTIN_DIR)
	var a := lib.get_auto("Climber Right Left")
	var names := func(t: float) -> Array:
		var out: Array = []
		for e: Dictionary in a.events_at(t):
			out.append(e["name"])
		out.sort()
		return out
	check_eq(names.call(1.0), ["ContinuousAimCommand", "ContinuousShooterCommand"])
	check(names.call(0.0).has("IntakeBottomCommand"), "intake bottom at 0")
	var top: Dictionary = a.events.filter(func(e: Dictionary) -> bool: return e["name"] == "IntakeTopCommand")[0]
	check(names.call(float(top["t0"])).has("IntakeTopCommand"), "intake top while the wrist moves")
	check(names.call(float(top["t0"])).has("MoveClimberUp"), "instant no-op shows at its time")
	check_eq(a.segment_at(1.0)["name"], "Climber Right Left")
	check_eq(a.segment_at(a.duration_s - 0.5)["name"], "Climber Right Close")


func test_clock_advances_loops_and_stops() -> void:
	var c := AutoClock.new()
	c.set_duration(2.0)
	check(not c.advance(0.5), "paused clock does not move")
	c.play()
	c.set_speed(2.0)
	c.advance(0.5)
	check_near(c.t, 1.0, 1e-12)
	c.advance(1.0)
	check_eq(c.t, 2.0)
	check(not c.playing, "stops at the end without loop")
	c.play()
	check_eq(c.t, 0.0, "play at the end restarts")
	c.loop = true
	c.set_speed(0.5)
	c.advance(5.0)
	check_near(c.t, 0.5, 1e-12, "loops")
	check(c.playing)
	c.seek(-4.0)
	check_eq(c.t, 0.0)
	c.seek(9.0)
	check_eq(c.t, 2.0)
