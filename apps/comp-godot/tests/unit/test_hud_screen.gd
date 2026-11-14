extends TestCase

## HUD geometry at 1920x1080 against hud.md section 3, and settings -> minimap.

const P := MatchEnums.Phase

var ms: MatchService
var settings: SettingsService
var hud: HudScreen


func before_each() -> void:
	ms = MatchService.new()
	ms.clock.freeze(10_000_000)
	tree.root.add_child(ms)
	settings = SettingsService.new()
	settings.persist = false
	tree.root.add_child(settings)
	hud = HudScreen.new()
	hud.match_service = ms
	hud.size = HudLayout.DESIGN
	tree.root.add_child(hud)
	hud.minimap.settings_service = settings
	hud.minimap.match_service = ms


func after_each() -> void:
	for n: Node in [hud, settings, ms]:
		if is_instance_valid(n):
			n.queue_free()
	await tree.process_frame


func _feed(values: Dictionary) -> void:
	var now := ms.now_us()
	ms.model.set_nt_ready(true, now)
	for k: String in values:
		ms.model.ingest(k, values[k], now)
	ms.model.step(now)
	hud.refresh()


func _near(a: float, b: float, what: String, tol: float = 2.0) -> void:
	check_near(a, b, tol, what)


func test_geometry_matches_the_web_layout() -> void:
	_feed({"seq": 5, "match_phase": 4, "hub_status": 3, "header_color": 2, "aim_mode": 1, "show_shift_indicator": true, "show_buffer": true,
		"total_time_remaining_s": 83.74, "buffer_remaining_s": 1.74, "shift_time_remaining_s": 23.74})
	var r := hud.layout_report()
	check_eq(r["header"]["rect"], [0.0, 0.0, 1920.0, 180.0], "header 0..180 full width")
	check_eq(r["header"]["color"], "ffd900")
	var box: Array = r["timer"]["box"]
	_near(box[0], 491.0, "timer box left")
	_near(box[2], 938.0, "timer box width")
	check_eq(r["timer"]["sizes"], [128, 64], "timer digit sizes")
	var line: Array = r["timer"]["line"]
	_near(line[0] + line[2] / 2.0, 960.0, "timer centered")
	_near(line[1] + line[3] / 2.0, 90.0, "timer line box centered in the header")
	check_eq(r["timer"]["text"], "01:23.74")
	var block: Array = r["shift"]["block"]
	_near(block[0] + block[2] / 2.0, 960.0, "shift block center x")
	var icon: Array = r["shift"]["icon"]
	check_eq([icon[2], icon[3]], [200.0, 200.0], "200 px icon")
	_near(icon[1] + icon[3] / 2.0, 335.5, "icon centered on y 335.5")
	_near(r["shift"]["baseline"], 406.6, "number baseline on the web line box", 0.5)
	check_eq(r["shift"]["sizes"], [128, 64])
	check_eq(r["shift"]["text"], "00.00", "warning forces 00.00")
	var buf: Array = r["buffer"]["line"]
	_near(buf[0], 975.0, "buffer line x")
	_near(buf[1], 224.0, "buffer line top")
	check_eq(r["buffer"]["text"], "01.74 with buffer")
	check_eq(r["minimap"]["rect"], [540.0, 480.0, 840.0, 619.2], "minimap 540..1380 from y 480 past the bottom edge")


func test_banner_bottom_center() -> void:
	_feed({})
	var r := hud.layout_report()
	check(r["banner"]["visible"])
	var b: Array = r["banner"]["rect"]
	_near(b[0] + b[2] / 2.0, 960.0, "banner centered")
	_near(b[1] + b[3], 1080.0 - 24.0, "banner 24 px from the bottom")
	check_eq(r["banner"]["text"], "No Robot Data")


func test_header_colors_and_visibility() -> void:
	var want := {0: "", 1: "70cd35", 2: "ffd900", 3: "a600ff", 7: ""}
	for v: int in want:
		_feed({"seq": 1, "header_color": v})
		var h: Dictionary = hud.layout_report()["header"]
		if want[v] == "":
			check(not h["visible"], "header_color %d hidden" % v)
		else:
			check(h["visible"] and h["color"] == want[v], "header_color %d -> %s, got %s" % [v, want[v], h["color"]])


func test_shift_indicator_hidden_outside_shift_phases() -> void:
	_feed({"seq": 1, "match_phase": P.ENDGAME, "show_shift_indicator": false, "total_time_remaining_s": 21.0})
	check(not hud.shift.visible and not hud.buffer_line.visible)
	_feed({"seq": 2, "match_phase": P.AUTONOMOUS, "show_shift_indicator": true, "period_time_remaining_s": 7.53})
	check(hud.shift.visible)
	check_eq("".join(hud.shift.digits.texts), "07.53")


func test_timers_dim_without_link() -> void:
	_feed({"seq": 1, "total_time_remaining_s": 50.0})
	check_eq(hud.timer.color, Tokens.TEXT)
	ms.model.set_nt_ready(false, ms.now_us())
	hud.refresh()
	check_eq(hud.timer.color, Tokens.TEXT_DIM)


func test_map_setting_reaches_the_minimap_camera_next_frame() -> void:
	_feed({"seq": 1})
	await tree.process_frame
	await tree.process_frame
	var before := hud.minimap.cam_model.dist
	check_near(before, MinimapCamera.target_dist(0.5), 1e-3)
	var frame := Engine.get_process_frames()
	settings.set_map({"zoom": 1.0, "mode": "driver", "angle": 1.0})
	await tree.process_frame
	check_eq(Engine.get_process_frames() - frame, 1, "one frame later")
	var moved := (before - hud.minimap.cam_model.dist) / (before - 2.0)
	check(moved > 0.0, "camera moves toward zoom 1 on the next frame")
	check(moved <= Smoothing.dt_lerp(MinimapCamera.LERP_SPHERE, 0.1), "a single smoothing step (%.3f)" % moved)
	check_eq(hud.minimap.map_settings()["mode"], "driver")


func test_icons_follow_aim_mode() -> void:
	for aim: int in [0, 1, 2]:
		_feed({"seq": aim + 1, "show_shift_indicator": true, "aim_mode": aim, "match_phase": P.AUTONOMOUS})
		var tex := hud.shift.icon_rect.texture
		check(tex != null and tex.get_width() == 200 and tex.get_height() == 200, "aim %d icon 200 px" % aim)
		var spec: Dictionary = Tokens.AIM_ICONS[aim]
		var img := tex.get_image()
		var hits := 0
		for y in range(0, 200, 4):
			for x in range(0, 200, 4):
				var c := img.get_pixel(x, y)
				if c.a > 0.9 and absf(c.r - spec["color"].r) < 0.02 and absf(c.g - spec["color"].g) < 0.02 and absf(c.b - spec["color"].b) < 0.02:
					hits += 1
		check(hits > 50, "aim %d icon drawn in %s (%d px)" % [aim, spec["color"].to_html(false), hits])
