class_name AutoPreviewPanel
extends Control

## The Auto tab's preview box (PathDetailPane.tsx: rounded-md bg-zinc-950,
## overflow hidden), holding the realtime 3D preview in place of the web's
## GIF. "Loading preview..." shows until the models are in, then the scene
## fades in over 150 ms like the GIF. Everything the 3D preview adds stays
## inside the box: mechanism chips, the start pose check, the auto's notes, a
## camera toggle and reset-view and expand buttons over the scene, then the
## scrub bar and the transport row (play/pause, restart, time, speed, loop,
## alliance) along its bottom. Everything reads and drives the shared clock
## in Autos, so the HUD mirrors exactly what plays here. Leaving the tab
## pauses playback.

signal expand_toggled(on: bool)

const RED := Color("#dd1111")
const BLUE := Color("#1111dd")
const FEED_S := 1.8
const RADIUS := 6.0
const AMBER := Color("#fbbf24")
## Narrower than this (the drawer is open), the speed buttons step aside.
const SPEEDS_MIN_W := 480.0

var autos: AutosService
var models: ModelsService
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
var time_label: PwText
var chips := {}
var no_path: Control
var feed: PwText
var feed_box: PanelContainer
var start_chip: StartChip
var warning: Note
var robot_line: Note
var loading: PwText
var stage: Control
var mask: PwCornerMask
var auto_name := ""
var _last_t := 0.0
var _feed_until_ms := 0
var _fade := UiAnim.new(1.0)
var _was_loading := false


class AllianceButton:
	extends PwButton
	var red := true
	var known := false

	func _look() -> Dictionary:
		var look := super()
		var bg := RED if red else BLUE
		look["bg"] = bg.darkened(0.25) if is_down() else bg
		look["fg"] = Color.WHITE
		return look


## Over the 3D view, readable on the light carpet as well as the dark sky.
class OverlayButton:
	extends PwButton

	func _look() -> Dictionary:
		var look := super()
		look["bg"] = Color(0.16, 0.16, 0.16, 0.92) if is_down() else Color(0.08, 0.08, 0.08, 0.78)
		look["fg"] = Color(1, 1, 1, 0.85)
		return look


## A square label on black at 72% over the scene.
class Note:
	extends PanelContainer
	var icon: PwIcon
	var text: PwText

	func _init(icon_name: String, col: Color, px: int = 16) -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		var sb := PwBox.new()
		sb.bg_color = Color(0, 0, 0, 0.72)
		sb.content_margin_left = 8
		sb.content_margin_right = 10
		sb.content_margin_top = 2
		sb.content_margin_bottom = 2
		add_theme_stylebox_override("panel", sb)
		var row := UiKit.hbox(6)
		if icon_name != "":
			icon = PwIcon.new(icon_name, px, col)
			icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(icon)
		text = PwText.new("", px, 500, col, px * 1.5)
		row.add_child(text)
		add_child(row)

	func show_text(s: String) -> void:
		visible = s != ""
		if text.text != s:
			text.text = s
			fit()

	## Shrinks to the text, wrapping it only where the stage is too narrow.
	func fit() -> void:
		var parent := get_parent() as Control
		if parent == null:
			return
		var icon_w := (icon.custom_minimum_size.x + 6.0) if icon != null else 0.0
		var avail := parent.size.x - 18.0 - icon_w
		text.custom_minimum_size.x = minf(ceilf(text._natural_width()), maxf(avail, 40.0))


class StartChip:
	extends Note
	var level := -1

	func _init() -> void:
		super("crosshair", AMBER)
		name = "StartChip"

	func show_check(c: Dictionary) -> void:
		visible = not c.is_empty()
		if not visible:
			level = -1
			return
		level = c["level"]
		var col := HudScreen.StartChip.color_for(level)
		icon.color = col
		icon.icon_name = "circle-check" if level == StartPoseCheck.Level.OK else "crosshair"
		text.color = col
		text.text = StartPoseCheck.text(c)


class Chip:
	extends PanelContainer
	var icon: PwIcon
	var text: PwText
	var color := Color.WHITE
	var on := false
	var _sb := PwBox.new()

	func _init(icon_name: String, label: String, col: Color) -> void:
		color = col
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_sb.set_border_width_all(2)
		_sb.content_margin_left = 8
		_sb.content_margin_right = 10
		_sb.content_margin_top = 3
		_sb.content_margin_bottom = 3
		add_theme_stylebox_override("panel", _sb)
		var row := UiKit.hbox(6)
		icon = PwIcon.new(icon_name, 16, col)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(icon)
		text = PwText.new(label, 14, 600, col, 20.0)
		text.wrap = PwText.Wrap.NONE
		row.add_child(text)
		add_child(row)
		set_on(false)

	func set_on(v: bool) -> void:
		on = v
		_sb.bg_color = Color(color, 0.28) if v else Color(0, 0, 0, 0.55)
		_sb.border_color = color if v else Color(1, 1, 1, 0.12)
		var c := color if v else Tokens.ZINC_500
		icon.color = c
		text.color = Color.WHITE if v else c


func _init() -> void:
	name = "AutoPreview"
	# This box and the 3D view (also z - 1) draw right after the overlay
	# background (z - 2) instead of between the other shapes, which would
	# split their draw call in two; the content goes back to z 0.
	z_index = -1
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	UiDraw.box(get_canvas_item(), Rect2(Vector2.ZERO, size), Tokens.ZINC_950, RADIUS)


func _ready() -> void:
	if autos == null:
		autos = get_node_or_null("/root/Autos") as AutosService
	if models == null:
		models = get_node_or_null("/root/Models") as ModelsService
	var col := UiKit.vbox(0)
	col.z_index = 1
	add_child(UiKit.full(col))

	stage = Control.new()
	stage.name = "Stage"
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(stage)
	view = AutoPreviewView.new()
	view.name = "PreviewView"
	view.z_index = -1
	view.autos = autos
	stage.add_child(UiKit.full(view))

	var top_left := UiKit.vbox(6)
	top_left.position = Vector2(8, 8)
	var chip_row := UiKit.hbox(6)
	chips["aim"] = Chip.new("crosshair", "Aim", AutoPathOverlay.KIND_COLORS[AutoMechanisms.Kind.AIM])
	chips["shooter"] = Chip.new("zap", "Shooter", AutoPathOverlay.KIND_COLORS[AutoMechanisms.Kind.SHOOTER])
	chips["intake"] = Chip.new("arrow-down-to-line", "Intake", AutoPathOverlay.KIND_COLORS[AutoMechanisms.Kind.INTAKE])
	for k: String in ["aim", "shooter", "intake"]:
		chips[k].name = "Chip_" + k
		chip_row.add_child(chips[k])
	top_left.add_child(chip_row)
	start_chip = StartChip.new()
	start_chip.visible = false
	top_left.add_child(start_chip)
	feed_box = PanelContainer.new()
	feed_box.name = "FeedBox"
	var fb_sb := PwBox.new()
	fb_sb.bg_color = Color(0, 0, 0, 0.75)
	fb_sb.content_margin_left = 10
	fb_sb.content_margin_right = 10
	fb_sb.content_margin_top = 2
	fb_sb.content_margin_bottom = 2
	feed_box.add_theme_stylebox_override("panel", fb_sb)
	feed_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feed_box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	feed = PwText.new("", 16, 600, Tokens.TEXT, 24.0)
	feed.wrap = PwText.Wrap.NONE
	feed.name = "Feed"
	feed_box.add_child(feed)
	feed_box.visible = false
	top_left.add_child(feed_box)
	stage.add_child(top_left)

	camera_button = OverlayButton.new("Path", PwButton.Style.GHOST, Vector2(96, 40))
	camera_button.name = "CameraMode"
	camera_button.icon_name = "route"
	camera_button.font_size = 16
	camera_button.pressed.connect(_toggle_camera)
	_top_right(camera_button, 56, 96)
	stage.add_child(camera_button)

	expand_button = OverlayButton.new("", PwButton.Style.GHOST, Vector2(40, 40))
	expand_button.name = "Expand"
	expand_button.icon_name = "maximize-2"
	expand_button.font_size = 20
	expand_button.pressed.connect(func() -> void: expand_toggled.emit(not expanded))
	_top_right(expand_button, 8, 40)
	stage.add_child(expand_button)

	reset_view_button = OverlayButton.new("", PwButton.Style.GHOST, Vector2(40, 40))
	reset_view_button.name = "ResetView"
	reset_view_button.icon_name = "locate-fixed"
	reset_view_button.font_size = 20
	reset_view_button.pressed.connect(func() -> void: view.reset_view())
	_top_right(reset_view_button, 160, 40)
	reset_view_button.visible = false
	stage.add_child(reset_view_button)

	var notes := UiKit.vbox(6)
	notes.name = "Notes"
	notes.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	notes.grow_vertical = Control.GROW_DIRECTION_BEGIN
	notes.offset_left = 8
	notes.offset_right = -8
	notes.offset_bottom = -8
	notes.offset_top = -8
	notes.resized.connect(func() -> void:
		for n in notes.get_children():
			(n as Note).fit())
	warning = Note.new("triangle-alert", AMBER)
	warning.name = "Warning"
	warning.visible = false
	notes.add_child(warning)
	no_path = Note.new("", Tokens.ZINC_300)
	no_path.name = "NoPath"
	(no_path as Note).show_text("No path: the robot stays where it starts. Its commands still run.")
	notes.add_child(no_path)
	robot_line = Note.new("", Tokens.ZINC_400)
	robot_line.name = "RobotLine"
	notes.add_child(robot_line)
	stage.add_child(notes)

	loading = PwText.new("Loading preview...", 34, 400, Tokens.ZINC_500)
	loading.align = HORIZONTAL_ALIGNMENT_CENTER
	loading.name = "Loading"
	loading.visible = false
	add_child(loading)

	var controls := UiKit.vbox(6)
	controls.name = "Controls"
	scrub = AutoScrubBar.new()
	scrub.name = "Scrub"
	scrub.clock = autos.clock if autos != null else null
	controls.add_child(scrub)

	var row := UiKit.hbox(6)
	row.name = "Transport"
	play_button = _button("PlayPause", "", "play", Vector2(48, 40), PwButton.Style.PRIMARY)
	play_button.pressed.connect(func() -> void: autos.clock.toggle())
	row.add_child(play_button)
	restart_button = _button("Restart", "", "skip-back", Vector2(44, 40))
	restart_button.pressed.connect(func() -> void: autos.clock.seek(0.0))
	row.add_child(restart_button)
	time_label = PwText.new("00.00 / 00.00 s", 16, 500, Tokens.ZINC_300, 24.0)
	time_label.configure({"wrap": PwText.Wrap.NONE, "ellipsis": true, "font": Tokens.text_font(500, true)})
	time_label.name = "Time"
	time_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(time_label)
	for s in AutoClock.SPEEDS:
		var b := _button("Speed_%s" % str(s).replace(".", "_"), speed_text(s), "", Vector2(48, 40))
		b.pressed.connect(func() -> void: autos.clock.set_speed(s))
		speed_buttons.append(b)
		row.add_child(b)
	loop_button = _button("Loop", "", "repeat", Vector2(44, 40))
	loop_button.pressed.connect(func() -> void: autos.clock.set_loop(not autos.clock.loop))
	row.add_child(loop_button)
	alliance_button = AllianceButton.new("Red", PwButton.Style.DARK, Vector2(80, 40))
	alliance_button.name = "Alliance"
	alliance_button.font_size = 16
	alliance_button.pressed.connect(func() -> void: autos.toggle_manual_alliance())
	row.add_child(alliance_button)
	controls.add_child(row)
	col.add_child(UiKit.margin(controls, 8, 6, 8, 8))

	mask = PwCornerMask.new(RADIUS, Tokens.PANEL)
	mask.z_index = 2
	add_child(mask)
	resized.connect(_on_resized)
	refresh()


static func _top_right(c: Control, right: float, w: float) -> void:
	c.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	c.offset_left = -right - w
	c.offset_right = -right
	c.offset_top = 8
	c.offset_bottom = 48


## Expanded, the scrub bar goes compact and moves into the transport row so
## the 3D view gets the height.
func set_expanded_icon(on: bool) -> void:
	expanded = on
	expand_button.icon_name = "minimize-2" if on else "maximize-2"
	expand_button.queue_redraw()
	var row := time_label.get_parent()
	var col := row.get_parent()
	scrub.get_parent().remove_child(scrub)
	if on:
		row.add_child(scrub)
		row.move_child(scrub, time_label.get_index() + 1)
	else:
		col.add_child(scrub)
		col.move_child(scrub, row.get_index())
	scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scrub.size_flags_vertical = Control.SIZE_SHRINK_CENTER if on else Control.SIZE_FILL
	time_label.size_flags_horizontal = Control.SIZE_FILL if on else Control.SIZE_EXPAND_FILL
	scrub.set_compact(on)


func _on_resized() -> void:
	var lh := loading.get_combined_minimum_size().y
	loading.position = Vector2(0, (size.y - lh) * 0.5)
	loading.size = Vector2(size.x, lh)
	var wide := size.x >= SPEEDS_MIN_W
	for b in speed_buttons:
		b.visible = wide
	queue_redraw()


## The robot's view of the auto, a warning about it and the start pose
## check, shown over the scene.
func set_notes(robot: String, warning_text: String, check: Dictionary) -> void:
	robot_line.show_text(robot)
	warning.show_text(warning_text)
	start_chip.show_check(check)


func _button(n: String, text: String, icon: String, min_size: Vector2, style: PwButton.Style = PwButton.Style.DARK) -> PwButton:
	var b := PwButton.new(text, style, min_size)
	b.name = n
	b.icon_name = icon
	b.font_size = 20 if text == "" else 16
	return b


static func speed_text(s: float) -> String:
	return ("%.1fx" % s) if s < 1.0 else ("%dx" % int(s))


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


func _process(delta: float) -> void:
	if is_visible_in_tree():
		refresh()
		_step_loading(delta)


func is_loading() -> bool:
	return models != null and not models.all_ready()


## The scene stays hidden while the models load, then fades in over 150 ms
## (the GIF's transition-opacity).
func _step_loading(delta: float) -> void:
	var now := is_loading()
	if now != _was_loading:
		_was_loading = now
		if now:
			_fade.jump(0.0)
		else:
			_fade.start(1.0, Tokens.MOTION_TAILWIND_S, Easing.tailwind)
	loading.visible = now
	_fade.step(delta)
	stage.modulate.a = _fade.value


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
			feed.color = AutoPathOverlay.kind_color(it).lightened(0.35)
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
	out["loading"] = loading.visible
	var m := autos.preview_mechanisms() if autos != null else null
	if m != null and view.robot != null:
		var p := m.pose_at(autos.clock.t, autos.alliance())
		var want := FieldFrame.robot_transform(p.x, p.y, p.z)
		out["robot_error_m"] = view.robot.transform.origin.distance_to(want.origin)
		out["robot_yaw_error"] = absf(angle_difference(view.robot.transform.basis.get_euler().y, want.basis.get_euler().y))
	return out
