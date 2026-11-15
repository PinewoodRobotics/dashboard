class_name TouchDnd
extends Node

## Rail/dock editor drags (useTouchscreenDnd.ts on dnd-kit). A press on a rail
## or dock item becomes a tap or, through DragGate, a drag. The ghost is the
## source's box moved by the pointer's travel since the press; the item under
## it is the closest slot center of every rail and dock item to the ghost's
## center (closestCenter over all sortables, wherever the pointer is). Items of
## the source's own list make room while it hovers (the sortable strategies),
## the lists change through DndRules on release, and the ghost then glides
## onto the source's new slot. Positions are canvas (design) coordinates.

signal tab_tapped(id: String)

var state: TouchLayoutState
var rail: LeftRail
var dock: DockDrawer
var ghost: DragGhost
var gate := DragGate.new()
var source: TabIcon
var clock := Callable(PointerInput, "now_ms")
var last_target := {}
## Rail items outside edit mode: taps only, a moving press is cancelled.
var _tap_only := false
var _source_rect := Rect2()
var _landing: Dictionary = {}


func _ready() -> void:
	set_process(false)


func press(item: TabIcon, pos: Vector2, is_touch: bool) -> void:
	source = item
	_tap_only = not state.can_drag(item.zone)
	gate.begin(pos, clock.call(), is_touch)
	set_process(not _tap_only)


func move(pos: Vector2) -> void:
	if source == null:
		return
	if _tap_only:
		if pos.distance_to(gate.start_pos) > PwButton.TAP_SLOP_PX:
			gate.state = DragGate.State.CANCELLED
		return
	var was := gate.is_dragging()
	gate.move(pos, clock.call())
	if gate.is_dragging() and not was:
		_start_drag()
	if gate.is_dragging():
		_track(pos)


func release(pos: Vector2) -> void:
	if source == null:
		return
	var item := source
	var s := gate.end()
	if s == DragGate.State.DRAGGING:
		_track(pos)
	source = null
	set_process(false)
	if s == DragGate.State.DRAGGING:
		var target := last_target
		_clear_preview()
		item.faded = false
		drop(item.zone, item.tab_id, target)
		_land(item.zone, item.tab_id)
	elif s == DragGate.State.PENDING:
		tab_tapped.emit(item.tab_id)


func cancel() -> void:
	if source != null:
		source.faded = false
	source = null
	gate.end()
	_clear_preview()
	ghost.hide_now()
	_finish_landing()
	set_process(false)


func is_dragging() -> bool:
	return source != null and gate.is_dragging()


func _process(_delta: float) -> void:
	if source == null or _tap_only:
		set_process(false)
		return
	var was := gate.is_dragging()
	gate.tick(clock.call())
	if gate.is_dragging() and not was:
		_start_drag()


func _start_drag() -> void:
	_finish_landing()
	ghost.hide_now()
	source.faded = true
	_source_rect = source.slot_rect()
	ghost.show_rect(source.symbol, _source_rect)
	last_target = {"zone": source.zone, "id": source.tab_id}


func ghost_rect(pos: Vector2) -> Rect2:
	return Rect2(_source_rect.position + pos - gate.start_pos, _source_rect.size)


func _track(pos: Vector2) -> void:
	var r := ghost_rect(pos)
	ghost.move_to(r.position)
	last_target = target_at(r.get_center())
	var same := str(last_target["zone"]) == source_zone()
	var over := str(last_target["id"]) if same else ""
	if source_zone() == "rail":
		rail.preview_order(_source_id(), over)
	elif source_zone() == "dock":
		dock.preview_order(_source_id(), over)


func source_zone() -> String:
	return source.zone if source != null else ""


func _source_id() -> String:
	return source.tab_id if source != null else ""


func _clear_preview() -> void:
	if rail != null:
		for it in rail.items:
			it.shift_to(Vector2.ZERO, Vector2.ONE, false)
	if dock != null:
		for it in dock.items:
			it.shift_to(Vector2.ZERO, Vector2.ONE, false)


## The sortable whose slot center is closest to `center`: rail items while the
## dock is open (edit mode), dock items while it is shown.
func target_at(center: Vector2) -> Dictionary:
	var keys: Array = []
	var centers: Array = []
	if state.can_drag("rail"):
		for it in rail.items:
			keys.append("rail:" + it.tab_id)
			centers.append(it.slot_center())
	if dock.visible:
		for it in dock.items:
			keys.append("dock:" + it.tab_id)
			centers.append(it.slot_center())
	var hit := DndRules.closest(keys, centers, center)
	if hit == "":
		return {"zone": "", "id": ""}
	var parts := hit.split(":")
	return {"zone": parts[0], "id": parts[1]}


func drop(src_zone: String, src_id: String, target: Dictionary) -> void:
	var res := DndRules.apply_drop(state.rail, state.dock, src_zone, src_id, target)
	if res["changed"]:
		state.set_lists(res["rail"], res["dock"])


func _land(zone: String, id: String) -> void:
	var home := rail.item(id) if zone == "rail" else dock.item(id)
	if home == null:
		ghost.hide_now()
		return
	home.landing_hidden = true
	_landing = {"zone": zone, "id": id}
	if not ghost.landed.is_connected(_finish_landing):
		ghost.landed.connect(_finish_landing)
	ghost.drop_to(home.slot_rect().position)


func _finish_landing() -> void:
	if _landing.is_empty():
		return
	var it := rail.item(_landing["id"]) if _landing["zone"] == "rail" else dock.item(_landing["id"])
	if it != null:
		it.landing_hidden = false
	_landing = {}
