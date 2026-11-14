class_name TouchDnd
extends Node

## Rail/dock editor drags. A press on a rail or dock item becomes a tap or,
## through DragGate, a drag with a ghost; the drop target is resolved from
## the pointer (rail: vertical position, dock: closest center) and the lists
## change through DndRules. Positions are canvas (design) coordinates.

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
		_start_drag(pos)
	if gate.is_dragging():
		ghost.move_to(pos)
		last_target = target_at(pos)
		var adds := source.zone == "dock" and not state.rail.has(source.tab_id)
		var moves := source.zone == "rail"
		rail.show_drop_marker(last_target["zone"] == "rail" and (adds or moves), last_target["id"])


func release(pos: Vector2) -> void:
	if source == null:
		return
	var item := source
	var s := gate.end()
	source = null
	set_process(false)
	ghost.visible = false
	item.faded = false
	rail.show_drop_marker(false)
	if s == DragGate.State.DRAGGING:
		drop(item.zone, item.tab_id, target_at(pos))
	elif s == DragGate.State.PENDING:
		tab_tapped.emit(item.tab_id)


func cancel() -> void:
	if source != null:
		source.faded = false
	if rail != null:
		rail.show_drop_marker(false)
	source = null
	gate.end()
	ghost.visible = false
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
		_start_drag(gate.start_pos)


func _start_drag(pos: Vector2) -> void:
	source.faded = true
	ghost.show_at(source.icon_name, pos)


func target_at(pos: Vector2) -> Dictionary:
	if dock.visible and dock.get_global_rect().has_point(pos):
		return {"zone": "dock", "id": DndRules.closest(dock.ids(), dock.centers(), pos)}
	if rail.get_global_rect().has_point(pos):
		return {"zone": "rail", "id": DndRules.rail_target(rail.ids(), rail.centers(), pos)}
	return {"zone": "", "id": ""}


func drop(src_zone: String, src_id: String, target: Dictionary) -> void:
	var res := DndRules.apply_drop(state.rail, state.dock, src_zone, src_id, target)
	if res["changed"]:
		state.set_lists(res["rail"], res["dock"])
