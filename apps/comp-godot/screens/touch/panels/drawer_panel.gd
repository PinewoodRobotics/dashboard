class_name DrawerPanel
extends Control

## The frame of a right-drawer panel (MapSettingsPanel.tsx,
## IntakeSpeedPanel.tsx): 16 px padding, the title in 36 px Inter medium on
## the font's own line height, and 16 px below it a colScroll column (5 px bar,
## 10 px right padding before it) whose children sit 20 px apart.

const PAD := 16
const TITLE_GAP := 16
const GAP := 20
const SCROLL_PAD_RIGHT := 10

var title: PwText
var scroll: PwScroll
var body: VBoxContainer


func _init(title_text: String = "") -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := UiKit.vbox(TITLE_GAP)
	title = PwText.new(title_text, 36, 500, Tokens.TEXT, PwText.NORMAL)
	title.wrap = PwText.Wrap.NONE
	title.name = "Title"
	col.add_child(title)
	scroll = UiKit.vscroll()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body = UiKit.vbox(GAP)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var m := UiKit.margin(body, 0, 0, SCROLL_PAD_RIGHT, 0)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(m)
	col.add_child(scroll)
	add_child(UiKit.full(UiKit.margin(col, PAD, PAD, PAD, PAD)))
