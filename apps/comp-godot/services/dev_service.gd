class_name DevService
extends Node

## Development hooks, inactive unless a flag asks (all after `--`):
##   --fixture=NAME|PATH  res://data/fixtures/NAME.json or a file; NT values are
##                        injected offline (no socket), see the format below
##   --screenshot=PREFIX  save PREFIX_<window>.png for every window, then quit
##   --frames=N           frames to wait once the models are visible (default 30)
##   --perf-frames=N      sample RenderingServer counters over N frames first
##   --report=PATH        JSON report (default PREFIX.json when --screenshot is set)
##   --probes=PATH        extra probes (JSON array) on top of the fixture's
##   --timeout=S          fail when the models are not visible after S seconds (default 20)
##   --quit-after-run     quit after the report even without --screenshot
## The process exits non-zero when a probe fails or the models never appear.
##
## Fixture: {"extends": "base", "nt": {topic: value}, "map": {mode, angle, zoom},
##   "orbit_preset": 0, "camera": {"hud"|"touch": {"position": [x,y,z], "target": [..], "up": [..]}},
##   "probes": [{"name": "..", "window": "hud"|"touch", "at": "robot" | "node:<Name>" | [x, y, w, h],
##     "half": 40, "kind": "hue"|"nonblack"|"color", "hue": "red"|"blue",
##     "color": "#rrggbb", "tol": 0.1, "min_fraction": 0.02}]}
## Rects and "half" are in design pixels of the window (1920x1080 HUD, 1920x515 touch).

const FIXTURE_DIR := "res://data/fixtures"

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


func _ready() -> void:
	dev_ready_msec = Time.get_ticks_msec()
	args = CliArgs.parse(OS.get_cmdline_user_args())
	if args.has("fixture"):
		fixture = load_fixture(str(args["fixture"]))
	RenderingServer.frame_post_draw.connect(_on_first_frame, CONNECT_ONE_SHOT)


func _on_first_frame() -> void:
	first_frame_msec = Time.get_ticks_msec()
	first_frame_unix = Time.get_unix_time_from_system()


func has_fixture() -> bool:
	return not fixture.is_empty()


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
	return out


func _windows() -> Dictionary:
	return _main.get("windows") if _main != null else {}


func _apply_fixture_views() -> void:
	var views := _views()
	if fixture.has("map") and views.has("hud"):
		(views["hud"] as MinimapView).settings.merge(fixture["map"], true)
	var cams: Dictionary = fixture.get("camera", {})
	for key: String in cams:
		if views.has(key):
			var c: Dictionary = cams[key]
			(views[key] as CadView).camera_override = {
				"position": _vec3(c.get("position", [0, 10, 0])),
				"target": _vec3(c.get("target", [0, 0, 0])),
				"up": _vec3(c.get("up", [0, 1, 0])),
			}
	if fixture.has("orbit_preset") and views.has("touch"):
		(views["touch"] as RobotOrbitView).apply_preset(int(fixture["orbit_preset"]))


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
	await RenderingServer.frame_post_draw
	models_visible_msec = Time.get_ticks_msec()

	for i in CliArgs.get_int(args, "frames", 30):
		await tree.process_frame

	var perf_frames := CliArgs.get_int(args, "perf_frames", 0)
	if perf_frames > 0:
		report["perf"] = await _sample_perf(perf_frames)

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
	report["os_windows"] = Array(DisplayServer.get_window_list())
	report["nt"] = {"state": NT.client.state_name(), "fixture_mode": NT.fixture_mode}
	report["anchors"] = _anchor_positions(images)
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
		}
		if prefix != "":
			var png := "%s_%s.png" % [prefix, key]
			var err := img.save_png(png)
			entry["png"] = png
			if err != OK:
				_failures.append("could not save " + png)
		report["windows"][key] = entry
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
		"avg_draw_calls": float(sum_draw) / frames,
		"avg_primitives": float(sum_prims) / frames,
		"per_view": per_view,
		"max_fps_setting": Engine.max_fps,
		"renderer": RenderingServer.get_current_rendering_driver_name(),
		"adapter": RenderingServer.get_video_adapter_name(),
	}


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
