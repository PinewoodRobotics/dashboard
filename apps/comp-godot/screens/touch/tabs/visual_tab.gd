class_name VisualTab
extends Control

## Visual settings (VisualTab.tsx, adapted): render scale, MSAA and frame cap
## apply live to every 3D viewport in both windows and persist; models can be
## reloaded from disk; live renderer diagnostics. Displays: which screen each
## window takes (Auto = the exact display size) and a re-tile button, the
## touch equivalent of Ctrl/Cmd+Shift+F. Settings apply live instead
## of through the web draft/Save flow. Log depth and panel blur are dropped.

const SCALE_HINTS := [
	{"min": 0.0, "text": "0.25x: for struggling hardware"},
	{"min": 0.4, "text": "0.5x: moderate quality loss"},
	{"min": 0.62, "text": "0.75x: barely noticeable quality loss"},
	{"min": 0.87, "text": "1x: native resolution, full quality"},
]
const MSAA_OPTIONS := [
	{"value": 0, "text": "Off", "hint": "No anti-aliasing (fastest)"},
	{"value": 2, "text": "2x", "hint": "Smooth edges, light GPU cost"},
	{"value": 4, "text": "4x", "hint": "Smoothest edges, highest GPU cost"},
]
const SCREEN_OPTIONS := [
	{"value": -1, "text": "Auto", "hint": "Auto: the display with the exact size"},
	{"value": 0, "text": "1", "hint": "Display 1"},
	{"value": 1, "text": "2", "hint": "Display 2"},
	{"value": 2, "text": "3", "hint": "Display 3"},
]
const AUTO_QUALITY_OPTIONS := [
	{"value": true, "text": "On", "hint": "Below the cap: MSAA off, then lower scale"},
	{"value": false, "text": "Off", "hint": "Always the Rendering settings"},
]
const FPS_OPTIONS := [
	{"value": 30, "text": "30", "hint": "30 fps: half the GPU load, both windows"},
	{"value": 60, "text": "60", "hint": "60 fps: smooth motion, both windows"},
]

var settings: SettingsService
var models: ModelsService
var render_scale: PwSlider
var msaa: PwSelector
var fps: PwSelector
var auto_quality: PwSelector
var reload: PwButton
var hud_screen: PwSelector
var touch_screen: PwSelector
var tiling: Label
var reload_status: Label
var diag: Label
var _diag_t := 0.0


func _ready() -> void:
	if settings == null:
		settings = get_node_or_null("/root/Settings") as SettingsService
	if models == null:
		models = get_node_or_null("/root/Models") as ModelsService
	var root := UiKit.vbox(0)
	var header := UiKit.hbox(16)
	var title := UiKit.label("Visual Settings", 28, 600)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var reset := PwButton.new("Reset", PwButton.Style.OUTLINE, Vector2(140, 48))
	reset.name = "Reset"
	reset.pressed.connect(func() -> void: settings.reset("visual"))
	header.add_child(reset)
	root.add_child(UiKit.margin(header, 32, 16, 32, 0))

	var scroll := UiKit.hscroll()
	scroll.name = "VisualScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var cols := UiKit.hbox(0)
	scroll.add_child(cols)
	root.add_child(scroll)

	var v := settings.visual()
	var c1 := UiKit.column("Rendering", true, 24, 20)
	render_scale = PwSlider.new().configure({"label": "Render Scale", "min_value": 0.0, "max_value": 1.0, "snap_points": AppSettings.RENDER_SCALES,
		"value_label": "{v}x", "format_value": func(x: float) -> String: return str(x), "hints": SCALE_HINTS, "value": float(v["render_scale"])})
	render_scale.name = "RenderScale"
	render_scale.value_changed.connect(func(x: float) -> void: _set_visual({"render_scale": x}))
	c1["box"].add_child(render_scale)
	msaa = PwSelector.new().configure("Anti-aliasing (MSAA)", MSAA_OPTIONS, v["msaa"])
	msaa.name = "Msaa"
	msaa.selected.connect(func(x: Variant) -> void: _set_visual({"msaa": x}))
	c1["box"].add_child(msaa)

	cols.add_child(c1["panel"])

	var c4 := UiKit.column("Frame Rate", true, 24, 20)
	fps = PwSelector.new().configure("Frame Cap", FPS_OPTIONS, v["fps_cap"])
	fps.name = "FpsCap"
	fps.selected.connect(func(x: Variant) -> void: settings.set_visual({"fps_cap": x}))
	c4["box"].add_child(fps)
	auto_quality = PwSelector.new().configure("Auto Quality", AUTO_QUALITY_OPTIONS, v.get("auto_quality", true))
	auto_quality.name = "AutoQuality"
	auto_quality.selected.connect(func(x: Variant) -> void: _set_visual({"auto_quality": x}))
	c4["box"].add_child(auto_quality)
	cols.add_child(c4["panel"])

	var c2 := UiKit.column("Assets", true, 24, 20)
	c2["box"].add_child(UiKit.wrapped("Robot and field models are bundled with the app. Reload them from disk after replacing the files in assets/models.", 18))
	reload = PwButton.new("Reload Models", PwButton.Style.DARK, Vector2(0, 64))
	reload.name = "ReloadModels"
	reload.icon_name = "refresh-cw"
	reload.pressed.connect(_reload_models)
	c2["box"].add_child(reload)
	reload_status = UiKit.wrapped("", 16)
	c2["box"].add_child(reload_status)
	cols.add_child(c2["panel"])

	var c5 := UiKit.column("Displays", true, 24, 20)
	var w := settings.windows()
	hud_screen = PwSelector.new().configure("HUD Display", SCREEN_OPTIONS, w["hud_screen"])
	hud_screen.name = "HudScreen"
	hud_screen.selected.connect(func(x: Variant) -> void: settings.set_windows({"hud_screen": x}))
	c5["box"].add_child(hud_screen)
	touch_screen = PwSelector.new().configure("Touchscreen Display", SCREEN_OPTIONS, w["touch_screen"])
	touch_screen.name = "TouchScreen"
	touch_screen.selected.connect(func(x: Variant) -> void: settings.set_windows({"touch_screen": x}))
	c5["box"].add_child(touch_screen)
	cols.add_child(c5["panel"])

	var c6 := UiKit.column("Window Tiling", true, 24, 20)
	c6["box"].add_child(UiKit.wrapped("Places both windows on their displays, borderless fullscreen. Same as Ctrl+Shift+F.", 18))
	var retile := PwButton.new("Re-tile Windows", PwButton.Style.DARK, Vector2(0, 64))
	retile.name = "Retile"
	retile.icon_name = "monitor"
	retile.pressed.connect(func() -> void: get_tree().call_group(KioskController.GROUP, "retile"))
	c6["box"].add_child(retile)
	tiling = UiKit.wrapped("", 16)
	c6["box"].add_child(tiling)
	cols.add_child(c6["panel"])

	var c3 := UiKit.column("Diagnostics", false, 24, 20)
	var touch_test := PwButton.new("Touch Test", PwButton.Style.DARK, Vector2(240, 52))
	touch_test.name = "TouchTest"
	touch_test.icon_name = "scan-eye"
	touch_test.font_size = 20
	touch_test.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	touch_test.pressed.connect(func() -> void:
		var kiosk := get_tree().get_first_node_in_group(KioskController.GROUP) as KioskController
		if kiosk != null:
			TouchTest.open_all(get_tree(), kiosk.windows))
	c3["box"].add_child(touch_test)
	diag = UiKit.label("", 16, 400, Tokens.ZINC_300)
	diag.add_theme_font_override("font", Tokens.mono())
	c3["box"].add_child(diag)
	cols.add_child(c3["panel"])

	add_child(UiKit.full(root))
	settings.changed.connect(_on_changed)
	if models != null:
		models.model_ready.connect(_on_model_ready)
	_update_diag()


func _set_visual(patch: Dictionary) -> void:
	settings.set_visual(patch)
	var perf := get_tree().get_first_node_in_group(PerfGovernor.GROUP) as PerfGovernor
	if perf != null:
		perf.restart()


func _on_changed(section: String) -> void:
	if section == "windows":
		hud_screen.select_value(settings.windows()["hud_screen"])
		touch_screen.select_value(settings.windows()["touch_screen"])
	if section != "visual":
		return
	var v := settings.visual()
	if not render_scale.dragging:
		render_scale.set_value(float(v["render_scale"]))
	msaa.select_value(v["msaa"])
	fps.select_value(v["fps_cap"])
	auto_quality.select_value(v.get("auto_quality", true))


func _reload_models() -> void:
	if models == null:
		return
	reload_status.text = "Reloading..."
	models.reload()


func _on_model_ready(key: String) -> void:
	if models.all_ready():
		reload_status.text = "Models loaded (%s)" % ", ".join(models.scenes.keys())


func _process(delta: float) -> void:
	_diag_t += delta
	if _diag_t >= 0.25:
		_diag_t = 0.0
		_update_diag()


func _update_diag() -> void:
	var kiosk := get_tree().get_first_node_in_group(KioskController.GROUP) as KioskController
	if kiosk != null:
		var parts := PackedStringArray(["%d display(s)" % DisplayServer.get_screen_count()])
		for key: String in kiosk.last_plan:
			var p: Dictionary = kiosk.last_plan[key]
			var where := "display %d" % (int(p["screen"]) + 1) if p["mode"] == "fullscreen" else "windowed"
			parts.append("%s: %s (%s)" % ["HUD" if key == "hud" else "Touch", where, p["reason"]])
		tiling.text = "\n".join(parts) if not kiosk.last_plan.is_empty() else "Not tiled yet: windows stay where they opened"
	var rs := RenderingServer
	var lines := PackedStringArray([
		"Renderer   %s" % rs.get_current_rendering_driver_name(),
		"Adapter    %s" % rs.get_video_adapter_name().left(28),
		"FPS        %d (cap %d)" % [Engine.get_frames_per_second(), Engine.max_fps],
		"Draw calls %d" % rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"Primitives %d" % rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"3D views   %d rendering" % CadView.rendering_views(get_tree()).size(),
		"3D scale   %sx, MSAA %s%s" % [str(settings.effective_visual()["render_scale"]), _msaa_text(int(settings.effective_visual()["msaa"])),
			", light models" if settings.effective_visual().get("models", "full") == "lite" else ""],
		"Video mem  %.0f MB" % (rs.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0),
	])
	var perf := get_tree().get_first_node_in_group(PerfGovernor.GROUP) as PerfGovernor
	if perf != null:
		lines.append("Auto qual  %s" % perf.status_text())
	var nt := get_node_or_null("/root/NT") as NtService
	if nt != null:
		var d := nt.diagnostics()
		lines.append("NT         %s" % ("fixture" if nt.fixture_mode else nt.client.state_name()))
		if d.has("rtt_us") and not nt.fixture_mode:
			lines.append("NT RTT     %.1f ms" % (float(d["rtt_us"]) / 1000.0))
	diag.text = "\n".join(lines)


static func _msaa_text(m: int) -> String:
	return "off" if m == 0 else "%dx" % m
