class_name DockDrawer
extends Control

## Bottom-center dock (DockDrawer.tsx): the full ordered tab list, 860 px wide,
## 4 px accent border on the left, right and top, black at 90%. Slides up in
## 100 ms; the owner moves it.

var state: TouchLayoutState
var dnd: TouchDnd
var items: Array[TabIcon] = []


func _ready() -> void:
	name = "Dock"
	mouse_filter = Control.MOUSE_FILTER_STOP
	size = Vector2(Tokens.DOCK_W, panel_height())
	rebuild()


static func panel_height() -> float:
	return Tokens.BORDER + Tokens.DOCK_PAD * 2.0 + Tokens.DOCK_CELL


func rebuild() -> void:
	for it in items:
		it.queue_free()
	items.clear()
	var per_row := int((Tokens.DOCK_W - 2 * (Tokens.BORDER + Tokens.DOCK_PAD) + Tokens.DOCK_GAP) / (Tokens.DOCK_CELL + Tokens.DOCK_GAP))
	for i in state.dock.size():
		var id: String = state.dock[i]
		var it := TabIcon.new(TabDefs.TAB_INFO[id]["icon"], "dock", id)
		it.dnd = dnd
		it.size = Vector2(Tokens.DOCK_CELL, Tokens.DOCK_CELL)
		it.position = Vector2(Tokens.BORDER + Tokens.DOCK_PAD + (i % per_row) * (Tokens.DOCK_CELL + Tokens.DOCK_GAP),
			Tokens.BORDER + Tokens.DOCK_PAD + (i / per_row) * (Tokens.DOCK_CELL + Tokens.DOCK_GAP))
		add_child(it)
		items.append(it)
	var rows := maxi(1, ceili(float(items.size()) / per_row))
	size.y = Tokens.BORDER + Tokens.DOCK_PAD * 2.0 + rows * Tokens.DOCK_CELL + (rows - 1) * Tokens.DOCK_GAP
	refresh()


func refresh() -> void:
	for it in items:
		it.active = it.tab_id == state.active_tab


func ids() -> Array:
	return items.map(func(it: TabIcon) -> String: return it.tab_id)


func centers() -> Array:
	return items.map(func(it: TabIcon) -> Vector2: return it.canvas_center())


func item(id: String) -> TabIcon:
	for it in items:
		if it.tab_id == id:
			return it
	return null


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Tokens.SCRIM)
	var b := float(Tokens.BORDER)
	draw_rect(Rect2(0, 0, size.x, b), Tokens.ACCENT)
	draw_rect(Rect2(0, 0, b, size.y), Tokens.ACCENT)
	draw_rect(Rect2(size.x - b, 0, b, size.y), Tokens.ACCENT)
