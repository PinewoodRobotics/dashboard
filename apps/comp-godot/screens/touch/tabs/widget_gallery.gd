class_name WidgetGallery
extends Control

## Every touchscreen widget on one page, for fixture screenshots and scripted
## input runs (Dev only; not in the tab list).

var slider: PwSlider
var snap_slider: PwSlider
var trim: PwSlider
var selector: PwSelector
var text_selector: PwSelector
var host: PwTextInput
var port: PwTextInput
var button: PwButton
var presses := 0


static func format_trim(deg: float) -> String:
	if absf(deg) < 0.005:
		return "0°"
	return "%s° %s" % [String.num(absf(deg), 2).trim_suffix("0").trim_suffix("0").trim_suffix("."), "L" if deg > 0.0 else "R"]


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Tokens.PANEL
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(UiKit.full(bg))
	var row := UiKit.hbox(48)
	var c1 := UiKit.vbox(24)
	c1.custom_minimum_size.x = 420
	slider = PwSlider.new().configure({"label": "Speed", "min_value": 0.0, "max_value": 1.0, "step": 0.01, "decimals": 2, "value_label": "{v} duty cycle", "value": 0.15})
	slider.name = "Speed"
	c1.add_child(slider)
	snap_slider = PwSlider.new().configure({"label": "Render Scale", "min_value": 0.0, "max_value": 1.0, "snap_points": [0.25, 0.5, 0.75, 1.0], "value_label": "{v}x", "value": 0.5, "hints": VisualTab.SCALE_HINTS})
	snap_slider.name = "Snap"
	c1.add_child(snap_slider)
	trim = PwSlider.new().configure({"label": "Aim Trim", "min_value": -10.0, "max_value": 10.0, "step": 0.25, "reversed": true, "format_value": format_trim, "value_label": "{v}", "value": 2.5})
	trim.name = "Trim"
	c1.add_child(trim)
	row.add_child(c1)
	var c2 := UiKit.vbox(24)
	c2.custom_minimum_size.x = 400
	selector = PwSelector.new().configure("Mode", MapSettingsPanel.MODE_OPTIONS, "follow")
	selector.name = "Mode"
	c2.add_child(selector)
	text_selector = PwSelector.new().configure("Anti-aliasing", VisualTab.MSAA_OPTIONS, 2)
	text_selector.name = "Msaa"
	c2.add_child(text_selector)
	row.add_child(c2)
	var c3 := UiKit.vbox(24)
	c3.custom_minimum_size.x = 420
	host = PwTextInput.new("Robot NT Host / IP", "10.47.65.2")
	host.name = "Host"
	c3.add_child(host)
	port = PwTextInput.new("NT Port", "5810", true)
	port.name = "Port"
	c3.add_child(port)
	var buttons := UiKit.hbox(12)
	button = PwButton.new("Save", PwButton.Style.PRIMARY, Vector2(130, 56))
	button.name = "Save"
	button.pressed.connect(func() -> void: presses += 1)
	buttons.add_child(button)
	buttons.add_child(PwButton.new("Reset", PwButton.Style.OUTLINE, Vector2(130, 56)))
	var dis := PwButton.new("Locked", PwButton.Style.DARK, Vector2(130, 56))
	dis.disabled = true
	buttons.add_child(dis)
	c3.add_child(buttons)
	row.add_child(c3)
	add_child(UiKit.full(UiKit.margin(row, 32, 24, 32, 24)))
