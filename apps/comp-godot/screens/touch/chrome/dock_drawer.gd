class_name DockDrawer
extends Control

## Bottom dock (DockDrawer.tsx): the full ordered tab list in an 860 px panel,
## square, 4 px accent border on the left, right and top, 8 px backdrop blur
## under black at 50% (black at 90% with blur off). Each item is its symbol's
## span, advance wide and 48 px tall, left-aligned 12 px apart from 10 px
## padding, wrapping like flex-wrap. Opening and closing are 100 ms keyframe
## slides from below its `bottom_center` anchor that always start from their
## own first keyframe.

signal close_finished

const BLUR_PX := 8.0
const SLIDE_S := 0.1

var state: TouchLayoutState
var dnd: TouchDnd
var items: Array[TabIcon] = []
var backdrop_blur := true:
	set(v):
		backdrop_blur = v
		if _blur != null:
			_blur.visible = v
		queue_redraw()
var bottom_center := Vector2(Tokens.TOUCH_DESIGN.x * 0.5, Tokens.TOUCH_DESIGN.y)
var t := UiAnim.new(0.0, true)
var _closing := false
var _blur: BackdropBlur


func _ready() -> void:
	name = "Dock"
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_blur = BackdropBlur.new(BLUR_PX)
	_blur.z_index = -1
	_blur.visible = backdrop_blur
	add_child(_blur)
	size = Vector2(Tokens.DOCK_W, panel_height(1))
	rebuild()


static func panel_height(rows: int) -> float:
	return Tokens.BORDER + Tokens.DOCK_PAD * 2.0 + rows * Tokens.ICON + (rows - 1) * Tokens.DOCK_GAP


func content_origin() -> Vector2:
	return Vector2(Tokens.BORDER + Tokens.DOCK_PAD, Tokens.BORDER + Tokens.DOCK_PAD)


func content_width() -> float:
	return Tokens.DOCK_W - 2.0 * (Tokens.BORDER + Tokens.DOCK_PAD)


func rebuild() -> void:
	for it in items:
		remove_child(it)
		it.queue_free()
	items.clear()
	for id: String in state.dock:
		var it := TabIcon.new(TabDefs.TAB_INFO[id], "dock", id)
		it.dnd = dnd
		add_child(it)
		items.append(it)
	refresh()


## Flex-wrap slots for the items' current widths, in item order.
func slots() -> Array[Rect2]:
	var out: Array[Rect2] = []
	var o := content_origin()
	var x := 0.0
	var row := 0
	for it in items:
		var w := it.span_width()
		if x > 0.0 and x + w > content_width():
			x = 0.0
			row += 1
		out.append(Rect2(o + Vector2(x, row * (Tokens.ICON + Tokens.DOCK_GAP)), Vector2(w, Tokens.ICON)))
		x += w + Tokens.DOCK_GAP
	return out


func refresh() -> void:
	for it in items:
		it.active = it.tab_id == state.active_tab
	var s := slots()
	for i in items.size():
		items[i].place(s[i])
	var rows := 1
	if not s.is_empty():
		rows = int(roundf((s[s.size() - 1].position.y - content_origin().y) / (Tokens.ICON + Tokens.DOCK_GAP))) + 1
	size = Vector2(Tokens.DOCK_W, panel_height(rows))
	_blur.size = size
	_place()
	queue_redraw()


func open() -> void:
	_closing = false
	visible = true
	t.play(0.0, 1.0, SLIDE_S)
	_place()


func close() -> void:
	if _closing:
		return
	_closing = true
	t.play(1.0, 0.0, SLIDE_S)
	_place()


func is_closing() -> bool:
	return _closing


func step(dt: float) -> void:
	for it in items:
		it.step(dt)
	if t.step(dt) and _closing:
		_closing = false
		visible = false
		close_finished.emit()
	_place()


func _place() -> void:
	position = Vector2(bottom_center.x - size.x * 0.5, bottom_center.y - size.y * t.value)


func ids() -> Array:
	return items.map(func(it: TabIcon) -> String: return it.tab_id)


func centers() -> Array:
	return items.map(func(it: TabIcon) -> Vector2: return it.slot_center())


func item(id: String) -> TabIcon:
	for it in items:
		if it.tab_id == id:
			return it
	return null


## rectSortingStrategy: while `active_id` is dragged over `over_id`, item i
## takes the rect of index i in the reordered list, translated and scaled
## from its own.
func preview_order(active_id: String, over_id: String) -> void:
	var order := ids()
	var from := order.find(active_id)
	var to := order.find(over_id)
	var s := slots()
	for i in items.size():
		if from < 0 or to < 0:
			items[i].shift_to(Vector2.ZERO)
			continue
		var moved := s.duplicate()
		var r: Rect2 = moved[to]
		moved.remove_at(to)
		moved.insert(from, r)
		var target: Rect2 = moved[i]
		items[i].shift_to(target.position - s[i].position, target.size / s[i].size)


func _draw() -> void:
	var ci := get_canvas_item()
	UiDraw.rect(ci, Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.5) if backdrop_blur else Tokens.SCRIM)
	var b := float(Tokens.BORDER)
	UiDraw.rect(ci, Rect2(0, 0, size.x, b), Tokens.ACCENT)
	UiDraw.rect(ci, Rect2(0, b, b, size.y - b), Tokens.ACCENT)
	UiDraw.rect(ci, Rect2(size.x - b, b, b, size.y - b), Tokens.ACCENT)
