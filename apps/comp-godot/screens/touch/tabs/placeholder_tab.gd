class_name PlaceholderTab
extends Control

## PlaceholderScreen.tsx: "<title> is coming soon™" in SF Pro 48 px, white,
## centered.

const TEXT_PX := 48

var title := ""


func _init(tab_title: String = "") -> void:
	title = tab_title
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func message() -> String:
	return "%s is coming soon™" % title


func _draw() -> void:
	UiDraw.begin(self)
	var f := Sf.font()
	var s := message()
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, TEXT_PX).x
	var c := size * 0.5
	UiDraw.text(self, f, Vector2(c.x - w * 0.5, roundf(c.y + Sf.BASELINE_EM * TEXT_PX)), s, TEXT_PX, Tokens.TEXT)
