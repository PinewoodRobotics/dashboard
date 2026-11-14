extends TestCase

## Every exported auto with a path, at every preview speed, played at the same
## time on independent clocks fed by the real wall clock: the wall time of the
## whole timeline must be within 1% of duration / speed.


func test_full_timelines_play_in_real_time() -> void:
	var lib := AutoLibrary.new()
	check(lib.load_dir(AutoLibrary.BUILTIN_DIR), lib.error)
	var runs: Array = []
	for n in lib.names():
		var p := lib.get_auto(n)
		if not p.has_path():
			continue
		for speed in AutoClock.SPEEDS:
			var c := AutoClock.new()
			c.set_duration(p.timeline_s())
			c.set_speed(speed)
			runs.append({"name": n, "speed": speed, "clock": c})
	check_eq(runs.size(), 8 * AutoClock.SPEEDS.size(), "8 autos with a path x 3 speeds")
	for r: Dictionary in runs:
		(r["clock"] as AutoClock).play()
	var deadline := now_s() + 45.0
	while now_s() < deadline:
		var now := Time.get_ticks_usec()
		var playing := 0
		for r: Dictionary in runs:
			var c: AutoClock = r["clock"]
			c.tick(now)
			playing += 1 if c.playing else 0
		if playing == 0:
			break
		await tree.process_frame
	for r: Dictionary in runs:
		var c: AutoClock = r["clock"]
		var want: float = c.duration / float(r["speed"])
		var got := float(c.last_run.get("wall_s", -1.0))
		var err := absf(got - want) / want
		note("%s at %sx: %.3f s for %.3f s (%.2f%%)" % [r["name"], r["speed"], got, want, err * 100.0])
		check(err <= 0.01, "%s at %sx off by %.2f%%" % [r["name"], r["speed"], err * 100.0])
