class_name PlaceholderPanel
extends Control

## RightSideContent.tsx fallback for panels without content yet: 10 px
## padding, "<label> Settings" in 36 px Inter medium, 16 px below it "Controls
## coming soon." in 14 px zinc-400.

var title := ""


func _init(panel_title: String = "") -> void:
	title = panel_title


func _ready() -> void:
	var col := UiKit.vbox(16)
	col.add_child(UiKit.label(title, 36, 500))
	col.add_child(UiKit.wrapped("Controls coming soon.", Tokens.FONT_TEXT_SM))
	add_child(UiKit.full(UiKit.margin(col, 10, 10, 10, 10)))
