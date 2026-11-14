class_name PlaceholderPanel
extends Control

## RightSideContent.tsx fallback for panels without content yet.

var title := ""


func _init(panel_title: String = "") -> void:
	title = panel_title


func _ready() -> void:
	var col := UiKit.vbox(16)
	col.add_child(UiKit.label(title, 36, 500))
	col.add_child(UiKit.wrapped("Controls coming soon.", 22))
	add_child(UiKit.full(col))
