class_name IntakePanel
extends Control

## Intake Speed panel (IntakeSpeedPanel.tsx + AimTrimSection.tsx): the intake
## override slider with its status line and Reset, then the aim trim (reversed
## slider, +-10 deg in 0.25 steps), Center, and the ten shooter readouts.

const SPEED_LABEL := "{v} - duty cycle sent to the intake motor"

var controls: ControlsService
var scroll: ScrollContainer
var speed: PwSlider
var speed_status: Label
var reset: PwButton
var trim: PwSlider
var trim_status: Label
var center: PwButton
var readout_values: Array[Label] = []
var readout_labels: Array[Label] = []


func _ready() -> void:
	if controls == null:
		controls = get_node_or_null("/root/Controls") as ControlsService
	var col := UiKit.vbox(20)
	col.add_child(UiKit.label("Intake Speed", 36, 500))
	scroll = UiKit.vscroll()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var body := UiKit.vbox(16)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	speed = PwSlider.new().configure({"label": "Speed", "min_value": 0.0, "max_value": 1.0, "step": 0.01, "decimals": 2,
		"value_label": SPEED_LABEL, "label_size": 22, "value": IntakeSpeed.FALLBACK_SPEED})
	speed.name = "Speed"
	speed.value_changed.connect(func(v: float) -> void:
		if controls != null:
			controls.intake.set_speed(v))
	body.add_child(speed)
	speed_status = UiKit.wrapped("", 16, Tokens.ZINC_400)
	speed_status.name = "SpeedStatus"
	body.add_child(speed_status)
	reset = PwButton.new("Reset", PwButton.Style.OUTLINE, Vector2(0, 48))
	reset.name = "Reset"
	reset.pressed.connect(func() -> void:
		if controls != null:
			controls.intake.reset())
	body.add_child(reset)

	var sep := ColorRect.new()
	sep.color = Tokens.OUTLINE
	sep.custom_minimum_size = Vector2(0, 2)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(sep)

	trim = PwSlider.new().configure({"label": "Aim Trim", "min_value": -AimTrim.LIMIT_DEG, "max_value": AimTrim.LIMIT_DEG,
		"step": AimTrim.STEP_DEG, "reversed": true, "format_value": AimTrim.format, "value_label": "{v}", "value": 0.0})
	trim.name = "AimTrim"
	trim.value_changed.connect(func(v: float) -> void:
		if controls != null:
			controls.trim.set_trim(v))
	body.add_child(trim)
	var captions := UiKit.hbox(4)
	captions.add_child(PwIcon.new("chevron-left", 16, Tokens.ZINC_400))
	var left := UiKit.label("Aim left", 14, 400, Tokens.ZINC_400)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	captions.add_child(left)
	captions.add_child(UiKit.label("Aim right", 14, 400, Tokens.ZINC_400))
	captions.add_child(PwIcon.new("chevron-right", 16, Tokens.ZINC_400))
	body.add_child(captions)
	trim_status = UiKit.wrapped("", 16, Tokens.ZINC_400)
	trim_status.name = "TrimStatus"
	body.add_child(trim_status)
	center = PwButton.new("Center (0°)", PwButton.Style.OUTLINE, Vector2(0, 48))
	center.name = "Center"
	center.pressed.connect(func() -> void:
		if controls != null:
			controls.trim.center())
	body.add_child(center)

	var grid := GridContainer.new()
	grid.name = "Readouts"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 4)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for row: Array in ShooterReadouts.ROWS:
		grid.add_child(_readout_cell(str(row[0])))
	body.add_child(grid)

	scroll.add_child(UiKit.margin(body, 0, 0, 14, 0))
	(scroll.get_child(0) as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	add_child(UiKit.full(col))
	refresh()


func _readout_cell(caption: String) -> Control:
	var cell := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Tokens.HAIRLINE
	sb.border_width_bottom = 1
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	cell.add_theme_stylebox_override("panel", sb)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := UiKit.hbox(8)
	var l := UiKit.label(caption, 14, 400, Tokens.ZINC_400)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var v := UiKit.label(ShooterReadouts.MISSING, 14, 400, Tokens.TEXT)
	v.add_theme_font_override("font", Tokens.mono())
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
