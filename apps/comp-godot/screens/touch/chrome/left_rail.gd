class_name LeftRail
extends Control

## 84 px rail (LeftRail.tsx), transparent and clipped: 27 px tall, 44 px wide
## buttons 48 px apart from 30 px padding, the driver-base button and the
## user's tabs from the top, the dock toggle at the bottom. Pinned tabs never
## shrink: past five they run under the dock toggle and out of the rail, as on
## the web.

signal home_tapped
signal dock_tapped

const PAD_Y := 30.0
const BUTTON := Vector2(44, 27)
const GAP := 48.0
const PITCH := BUTTON.y + GAP

var state: TouchLayoutState
var dnd: TouchDnd
var home: TabIcon
var dock_toggle: TabIcon
var items: Array[TabIcon] = []


func _ready() -> void:
	name = "LeftRail"
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	size = Vector2(Tokens.RAIL_W, Tokens.TOUCH_DESIGN.y)
	home = TabIcon.new(TabDefs.HOME_INFO)
	home.name = "Home"
	home.tapped.connect(func() -> void: home_tapped.emit())
	add_child(home)
	dock_toggle = TabIcon.new(TabDefs.DOCK_INFO)
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
		var it := TabIcon.new(TabDefs.TAB_INFO[id], "rail", id)
		it.dnd = dnd
		add_child(it)
		items.append(it)
	move_child(dock_toggle, -1)
	layout()
	refresh()


func slot(index: int) -> Rect2:
	return Rect2(Vector2((size.x - BUTTON.x) * 0.5, PAD_Y + PITCH * (index + 1)), BUTTON)


func layout() -> void:
	var x := (size.x - BUTTON.x) * 0.5
	home.place(Rect2(Vector2(x, PAD_Y), BUTTON))
	for i in items.size():
		items[i].place(slot(i))
	dock_toggle.place(Rect2(Vector2(x, size.y - PAD_Y - BUTTON.y), BUTTON))


func refresh() -> void:
	home.active = state.is_driver_base()
	dock_toggle.active = state.dock_open
	for it in items:
		it.active = it.tab_id == state.active_tab


func step(dt: float) -> void:
	for it in items:
		it.step(dt)


func item(id: String) -> TabIcon:
	for it in items:
		if it.tab_id == id:
			return it
	return null


func ids() -> Array:
	return items.map(func(it: TabIcon) -> String: return it.tab_id)


func centers() -> Array:
	return items.map(func(it: TabIcon) -> Vector2: return it.slot_center())


## verticalListSortingStrategy: while `active_id` is dragged over `over_id`,
## every item moves to the slot of its index in the reordered list.
func preview_order(active_id: String, over_id: String) -> void:
	var order := ids()
	var from := order.find(active_id)
	var to := order.find(over_id)
	if from >= 0 and to >= 0:
		order.remove_at(from)
		order.insert(to, active_id)
	for i in items.size():
		var at := order.find(items[i].tab_id) if from >= 0 and to >= 0 else i
		items[i].shift_to(slot(at).position - slot(i).position)
