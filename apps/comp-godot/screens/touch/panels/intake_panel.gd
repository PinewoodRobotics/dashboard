class_name IntakePanel
extends DrawerPanel

## Intake Speed panel (IntakeSpeedPanel.tsx + AimTrimSection.tsx): the intake
## override slider with its status line and Reset, then the aim trim section
## under a 2 px rule (reversed slider, +-10 deg in 0.25 steps, Center and the
## ten shooter readouts).

const SPEED_LABEL := "{v} — duty cycle sent to the intake motor"
const STATUS_PX := 14
const STATUS_LINE := 20.0

var controls: ControlsService
var speed: PwSlider
var speed_status: PwText
var reset: PwButton
var trim: PwSlider
var trim_status: PwText
var center: PwButton
var readout_values: Array[PwText] = []
var readout_labels: Array[PwText] = []


func _init() -> void:
	super("Intake Speed")
	scroll.name = "IntakeScroll"


static func status_text() -> PwText:
	return PwText.new("", STATUS_PX, 400, Tokens.ZINC_400, STATUS_LINE)


func _ready() -> void:
	if controls == null:
		controls = get_node_or_null("/root/Controls") as ControlsService
	speed = PwSlider.new().configure({"label": "Speed", "min_value": 0.0, "max_value": 1.0, "step": 0.01, "decimals": 2,
		"value_label": SPEED_LABEL, "value": IntakeSpeed.FALLBACK_SPEED})
	speed.name = "Speed"
	speed.value_changed.connect(func(v: float) -> void:
		if controls != null:
			controls.intake.set_speed(v))
	body.add_child(speed)
	speed_status = status_text()
	speed_status.name = "SpeedStatus"
	body.add_child(speed_status)
	reset = PwButton.new("Reset", PwButton.Style.OUTLINE_BLOCK)
	reset.name = "Reset"
	reset.pressed.connect(func() -> void:
		if controls != null:
			controls.intake.reset())
	body.add_child(reset)
	body.add_child(_aim_trim_section())
	refresh()


func _aim_trim_section() -> Control:
	var section := PanelContainer.new()
	section.name = "AimTrimSection"
	section.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := PwBox.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Tokens.OUTLINE
	sb.border_width_top = 2
	sb.content_margin_top = 2 + 20
	section.add_theme_stylebox_override("panel", sb)
	var col := UiKit.vbox(16)

	var slider_box := UiKit.vbox(4)
	trim = PwSlider.new().configure({"label": "Aim Trim", "min_value": -AimTrim.LIMIT_DEG, "max_value": AimTrim.LIMIT_DEG,
		"step": AimTrim.STEP_DEG, "reversed": true, "format_value": AimTrim.format, "value_label": "{v}", "value": 0.0})
	trim.name = "AimTrim"
	trim.value_changed.connect(func(v: float) -> void:
		if controls != null:
			controls.trim.set_trim(v))
	slider_box.add_child(trim)
	var captions := UiKit.hbox(0)
	captions.add_child(_caption("Aim left", "chevron-left", true))
	var gap := Control.new()
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	captions.add_child(gap)
	captions.add_child(_caption("Aim right", "chevron-right", false))
	slider_box.add_child(captions)
	col.add_child(slider_box)

	trim_status = status_text()
	trim_status.name = "TrimStatus"
	col.add_child(trim_status)
	center = PwButton.new("Center (0°)", PwButton.Style.OUTLINE_BLOCK)
	center.name = "Center"
	center.pressed.connect(func() -> void:
		if controls != null:
			controls.trim.center())
	col.add_child(center)

	var grid := GridContainer.new()
	grid.name = "Readouts"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 4)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for row: Array in ShooterReadouts.ROWS:
		grid.add_child(_readout_cell(str(row[0])))
	col.add_child(grid)
	section.add_child(col)
	return section


static func _caption(text: String, icon: String, icon_first: bool) -> Control:
	var row := UiKit.hbox(4)
	var icon_ctl := PwIcon.new(icon, 16, Tokens.ZINC_400)
	icon_ctl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var label := PwText.new(text, STATUS_PX, 400, Tokens.ZINC_400, STATUS_LINE)
	label.wrap = PwText.Wrap.NONE
	if icon_first:
		row.add_child(icon_ctl)
	row.add_child(label)
	if not icon_first:
		row.add_child(icon_ctl)
	return row


func _readout_cell(caption: String) -> Control:
	var cell := PanelContainer.new()
	var sb := PwBox.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Tokens.HAIRLINE
	sb.border_width_bottom = 1
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2 + 1
	cell.add_theme_stylebox_override("panel", sb)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := UiKit.hbox(8)
	var l := PwText.new(caption, STATUS_PX, 400, Tokens.ZINC_400, STATUS_LINE)
	l.wrap = PwText.Wrap.NONE
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var v := PwText.new(ShooterReadouts.MISSING, STATUS_PX, 400, Tokens.TEXT, STATUS_LINE)
	v.wrap = PwText.Wrap.NONE
	v.font = Tokens.mono()
	v.name = "Value_" + caption.replace(" ", "")
	row.add_child(v)
	cell.add_child(row)
	readout_labels.append(l)
	readout_values.append(v)
	return cell


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		refresh()


func refresh() -> void:
	if controls == null:
		return
	var i := controls.intake
	if not speed.dragging:
		speed.set_value(i.slider_value())
	speed_status.text = i.status()
	var t := controls.trim
	trim.disabled = not t.connected()
	center.disabled = not t.connected()
	if not trim.dragging:
		trim.set_value(t.slider_value())
	trim_status.text = t.status()
	var rows := controls.readouts()
	for k in rows.size():
		readout_values[k].text = rows[k][1]


func probe() -> Dictionary:
	var values := {}
	for k in readout_values.size():
		values[readout_labels[k].text] = readout_values[k].text
	return {
		"speed": speed.value, "speed_status": speed_status.text, "trim": trim.value, "trim_label": trim.formatted(),
		"trim_disabled": trim.disabled, "trim_status": trim_status.text, "center_disabled": center.disabled, "readouts": values,
	}
