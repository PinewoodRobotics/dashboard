class_name PwKeyboard
extends Control

## In-app on-screen keyboard for one window: a bottom sheet with a preview of
## the field being edited (the sheet covers the lower part of a 515 px screen),
## a text layout or a numeric keypad. Physical keys work too while it is open.
## Tapping outside the sheet or Done closes it; edits apply live.

signal closed

const KEY_H := 46.0
const KEY_GAP := 6.0
const PAD := 10.0
const HEADER_H := 56.0
const ROWS := [
	["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-"],
	["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "/"],
	["a", "s", "d", "f", "g", "h", "j", "k", "l", ".", ":"],
	["SHIFT", "z", "x", "c", "v", "b", "n", "m", "_", "BKSP"],
	["SPACE", "DONE"],
]
const PAD_ROWS := [
	["1", "2", "3"],
	["4", "5", "6"],
	["7", "8", "9"],
	["CLEAR", "0", "BKSP"],
]

var target: PwTextInput
var numeric := false
var shift := false
var sheet: Control
var _keys: Array = []


static func for_window(node: Node) -> PwKeyboard:
	for kb: Node in node.get_tree().get_nodes_in_group("pw_keyboard"):
		if kb.get_window() == node.get_window():
			return kb
	return null


func _init() -> void:
	add_to_group("pw_keyboard")
	add_to_group("pw_grab")
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sheet = Control.new()
	sheet.name = "Sheet"
	sheet.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(sheet)


func is_open() -> bool:
	return visible and target != null


func open_for(input: PwTextInput) -> void:
	if target != null and target != input:
		target.editing = false
	target = input
	numeric = input.numeric
	shift = false
	input.editing = true
	_build()
	visible = true
	queue_redraw()


func close() -> void:
	if target != null:
		target.editing = false
		target.submit()
	target = null
	visible = false
	closed.emit()


func sheet_rect() -> Rect2:
	var rows := PAD_ROWS.size() if numeric else ROWS.size()
	var h := PAD * 2.0 + HEADER_H + rows * KEY_H + (rows - 1) * KEY_GAP
	var w := 560.0 if numeric else minf(size.x - 40.0, 1200.0)
	return Rect2((size.x - w) * 0.5, size.y - h, w, h)


func _build() -> void:
	for k: Node in _keys:
		sheet.remove_child(k)
		k.queue_free()
	_keys.clear()
	var r := sheet_rect()
	sheet.position = r.position
	sheet.size = r.size
	var rows: Array = PAD_ROWS if numeric else ROWS
	var top := PAD + HEADER_H
	var avail := r.size.x - PAD * 2.0
	if numeric:
		avail -= 130.0
	for ri in rows.size():
		var row: Array = rows[ri]
		var units := 0.0
		for k: String in row:
			units += _units(k)
		var unit_w := (avail - KEY_GAP * (row.size() - 1)) / units
		var x := PAD
		for k: String in row:
			var w := unit_w * _units(k)
			var b := _make_key(k)
			b.position = Vector2(x, top + ri * (KEY_H + KEY_GAP))
			b.size = Vector2(w, KEY_H)
			x += w + KEY_GAP
	if numeric:
		var done := _make_key("DONE")
		done.position = Vector2(r.size.x - PAD - 120.0, top)
		done.size = Vector2(120.0, rows.size() * KEY_H + (rows.size() - 1) * KEY_GAP)


func _units(k: String) -> float:
	match k:
		"SPACE":
			return 8.0
		"DONE":
			return 2.0
		"SHIFT", "BKSP":
			return 1.0 if numeric else 1.5
	return 1.0


## Node name of a key ("." ":" "/" are not allowed in node names).
static func key_name(k: String) -> String:
	return "Key_" + {".": "DOT", ":": "COLON", "/": "SLASH"}.get(k, k)


func _make_key(k: String) -> PwButton:
	var b := PwButton.new(_caption(k), PwButton.Style.PRIMARY if k == "DONE" else PwButton.Style.DARK)
	b.name = key_name(k)
	b.set_meta("key", k)
	b.font_size = 22
	b.radius = 6.0
	match k:
		"BKSP":
			b.text = ""
			b.icon_name = "delete"
		"SHIFT":
			b.text = ""
			b.icon_name = "arrow-big-up"
		"DONE":
			b.icon_name = "corner-down-left"
	b.pressed.connect(press_key.bind(k))
	sheet.add_child(b)
	_keys.append(b)
	return b


func _caption(k: String) -> String:
	match k:
		"SPACE":
			return "space"
		"DONE":
			return "Done"
		"CLEAR":
			return "Clear"
		"BKSP", "SHIFT":
			return ""
	return k.to_upper() if shift else k


func key_button(k: String) -> PwButton:
	return sheet.get_node_or_null(key_name(k)) as PwButton


func press_key(k: String) -> void:
	if target == null:
		return
	match k:
		"BKSP":
			target.backspace()
		"CLEAR":
			target.clear()
		"DONE":
			close()
			return
		"SPACE":
			target.insert(" ")
		"SHIFT":
			shift = not shift
			_refresh_captions()
			return
		_:
			target.insert(k.to_upper() if shift else k)
			if shift:
				shift = false
				_refresh_captions()
	queue_redraw()


func _refresh_captions() -> void:
	for b: PwButton in _keys:
		var k: String = b.get_meta("key")
		if b.icon_name == "":
			b.text = _caption(k)
		if k == "SHIFT":
			b.variant = PwButton.Style.ACCENT if shift else PwButton.Style.DARK


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.UP and not sheet_rect().has_point(p.pos):
		close()
	if p.kind != PointerInput.Kind.NONE:
		accept_event()


func _input(event: InputEvent) -> void:
	if not is_open() or not (event is InputEventKey) or not event.pressed:
		return
	var ke := event as InputEventKey
	match ke.keycode:
		KEY_BACKSPACE:
			target.backspace()
		KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE:
			close()
		_:
			if ke.unicode > 0:
				target.insert(String.chr(ke.unicode))
	queue_redraw()
	get_viewport().set_input_as_handled()


func _draw() -> void:
	if not visible:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55))
	var r := sheet_rect()
	draw_rect(r, Color(0.04, 0.04, 0.04, 0.98))
	draw_rect(Rect2(r.position, Vector2(r.size.x, Tokens.BORDER)), Tokens.ACCENT)
	if target == null:
		return
	var f := Tokens.inter(500)
	draw_string(Tokens.label_font(), r.position + Vector2(PAD + 4.0, PAD + 16.0), target.label.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Tokens.ZINC_400)
	var shown := target.text if target.text != "" else target.placeholder
	draw_string(f, r.position + Vector2(PAD + 4.0, PAD + 46.0), shown, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - PAD * 2.0, 26, Tokens.TEXT if target.text != "" else Tokens.ZINC_500)
