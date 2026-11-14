class_name DevService
extends Node

## Development hooks, inactive unless a flag asks (all after `--`):
##   --fixture=NAME|PATH  res://data/fixtures/NAME.json or a file; NT values are
##                        injected offline (no socket), see the format below
##   --live               keep the fixture's views and probes but take NT values
##                        from the live connection (waits for pose and alliance)
##   --screenshot=PREFIX  save PREFIX_<window>.png for every window, then quit
##   --frames=N           frames to wait once the models are visible (default 30)
##   --perf-frames=N      sample RenderingServer counters over N frames first
##   --report=PATH        JSON report (default PREFIX.json when --screenshot is set)
##   --probes=PATH        extra probes (JSON array) on top of the fixture's
##   --timeout=S          fail when the models are not visible after S seconds (default 20)
##   --quit-after-run     quit after the report even without --screenshot
##   --run-s=S            keep running S seconds after the frames, input and perf
##                        sampling, recording memory, object counts, NT state and
##                        match phases every --sample-s (default 10) into "soak"
##   --quit-file=PATH     end a --run-s run early once PATH exists
##   --autos-dir=PATH     auto export folder used instead of user://autos
##   --nt-trace=PATH      append every NT client state change as a JSON line
##                        {"unix": seconds, "state": name}, from launch on
## The process exits non-zero when a probe fails or the models never appear.
##
## Fixture: {"extends": "base", "nt": {topic: value}, "map": {mode, angle, zoom},
##   "nt_link": "up"|"down" (down: values cached as if the connection dropped),
##   "nt_steps": [{topic: value}, ...] injected in order after start (e.g. toasts),
##   "match": {"advance_s": S} advance the frozen match clock after the steps,
##   "orbit_preset": 0, "camera": {"hud"|"touch"|"preview": {"position": [x,y,z], "target": [..], "up": [..]}},
##   "touch": {"active_tab": id, "open_panel": id, "dock_open": bool, "dev_tab": "gallery",
##     "keyboard": "<gallery input name>", "keyboard_text": "..", "howard_index": N,
##     "view_auto": name, "panel_scroll": px}
##     (applied, then every transition finished, before the run),
##   "controls": {"selected_auto": name|"NONE", "intake_speed": x, "conflict": bool, "trim_requested": deg},
##   "preview": {"auto", "t", "playing", "speed", "loop", "alliance", "realtime", "camera": "path"|"field"} auto preview
##     (offline the preview clock is frozen unless realtime is true),
##   "connection": {shared-file "settings" object} (offline: replaces the connection settings in memory),
##   "input": [steps] scripted touch or mouse input with expectations (services/dev_input.gd),
##   "probes": [{"name": "..", "window": "hud"|"touch", "at": "robot" | "node:<Name>" | [x, y, w, h],
##     "half": 40, "kind": "hue"|"nonblack"|"color"|"mean_luma", "hue": "red"|"blue",
##     "color": "#rrggbb", "tol": 0.1, "min_fraction": 0.02}]}
##   mean_luma probes compare the region's mean luma with "min" / "max" instead.
## Rects and "half" are in design pixels of the window (1920x1080 HUD, 1920x515 touch).
## Every frame the number of SubViewports rendering 3D is checked: more than
## MAX_RENDERING_VIEWS logs an error (and fails a run).

const FIXTURE_DIR := "res://data/fixtures"
const MAX_RENDERING_VIEWS := 2

var args := {}
var fixture := {}
var report := {}
var first_frame_msec := -1
var first_frame_unix := 0.0
var models_visible_msec := -1
var dev_ready_msec := -1
var main_attach_msec := -1
var _main: Node
var _failures: PackedStringArray = []
var max_rendering_views := 0
var _over_budget_frames := 0
var _input: DevInput


func _ready() -> void:
	dev_ready_msec = Time.get_ticks_msec()
	args = CliArgs.parse(OS.get_cmdline_user_args())
	if args.has("fixture"):
		fixture = load_fixture(str(args["fixture"]))
	RenderingServer.frame_post_draw.connect(_on_first_frame, CONNECT_ONE_SHOT)
	if args.has("nt_trace"):
		_start_nt_trace(str(args["nt_trace"]))


func _process(_delta: float) -> void:
	var n := CadView.rendering_views(get_tree()).size()
	max_rendering_views = maxi(max_rendering_views, n)
	if n > MAX_RENDERING_VIEWS:
		if _over_budget_frames == 0:
			push_error("%d SubViewports render 3D this frame (budget %d)" % [n, MAX_RENDERING_VIEWS])
		_over_budget_frames += 1


func _start_nt_trace(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_failures.append("cannot write the NT trace " + path)
		return
	var write := func(s: int) -> void:
		f.store_line(JSON.stringify({"unix": Time.get_unix_time_from_system(), "state": Nt4Client.STATE_NAMES[s]}))
		f.flush()
	write.call(NT.client.get_state())
	NT.client.state_changed.connect(func(s: int, _prev: int) -> void: write.call(s))


func _on_first_frame() -> void:
	first_frame_msec = Time.get_ticks_msec()
	first_frame_unix = Time.get_unix_time_from_system()


func has_fixture() -> bool:
	return not fixture.is_empty()


func offline_fixture() -> bool:
	return has_fixture() and not args.has("live")


func fixture_nt() -> Dictionary:
	return fixture.get("nt", {})


static func load_fixture(name_or_path: String, depth: int = 0) -> Dictionary:
	var path := name_or_path
	if not FileAccess.file_exists(path):
		path = FIXTURE_DIR.path_join(name_or_path + ".json")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("fixture unreadable: " + name_or_path)
		return {}
	var fx: Dictionary = parsed
	if fx.has("extends") and depth < 8:
		var base := load_fixture(str(fx["extends"]), depth + 1)
		for key: String in fx:
			if typeof(fx[key]) == TYPE_DICTIONARY and typeof(base.get(key)) == TYPE_DICTIONARY:
				var merged: Dictionary = base[key].duplicate(true)
				merged.merge(fx[key], true)
				base[key] = merged
			else:
				base[key] = fx[key]
		base.erase("extends")
		return base
	return fx


func wants_run() -> bool:
	return args.has("screenshot") or args.has("report") or args.has("quit_after_run")


func attach(main: Node) -> void:
	main_attach_msec = Time.get_ticks_msec()
	_main = main
	_apply_fixture_views()
	if wants_run():
		_run.call_deferred()


func _views() -> Dictionary:
	var out := {}
	if _main == null:
		return out
	var mm: MinimapView = _main.call("minimap")
	var ob: RobotOrbitView = _main.call("orbit")
	if mm != null:
		out["hud"] = mm
	if ob != null:
		out["touch"] = ob
	for v: CadView in get_tree().get_nodes_in_group(CadView.GROUP):
		if v is AutoPreviewView and v.is_visible_in_tree():
			out["preview"] = v
			break
	return out


func _windows() -> Dictionary:
	return _main.get("windows") if _main != null else {}


func _apply_fixture_views() -> void:
	var views := _views()
	if fixture.has("map"):
		Settings.set_map(fixture["map"])
	if offline_fixture():
		for step: Dictionary in fixture.get("nt_steps", []):
			NT.inject(step, fixture.get("nt_link", "up") != "down")
		var adv := float(fixture.get("match", {}).get("advance_s", 0.0))
		if adv > 0.0 and Match.clock.is_frozen():
			Match.clock.advance_s(adv)
			Match.model.step(Match.clock.now_us())
	if fixture.has("orbit_preset") and views.has("touch"):
		(views["touch"] as RobotOrbitView).apply_preset(int(fixture["orbit_preset"]))
	if fixture.has("controls"):
		Controls.apply_fixture(fixture["controls"])
		Controls.step()
	var ts := touch_screen()
	if ts != null and fixture.has("touch"):
		ts.call("apply_fixture", fixture["touch"])
	if fixture.has("preview"):
		Autos.apply_fixture(fixture["preview"])
	views = _views()
	if views.has("preview") and fixture.get("preview", {}).has("camera"):
		var panel := (views["preview"] as Node).find_parent("AutoPreview")
		if panel != null:
			panel.call("set_camera", fixture["preview"]["camera"] == "field")
	var cams: Dictionary = fixture.get("camera", {})
	for key: String in cams:
		if views.has(key):
			var c: Dictionary = cams[key]
			(views[key] as CadView).camera_override = {
				"position": _vec3(c.get("position", [0, 10, 0])),
				"target": _vec3(c.get("target", [0, 0, 0])),
				"up": _vec3(c.get("up", [0, 1, 0])),
			}


## Untyped on purpose: a typed reference would compile every touchscreen
## script at startup, also in --screen=hud.
func touch_screen() -> Control:
	return _main.call("touch_screen") if _main != null else null


func window(key: String) -> Window:
	return _windows().get(key)


func screen_root(key: String) -> Node:
	if key == "touch":
		return touch_screen()
	return _main.call("hud_screen") if _main != null else null


func save_settings() -> void:
	Settings.save_now()


func inject_nt(values: Dictionary) -> void:
	if offline_fixture():
		NT.inject(values, fixture.get("nt_link", "up") != "down")


## What scripted-input expectations can look at.
func probe_state() -> Dictionary:
	var out := {"settings": Settings.data.duplicate(true), "max_rendering_views": max_rendering_views,
		"controls": Controls.snapshot(), "connection": Settings.connection().duplicate(true), "nt_ready": NT.is_ready(),
		"autos": Autos.snapshot(),
		"models": {"generation": Models.generation.duplicate()}, "engine": {"max_fps": Engine.max_fps}}
	var views: Array = []
	for v: CadView in get_tree().get_nodes_in_group(CadView.GROUP):
		views.append({"name": String(v.name), "scale": v.viewport.scaling_3d_scale, "msaa": int(v.viewport.msaa_3d), "rendering": v.is_rendering(), "loaded": v.robot.is_loaded()})
	out["views"] = views
	var ts := touch_screen()
	if ts != null:
		out.merge(ts.call("probe"), true)
		out["telemetry"] = {"manual": Telemetry.manual_joints.duplicate(), "targets": Telemetry.joint_targets.duplicate()}
	var kiosk: KioskController = _main.get("kiosk") if _main != null else null
	if kiosk != null:
		out["kiosk"] = {"retiles": kiosk.retiles, "plan": kiosk.last_plan.duplicate(true), "watch": kiosk.watch_screens}
	var mm: MinimapView = _main.call("minimap") if _main != null else null
	if mm != null:
		var p := mm.camera.global_position
		out["minimap"] = {"camera": [p.x, p.y, p.z], "dist": mm.cam_model.dist, "mirroring": mm.mirroring,
			"auto_overlay": mm.auto_overlay.key, "robot": [mm.robot.position.x, mm.robot.position.z]}
	return out


static func _vec3(a: Variant) -> Vector3:
	return Vector3(a[0], a[1], a[2]) if typeof(a) == TYPE_ARRAY and (a as Array).size() == 3 else Vector3.ZERO


func _models_visible() -> bool:
	var views := _views()
	for key: String in views:
		var v: CadView = views[key]
		if v.robot == null or not v.robot.is_loaded():
			return false
		if v is MinimapView and (v as MinimapView).field == null:
			return false
	return true


func _run() -> void:
	var tree := get_tree()
	var timeout_ms := int(CliArgs.get_float(args, "timeout", 20.0) * 1000.0)
	var t0 := Time.get_ticks_msec()
	while not _models_visible():
		if Time.get_ticks_msec() - t0 > timeout_ms:
			_failures.append("models not visible after %d ms" % timeout_ms)
			break
		await tree.process_frame
	if args.has("live"):
		while not (Telemetry.has_pose and Telemetry.alliance_red != null):
			if Time.get_ticks_msec() - t0 > timeout_ms:
				_failures.append("no live pose and alliance after %d ms" % timeout_ms)
				break
			await tree.process_frame
	await RenderingServer.frame_post_draw
	models_visible_msec = Time.get_ticks_msec()

	for i in CliArgs.get_int(args, "frames", 30):
		await tree.process_frame

	var steps: Array = fixture.get("input", [])
	if not steps.is_empty():
		_input = DevInput.new(self)
		await _input.run(steps, str(args.get("screenshot", "")))
		_failures.append_array(_input.failures)
		report["input"] = _input.trace
		for i in 10:
			await tree.process_frame

	var perf_frames := CliArgs.get_int(args, "perf_frames", 0)
	if perf_frames > 0:
		report["perf"] = await _sample_perf(perf_frames)

	var run_s := CliArgs.get_float(args, "run_s", 0.0)
	if run_s > 0.0:
		report["soak"] = await _soak(run_s, CliArgs.get_float(args, "sample_s", 10.0))

	await RenderingServer.frame_post_draw
	var images := {}
	var windows := _windows()
	for key: String in windows:
		var w: Window = windows[key]
		images[key] = w.get_texture().get_image()
	report["screen"] = _main.get("screen")
	report["timings"] = {
		"dev_ready_msec": dev_ready_msec,
		"main_attach_msec": main_attach_msec,
		"first_frame_msec": first_frame_msec,
		"first_frame_unix": first_frame_unix,
		"models_visible_msec": models_visible_msec,
		"models_ready_msec": Models.ready_msec,
	}
	report["robot_meshes"] = robot_mesh_report()
	report["max_rendering_views"] = max_rendering_views
	if _over_budget_frames > 0:
		_failures.append("%d frame(s) rendered more than %d 3D SubViewports" % [_over_budget_frames, MAX_RENDERING_VIEWS])
	var ts := touch_screen()
	if ts != null:
		report["touch"] = ts.call("layout_report")
	report["os_windows"] = Array(DisplayServer.get_window_list())
	var kiosk: KioskController = _main.get("kiosk")
	if kiosk != null:
		report["kiosk"] = {"retiles": kiosk.retiles, "plan": var_to_str(kiosk.last_plan), "watch": kiosk.watch_screens}
	report["nt"] = {"state": NT.client.state_name(), "fixture_mode": NT.fixture_mode}
	report["controls"] = Controls.snapshot()
	report["autos"] = Autos.snapshot()
	report["anchors"] = _anchor_positions(images)
	var hud: HudScreen = _main.call("hud_screen")
	if hud != null:
		report["hud_layout"] = hud.layout_report()
		var m := Match.model
		report["match"] = {
			"phase": MatchEnums.PHASE_NAMES[m.phase],
			"hub": MatchEnums.HUB_NAMES[m.hub],
			"header": MatchEnums.HEADER_NAMES[m.header],
			"aim": MatchEnums.AIM_NAMES[m.aim],
			"banner": MatchModel.Banner.keys()[m.banner()],
			"link_ok": m.link_ok(),
			"pose_trusted": m.pose_trusted(),
			"robot_dimmed": hud.minimap.robot.dimmed,
		}
		report["map_settings"] = Settings.map().duplicate()
	report["windows"] = {}
	var prefix := str(args.get("screenshot", ""))
	for key: String in images:
		var img: Image = images[key]
		var win: Window = windows[key]
		var entry := {
			"size": [img.get_width(), img.get_height()],
			"design": [win.content_scale_size.x, win.content_scale_size.y],
			"window_id": win.get_window_id(),
			"embedded": win.is_embedded(),
			"mode": win.mode,
			"borderless": win.borderless,
			"position": [win.position.x, win.position.y],
			"os_size": [win.size.x, win.size.y],
			"current_screen": win.current_screen,
		}
		if prefix != "":
			var png := "%s_%s.png" % [prefix, key]
			var err := img.save_png(png)
			entry["png"] = png
			if err != OK:
				_failures.append("could not save " + png)
		report["windows"][key] = entry
	report["objects"] = _object_counts()
	report["probes"] = _evaluate_probes(images)
	report["failures"] = _failures
	var report_path := str(args.get("report", prefix + ".json" if prefix != "" else ""))
	if report_path != "":
		var f := FileAccess.open(report_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(report, "  ", false))
		f.close()
	for msg in _failures:
		printerr("DEV FAIL: ", msg)
	print("dev run done: %d failure(s)" % _failures.size())
	tree.quit(1 if _failures.size() > 0 else 0)


func _sample_perf(frames: int) -> Dictionary:
	var tree := get_tree()
	var max_draw := 0
	var max_prims := 0
	var max_objects := 0
	var sum_draw := 0
	var sum_prims := 0
	var frame_times: Array[float] = []
	var max_draw_3d := 0
	var max_prims_3d := 0
	var windows := _windows()
	var max_canvas := {}
	for key: String in windows:
		max_canvas[key] = 0
	var last := Time.get_ticks_usec()
	var start := last
	for i in frames:
		await tree.process_frame
		var now := Time.get_ticks_usec()
		frame_times.append((now - last) / 1000.0)
		last = now
		var d := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		var p := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		var o := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
		var d3 := 0
		var p3 := 0
		for v: CadView in CadView.rendering_views(tree):
			var vrid := v.viewport.get_viewport_rid()
			d3 += RenderingServer.viewport_get_render_info(vrid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
			p3 += RenderingServer.viewport_get_render_info(vrid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
		for key: String in windows:
			var wrid := (windows[key] as Window).get_viewport_rid()
			max_canvas[key] = maxi(max_canvas[key], RenderingServer.viewport_get_render_info(wrid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME))
		max_draw_3d = maxi(max_draw_3d, d3)
		max_prims_3d = maxi(max_prims_3d, p3)
		max_draw = maxi(max_draw, d)
		max_prims = maxi(max_prims, p)
		max_objects = maxi(max_objects, o)
		sum_draw += d
		sum_prims += p
	var elapsed_s := (Time.get_ticks_usec() - start) / 1_000_000.0
	frame_times.sort()
	var per_view := {}
	var views := _views()
	for key: String in views:
		var rid := (views[key] as CadView).viewport.get_viewport_rid()
		per_view[key] = {
			"draw_calls": RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
			"primitives": RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME),
			"objects": RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME),
			"scaling_3d_scale": (views[key] as CadView).viewport.scaling_3d_scale,
		}
	return {
		"frames": frames,
		"fps": frames / maxf(elapsed_s, 1e-6),
		"frame_ms_p50": frame_times[frame_times.size() / 2],
		"frame_ms_p95": frame_times[int(frame_times.size() * 0.95)],
		"max_draw_calls": max_draw,
		"max_primitives": max_prims,
		"max_objects": max_objects,
		"max_draw_calls_3d": max_draw_3d,
		"max_canvas_draw_calls": max_canvas,
		"max_primitives_3d": max_prims_3d,
		"avg_draw_calls": float(sum_draw) / frames,
		"avg_primitives": float(sum_prims) / frames,
		"per_view": per_view,
		"max_fps_setting": Engine.max_fps,
		"renderer": RenderingServer.get_current_rendering_driver_name(),
		"adapter": RenderingServer.get_video_adapter_name(),
	}


static func _object_counts() -> Dictionary:
	return {
		"static_memory": Performance.get_monitor(Performance.MEMORY_STATIC),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"orphan_nodes": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"video_memory": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
	}


func _soak(seconds: float, sample_s: float) -> Dictionary:
	var tree := get_tree()
	var t0 := Time.get_ticks_msec()
	var next := 0.0
	var samples: Array = []
	var phases := {}
	var nt_states := {}
	var frames := 0
	var reconnects_before := int(NT.diagnostics().get("reconnects", 0))
	var worst_frame_ms := 0.0
	var last_us := Time.get_ticks_usec()
	var quit_file := str(args.get("quit_file", ""))
	var preview_loops := 0
	var last_preview_t := Autos.clock.t
	while true:
		await tree.process_frame
		frames += 1
		var now_us := Time.get_ticks_usec()
		if frames > 1:
			worst_frame_ms = maxf(worst_frame_ms, (now_us - last_us) / 1000.0)
		last_us = now_us
		var el := (Time.get_ticks_msec() - t0) / 1000.0
		phases[MatchEnums.PHASE_NAMES[Match.model.phase]] = true
		nt_states[NT.client.state_name()] = true
		if Autos.clock.t < last_preview_t - 1.0:
			preview_loops += 1
		last_preview_t = Autos.clock.t
		if el >= next:
			var row := _object_counts()
			row["t"] = el
			row["fps"] = Engine.get_frames_per_second()
			row["nt"] = NT.client.state_name()
			row["phase"] = MatchEnums.PHASE_NAMES[Match.model.phase]
			row["preview_t"] = Autos.clock.t
			samples.append(row)
			next += sample_s
		if el >= seconds or (quit_file != "" and frames % 30 == 0 and FileAccess.file_exists(quit_file)):
			break
	return {"seconds": (Time.get_ticks_msec() - t0) / 1000.0, "frames": frames, "samples": samples, "phases": phases.keys(), "nt_states": nt_states.keys(),
		"reconnects": int(NT.diagnostics().get("reconnects", 0)) - reconnects_before, "worst_frame_ms": worst_frame_ms,
		"preview_loops": preview_loops}


## Mesh RIDs of every robot instance, per node name; shared = all identical.
func robot_mesh_report() -> Dictionary:
	var lists: Array = []
	for v: CadView in _views().values():
		var ids := {}
		for mi in v.robot.mesh_instances():
			ids[String(mi.name)] = mi.mesh.get_rid().get_id()
		lists.append(ids)
	var shared := lists.size() > 0
	for l: Dictionary in lists:
		if l != lists[0] or l.is_empty():
			shared = false
	return {"instances": lists, "shared": shared}


func _design_size(window_key: String) -> Vector2:
	var w: Window = _windows()[window_key]
	return Vector2(w.content_scale_size)


func _to_image(window_key: String, canvas: Vector2, img: Image) -> Vector2:
	return canvas * Vector2(img.get_size()) / _design_size(window_key)


## Image-pixel positions of the robot and its joint anchors in every view.
func _anchor_positions(images: Dictionary) -> Dictionary:
	var out := {}
	var views := _views()
	for key: String in views:
		if not images.has(key):
			continue
		var v: CadView = views[key]
		var pts := {}
		var robot_c: Variant = v.project_to_canvas(v.robot.global_position + Vector3(0, 0.25, 0))
		if robot_c != null:
			var p := _to_image(key, robot_c, images[key])
			pts["robot"] = [p.x, p.y]
		if v.robot.rig != null:
			for n: String in ["TurretRControl", "IndexWristRControl", "ClimberControlInner", "BumperPlane"]:
				var node: Node3D = v.robot.rig.nodes.get(n)
				if node == null:
					continue
				var c: Variant = v.project_to_canvas(node.global_position)
				if c != null:
					var p := _to_image(key, c, images[key])
					pts[n] = [p.x, p.y]
		out[key] = pts
	return out


func _evaluate_probes(images: Dictionary) -> Array:
	var probes: Array = fixture.get("probes", []).duplicate()
	if args.has("probes"):
		var extra: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(args["probes"])))
		if typeof(extra) == TYPE_ARRAY:
			probes.append_array(extra)
	var results: Array = []
	var anchors: Dictionary = report.get("anchors", {})
	for pr: Dictionary in probes:
		var key := str(pr.get("window", "hud"))
		var name := str(pr.get("name", "probe"))
		if not images.has(key):
			results.append({"name": name, "skipped": "no %s window in this --screen mode" % key})
			continue
		var img: Image = images[key]
		var rect := _probe_rect(pr, key, img, anchors.get(key, {}))
		if rect.size.x <= 0:
			results.append({"name": name, "pass": false, "error": "anchor not visible"})
			_failures.append("probe %s: anchor %s not visible" % [name, pr.get("at")])
			continue
		if str(pr.get("kind", "")) == "mean_luma":
			var luma := _mean_luma(img, rect)
			var lo := float(pr.get("min", 0.0))
			var hi := float(pr.get("max", 1.0))
			var luma_ok := luma >= lo and luma <= hi
			results.append({"name": name, "pass": luma_ok, "mean_luma": luma, "rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y]})
			if not luma_ok:
				_failures.append("probe %s: mean luma %.4f outside [%.4f, %.4f]" % [name, luma, lo, hi])
			continue
		var fraction := _match_fraction(img, rect, pr)
		var min_fraction := float(pr.get("min_fraction", 0.02))
		var max_fraction := float(pr.get("max_fraction", 1.0))
		var ok := fraction >= min_fraction and fraction <= max_fraction
		results.append({"name": name, "pass": ok, "fraction": fraction, "rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y]})
		if not ok:
			_failures.append("probe %s: fraction %.4f outside [%.4f, %.4f]" % [name, fraction, min_fraction, max_fraction])
	return results


func _probe_rect(pr: Dictionary, key: String, img: Image, anchors: Dictionary) -> Rect2i:
	var at: Variant = pr.get("at", [0, 0, 0, 0])
	var scale := Vector2(img.get_size()) / _design_size(key)
	var r: Rect2
	if typeof(at) == TYPE_ARRAY:
		r = Rect2(Vector2(at[0], at[1]) * scale, Vector2(at[2], at[3]) * scale)
	else:
		var anchor_name := str(at).trim_prefix("node:")
		if not anchors.has(anchor_name):
			return Rect2i()
		var c := Vector2(anchors[anchor_name][0], anchors[anchor_name][1])
		var half := Vector2.ONE * float(pr.get("half", 40)) * scale
		r = Rect2(c - half, half * 2.0)
	return Rect2i(r).intersection(Rect2i(Vector2i.ZERO, img.get_size()))


static func _mean_luma(img: Image, rect: Rect2i) -> float:
	var sum := 0.0
	var total := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			sum += img.get_pixel(x, y).get_luminance()
			total += 1
	return sum / maxf(1.0, total)


static func _match_fraction(img: Image, rect: Rect2i, pr: Dictionary) -> float:
	var kind := str(pr.get("kind", "nonblack"))
	var tol := float(pr.get("tol", 0.1))
	var want := Color(str(pr.get("color", "#000000")))
	var hue := str(pr.get("hue", "red"))
	var hits := 0
	var total := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := img.get_pixel(x, y)
			total += 1
			match kind:
				"nonblack":
					if maxf(c.r, maxf(c.g, c.b)) > 0.08:
						hits += 1
				"color":
					if absf(c.r - want.r) <= tol and absf(c.g - want.g) <= tol and absf(c.b - want.b) <= tol:
						hits += 1
				"hue":
					if is_hue(c, hue):
						hits += 1
	return float(hits) / maxf(1.0, total)


static func is_hue(c: Color, hue: String) -> bool:
	match hue:
		"red":
			return c.r > 0.3 and c.r > c.g * 2.0 and c.r > c.b * 2.0
		"blue":
			return c.b > 0.3 and c.b > c.r * 2.0 and c.b > c.g * 2.0
		"green":
			return c.g > 0.3 and c.g > c.r * 1.5 and c.g > c.b * 1.5
	return false
