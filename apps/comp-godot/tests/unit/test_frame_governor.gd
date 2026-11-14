extends TestCase


func _run(g: FrameGovernor, seconds: float, fps_at: Callable, target: float = 60.0, rendering: bool = true, base: Dictionary = {}) -> Array:
	var changes: Array = []
	var t := 0.0
	while t < seconds:
		var dt := 1.0 / float(fps_at.call(g.caps()))
		if g.feed(dt, target, rendering, base):
			changes.append(g.caps())
		t += dt
	return changes


## Frame rate of a GPU whose cost splits into fill (pixels, MSAA) and vertices.
func _gpu(fill_ms: float, vertex_ms: float, other_ms: float = 0.0) -> Callable:
	return func(c: Dictionary) -> float:
		var scale := float(c.get("render_scale", 1.0))
		var fill := fill_ms * scale * scale * (0.8 if c.has("msaa") else 1.0)
		var verts := vertex_ms * (0.2 if c.get("models", "") == "lite" else 1.0)
		return 1000.0 / maxf(16.667, fill + verts + other_ms)


func test_holds_full_quality_at_the_cap() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 30.0, func(_c: Dictionary) -> float: return 60.0), [])
	check_eq(g.caps(), {})
	check_eq(g.state, FrameGovernor.State.WATCHING)


func test_fill_bound_gpu_skips_the_light_models_and_lowers_the_scale() -> void:
	var g := FrameGovernor.new()
	g.reset()
	var changes := _run(g, 40.0, _gpu(26.0, 0.5))
	check_eq(changes, [{"msaa": 0}, {"msaa": 0, "models": "lite"}, {"msaa": 0, "render_scale": 0.75}])
	check_eq(g.caps(), {"msaa": 0, "render_scale": 0.75})
	check_eq(g.state, FrameGovernor.State.HELD)
	check_eq(g.status_text(), "0.75x scale, MSAA off, 60 fps")


func test_vertex_bound_gpu_gets_the_light_models() -> void:
	var g := FrameGovernor.new()
	g.reset()
	var changes := _run(g, 40.0, _gpu(1.0, 30.0))
	check_eq(changes, [{"msaa": 0}, {"models": "lite"}], "MSAA off does not help, the light models do")
	check_eq(g.caps(), {"models": "lite"})
	check_eq(g.state, FrameGovernor.State.HELD)
	check_eq(g.status_text(), "light models, 60 fps")


func test_stops_at_the_lowest_step() -> void:
	var g := FrameGovernor.new()
	g.reset()
	var changes := _run(g, 80.0, _gpu(60.0, 20.0))
	check_eq(changes.size(), 4)
	check_eq(g.caps(), {"msaa": 0, "models": "lite", "render_scale": 0.5})
	check_eq(g.state, FrameGovernor.State.HELD)


func test_undoes_steps_that_do_not_help() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 60.0, func(_c: Dictionary) -> float: return 30.0),
		[{"msaa": 0}, {"models": "lite"}, {"render_scale": 0.75}, {}], "a vsync pair at half rate is not a GPU limit; 0.5 is not tried after 0.75 failed")
	check_eq(g.caps(), {})
	check_eq(g.state, FrameGovernor.State.GAVE_UP)
	check(g.status_text().contains("lowering did not help"), g.status_text())
	check_eq(_run(g, 20.0, func(_c: Dictionary) -> float: return 20.0), [], "stays put after giving up")
	g.reset()
	check_eq(g.state, FrameGovernor.State.WATCHING)


func test_skips_steps_the_saved_settings_already_meet() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 40.0, _gpu(26.0, 0.5), 60.0, true, {"render_scale": 1.0, "msaa": 0}),
		[{"models": "lite"}, {"render_scale": 0.75}])
	check_eq(g.caps(), {"render_scale": 0.75})
	check_eq(g.state, FrameGovernor.State.HELD)
	var h := FrameGovernor.new()
	h.reset()
	check_eq(_run(h, 40.0, _gpu(40.0, 0.5), 60.0, true, {"render_scale": 0.75, "msaa": 0}),
		[{"models": "lite"}, {"render_scale": 0.5}])
	check_eq(h.caps(), {"render_scale": 0.5})


func test_gives_up_past_skipped_steps() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 40.0, func(_c: Dictionary) -> float: return 30.0, 60.0, true, {"render_scale": 1.0, "msaa": 0}),
		[{"models": "lite"}, {"render_scale": 0.75}, {}])
	check_eq(g.state, FrameGovernor.State.GAVE_UP)


func test_holds_when_the_saved_settings_are_already_lowest() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 30.0, func(_c: Dictionary) -> float: return 30.0, 60.0, true, {"render_scale": 0.5, "msaa": 0, "models": "lite"}), [])
	check_eq(g.caps(), {})
	check_eq(g.state, FrameGovernor.State.HELD)


func test_ignores_warmup_and_frames_without_3d() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, FrameGovernor.WARMUP_S - 0.5, func(_c: Dictionary) -> float: return 10.0), [], "startup hitches are not measured")
	var h := FrameGovernor.new()
	h.reset()
	check_eq(_run(h, 30.0, func(_c: Dictionary) -> float: return 10.0, 60.0, false), [], "no 3D view rendering")


func test_target_follows_a_30_fps_cap() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 30.0, func(_c: Dictionary) -> float: return 30.0, 30.0), [])


func test_service_caps_the_saved_settings_and_follows_the_toggle() -> void:
	var settings := SettingsService.new()
	settings.persist = false
	tree.root.add_child(settings)
	var perf := PerfGovernor.new()
	perf.settings = settings
	perf.args = {"auto_quality": "on"}
	tree.root.add_child(perf)
	perf.set_process(false)
	check(perf.enabled())
	settings.set_visual({"render_scale": 0.5, "msaa": 4})
	settings.set_perf_caps({"msaa": 0, "render_scale": 0.75})
	var v := settings.effective_visual()
	check_eq([v["render_scale"], v["msaa"]], [0.5, 0], "caps never raise a lower saved value")
	settings.set_perf_caps({"models": "lite"})
	check_eq(settings.effective_visual().get("models"), "lite", "the light models cap passes through")
	settings.set_perf_caps({"msaa": 0, "render_scale": 0.75})
	check_eq(settings.visual()["msaa"], 4, "the saved settings stay untouched")
	settings.set_visual({"auto_quality": false})
	check(not perf.enabled())
	check_eq(settings.perf_caps, {}, "turning Auto Quality off drops the caps")
	perf.args = {"auto_quality": "off"}
	settings.set_visual({"auto_quality": true})
	check(not perf.enabled(), "--auto-quality=off wins")
	perf.queue_free()
	settings.queue_free()
	await tree.process_frame
