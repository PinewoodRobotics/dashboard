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
	var heading := PwText.new(title, 36, 500, Tokens.TEXT, PwText.NORMAL)
	col.add_child(heading)
	col.add_child(PwText.new("Controls coming soon.", 14, 400, Tokens.ZINC_400, 20.0))
	add_child(UiKit.full(UiKit.margin(col, 10, 10, 10, 10)))
