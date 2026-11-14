class_name LeftRail
extends Control

## 84 px rail (LeftRail.tsx): driver-base icon on top, the user's tab icons,
## the dock toggle at the bottom. Cells are 75 px (the web 27 px line box plus
## its 48 px gap) and shrink when many tabs are pinned.

signal home_tapped
signal dock_tapped

const PAD_Y := 30.0
const CELL_H := 75.0

var state: TouchLayoutState
var dnd: TouchDnd
var home: TabIcon
var dock_toggle: TabIcon
var items: Array[TabIcon] = []


func _ready() -> void:
	name = "LeftRail"
	mouse_filter = Control.MOUSE_FILTER_STOP
	position = Vector2.ZERO
	size = Vector2(Tokens.RAIL_W, Tokens.TOUCH_DESIGN.y)
	home = TabIcon.new(TabDefs.HOME_ICON)
	home.name = "Home"
	home.tapped.connect(func() -> void: home_tapped.emit())
	add_child(home)
	dock_toggle = TabIcon.new(TabDefs.DOCK_ICON)
	dock_toggle.name = "DockToggle"
	dock_toggle.tapped.connect(func() -> void: dock_tapped.emit())
	add_child(dock_toggle)
	rebuild()


func rebuild() -> void:
	for it in items:
		remove_child(it)
		it.queue_free()
	items.clear()
	for id: String in state.rail:
		var it := TabIcon.new(TabDefs.TAB_INFO[id]["icon"], "rail", id)
		it.dnd = dnd
		add_child(it)
		items.append(it)
	layout()
	refresh()


func cell_height() -> float:
	var avail := size.y - 2.0 * PAD_Y - 2.0 * CELL_H
	return minf(CELL_H, avail / maxf(1.0, items.size()))


func layout() -> void:
	home.position = Vector2(0, PAD_Y)
	home.size = Vector2(size.x, CELL_H)
	var h := cell_height()
	for i in items.size():
		items[i].position = Vector2(0, PAD_Y + CELL_H + i * h)
		items[i].size = Vector2(size.x, h)
	dock_toggle.position = Vector2(0, size.y - PAD_Y - CELL_H)
	dock_toggle.size = Vector2(size.x, CELL_H)


func refresh() -> void:
	home.active = state.is_driver_base()
	dock_toggle.active = state.dock_open and not state.dock_closing
	for it in items:
		it.active = it.tab_id == state.active_tab


func item(id: String) -> TabIcon:
	for it in items:
		if it.tab_id == id:
			return it
	return null


func ids() -> Array:
	return items.map(func(it: TabIcon) -> String: return it.tab_id)


func centers() -> Array:
	return items.map(func(it: TabIcon) -> Vector2: return it.canvas_center())


## Insertion marker while a tab is dragged over the rail: before `before_id`, or after the last item.
var drop_marker := ""
var drop_marker_on := false


func show_drop_marker(on: bool, before_id: String = "") -> void:
	if on == drop_marker_on and before_id == drop_marker:
		return
	drop_marker_on = on
	drop_marker = before_id
	queue_redraw()


func _draw() -> void:
	UiDraw.rect(get_canvas_item(), Rect2(Vector2.ZERO, size), Color.BLACK)
	if not drop_marker_on:
		return
	var y := PAD_Y + CELL_H
	var it := item(drop_marker)
	if it != null:
		y = it.position.y
	elif not items.is_empty():
		y = items[items.size() - 1].position.y + items[items.size() - 1].size.y
	UiDraw.rect(get_canvas_item(), Rect2(14, y - 2, size.x - 28, 4), Tokens.ACCENT)
