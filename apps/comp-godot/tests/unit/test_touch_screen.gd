extends TestCase

## TouchScreen at 1920x515: geometry (touchscreen.md 1), transition timing,
## swipe gestures through _input, the one-touch-view rendering rule, and map
## settings reaching the HUD minimap in the same process.

var settings: SettingsService
var ts: TouchScreen
var host: Control


func before_each() -> void:
	settings = SettingsService.new()
	settings.persist = false
	tree.root.add_child(settings)
	host = Control.new()
	host.size = Tokens.TOUCH_DESIGN
	tree.root.add_child(host)
	ts = TouchScreen.new()
	ts.settings = settings
	host.add_child(ts)
	ts.set_process(false)
	ts.set_deferred("size", Tokens.TOUCH_DESIGN)
	ts.step(0.0)


func after_each() -> void:
	for n: Node in [host, settings]:
		if is_instance_valid(n):
			n.queue_free()
	await tree.process_frame


static func _ev(pos: Vector2, kind: String) -> InputEvent:
	if kind == "move":
		var m := InputEventMouseMotion.new()
		m.position = pos
		m.device = InputEvent.DEVICE_ID_EMULATION
		return m
	var b := InputEventMouseButton.new()
	b.button_index = MOUSE_BUTTON_LEFT
	b.pressed = kind == "down"
	b.position = pos
	b.device = InputEvent.DEVICE_ID_EMULATION
	return b


## A gesture through TouchScreen._input, `ms` long, in `n` moves.
func _gesture(a: Vector2, b: Vector2, n: int = 10) -> void:
	ts._input(_ev(a, "down"))
	for i in range(1, n + 1):
		ts._input(_ev(a.lerp(b, float(i) / n), "move"))
	ts._input(_ev(b, "up"))


func test_geometry_at_1920x515() -> void:
	var r := ts.layout_report()
	check_eq(r["rail"]["rect"], [0.0, 0.0, 84.0, 515.0], "rail 84 px")
	check_eq(r["rail"]["icon_px"], 48)
	check_eq(r["drawer"]["rect"], [1836.0, 0.0, 84.0, 515.0], "drawer 84 closed")
	check_eq(r["overlay"]["rect"], [84.0, 0.0, 1752.0, 515.0], "overlay between rail and drawer")
	check_eq(r["driver"]["rect"], [84.0, 0.0, 1836.0, 515.0], "driver base from the rail to the right edge")
	ts.state.toggle_panel("showMap")
	ts.step(1.0)
	r = ts.layout_report()
	check_eq(r["drawer"]["rect"], [1380.0, 0.0, 540.0, 515.0], "drawer 540 open")
	check_eq(r["drawer"]["edge_px"], 4)
	check_eq(r["overlay"]["rect"], [84.0, 0.0, 1296.0, 515.0], "overlay shrinks with the drawer")
	ts.state.toggle_dock()
	ts.step(1.0)
	r = ts.layout_report()
	check_eq(r["dock"]["rect"][2], 860.0, "dock 860 wide")
	check_near(r["dock"]["rect"][0] + 430.0, 960.0, 0.01, "bottom center")
	check_near(r["dock"]["rect"][1] + r["dock"]["rect"][3], 515.0, 0.01, "on the bottom edge")
	var icon: Array = r["rail"]["icons"][0]["rect"]
	check_eq(icon[2], 84.0)
	check_eq(r["drawer"]["icons"][0]["rect"][0] + r["drawer"]["icons"][0]["rect"][2] / 2.0, 1380.0 + 42.0, "drawer icons in the 44 px column after 20 px padding")


func test_overlay_timing_200ms() -> void:
	ts.state.switch_tab("effects")
	var node := ts.overlay_node("effects")
	check(node != null)
	ts.step(0.1)
	check_near(node.position.y, 515.0 * (1.0 - Easing.css(0.5)), 0.01, "halfway on the css curve at 100 ms")
	ts.step(0.1)
	check_eq(node.position.y, 0.0, "in place at 200 ms")
	check(ts.entry_done())
	ts.state.switch_tab("howard")
	ts.step(0.199)
	check(ts.overlay_node("effects") != null, "the replaced tab is still sliding out")
	check_eq(ts.state.prev_tab, "effects")
	ts.step(0.002)
	await tree.process_frame
	check(ts.overlay_node("effects") == null, "removed at the end of its 200 ms exit")
	check_eq(ts.state.prev_tab, "")


func test_drawer_200ms_and_dock_100ms() -> void:
	ts.state.toggle_panel("showMap")
	ts.step(0.1)
	check(ts.drawer.size.x > 84.0 and ts.drawer.size.x < 540.0)
	ts.step(0.1)
	check_eq(ts.drawer.size.x, 540.0)
	ts.state.toggle_dock()
	check(ts.dock.visible)
	ts.step(0.05)
	check(ts.dock_t.running)
	ts.step(0.05)
	check(not ts.dock_t.running)
	check_eq(ts.dock.position.y, 515.0 - ts.dock.size.y, "up after 100 ms")
	ts.state.toggle_dock()
	ts.step(0.1)
	check(not ts.dock.visible and not ts.state.dock_open, "down and unmounted after 100 ms")


func test_drawer_keeps_content_while_collapsing() -> void:
	ts.state.toggle_panel("showMap")
	ts.step(1.0)
	var panel := ts.drawer.panel("showMap")
	check(panel is MapSettingsPanel and panel.visible)
	ts.state.toggle_panel("showMap")
	ts.step(0.1)
	check(panel.is_visible_in_tree(), "still rendered mid-collapse")
	check(ts.drawer.size.x < 540.0 and ts.drawer.size.x > 84.0)
	ts.step(0.1)
	check_eq(ts.drawer.size.x, 84.0)


func test_swipe_down_dismisses_the_overlay() -> void:
	ts.state.switch_tab("effects")
	ts.step(1.0)
	_gesture(Vector2(900, 100), Vector2(900, 400))
	ts.step(0.2)
	check_eq(ts.state.active_tab, "", "back to the driver view")
	await tree.process_frame
	check(ts.overlay_node("effects") == null)


func test_short_swipe_snaps_back_and_up_swipe_is_ignored() -> void:
	ts.state.switch_tab("effects")
	ts.step(1.0)
	ts._input(_ev(Vector2(900, 100), "down"))
	ts._input(_ev(Vector2(900, 112), "move"))
	check_eq(ts.swiping(), "overlay")
	check_eq(ts.overlay_node("effects").position.y, 12.0, "the overlay follows the finger")
	await tree.create_timer(0.15).timeout
	ts._input(_ev(Vector2(900, 120), "move"))
	ts._input(_ev(Vector2(900, 120), "up"))
	ts.step(0.2)
	check_eq(ts.state.active_tab, "effects", "slow short swipe snaps back")
	check_eq(ts.overlay_node("effects").position.y, 0.0)
	_gesture(Vector2(900, 400), Vector2(900, 100))
	ts.step(0.2)
	check_eq(ts.state.active_tab, "effects")


func test_swipe_right_closes_the_drawer_but_sliders_win() -> void:
	ts.state.toggle_panel("showMap")
	ts.step(1.0)
	await tree.process_frame
	var panel := ts.drawer.panel("showMap") as MapSettingsPanel
	var zoom_center := panel.zoom.get_global_rect().get_center()
	var ctx := TouchScreen.gesture_context(ts.drawer, zoom_center)
	check(ctx["on_horizontal_widget"], "the zoom slider is under the finger")
	_gesture(zoom_center, zoom_center + Vector2(300, 0))
	ts.step(0.3)
	check_eq(ts.state.open_panel, "showMap", "a horizontal drag on a slider never closes the drawer")
	var title := Vector2(1500, 40)
	check(not TouchScreen.gesture_context(ts.drawer, title)["on_horizontal_widget"])
	_gesture(title, title + Vector2(300, 0))
	check(ts.drawer.size.x < 540.0)
	ts.step(0.2)
	check_eq(ts.state.open_panel, "", "swipe right closes the drawer")
	check_eq(ts.drawer.size.x, 84.0)


func test_scroll_not_at_top_blocks_swipe_down() -> void:
	ts.state.switch_tab("effects")
	ts.step(1.0)
	var content := ts.tab_content("effects")
	var sc := PwScroll.new()
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var tall := Control.new()
	tall.custom_minimum_size = Vector2(100, 2000)
	sc.add_child(tall)
	content.add_child(sc)
	await tree.process_frame
	sc.scroll_vertical = 200
	await tree.process_frame
	check(TouchScreen.gesture_context(ts.overlay_node("effects"), Vector2(900, 100))["scroll_not_at_top"])
	_gesture(Vector2(900, 100), Vector2(900, 450))
	ts.step(0.3)
	check_eq(ts.state.active_tab, "effects")


func test_one_touch_view_renders() -> void:
	check(ts.orbit.is_rendering(), "driver view renders on the driver base")
	ts.state.switch_tab("robot3d")
	ts.step(0.05)
	var tab := ts.tab_content("robot3d") as Robot3DTab
	check(not ts.orbit.is_rendering(), "covered driver view is UPDATE_DISABLED")
	check_eq(ts.orbit.viewport.render_target_update_mode, SubViewport.UPDATE_DISABLED)
	check(tab.view.is_rendering())
	ts.step(1.0)
	await tree.process_frame
	check_eq(_rendering_in_touch(), 1)
	ts._input(_ev(Vector2(900, 20), "down"))
	ts._input(_ev(Vector2(900, 60), "move"))
	check_eq(ts.swiping(), "", "the 3D view in the tab owns its drags")
	ts._input(_ev(Vector2(900, 60), "up"))
	ts.state.switch_tab("effects")
	ts.step(0.1)
	check(not tab.view.is_rendering(), "the tab sliding out is frozen")
	check_eq(_rendering_in_touch(), 0, "nothing renders while two overlays cover the driver view")
	ts.state.dismiss_overlay()
	ts.step(0.05)
	check(ts.orbit.is_rendering(), "renders again as soon as the overlay leaves")


func _rendering_in_touch() -> int:
	var n := 0
	for v: CadView in tree.get_nodes_in_group(CadView.GROUP):
		if ts.is_ancestor_of(v) and v.is_rendering():
			n += 1
	return n


func test_layout_persists_through_settings() -> void:
	ts.state.toggle_dock()
	ts.step(1.0)
	ts.dnd.drop("dock", "howard", ts.dnd.target_at(ts.rail.item("settings").canvas_center()))
	check_eq(ts.state.rail, ["auto", "howard", "settings"])
	check_eq(settings.layout()["rail"], ["auto", "howard", "settings"])
	check_eq(ts.rail.ids(), ["auto", "howard", "settings"], "rail rebuilt")
	ts.dnd.drop("rail", "auto", ts.dnd.target_at(ts.dock.item("visual").canvas_center()))
	check_eq(settings.layout()["rail"], ["howard", "settings"], "rail to dock removes")


func test_map_settings_move_the_minimap_camera() -> void:
	var mm := MinimapView.new()
	mm.settings_service = settings
	mm.size = Vector2(840, 600)
	host.add_child(mm)
	mm.set_process(false)
	ts.state.toggle_panel("showMap")
	ts.step(1.0)
	await tree.process_frame
	var panel := ts.drawer.panel("showMap") as MapSettingsPanel
	mm._process(1.0)
	var before := mm.camera.global_position
	var z := panel.zoom
	var a := z.get_global_rect().get_center()
	z._gui_input(_ev(a - z.get_global_position(), "down"))
	z._gui_input(_ev(a + Vector2(150, 0) - z.get_global_position(), "move"))
	z._gui_input(_ev(a + Vector2(150, 0) - z.get_global_position(), "up"))
	check(settings.map()["zoom"] > 0.6, "slider wrote the zoom")
	mm._process(1.0)
	check(mm.camera.global_position.distance_to(before) > 0.1, "minimap camera moved on the next frame")
	panel.mode._gui_input(_ev(Vector2(30, 70), "down"))
	panel.mode._gui_input(_ev(Vector2(30, 70), "up"))
	check_eq(settings.map()["mode"], "driver")
	panel.reset.pressed.emit()
	check_eq(settings.map(), AppSettings.DEFAULT_MAP)
	check_eq(panel.zoom.value, 0.5, "widgets follow the reset")
