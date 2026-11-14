class_name Robot3DTab
extends Control

## Robot3DTab.tsx: an orbit view plus a 208 px column of joint debug sliders.
## A joint follows NT while its topic is live (slider disabled, "NT live") and
## the slider otherwise ("Manual fallback"). Manual values live in Telemetry,
## in memory only. Topics are shown without the AdvantageKit outputs prefix.

const COL_W := 240.0
const TOPIC_PREFIX := "/AdvantageKit/RealOutputs/"

var telemetry: TelemetryService
var nt: NtService
var view: RobotOrbitView
var rows := {}


func _ready() -> void:
	if telemetry == null:
		telemetry = get_node_or_null("/root/Telemetry") as TelemetryService
	if nt == null:
		nt = get_node_or_null("/root/NT") as NtService
	var row := UiKit.hbox(8)
	view = RobotOrbitView.new()
	view.name = "Robot3DView"
	view.cam.idle_return = false
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(view)

	var side := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.4)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(12)
	side.add_theme_stylebox_override("panel", sb)
	side.custom_minimum_size.x = COL_W
	var scroll := UiKit.vscroll()
	var col := UiKit.vbox(12)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UiKit.label("Joints", 20, 600))
	col.add_child(UiKit.wrapped("Live robot values while NT has them, these sliders otherwise.", 12))
	for j in telemetry.rig.joints:
		if j.link_source != "" or j.debug_label == "":
			continue
		col.add_child(_joint_row(j))
	var reset_all := PwButton.new("Reset all", PwButton.Style.OUTLINE, Vector2(0, 40))
	reset_all.name = "ResetAll"
	reset_all.font_size = 18
	reset_all.pressed.connect(reset_all_joints)
	col.add_child(reset_all)
	scroll.add_child(col)
	side.add_child(scroll)
	row.add_child(side)
	add_child(UiKit.margin(row, 8, 8, 8, 8))
	(get_child(0) as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _joint_row(j: RigSolver.Joint) -> Control:
	var box := UiKit.vbox(4)
	box.name = "Joint_" + j.key
	var slider := PwSlider.new().configure({"label": j.debug_label, "label_size": 16, "bar_height": 36.0,
		"min_value": j.min_value, "max_value": j.max_value, "step": j.debug_step, "decimals": 2,
		"value_label": "{v}", "value": float(telemetry.manual_joints.get(j.key, j.default_value))})
	slider.name = "Slider"
	slider.value_changed.connect(func(v: float) -> void: telemetry.manual_joints[j.key] = v)
	box.add_child(slider)
	var line := UiKit.hbox(6)
	var source := UiKit.wrapped("", 11, Tokens.ZINC_500)
	source.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	source.name = "Source"
	source.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(source)
	var reset := PwButton.new("reset", PwButton.Style.OUTLINE, Vector2(56, 28))
	reset.name = "Reset"
	reset.font_size = 13
	reset.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	reset.pressed.connect(reset_joint.bind(j.key))
	line.add_child(reset)
	box.add_child(line)
	rows[j.key] = {"slider": slider, "source": source, "reset": reset, "joint": j}
	return box


func reset_joint(key: String) -> void:
	var j: RigSolver.Joint = rows[key]["joint"]
	telemetry.manual_joints[key] = j.default_value
	if not is_live(key):
		(rows[key]["slider"] as PwSlider).set_value(j.default_value)


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
		var slider: PwSlider = r["slider"]
		slider.disabled = live
		(r["reset"] as PwButton).disabled = live
		if live:
			slider.set_value(float(telemetry.joint_targets.get(key, j.default_value)))
		var text := ("NT live: " if live else "Manual fallback: ") + j.nt_topic.trim_prefix(TOPIC_PREFIX)
		if (r["source"] as Label).text != text:
			(r["source"] as Label).text = text
