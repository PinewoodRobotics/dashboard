class_name AutoPreviewPanel
extends PanelContainer

## Auto tab preview: 3D view with mechanism chips, camera toggle, reset-view
## and expand buttons, no-path note and an event feed, then the scrub bar and
## the transport row (play/pause, restart, time, speed, loop, alliance).
## Everything reads and drives the shared clock in Autos, so the HUD mirrors
## exactly what plays here. Leaving the tab pauses playback.

signal expand_toggled(on: bool)

const RED := Color("#dd1111")
const BLUE := Color("#1111dd")
const FEED_S := 1.8

var autos: AutosService
var view: AutoPreviewView
var scrub: AutoScrubBar
var play_button: PwButton
var restart_button: PwButton
var loop_button: PwButton
var alliance_button: AllianceButton
var camera_button: PwButton
var expand_button: PwButton
var reset_view_button: PwButton
var expanded := false
var speed_buttons: Array[PwButton] = []
var time_label: Label
var chips := {}
var no_path: Control
var feed: Label
var feed_box: PanelContainer
var auto_name := ""
var _last_t := 0.0
var _feed_until_ms := 0


class AllianceButton:
	extends PwButton
	var red := true
	var known := false

	func _colors() -> Dictionary:
		var bg := RED if red else BLUE
		return {"bg": bg.darkened(0.25) if is_down() else bg, "border": Color(0, 0, 0, 0), "text": Color.WHITE}


## Over the 3D view, readable on the light carpet as well as the dark sky.
class OverlayButton:
	extends PwButton

	func _colors() -> Dictionary:
		return {"bg": Color(0.16, 0.16, 0.16, 0.92) if is_down() else Color(0.08, 0.08, 0.08, 0.78),
			"border": Color(1, 1, 1, 0.14), "text": Color(1, 1, 1, 0.85)}


class Chip:
	extends PanelContainer
	var icon: PwIcon
	var text: Label
	var color := Color.WHITE
	var on := false
	var _sb := PwBox.new()

	func _init(icon_name: String, label: String, col: Color) -> void:
		color = col
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_sb.set_corner_radius_all(6)
		_sb.set_border_width_all(2)
		_sb.content_margin_left = 8
		_sb.content_margin_right = 10
		_sb.content_margin_top = 3
		_sb.content_margin_bottom = 3
		add_theme_stylebox_override("panel", _sb)
		var row := UiKit.hbox(6)
		icon = PwIcon.new(icon_name, 18, col)
		row.add_child(icon)
		text = UiKit.label(label, 15, 600, col)
		row.add_child(text)
		add_child(row)
		set_on(false)

	func set_on(v: bool) -> void:
		on = v
		_sb.bg_color = Color(color, 0.28) if v else Color(0, 0, 0, 0.55)
		_sb.border_color = color if v else Color(1, 1, 1, 0.12)
		var c := color if v else Tokens.ZINC_500
		icon.color = c
		text.add_theme_color_override("font_color", Color.WHITE if v else c)


func _init() -> void:
	name = "AutoPreview"
	# This box and the 3D view (also z - 1) draw right after the overlay
	# background (z - 2) instead of between the other shapes, which would
	# split their draw call in two; the content goes back to z 0.
	z_index = -1
	var sb := PwBox.new()
	sb.bg_color = Tokens.ZINC_950
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	if autos == null:
		autos = get_node_or_null("/root/Autos") as AutosService
	var col := UiKit.vbox(6)
	col.z_index = 1
	add_child(col)

	var stage := Control.new()
	stage.name = "Stage"
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(stage)
	view = AutoPreviewView.new()
	view.name = "PreviewView"
	view.z_index = -1
	view.autos = autos
	stage.add_child(UiKit.full(view))

	var chip_row := UiKit.hbox(6)
	chip_row.position = Vector2(8, 8)
	chips["aim"] = Chip.new("crosshair", "Aim", AutoPathOverlay.KIND_COLORS[AutoMechanisms.Kind.AIM])
	chips["shooter"] = Chip.new("zap", "Shooter", AutoPathOverlay.KIND_COLORS[AutoMechanisms.Kind.SHOOTER])
	chips["intake"] = Chip.new("arrow-down-to-line", "Intake", AutoPathOverlay.KIND_COLORS[AutoMechanisms.Kind.INTAKE])
	for k: String in ["aim", "shooter", "intake"]:
		chips[k].name = "Chip_" + k
		chip_row.add_child(chips[k])
	stage.add_child(chip_row)

	camera_button = OverlayButton.new("Path", PwButton.Style.GHOST, Vector2(108, 40))
	camera_button.name = "CameraMode"
	camera_button.icon_name = "route"
	camera_button.font_size = 18
	camera_button.pressed.connect(_toggle_camera)
	_top_right(camera_button, 64, 108)
	stage.add_child(camera_button)

	expand_button = OverlayButton.new("", PwButton.Style.GHOST, Vector2(48, 40))
	expand_button.name = "Expand"
	expand_button.icon_name = "maximize-2"
	expand_button.font_size = 20
	expand_button.pressed.connect(func() -> void: expand_toggled.emit(not expanded))
	_top_right(expand_button, 8, 48)
	stage.add_child(expand_button)

	reset_view_button = OverlayButton.new("", PwButton.Style.GHOST, Vector2(48, 40))
	reset_view_button.name = "ResetView"
	reset_view_button.icon_name = "locate-fixed"
	reset_view_button.font_size = 20
	reset_view_button.pressed.connect(func() -> void: view.reset_view())
	_top_right(reset_view_button, 180, 48)
	reset_view_button.visible = false
	stage.add_child(reset_view_button)

	no_path = PanelContainer.new()
	no_path.name = "NoPath"
	var np_sb := PwBox.new()
	np_sb.bg_color = Color(0, 0, 0, 0.72)
	np_sb.set_corner_radius_all(8)
	np_sb.set_content_margin_all(12)
	no_path.add_theme_stylebox_override("panel", np_sb)
	no_path.mouse_filter = Control.MOUSE_FILTER_IGNORE
	no_path.add_child(UiKit.label("No path: the robot stays where it starts. Its commands still run.", 18, 500, Tokens.ZINC_300))
	stage.add_child(no_path)

	feed_box = PanelContainer.new()
	feed_box.name = "FeedBox"
	var fb_sb := PwBox.new()
	fb_sb.bg_color = Color(0, 0, 0, 0.75)
	fb_sb.set_corner_radius_all(6)
	fb_sb.content_margin_left = 10
	fb_sb.content_margin_right = 10
	fb_sb.content_margin_top = 4
	fb_sb.content_margin_bottom = 4
	feed_box.add_theme_stylebox_override("panel", fb_sb)
	feed_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feed_box.position = Vector2(8, 52)
	feed = UiKit.label("", 17, 600)
	feed.name = "Feed"
	feed_box.add_child(feed)
	feed_box.visible = false
	stage.add_child(feed_box)
	stage.resized.connect(_place_stage_overlays.bind(stage))

	scrub = AutoScrubBar.new()
	scrub.name = "Scrub"
	scrub.clock = autos.clock if autos != null else null
	col.add_child(scrub)

	var row := UiKit.hbox(8)
	row.name = "Transport"
	play_button = _button("PlayPause", "", "play", Vector2(60, 48), PwButton.Style.PRIMARY)
	play_button.pressed.connect(func() -> void: autos.clock.toggle())
	row.add_child(play_button)
	restart_button = _button("Restart", "", "skip-back", Vector2(52, 48))
	restart_button.pressed.connect(func() -> void: autos.clock.seek(0.0))
	row.add_child(restart_button)
	time_label = UiKit.label("00.00 / 00.00 s", 20, 500, Tokens.ZINC_300)
	time_label.name = "Time"
	time_label.add_theme_font_override("font", Tokens.inter_tabular(500))
	time_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(time_label)
	for s in AutoClock.SPEEDS:
		var b := _button("Speed_%s" % str(s).replace(".", "_"), speed_text(s), "", Vector2(58, 48))
		b.pressed.connect(func() -> void: autos.clock.set_speed(s))
		speed_buttons.append(b)
		row.add_child(b)
	loop_button = _button("Loop", "", "repeat", Vector2(52, 48))
	loop_button.pressed.connect(func() -> void: autos.clock.set_loop(not autos.clock.loop))
	row.add_child(loop_button)
	alliance_button = AllianceButton.new("Red", PwButton.Style.DARK, Vector2(104, 48))
	alliance_button.name = "Alliance"
	alliance_button.font_size = 18
	alliance_button.pressed.connect(func() -> void: autos.toggle_manual_alliance())
	row.add_child(alliance_button)
	col.add_child(row)
	refresh()


static func _top_right(c: Control, right: float, w: float) -> void:
	c.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	c.offset_left = -right - w
	c.offset_right = -right
	c.offset_top = 8
	c.offset_bottom = 48


func set_expanded_icon(on: bool) -> void:
	expanded = on
	expand_button.icon_name = "minimize-2" if on else "maximize-2"
	expand_button.queue_redraw()


func _button(n: String, text: String, icon: String, min_size: Vector2, style: PwButton.Style = PwButton.Style.DARK) -> PwButton:
	var b := PwButton.new(text, style, min_size)
	b.name = n
	b.icon_name = icon
	b.font_size = 22 if text == "" else 20
	b.radius = 6.0
	return b


static func speed_text(s: float) -> String:
	return ("%.1fx" % s) if s < 1.0 else ("%dx" % int(s))


func _place_stage_overlays(stage: Control) -> void:
	no_path.reset_size()
	no_path.position = Vector2(roundf((stage.size.x - no_path.size.x) * 0.5), stage.size.y - no_path.size.y - 10.0)


func _toggle_camera() -> void:
	set_camera(view.camera_mode == AutoPreviewView.CameraMode.PATH)


func set_camera(field: bool) -> void:
	view.set_camera_mode(AutoPreviewView.CameraMode.FIELD if field else AutoPreviewView.CameraMode.PATH)
	view.reset_view()
	camera_button.text = "Field" if field else "Path"
	camera_button.icon_name = "map" if field else "route"


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_EXIT_TREE:
		if autos != null and (what == NOTIFICATION_EXIT_TREE or not is_visible_in_tree()):
			autos.clock.pause()
			autos.clock.end_scrub()


func show_auto(n: String) -> void:
	auto_name = n
	if autos == null:
		return
	if autos.preview_name != n:
		autos.set_preview(n)
	var m := autos.preview_mechanisms()
	scrub.set_auto(m)
	no_path.visible = m != null and not m.playback.has_path()
	_last_t = autos.clock.t
	_feed_until_ms = 0
	feed.text = ""
	feed_box.visible = false
	refresh()


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		refresh()


func refresh() -> void:
	if autos == null or play_button == null:
		return
	var c := autos.clock
	play_button.icon_name = "pause" if c.playing else "play"
	play_button.queue_redraw()
	time_label.text = "%05.2f / %05.2f s" % [c.t, c.duration]
	for i in speed_buttons.size():
		var on := is_equal_approx(AutoClock.SPEEDS[i], c.speed)
		speed_buttons[i].variant = PwButton.Style.ACCENT if on else PwButton.Style.DARK
	loop_button.variant = PwButton.Style.ACCENT if c.loop else PwButton.Style.DARK
	var red := autos.alliance_red()
	var known := autos.alliance_known()
	if alliance_button.red != red or alliance_button.known != known:
		alliance_button.red = red
		alliance_button.known = known
		alliance_button.text = "Red" if red else "Blue"
		alliance_button.icon_name = "lock" if known else ""
		alliance_button.disabled = known
	reset_view_button.visible = view.user_moved()
	var f := autos.frame
	chips["aim"].set_on(not f.is_empty() and f["aim"])
	chips["aim"].text.text = "Aim · default cmd" if not f.is_empty() and f["aim_source"] == "default" else "Aim"
	chips["shooter"].set_on(not f.is_empty() and f["shooter"])
	chips["intake"].set_on(not f.is_empty() and f["rollers"])
	_update_feed(c)


func _update_feed(c: AutoClock) -> void:
	var m := autos.preview_mechanisms()
	if m != null and c.playing and not c.scrubbing and c.t > _last_t:
		var started := m.items_started(_last_t, c.t)
		if not started.is_empty():
			var it: Dictionary = started.back()
			feed.text = AutoScrubBar.short_name(it["name"]) + ("  ·  " + it["note"] if it["note"] != "" else "")
			feed.add_theme_color_override("font_color", AutoPathOverlay.kind_color(it).lightened(0.35))
			feed_box.reset_size()
			_feed_until_ms = Time.get_ticks_msec() + int(FEED_S * 1000.0)
	_last_t = c.t
	feed_box.visible = Time.get_ticks_msec() < _feed_until_ms


func probe() -> Dictionary:
	var out := {"auto": auto_name, "no_path": no_path.visible, "time": time_label.text, "feed": feed.text if feed_box.visible else "",
		"play_icon": play_button.icon_name, "camera": camera_button.text, "alliance_button": alliance_button.text,
		"alliance_enabled": not alliance_button.disabled, "chips": {}, "scrub": scrub.report(), "rendering": view.is_rendering(),
		"expanded": expanded, "view_size": [view.size.x, view.size.y], "view_camera": view.camera_report(), "reset_view": reset_view_button.visible}
	for k: String in chips:
		out["chips"][k] = chips[k].on
	var m := autos.preview_mechanisms() if autos != null else null
	if m != null and view.robot != null:
		var p := m.pose_at(autos.clock.t, autos.alliance())
		var want := FieldFrame.robot_transform(p.x, p.y, p.z)
		out["robot_error_m"] = view.robot.transform.origin.distance_to(want.origin)
		out["robot_yaw_error"] = absf(angle_difference(view.robot.transform.basis.get_euler().y, want.basis.get_euler().y))
	return out
