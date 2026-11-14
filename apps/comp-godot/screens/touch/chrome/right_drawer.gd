class_name RightDrawer
extends Control

## Right drawer (RightPanel.tsx): 84 px closed, 540 px open, width animated by
## the owner. Content is [44 px icon column] 30 px gap [426 px body] with 20 px
## padding; the body is clipped, so the last panel stays rendered while the
## drawer collapses. 4 px accent edge on the left while it is open. Black at
## 90% over the driver view, solid over an overlay tab.

signal panel_tapped(id: String)

const ICON_TOP := 30.0
const ICON_STRIDE := 96.0

var state: TouchLayoutState
var icons: Array[TabIcon] = []
var body: Control
var panels := {}
var factory: Callable


func _ready() -> void:
	name = "RightDrawer"
	mouse_filter = Control.MOUSE_FILTER_STOP
	for i in TabDefs.PANELS.size():
		var id: String = TabDefs.PANELS[i]
		var it := TabIcon.new(TabDefs.PANEL_INFO[id]["icon"], "", id)
		it.name = "Panel_" + id
		it.position = Vector2(0, ICON_TOP - 24.0 + i * ICON_STRIDE)
		it.size = Vector2(Tokens.RAIL_W, ICON_STRIDE)
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
	refresh()


func set_width(w: float) -> void:
	position = Vector2(Tokens.TOUCH_DESIGN.x - w, 0)
	size = Vector2(w, Tokens.TOUCH_DESIGN.y)
	for it in icons:
		it.position.x = Tokens.DRAWER_PAD + Tokens.DRAWER_ICON_COL * 0.5 - Tokens.RAIL_W * 0.5
	queue_redraw()


func is_expanded() -> bool:
	return size.x > Tokens.RAIL_W + 0.5


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


func _draw() -> void:
	UiDraw.rect(get_canvas_item(), Rect2(Vector2.ZERO, size), Color.BLACK if not state.is_driver_base() else Tokens.SCRIM)
	if is_expanded():
		UiDraw.rect(get_canvas_item(), Rect2(0, 0, Tokens.BORDER, size.y), Tokens.ACCENT)
