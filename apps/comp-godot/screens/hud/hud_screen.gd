class_name HudScreen
extends Control

## HUD window content at the 1920x1080 design size: the minimap in its final
## rectangle plus an NT status line.

const MINIMAP_RECT := Rect2(540, 480, 840, 600)

var minimap: MinimapView
var _status: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	minimap = MinimapView.new()
	minimap.name = "Minimap"
	minimap.position = MINIMAP_RECT.position
	minimap.size = MINIMAP_RECT.size
	add_child(minimap)
	_status = Label.new()
	_status.position = Vector2(32, 24)
	_status.add_theme_font_size_override("font_size", 28)
	_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	add_child(_status)


func _process(_delta: float) -> void:
	var nt := get_node_or_null("/root/NT") as NtService
	if nt != null:
		_status.text = "HUD  NT %s  %s:%d" % ["fixture" if nt.fixture_mode else nt.client.state_name(), nt.client.host, nt.client.port]
