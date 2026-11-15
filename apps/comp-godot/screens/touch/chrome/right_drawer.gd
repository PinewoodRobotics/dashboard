class_name RightDrawer
extends Control

## Right panel (RightPanel.tsx, RightSideContent.tsx, RightIconColumn.tsx):
## 84 px closed, 540 px open, its right edge on `right_edge`, clipped. The
## content is a fixed 540 px row anchored to the left edge, so widening
## reveals it: 20 px padding, the 44 px icon column (27 px buttons 48 px
## apart from 30 px down), 30 px gap, the 426 px body that keeps the last
## panel while the drawer collapses. Over the driver view the background is a
## 4 px backdrop blur under black at 50% (black at 90% with blur off), over a
## tab it is opaque black. Width and the 4 px inset accent edge are CSS
## transitions (200 ms ease) keyed to the open panel. A swipe translates the
## whole panel; a committed swipe closes it with no transition.

signal panel_tapped(id: String)
signal swipe_committed

const BLUR_PX := 4.0
const MOTION_S := 0.2
const ICON_TOP := 30.0
const BUTTON := Vector2(44, 27)
const ICON_PITCH := 75.0
## The swipe's travel: the panel width less the rail-wide strip that stays.
const SWIPE_DIM := Tokens.DRAWER_W - Tokens.RAIL_W

var state: TouchLayoutState
var icons: Array[TabIcon] = []
var body: Control
var panels := {}
var factory: Callable
var right_edge := Tokens.TOUCH_DESIGN.x
var over_driver := true:
	set(v):
		if v != over_driver:
			over_driver = v
			_sync_background()
var backdrop_blur := true:
	set(v):
		if v != backdrop_blur:
			backdrop_blur = v
			_sync_background()
var width := UiAnim.new(Tokens.RAIL_W, true)
var glow := UiAnim.new(0.0, true)
var swipe_dx := UiAnim.new(0.0, true)
var _swiping := false
var _committing := false
var _open := false
var _blur: BackdropBlur


func _ready() -> void:
	name = "RightDrawer"
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_blur = BackdropBlur.new(BLUR_PX)
	_blur.z_index = -1
	add_child(_blur)
	for i in TabDefs.PANELS.size():
		var id: String = TabDefs.PANELS[i]
		var it := TabIcon.new(TabDefs.PANEL_INFO[id], "", id)
		it.name = "Panel_" + id
		it.place(Rect2(Vector2(Tokens.DRAWER_PAD, ICON_TOP + i * ICON_PITCH), BUTTON))
		it.tapped.connect(func() -> void: panel_tapped.emit(id))
		add_child(it)
		icons.append(it)
	body = Control.new()
	body.name = "Body"
	body.clip_contents = true
	body.position = Vector2(Tokens.DRAWER_PAD + Tokens.DRAWER_ICON_COL + Tokens.DRAWER_GAP, Tokens.DRAWER_PAD)
	body.size = Vector2(Tokens.DRAWER_W - body.position.x - Tokens.DRAWER_PAD, Tokens.TOUCH_DESIGN.y - 2 * Tokens.DRAWER_PAD)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(body)
	_sync_background()
	refresh()
	_place()


## Follows the open panel: animated, or at once after a committed swipe.
func set_open(open: bool, instant: bool = false) -> void:
	_open = open
	var w := float(Tokens.DRAWER_W if open else Tokens.RAIL_W)
	if instant:
		width.jump(w)
		glow.jump(1.0 if open else 0.0)
	else:
		width.retarget(w, MOTION_S)
		glow.retarget(1.0 if open else 0.0, MOTION_S)
	_place()


func is_expanded() -> bool:
	return width.value > Tokens.RAIL_W + 0.5


func swipe_active() -> bool:
	return _swiping or _committing or swipe_dx.running


func begin_swipe() -> void:
	_swiping = true


func swipe_to(dx: float) -> void:
	swipe_dx.jump(clampf(dx, 0.0, SWIPE_DIM))
	_place()


func end_swipe(commit: bool) -> void:
	_swiping = false
	_committing = commit
	swipe_dx.start(SWIPE_DIM if commit else 0.0, MOTION_S)


## Width the drawer takes from the screen; the overlay's right inset follows
## it (a swipe sets the inset from the translation, as the web's onProgress).
func occupied_width() -> float:
	if swipe_active():
		return Tokens.DRAWER_W - swipe_dx.value
	return width.value


func step(dt: float) -> void:
	width.step(dt)
	if glow.step(dt) or glow.running:
		queue_redraw()
	if swipe_dx.step(dt) and _committing:
		_committing = false
		swipe_committed.emit()
		swipe_dx.jump(0.0)
	_place()


func _place() -> void:
	var w := width.value
	position = Vector2(right_edge - w + swipe_dx.value, 0)
	size = Vector2(w, Tokens.TOUCH_DESIGN.y)
	if _blur != null:
		_blur.size = size


func refresh() -> void:
	for it in icons:
		it.active = it.tab_id == state.open_panel
	var shown := state.display_panel()
	if shown != "" and not panels.has(shown) and factory.is_valid():
		var p: Control = factory.call(shown)
		p.name = "PanelBody_" + shown
		p.size = body.size
		body.add_child(p)
		panels[shown] = p
	for id: String in panels:
		(panels[id] as Control).visible = id == shown
	queue_redraw()


func panel(id: String) -> Control:
	return panels.get(id)


func _sync_background() -> void:
	if _blur != null:
		_blur.visible = over_driver and backdrop_blur
	queue_redraw()


func _draw() -> void:
	var ci := get_canvas_item()
	var bg := Color.BLACK
	if over_driver:
		bg = Color(0, 0, 0, 0.5) if backdrop_blur else Tokens.SCRIM
	UiDraw.rect(ci, Rect2(Vector2.ZERO, size), bg)
	UiDraw.rect(ci, Rect2(0, 0, Tokens.BORDER, size.y), Color(Tokens.ACCENT, glow.value))
