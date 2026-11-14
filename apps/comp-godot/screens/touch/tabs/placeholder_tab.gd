class_name PlaceholderTab
extends Control

## PlaceholderScreen.tsx: one centered 48 px line.

var text := ""


func _init(message: String = "") -> void:
	text = message


func _ready() -> void:
	var l := UiKit.label(text, 48, 500, Tokens.ZINC_400)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(UiKit.full(l))
