class_name PwButton
extends Control

## Touch button with tap semantics: it fires on release inside the button
## when the pointer moved less than TAP_SLOP_PX, so a swipe that starts on a
## button never presses it. Styles are the web touchscreen's inline Tailwind
## buttons, square unless the web rounds them:
##   OUTLINE        header Reset/Reconnect (SettingsHeader.tsx, VisualTab.tsx)
##   OUTLINE_BLOCK  panel Reset (MapSettingsPanel.tsx, IntakeSpeedPanel.tsx, AimTrimSection.tsx)
##   PRIMARY        Save
##   DARK           text buttons (HowardTab.tsx, AutoSelector.tsx); `selected` is the green Selected state
##   DIALOG, DIALOG_PRIMARY  the auto sync-conflict dialog
##   PILL           driver camera presets (DriverTab.tsx), round; `selected` is the white active one
##   ACCENT, LIGHT, GHOST  Godot-only controls with no web counterpart

signal pressed

enum Style { DARK, PRIMARY, OUTLINE, ACCENT, LIGHT, GHOST, OUTLINE_BLOCK, DIALOG, DIALOG_PRIMARY, PILL }

const TAP_SLOP_PX := 16.0
const OUTLINE_W := 2
const PILL_PX := 40.0

var text := "":
	set(v):
		text = v
		update_minimum_size()
		queue_redraw()
var variant := Style.DARK:
	set(v):
		variant = v
		update_minimum_size()
		_restyle(false)
## -1 takes the style's web size.
var font_size := -1:
	set(v):
		font_size = v
		update_minimum_size()
		queue_redraw()
var icon_name := "":
	set(v):
		icon_name = v
		update_minimum_size()
		queue_redraw()
var disabled := false:
	set(v):
		disabled = v
		if v:
			_down = false
		_restyle(true)
var selected := false:
	set(v):
		selected = v
		_restyle(true)
var radius := 0.0
var _down := false
var _hover := false
var _start := Vector2.ZERO
var _bg := ColorAnim.new()
var _fg := ColorAnim.new()
var _alpha := UiAnim.new(1.0)
var _glow := UiAnim.new(0.0)


func _init(label: String = "", kind: Style = Style.DARK, min_size: Vector2 = Vector2.ZERO) -> void:
	text = label
	variant = kind
	custom_minimum_size = min_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	_restyle(false)


func is_down() -> bool:
	return _down


func text_px() -> int:
	if font_size > 0:
		return font_size
	match variant:
		Style.OUTLINE, Style.PRIMARY, Style.PILL:
			return 14
		Style.OUTLINE_BLOCK:
			return 20
		Style.DARK:
			return 34
		Style.DIALOG, Style.DIALOG_PRIMARY:
			return 22
	return 24


func text_font() -> Font:
	match variant:
		Style.OUTLINE, Style.OUTLINE_BLOCK, Style.PRIMARY:
			return Tokens.inter(600)
		Style.DARK, Style.DIALOG, Style.DIALOG_PRIMARY:
			return Tokens.inter(400)
	return Tokens.inter(500)


func _padding() -> Vector2:
	match variant:
		Style.PRIMARY:
			return Vector2(32, 0)
		Style.DARK:
			return Vector2(10, 4)
		Style.DIALOG, Style.DIALOG_PRIMARY:
			return Vector2(16, 8)
		Style.PILL:
			return Vector2.ZERO
	return Vector2(24, 0)


func _content_width() -> float:
	var px := text_px()
	var w := text_font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x if text != "" else 0.0
	if icon_name != "":
		w += px + (10.0 if text != "" else 0.0)
	return w


## The style's web height unless the caller fixed a height (Godot-only uses).
func _get_minimum_size() -> Vector2:
	if variant == Style.PILL:
		return Vector2(PILL_PX, PILL_PX)
	var pad := _padding()
	var h := 48.0
	if variant in [Style.DARK, Style.DIALOG, Style.DIALOG_PRIMARY]:
		h = text_px() + pad.y * 2.0
	return Vector2(ceilf(_content_width() + pad.x * 2.0), 0.0 if custom_minimum_size.y > 0.0 else h)


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.NONE:
		return
	if p.kind == PointerInput.Kind.MOVE and not p.is_touch:
		_set_hover(Rect2(Vector2.ZERO, size).has_point(p.pos))
	if disabled:
		return
	match p.kind:
		PointerInput.Kind.DOWN:
			_down = true
			_start = p.pos
			accept_event()
		PointerInput.Kind.MOVE:
			if _down and p.pos.distance_to(_start) > TAP_SLOP_PX:
				_down = false
		PointerInput.Kind.UP:
			var fire := _down and Rect2(Vector2.ZERO, size).has_point(p.pos)
			_down = false
			if fire:
				pressed.emit()
	_restyle(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_set_hover(false)


func _set_hover(on: bool) -> void:
	if on != _hover:
		_hover = on
		_restyle(true)


## Colors, opacity and glow the web shows for the current state, with the
## style's transition: {bg, fg, alpha, glow, s, curve, alpha_s}.
func _look() -> Dictionary:
	var pressing := _down and not disabled
	var look := {"bg": Color.TRANSPARENT, "fg": Tokens.TEXT, "alpha": 0.5 if disabled else 1.0, "glow": 0.0,
		"s": 0.0, "curve": Easing.tailwind, "alpha_s": 0.0}
	match variant:
		Style.OUTLINE:
			look["fg"] = Tokens.ZINC_400
			look["bg"] = Color(1, 1, 1, 0.1) if pressing else (Color(1, 1, 1, 0.05) if _hover else Color(1, 1, 1, 0))
			look["s"] = Tokens.MOTION_TAILWIND_S
		Style.OUTLINE_BLOCK:
			look["fg"] = Tokens.ZINC_400
		Style.PRIMARY:
			look["bg"] = Tokens.ACCENT
			look["fg"] = Color.BLACK
			look["alpha"] = 0.3 if disabled else (0.7 if pressing else 1.0)
			look["alpha_s"] = Tokens.MOTION_TAILWIND_S
		Style.DARK:
			look["bg"] = Tokens.ACCENT if selected else (Tokens.ZINC_800 if pressing else Color.BLACK)
		Style.DIALOG:
			look["bg"] = Color.BLACK
		Style.DIALOG_PRIMARY:
			look["bg"] = Tokens.ACCENT
		Style.PILL:
			look["bg"] = Color.WHITE if selected else Color(1, 1, 1, 0.2 if _hover else 0.1)
			look["fg"] = Color.BLACK if selected else Color(1, 1, 1, 0.6)
			look["glow"] = 1.0 if selected else 0.0
			look["s"] = Tokens.MOTION_OVERLAY_S
			look["alpha_s"] = Tokens.MOTION_OVERLAY_S
		Style.ACCENT:
			look["bg"] = Tokens.SELECTED_FILL
			look["fg"] = Tokens.ACCENT
		Style.GHOST:
			look["bg"] = Color(1, 1, 1, 0.2 if pressing else 0.1)
			look["fg"] = Color(1, 1, 1, 0.6)
		Style.LIGHT:
			look["bg"] = Tokens.ZINC_300 if pressing else Color.WHITE
			look["fg"] = Color.BLACK
	return look


func _restyle(animate: bool) -> void:
	var look := _look()
	var s: float = look["s"] if animate and is_inside_tree() else 0.0
	var a_s: float = look["alpha_s"] if animate and is_inside_tree() else 0.0
	_bg.set_target(look["bg"], s, look["curve"])
	_fg.set_target(look["fg"], s, look["curve"])
	if a_s > 0.0:
		_alpha.retarget(look["alpha"], a_s, look["curve"])
		_glow.retarget(look["glow"], a_s, look["curve"])
	else:
		_alpha.jump(look["alpha"])
		_glow.jump(look["glow"])
	set_process(_animating())
	queue_redraw()


func _animating() -> bool:
	return _bg.running() or _fg.running() or _alpha.running or _glow.running


func _process(delta: float) -> void:
	_bg.step(delta)
	_fg.step(delta)
	_alpha.step(delta)
	_glow.step(delta)
	queue_redraw()
	if not _animating():
		set_process(false)


func _draw() -> void:
	UiDraw.begin(self)
	var ci := get_canvas_item()
	var a := _alpha.value
	var r := Rect2(Vector2.ZERO, size)
	var bg := _bg.value()
	bg.a *= a
	if variant == Style.PILL:
		var glow := Color(1, 1, 1, 0.2 * _glow.value * a)
		var c := r.get_center()
		UiDraw.shadow(ci, Rect2(c + Vector2(-17, -17 + 10), Vector2(34, 34)), 17, 15, glow)
		UiDraw.shadow(ci, Rect2(c + Vector2(-16, -16 + 4), Vector2(32, 32)), 16, 6, glow)
		UiDraw.circle(ci, c, PILL_PX * 0.5, bg)
	else:
		var border := 0
		var border_col := Color.TRANSPARENT
		if variant in [Style.OUTLINE, Style.OUTLINE_BLOCK]:
			border = OUTLINE_W
			border_col = Color(Tokens.OUTLINE, Tokens.OUTLINE.a * a)
		elif variant == Style.ACCENT:
			border = Tokens.BORDER
			border_col = Color(Tokens.ACCENT, a)
		UiDraw.box(ci, r, bg, radius, border, border_col)
	var col := _fg.value()
	col.a *= a
	var px := text_px()
	var font := text_font()
	var x := (size.x - _content_width()) * 0.5
	if icon_name != "":
		var tex := Icons.texture(icon_name, px)
		if tex != null:
			draw_texture(tex, Vector2(x, (size.y - px) * 0.5).round(), col)
		x += px + 10.0
	var baseline := (size.y + font.get_ascent(px) - font.get_descent(px)) * 0.5
	UiDraw.text(self, font, Vector2(x, roundf(baseline)), text, px, col)
