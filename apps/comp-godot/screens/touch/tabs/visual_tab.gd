class_name VisualTab
extends Control

## VisualTab.tsx: the settings header with Reset and Save, then 420 px
## columns on a horizontal strip. Edits go to a draft; Save (enabled while the
## draft differs) applies it to every 3D viewport in both windows and persists
## it, Reset restores the defaults at once, and a saved change reloads the
## draft. Rendering keeps the web's Backdrop Blur and Render Scale (Log Depth
## is meaningless here and dropped); Assets reloads the models from disk in
## place of the browser cache refresh. Godot-only settings follow in their own
## columns through the same draft: Performance (MSAA, frame cap, automatic
## quality fallback), Displays (which screen each window takes, re-tile) and
## Diagnostics (touch test, renderer readout).

const BLUR_OPTIONS := [
	{"value": false, "symbol": Sf.TOGGLE_OFF, "hint": "Solid panels (better GPU performance)"},
	{"value": true, "symbol": Sf.TOGGLE_ON, "hint": "Frosted glass blur effect"},
]
const SCALE_HINTS := [
	{"min": 0.0, "text": "0.25x: for struggling hardware"},
	{"min": 0.4, "text": "0.5x: moderate quality loss"},
	{"min": 0.62, "text": "0.75: barely noticeable quality loss"},
	{"min": 0.87, "text": "1: native resolution, full quality"},
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
	{"value": false, "symbol": Sf.TOGGLE_OFF, "hint": "Always the Rendering settings"},
	{"value": true, "symbol": Sf.TOGGLE_ON, "hint": "Below the cap: MSAA off, then lower scale"},
]
const FPS_OPTIONS := [
	{"value": 30, "text": "30", "hint": "30 fps: half the GPU load, both windows"},
	{"value": 60, "text": "60", "hint": "60 fps: smooth motion, both windows"},
]
const VISUAL_KEYS := ["backdrop_blur", "render_scale", "msaa", "fps_cap", "auto_quality"]
const WINDOW_KEYS := ["hud_screen", "touch_screen"]

var settings: SettingsService
var models: ModelsService
var draft := {}
var header: SettingsHeader
var save: PwButton
var reset: PwButton
var blur: PwSelector
var render_scale: PwSlider
var msaa: PwSelector
var fps: PwSelector
var auto_quality: PwSelector
var reload: PwButton
var hud_screen: PwSelector
var touch_screen: PwSelector
var tiling: PwText
var renderer: InfoBox
var _reloading := false
var _diag_t := 0.0


func _ready() -> void:
	if settings == null:
		settings = get_node_or_null("/root/Settings") as SettingsService
	if models == null:
		models = get_node_or_null("/root/Models") as ModelsService
	add_child(UiKit.full(PwRect.new(Tokens.PANEL)))
	var root := UiKit.vbox(0)
	header = SettingsHeader.new("Visual Settings")
	reset = header.add_button(PwButton.new("Reset", PwButton.Style.OUTLINE))
	reset.name = "Reset"
	reset.pressed.connect(_on_reset)
	save = header.add_button(PwButton.new("Save", PwButton.Style.PRIMARY))
	save.name = "Save"
	save.pressed.connect(_on_save)
	root.add_child(header)

	var scroll := UiKit.hscroll(false)
	scroll.name = "VisualScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var cols := UiKit.hbox(0)
	scroll.add_child(cols)
	root.add_child(scroll)
	_load_draft()

	var c1 := UiKit.column("Rendering", false)
	blur = _selector(c1["box"], "BackdropBlur", "Backdrop Blur", BLUR_OPTIONS, "backdrop_blur")
	render_scale = PwSlider.new().configure({"label": "Render Scale", "min_value": 0.0, "max_value": 1.0,
		"snap_points": AppSettings.RENDER_SCALES, "hints": SCALE_HINTS, "value": float(draft["render_scale"])})
	render_scale.name = "RenderScale"
	render_scale.value_changed.connect(func(x: float) -> void: _set_draft("render_scale", x))
	c1["box"].add_child(render_scale)
	cols.add_child(c1["panel"])

	var c2 := UiKit.column("Assets", false)
	var assets := UiKit.vbox(8)
	assets.add_child(PwText.new("Reload the robot and field models from disk, so a new robot CAD is picked up without restarting the dashboard.", 14, 400, Tokens.ZINC_400, 20.0))
	reload = PwButton.new("Reload Models", PwButton.Style.OUTLINE)
	reload.name = "ReloadModels"
	reload.pressed.connect(_reload_models)
	assets.add_child(reload)
	c2["box"].add_child(assets)
	cols.add_child(c2["panel"])

	var c3 := UiKit.column("Performance", false)
	msaa = _selector(c3["box"], "Msaa", "Anti-aliasing (MSAA)", MSAA_OPTIONS, "msaa")
	fps = _selector(c3["box"], "FpsCap", "Frame Cap", FPS_OPTIONS, "fps_cap")
	auto_quality = _selector(c3["box"], "AutoQuality", "Auto Quality", AUTO_QUALITY_OPTIONS, "auto_quality")
	cols.add_child(c3["panel"])

	var c4 := UiKit.column("Displays", false)
	hud_screen = _selector(c4["box"], "HudScreen", "HUD Display", SCREEN_OPTIONS, "hud_screen")
	touch_screen = _selector(c4["box"], "TouchScreen", "Touchscreen Display", SCREEN_OPTIONS, "touch_screen")
	var tile := UiKit.vbox(8)
	tiling = PwText.new("", 14, 400, Tokens.ZINC_400, 20.0)
	tiling.name = "Tiling"
	tile.add_child(tiling)
	var retile := PwButton.new("Re-tile Windows", PwButton.Style.OUTLINE)
	retile.name = "Retile"
	retile.pressed.connect(func() -> void: get_tree().call_group(KioskController.GROUP, "retile"))
	tile.add_child(retile)
	c4["box"].add_child(tile)
	cols.add_child(c4["panel"])

	var c5 := UiKit.column("Diagnostics", false)
	var touch_test := PwButton.new("Touch Test", PwButton.Style.OUTLINE)
	touch_test.name = "TouchTest"
	touch_test.pressed.connect(func() -> void:
		var kiosk := get_tree().get_first_node_in_group(KioskController.GROUP) as KioskController
		if kiosk != null:
			TouchTest.open_all(get_tree(), kiosk.windows))
	c5["box"].add_child(touch_test)
	renderer = InfoBox.new("Renderer", [["driver", "Driver"], ["adapter", "Adapter"], ["fps", "Frame rate"], ["draws", "Draw calls"],
		["views", "3D views"], ["quality", "Effective quality"], ["auto", "Auto quality"], ["nt", "NetworkTables"]])
	renderer.name = "RendererInfo"
	c5["box"].add_child(renderer)
	cols.add_child(c5["panel"])

	add_child(UiKit.full(root))
	settings.changed.connect(_on_changed)
	if models != null:
		models.model_ready.connect(_on_model_ready)
	_refresh_controls()
	_update_diag()


func _selector(parent: Control, node_name: String, caption: String, options: Array, key: String) -> PwSelector:
	var s := PwSelector.new().configure(caption, options, draft[key])
	s.name = node_name
	s.selected.connect(func(x: Variant) -> void: _set_draft(key, x))
	parent.add_child(s)
	return s


func saved() -> Dictionary:
	var out := {}
	var v := settings.visual()
	for k: String in VISUAL_KEYS:
		out[k] = v.get(k, AppSettings.DEFAULT_VISUAL[k])
	var w := settings.windows()
	for k: String in WINDOW_KEYS:
		out[k] = w[k]
	return out


func has_changes() -> bool:
	var s := saved()
	for k: String in s:
		if not _same(s[k], draft.get(k)):
			return true
	return false


static func _same(a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(float(a), float(b))
	return a == b


func _load_draft(keys: Array = VISUAL_KEYS + WINDOW_KEYS) -> void:
	var s := saved()
	for k: String in keys:
		draft[k] = s[k]


func _set_draft(key: String, v: Variant) -> void:
	draft[key] = v
	save.disabled = not has_changes()


func _on_save() -> void:
	if not has_changes():
		return
	var visual := {}
	for k: String in VISUAL_KEYS:
		visual[k] = draft[k]
	var windows := {}
	for k: String in WINDOW_KEYS:
		windows[k] = draft[k]
	settings.set_visual(visual)
	if not _same(windows["hud_screen"], settings.windows()["hud_screen"]) or not _same(windows["touch_screen"], settings.windows()["touch_screen"]):
		settings.set_windows(windows)
	_restart_perf()
	_refresh_controls()


func _on_reset() -> void:
	settings.reset("visual")
	_restart_perf()
	_load_draft(VISUAL_KEYS)
	_refresh_controls()


func _restart_perf() -> void:
	var perf := get_tree().get_first_node_in_group(PerfGovernor.GROUP) as PerfGovernor
	if perf != null:
		perf.restart()


func _on_changed(section: String) -> void:
	if section == "visual":
		_load_draft(VISUAL_KEYS)
	elif section == "windows":
		_load_draft(WINDOW_KEYS)
	else:
		return
	_refresh_controls()


func _refresh_controls() -> void:
	blur.select_value(draft["backdrop_blur"])
	if not render_scale.dragging:
		render_scale.set_value(float(draft["render_scale"]))
	msaa.select_value(draft["msaa"])
	fps.select_value(draft["fps_cap"])
	auto_quality.select_value(draft["auto_quality"])
	hud_screen.select_value(draft["hud_screen"])
	touch_screen.select_value(draft["touch_screen"])
	save.disabled = not has_changes()


func _reload_models() -> void:
	if models == null or _reloading:
		return
	_reloading = true
	reload.text = "Reloading…"
	reload.disabled = true
	models.reload()


func _on_model_ready(_key: String) -> void:
	if _reloading and models.all_ready():
		_reloading = false
		reload.text = "Reload Models"
		reload.disabled = false


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
	var eff := settings.effective_visual()
	renderer.set_value("driver", rs.get_current_rendering_driver_name())
	renderer.set_value("adapter", rs.get_video_adapter_name())
	renderer.set_value("fps", "%d fps (cap %d)" % [Engine.get_frames_per_second(), Engine.max_fps])
	renderer.set_value("draws", "%d, %d primitives" % [rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
	renderer.set_value("views", "%d rendering, %.0f MB video memory" % [CadView.rendering_views(get_tree()).size(),
		rs.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0])
	renderer.set_value("quality", "%sx scale, MSAA %s" % [str(eff["render_scale"]), _msaa_text(int(eff["msaa"]))])
	var perf := get_tree().get_first_node_in_group(PerfGovernor.GROUP) as PerfGovernor
	renderer.set_value("auto", perf.status_text() if perf != null else "--")
	var nt := get_node_or_null("/root/NT") as NtService
	if nt != null:
		var d := nt.diagnostics()
		var rtt := " (%.1f ms)" % (float(d["rtt_us"]) / 1000.0) if d.has("rtt_us") and not nt.fixture_mode and int(d["rtt_us"]) >= 0 else ""
		renderer.set_value("nt", ("fixture" if nt.fixture_mode else nt.client.state_name()) + rtt)


func probe() -> Dictionary:
	return {"draft": draft.duplicate(), "save_enabled": not save.disabled}


static func _msaa_text(m: int) -> String:
	return "off" if m == 0 else "%dx" % m
