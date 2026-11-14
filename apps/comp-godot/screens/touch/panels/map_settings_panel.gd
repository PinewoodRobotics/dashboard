class_name MapSettingsPanel
extends Control

## MapSettingsPanel.tsx: writes Settings.map immediately; the HUD minimap
## reads the same dictionary every frame, so it follows with no restart.

const MODE_OPTIONS := [
	{"value": "driver", "icon": "user", "hint": "Camera is aligned to the driver station"},
	{"value": "follow", "icon": "locate-fixed", "hint": "Camera orbits to follow robot rotation"},
]
const ANGLE_HINTS := [
	{"min": 0.0, "text": "Camera is close to the ground"},
	{"min": 0.1, "text": "Standard third person camera view"},
	{"min": 0.5, "text": "Camera view from up high"},
	{"min": 0.9, "text": "Top down camera view"},
]
const ZOOM_HINTS := [
	{"min": 0.0, "text": "Zoomed out to field width (best in driver aligned camera)"},
	{"min": 0.2, "text": "Moderate camera distance from robot"},
	{"min": 0.6, "text": "Close camera distance to robot"},
]

var settings: SettingsService
var mode: PwSelector
var angle: PwSlider
var zoom: PwSlider
var reset: PwButton
var scroll: PwScroll


func _ready() -> void:
	if settings == null:
		settings = get_node_or_null("/root/Settings") as SettingsService
	var col := UiKit.vbox(20)
	col.add_child(UiKit.label("Map Settings", 36, 500))
	scroll = UiKit.vscroll()
	scroll.name = "MapScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var body := UiKit.vbox(20)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var m := settings.map()
	mode = PwSelector.new().configure("Mode", MODE_OPTIONS, m["mode"])
	mode.name = "Mode"
	mode.selected.connect(func(v: Variant) -> void: settings.set_map({"mode": v}))
	body.add_child(mode)
	angle = PwSlider.new().configure({"label": "Angle", "min_value": 0.0, "max_value": 1.0, "step": 0.01, "decimals": 2, "value_label": "{v}", "hints": ANGLE_HINTS, "value": float(m["angle"])})
	angle.name = "Angle"
	angle.value_changed.connect(func(v: float) -> void: settings.set_map({"angle": v}))
	body.add_child(angle)
	zoom = PwSlider.new().configure({"label": "Zoom", "min_value": 0.0, "max_value": 1.0, "step": 0.01, "decimals": 2, "value_label": "{v}", "hints": ZOOM_HINTS, "value": float(m["zoom"])})
	zoom.name = "Zoom"
	zoom.value_changed.connect(func(v: float) -> void: settings.set_map({"zoom": v}))
	body.add_child(zoom)
	reset = PwButton.new("Reset", PwButton.Style.OUTLINE, Vector2(0, 48))
	reset.name = "Reset"
	reset.pressed.connect(func() -> void: settings.reset("map"))
	body.add_child(reset)
	scroll.add_child(UiKit.margin(body, 0, 0, 14, 0))
	(scroll.get_child(0) as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	add_child(UiKit.full(col))
	settings.changed.connect(_on_changed)


func _on_changed(section: String) -> void:
	if section != "map":
		return
	var m := settings.map()
	mode.select_value(m["mode"])
	if not angle.dragging:
		angle.set_value(float(m["angle"]))
	if not zoom.dragging:
		zoom.set_value(float(m["zoom"]))
