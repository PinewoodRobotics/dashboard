class_name Robot3DTab
extends Control

## Robot3DTab.tsx: 8 px padding and gap, the orbit view in a 12 px rounded box
## of black at 30%, then a 208 px column (black at 40%, 12 px rounded, 12 px
## padding and gap, scrolling) of joint debug controls: label and value,
## the NT topic it follows ("NT live" while the topic is live, the slider is
## then disabled, else "Manual fallback"), the browser range input and a reset
## link, with Reset all at the bottom. Manual values live in Telemetry, in
## memory only.

const COL_W := 208.0
const PAD := 8.0
const RADIUS := 12.0
const COL_PAD := 12

var telemetry: TelemetryService
var nt: NtService
var view: RobotOrbitView
var rows := {}
var _viewport_box: Control
var _side: Control


class ResetLink:
	extends PwText
	signal pressed
	var _down := false

	func _init(label: String) -> void:
		super(label, 10, 400, Color(1, 1, 1, 0.3), 15.0)
		wrap = PwText.Wrap.NONE
		mouse_filter = Control.MOUSE_FILTER_STOP
		size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	func _gui_input(event: InputEvent) -> void:
		var p := PointerInput.from_event(event)
		if p.kind == PointerInput.Kind.MOVE and not p.is_touch:
			color = Color(1, 1, 1, 0.6 if Rect2(Vector2.ZERO, size).has_point(p.pos) else 0.3)
		match p.kind:
			PointerInput.Kind.DOWN:
				_down = true
				accept_event()
			PointerInput.Kind.UP:
				if _down and Rect2(Vector2.ZERO, size).has_point(p.pos):
					pressed.emit()
				_down = false

	func _notification(what: int) -> void:
		super(what)
		if what == NOTIFICATION_MOUSE_EXIT:
			color = Color(1, 1, 1, 0.3)


class ResetAll:
	extends PwButton

	func _look() -> Dictionary:
		var look := super()
		look["bg"] = Color(1, 1, 1, 0.2 if _hover else 0.1)
		look["fg"] = Color(1, 1, 1, 0.6)
		look["s"] = 0.0
		return look

	func text_font() -> Font:
		return Tokens.text_font(400)


func _ready() -> void:
	if telemetry == null:
		telemetry = get_node_or_null("/root/Telemetry") as TelemetryService
	if nt == null:
		nt = get_node_or_null("/root/NT") as NtService
	_viewport_box = _rounded_box(Color(0, 0, 0, 0.3))
	_viewport_box.name = "Viewport"
	add_child(_viewport_box)
	view = RobotOrbitView.new()
	view.name = "Robot3DView"
	view.use_robot_viewer()
	_viewport_box.add_child(UiKit.full(view))
	_viewport_box.add_child(PwCornerMask.new(RADIUS, Color.BLACK))

	_side = _rounded_box(Color(0, 0, 0, 0.4))
	_side.name = "Side"
	add_child(_side)
	var scroll := PwScroll.new(true, false)
	scroll.name = "JointsScroll"
	var col := UiKit.vbox(12)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var heading := PwText.new("JOINTS", 12, 600, Color(1, 1, 1, 0.4), 16.0)
	heading.wrap = PwText.Wrap.NONE
	heading.tracking = 1.2
	col.add_child(heading)
	col.add_child(PwText.new("NT-backed joints use live robot values when connected and fall back to sliders when not.", 10, 400, Color(1, 1, 1, 0.35), 16.0))
	for j in telemetry.rig.joints:
		if j.link_source != "" or j.debug_label == "":
			continue
		col.add_child(_joint_row(j))
	var push := Control.new()
	push.mouse_filter = Control.MOUSE_FILTER_IGNORE
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(push)
	var reset_all := ResetAll.new("Reset all", PwButton.Style.GHOST, Vector2(0, 28))
	reset_all.name = "ResetAll"
	reset_all.font_size = 12
	reset_all.radius = 8.0
	reset_all.pressed.connect(reset_all_joints)
	col.add_child(reset_all)
	scroll.add_child(UiKit.margin(col, COL_PAD, COL_PAD, COL_PAD, COL_PAD))
	(scroll.get_child(0) as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL
	_side.add_child(UiKit.full(scroll))
	resized.connect(_layout)
	_layout()


static func _rounded_box(fill: Color) -> Control:
	var box := Panel.new()
	var sb := PwBox.new()
	sb.bg_color = fill
	sb.corner_radius = int(RADIUS)
	box.add_theme_stylebox_override("panel", sb)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.clip_contents = true
	return box


func _layout() -> void:
	var h := size.y - 2.0 * PAD
	_side.position = Vector2(size.x - PAD - COL_W, PAD)
	_side.size = Vector2(COL_W, h)
	_viewport_box.position = Vector2(PAD, PAD)
	_viewport_box.size = Vector2(maxf(0.0, size.x - 3.0 * PAD - COL_W), h)


func _joint_row(j: RigSolver.Joint) -> Control:
	var box := UiKit.vbox(4)
	box.name = "Joint_" + j.key
	var head := UiKit.hbox(0)
	var label := PwText.new(j.debug_label, 12, 400, Color(1, 1, 1, 0.6), 16.0)
	label.wrap = PwText.Wrap.NONE
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(label)
	var value := PwText.new("", 12, 400, Color(1, 1, 1, 0.6), 16.0)
	value.wrap = PwText.Wrap.NONE
	value.name = "Value"
	head.add_child(value)
	box.add_child(head)
	var source := PwText.new("", 10, 400, Color(1, 1, 1, 0.3), 15.0)
	source.configure({"wrap": PwText.Wrap.NONE, "ellipsis": true})
	source.name = "Source"
	source.visible = j.nt_topic != ""
	box.add_child(source)
	var slider := PwRange.new()
	slider.name = "Slider"
	slider.min_value = j.min_value
	slider.max_value = j.max_value
	slider.step = j.debug_step
	slider.set_value(float(telemetry.manual_joints.get(j.key, j.default_value)))
	slider.value_changed.connect(func(v: float) -> void: telemetry.manual_joints[j.key] = v)
	box.add_child(slider)
	var reset := ResetLink.new("reset")
	reset.name = "Reset"
	reset.pressed.connect(reset_joint.bind(j.key))
	box.add_child(reset)
	rows[j.key] = {"slider": slider, "source": source, "value": value, "reset": reset, "joint": j}
	return box


func reset_joint(key: String) -> void:
	var j: RigSolver.Joint = rows[key]["joint"]
	telemetry.manual_joints[key] = j.default_value
	(rows[key]["slider"] as PwRange).set_value(j.default_value)


func reset_all_joints() -> void:
	for key: String in rows:
		reset_joint(key)


func is_live(key: String) -> bool:
	var j: RigSolver.Joint = rows[key]["joint"]
	return nt != null and j.nt_topic != "" and nt.is_live(j.nt_topic)


func _process(_delta: float) -> void:
	for key: String in rows:
		var r: Dictionary = rows[key]
		var j: RigSolver.Joint = r["joint"]
		var live := is_live(key)
		(r["slider"] as PwRange).disabled = live
		var resolved := float(telemetry.joint_targets.get(key, telemetry.manual_joints.get(key, j.default_value))) if live \
			else float(telemetry.manual_joints.get(key, j.default_value))
		(r["value"] as PwText).text = "%.2f" % resolved
		(r["source"] as PwText).text = ("NT live: " if live else "Manual fallback: ") + j.nt_topic
