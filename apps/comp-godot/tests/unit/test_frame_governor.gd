extends TestCase


## Feeds frames at the fps that `fps_at(level)` returns for `seconds`.
func _run(g: FrameGovernor, seconds: float, fps_at: Callable, target: float = 60.0, rendering: bool = true, base: Dictionary = {}) -> Array:
	var changes: Array = []
	var t := 0.0
	while t < seconds:
		var dt := 1.0 / float(fps_at.call(g.level))
		if g.feed(dt, target, rendering, base):
			changes.append(g.level)
		t += dt
	return changes


func test_holds_full_quality_at_the_cap() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 30.0, func(_l: int) -> float: return 60.0), [])
	check_eq(g.caps(), {})
	check_eq(g.state, FrameGovernor.State.WATCHING)


func test_steps_down_until_the_cap_holds() -> void:
	var g := FrameGovernor.new()
	g.reset()
	var fps := [38.0, 46.0, 60.0, 60.0]
	check_eq(_run(g, 40.0, func(l: int) -> float: return fps[l]), [1, 2])
	check_eq(g.caps(), {"msaa": 0, "render_scale": 0.75})
	check_eq(g.state, FrameGovernor.State.HELD)
	check_eq(g.status_text(), "0.75x scale, MSAA off, 60 fps")


func test_stops_at_the_lowest_level() -> void:
	var g := FrameGovernor.new()
	g.reset()
	var fps := [20.0, 26.0, 32.0, 40.0]
	check_eq(_run(g, 60.0, func(l: int) -> float: return fps[l]), [1, 2, 3])
	check_eq(g.caps(), {"msaa": 0, "render_scale": 0.5})


func test_undoes_a_level_that_does_not_help() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 40.0, func(_l: int) -> float: return 30.0), [1, 0], "a vsync pair at half rate is not a GPU limit")
	check_eq(g.caps(), {})
	check_eq(g.state, FrameGovernor.State.GAVE_UP)
	check(g.status_text().contains("lowering did not help"), g.status_text())
	check_eq(_run(g, 20.0, func(_l: int) -> float: return 20.0), [], "stays put after giving up")
	g.reset()
	check_eq(g.state, FrameGovernor.State.WATCHING)


func test_skips_levels_the_saved_settings_already_meet() -> void:
	var g := FrameGovernor.new()
	g.reset()
	var fps := [40.0, 40.0, 60.0, 60.0]
	check_eq(_run(g, 40.0, func(l: int) -> float: return fps[l], 60.0, true, {"render_scale": 1.0, "msaa": 0}), [2])
	check_eq(g.caps(), {"msaa": 0, "render_scale": 0.75})
	check_eq(g.state, FrameGovernor.State.HELD)
	var h := FrameGovernor.new()
	h.reset()
	var slow := [30.0, 30.0, 30.0, 60.0]
	check_eq(_run(h, 40.0, func(l: int) -> float: return slow[l], 60.0, true, {"render_scale": 0.75, "msaa": 0}), [3])
	check_eq(h.caps(), {"msaa": 0, "render_scale": 0.5})


func test_undo_returns_past_skipped_levels() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 40.0, func(_l: int) -> float: return 30.0, 60.0, true, {"render_scale": 1.0, "msaa": 0}), [2, 0])
	check_eq(g.state, FrameGovernor.State.GAVE_UP)


func test_holds_when_the_saved_settings_are_already_lowest() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 30.0, func(_l: int) -> float: return 30.0, 60.0, true, {"render_scale": 0.5, "msaa": 0}), [])
	check_eq(g.caps(), {})
	check_eq(g.state, FrameGovernor.State.HELD)


func test_ignores_warmup_and_frames_without_3d() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, FrameGovernor.WARMUP_S - 0.5, func(_l: int) -> float: return 10.0), [], "startup hitches are not measured")
	var h := FrameGovernor.new()
	h.reset()
	check_eq(_run(h, 30.0, func(_l: int) -> float: return 10.0, 60.0, false), [], "no 3D view rendering")


func test_target_follows_a_30_fps_cap() -> void:
	var g := FrameGovernor.new()
	g.reset()
	check_eq(_run(g, 30.0, func(_l: int) -> float: return 30.0, 30.0), [])


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
