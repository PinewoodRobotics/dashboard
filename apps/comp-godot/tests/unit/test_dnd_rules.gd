extends TestCase

const RAIL := ["auto", "settings", "visual"]
const DOCK := ["auto", "settings", "effects", "howard", "robot3d", "visual"]


func _drop(src_zone: String, id: String, zone: String, over: String) -> Dictionary:
	return DndRules.apply_drop(RAIL, DOCK, src_zone, id, {"zone": zone, "id": over})


func test_rail_reorder() -> void:
	var r := _drop("rail", "visual", "rail", "auto")
	check_eq(r["rail"], ["visual", "auto", "settings"])
	check_eq(r["dock"], DOCK)
	check_eq(_drop("rail", "auto", "rail", "visual")["rail"], ["settings", "visual", "auto"])
	check_eq(_drop("rail", "auto", "rail", "")["rail"], ["settings", "visual", "auto"], "over the zone moves to the end")


func test_dock_reorder() -> void:
	var r := _drop("dock", "howard", "dock", "auto")
	check_eq(r["dock"], ["howard", "auto", "settings", "effects", "robot3d", "visual"])
	check_eq(r["rail"], RAIL)


func test_dock_to_rail_inserts_at_target_without_duplicates() -> void:
	check_eq(_drop("dock", "howard", "rail", "settings")["rail"], ["auto", "howard", "settings", "visual"])
	check_eq(_drop("dock", "howard", "rail", "")["rail"], ["auto", "settings", "visual", "howard"], "over the zone appends")
	var dup := _drop("dock", "visual", "rail", "auto")
	check_eq(dup["rail"], RAIL, "already in the rail: no duplicate")
	check(not dup["changed"])
	check_eq(_drop("dock", "howard", "rail", "settings")["dock"], DOCK, "dock order unchanged")
	check_eq(DndRules.apply_drop([], DOCK, "dock", "effects", {"zone": "rail", "id": ""})["rail"], ["effects"], "empty rail")


func test_rail_to_dock_removes() -> void:
	var r := _drop("rail", "settings", "dock", "howard")
	check_eq(r["rail"], ["auto", "visual"])
	check_eq(r["dock"], DOCK)
	check_eq(_drop("rail", "settings", "dock", "settings")["rail"], ["auto", "visual"], "even over its own dock item")


func test_drop_on_nothing_is_a_no_op() -> void:
	var r := _drop("dock", "howard", "", "")
	check(not r["changed"])
	check_eq(r["rail"], RAIL)
	check(not _drop("rail", "auto", "", "")["changed"])
	check(not _drop("rail", "auto", "rail", "auto")["changed"], "onto itself")


func test_targets_from_positions() -> void:
	var ids := ["auto", "settings", "visual"]
	var centers := [Vector2(42, 140), Vector2(42, 215), Vector2(42, 290)]
	check_eq(DndRules.rail_target(ids, centers, Vector2(40, 150)), "auto")
	check_eq(DndRules.rail_target(ids, centers, Vector2(40, 200)), "settings")
	check_eq(DndRules.rail_target(ids, centers, Vector2(40, 330)), "", "below the last item appends")
	check_eq(DndRules.rail_target([], [], Vector2(40, 100)), "")
	check_eq(DndRules.closest(ids, [Vector2(0, 0), Vector2(100, 0), Vector2(200, 0)], Vector2(130, 30)), "settings")


func test_touch_drag_starts_after_hold_within_tolerance() -> void:
	var g := DragGate.new()
	g.begin(Vector2(100, 100), 1000, true)
	check_eq(g.move(Vector2(110, 110), 1100), DragGate.State.PENDING, "14 px early: still pending")
	check_eq(g.tick(1199), DragGate.State.PENDING, "199 ms")
	check_eq(g.tick(1200), DragGate.State.DRAGGING, "200 ms hold")
	g.begin(Vector2(100, 100), 1000, true)
	check_eq(g.move(Vector2(126, 100), 1050), DragGate.State.CANCELLED, "26 px before the hold ends is not a drag")
	check_eq(g.tick(1300), DragGate.State.CANCELLED)
	g.begin(Vector2(100, 100), 1000, true)
	check_eq(g.move(Vector2(125, 100), 1250), DragGate.State.DRAGGING, "25 px is within tolerance")


func test_mouse_drag_starts_after_8px() -> void:
	var g := DragGate.new()
	g.begin(Vector2(100, 100), 0, false)
	check_eq(g.move(Vector2(107, 100), 5000), DragGate.State.PENDING, "time alone never starts a mouse drag")
	check_eq(g.tick(5000), DragGate.State.PENDING)
	check_eq(g.move(Vector2(108, 100), 5001), DragGate.State.DRAGGING)
	check_eq(g.end(), DragGate.State.DRAGGING)
	check_eq(g.state, DragGate.State.IDLE)
