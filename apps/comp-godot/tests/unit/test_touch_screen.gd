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
	check_eq(r["drawer"]["edge_alpha"], 1.0)
	check_eq(r["overlay"]["rect"], [84.0, 0.0, 1296.0, 515.0], "overlay shrinks with the drawer")
	ts.state.toggle_dock()
	ts.step(1.0)
	r = ts.layout_report()
	check_eq(r["dock"]["rect"], [530.0, 443.0, 860.0, 72.0], "860 x 72 at the bottom center")


func test_rail_and_drawer_buttons_sit_where_the_web_puts_them() -> void:
	ts.state.set_lists(["auto", "settings", "visual"], ts.state.dock)
	var rects: Array = ts.layout_report()["rail"]["icons"].map(func(i: Dictionary) -> Array: return i["rect"])
	check_eq(rects[0], [20.0, 30.0, 44.0, 27.0], "home: 44 x 27 from 30 px down")
	check_eq(rects[1], [20.0, 105.0, 44.0, 27.0], "pinned tabs 48 px apart")
	check_eq(rects[2], [20.0, 180.0, 44.0, 27.0])
	check_eq(rects[3], [20.0, 255.0, 44.0, 27.0])
	check_eq(rects[4], [20.0, 458.0, 44.0, 27.0], "dock toggle 30 px above the bottom")
	var d: Array = ts.layout_report()["drawer"]["icons"].map(func(i: Dictionary) -> Array: return i["rect"])
	check_eq(d[0], [1856.0, 30.0, 44.0, 27.0], "map button centered 42 px from the drawer edge")
	check_eq(d[1], [1856.0, 105.0, 44.0, 27.0])
	var home := ts.rail.home
	check(home._has_point(Vector2(22, -9)), "the 48 px symbol span above the 27 px button takes taps")
	check(not home._has_point(Vector2(22, -13)))


func test_dock_items_are_symbol_spans_12_px_apart() -> void:
	ts.state.toggle_dock()
	ts.step(1.0)
	var rects: Array = ts.layout_report()["dock"]["item_rects"]
	var want := [[544.0, 597.18], [609.18, 665.38], [677.38, 747.93], [759.93, 816.13], [828.13, 887.12], [899.12, 955.32]]
	for i in want.size():
		check_near(rects[i][0], want[i][0], 0.1, "item %d left" % i)
		check_near(rects[i][0] + rects[i][2], want[i][1], 0.1, "item %d right" % i)
		check_eq(rects[i][1], 457.0)
		check_eq(rects[i][3], 48.0)


func test_app_layers_are_black_and_the_pill_sits_bottom_center() -> void:
	ts.state.switch_tab("effects")
	ts.step(1.0)
	var bg := ts.overlay_node("effects").get_child(0) as PwRect
	check_eq(bg.color, Color.BLACK)
	var pill: Array = ts.layout_report()["pill"]["rect"]
	check_near(pill[0] + pill[2] / 2.0, 960.0, 0.01, "centered on the window, not the app area")
	check_eq(pill[1] + pill[3], 491.0, "24 px above the bottom")
	check_eq(pill[3], 34.0)
	ts.state.toggle_panel("showMap")
	ts.step(1.0)
	pill = ts.layout_report()["pill"]["rect"]
	check_near(pill[0] + pill[2] / 2.0, 960.0, 0.01, "does not move with the drawer")


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


func test_slides_restart_from_their_first_keyframe() -> void:
	ts.state.switch_tab("effects")
	ts.step(0.1)
	ts.state.switch_tab("howard")
	check_eq(ts.overlay_node("effects").position.y, 0.0, "the exit slide starts from in place")
	ts.step(0.05)
	ts.state.switch_tab("effects")
	check_eq(ts.overlay_node("effects").position.y, 515.0, "a reopened tab slides up from below")
	check_eq(ts.overlay_layer.get_child(-1), ts.overlay_node("effects"), "the entering tab is on top")


func test_first_open_waits_for_its_first_drawn_frame() -> void:
	UiAnim.frame_holds = true
	ts.state.switch_tab("visual")
	var node := ts.overlay_node("visual")
	ts.step(0.15)
	check_eq(node.position.y, 515.0, "a 150 ms build and first draw moves nothing")
	UiAnim.release_held()
	ts.step(0.15)
	check_near(node.position.y, 515.0 * (1.0 - Easing.css(1.0 / 60.0 / 0.2)), 0.01, "then one frame of motion")
	for i in 11:
		ts.step(1.0 / 60.0)
	check(node.position.y > 0.0, "still sliding 12 frames in")
	ts.step(1.0 / 60.0)
	check_eq(node.position.y, 0.0, "the full 200 ms is shown")
	UiAnim.frame_holds = false


func test_drawer_200ms_and_dock_100ms() -> void:
	ts.state.toggle_panel("showMap")
	ts.step(0.1)
	check(ts.drawer.size.x > 84.0 and ts.drawer.size.x < 540.0)
	ts.step(0.1)
	check_eq(ts.drawer.size.x, 540.0)
	ts.state.toggle_dock()
	check(ts.dock.visible)
	ts.step(0.05)
	check(ts.dock.t.running)
	ts.step(0.05)
	check(not ts.dock.t.running)
	check_eq(ts.dock.position.y, 515.0 - ts.dock.size.y, "up after 100 ms")
	ts.state.toggle_dock()
	check(ts.rail.dock_toggle.active, "the toggle stays green while the dock closes")
	ts.step(0.1)
	check(not ts.dock.visible and not ts.state.dock_open, "down and unmounted after 100 ms")
	check(not ts.rail.dock_toggle.active)


func test_dock_keyframes_and_toggle_while_closing() -> void:
	ts.state.toggle_dock()
	ts.step(0.03)
	ts.state.toggle_dock()
	check_eq(ts.dock.position.y, 515.0 - ts.dock.size.y, "the close slide starts fully up")
	ts.state.toggle_dock()
	check(ts.state.dock_closing, "a tap while it closes is ignored")
	ts.step(0.1)
	check(not ts.state.dock_open)


func test_drawer_edge_glow_fades_with_the_width() -> void:
	ts.state.toggle_panel("showMap")
	check_eq(ts.drawer.glow.value, 0.0)
	ts.step(0.1)
	check_near(ts.drawer.glow.value, Easing.css(0.5), 0.001, "alpha on the same 200 ms ease")
	ts.step(0.1)
	check_eq(ts.drawer.glow.value, 1.0)
	ts.state.toggle_panel("showMap")
	ts.step(0.1)
	check_near(ts.drawer.glow.value, 1.0 - Easing.css(0.5), 0.001, "fades out on close")
	ts.step(0.1)
	check_eq(ts.drawer.glow.value, 0.0)


func test_drawer_background_blurs_only_over_the_driver_view() -> void:
	check(ts.layout_report()["drawer"]["blur"], "blur and black/50 over the driver view")
	ts.state.switch_tab("effects")
	check(not ts.layout_report()["drawer"]["blur"], "opaque black over an app")
	settings.set_visual({"backdrop_blur": false})
	ts.state.dismiss_overlay()
	check(not ts.drawer.backdrop_blur and not ts.dock.backdrop_blur, "the setting turns both blurs off")


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
	ts._input(_ev(title, "down"))
	ts._input(_ev(title + Vector2(100, 0), "move"))
	check_eq(ts.drawer.position.x, 1480.0, "the whole panel follows the finger")
	check_eq(ts.overlay_rect().size.x, 1920.0 - 84.0 - 440.0)
	check_eq(ts.drawer.glow.value, 1.0, "the edge stays lit while dragged")
	for i in range(2, 11):
		ts._input(_ev(title + Vector2(30 * i + 40, 0), "move"))
	ts._input(_ev(title + Vector2(340, 0), "up"))
	ts.step(0.2)
	check_eq(ts.state.open_panel, "", "swipe right closes the drawer")
	check_eq(ts.drawer.size.x, 84.0)
	check_eq(ts.drawer.position.x, 1836.0)
	check_eq(ts.drawer.glow.value, 0.0, "the edge goes out at once after a swipe")


func test_swipes_are_touch_only_and_not_through_the_dock_catcher() -> void:
	ts.state.switch_tab("effects")
	ts.step(1.0)
	var m := InputEventMouseButton.new()
	m.button_index = MOUSE_BUTTON_LEFT
	m.pressed = true
	m.position = Vector2(900, 100)
	ts._input(m)
	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(900, 300)
	ts._input(mm)
	check_eq(ts.swiping(), "", "a mouse drag never swipes")
	m.pressed = false
	ts._input(m)
	ts.state.toggle_dock()
	ts.step(1.0)
	_gesture(Vector2(900, 100), Vector2(900, 400))
	ts.step(0.3)
	check_eq(ts.state.active_tab, "effects", "the open dock's click catcher covers the app layer")


func test_swipe_deadzone_is_per_axis() -> void:
	ts.state.switch_tab("effects")
	ts.step(1.0)
	ts._input(_ev(Vector2(900, 100), "down"))
	ts._input(_ev(Vector2(906, 107), "move"))
	check_eq(ts.swiping(), "", "under 8 px on both axes nothing is decided")
	ts._input(_ev(Vector2(900, 108), "move"))
	check_eq(ts.swiping(), "overlay")
	ts._input(_ev(Vector2(900, 108), "up"))


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


func test_drag_targets_the_slot_nearest_the_ghost_center() -> void:
	ts.state.toggle_dock()
	ts.step(1.0)
	var howard := ts.dock.item("howard")
	var grab := howard.slot_center() + Vector2(20, 10)
	ts.dnd.press(howard, grab, false)
	var to := ts.rail.item("settings").slot_center() + Vector2(20, 10)
	ts.dnd.move(to)
	check(ts.dnd.is_dragging())
	check(howard.faded)
	check_eq(ts.ghost.size, howard.size, "the ghost is the dragged element's box")
	check_eq(ts.ghost.get_rect().get_center(), ts.rail.item("settings").slot_center(), "and keeps the grab offset")
	check_eq(ts.dnd.last_target, {"zone": "rail", "id": "settings"})
	ts.dnd.release(to)
	check_eq(ts.state.rail, ["auto", "howard", "settings"], "spliced before the item it is over")
	check(ts.ghost.visible, "the ghost glides back onto the dock item")
	check(ts.dock.item("howard").landing_hidden)
	ts.step(0.125)
	check(ts.ghost.position.distance_to(ts.dock.item("howard").slot_rect().position) > 1.0)
	ts.step(0.125)
	check(not ts.ghost.visible)
	check(not ts.dock.item("howard").landing_hidden)


func test_rail_items_make_room_while_dragged_over() -> void:
	ts.state.set_lists(["auto", "settings", "visual"], ts.state.dock)
	ts.state.toggle_dock()
	ts.step(1.0)
	var auto := ts.rail.item("auto")
	var start := auto.slot_center()
	ts.dnd.press(auto, start, false)
	ts.dnd.move(start + Vector2(0, 150))
	check_eq(ts.dnd.last_target["id"], "visual")
	ts.step(0.1)
	check_near(ts.rail.item("settings").position.y, 180.0 - 75.0 * Easing.css(0.5), 0.01, "siblings slide over 200 ms")
	ts.step(0.1)
	check_eq(ts.rail.item("settings").position.y, 105.0)
	check_eq(ts.rail.item("visual").position.y, 180.0)
	check_eq(auto.position.y, 255.0, "the faded source moves to the slot it would take")
	ts.dnd.release(start + Vector2(0, 150))
	check_eq(ts.state.rail, ["settings", "visual", "auto"])
	check_eq(ts.rail.item("auto").position.y, 255.0)


func test_dock_items_stretch_into_the_slots_they_take() -> void:
	ts.state.toggle_dock()
	ts.step(1.0)
	check_eq(ts.dock.ids(), ["auto", "settings", "effects", "howard", "robot3d", "visual"])
	var auto := ts.dock.item("auto")
	var settings_item := ts.dock.item("settings")
	var slots := ts.dock.slots()
	ts.dnd.press(auto, auto.slot_center(), false)
	ts.dnd.move(ts.dock.item("effects").slot_center())
	ts.step(1.0)
	check_near(auto.scale.x, slots[2].size.x / slots[0].size.x, 0.001, "auto takes the effects slot's width")
	check_eq(auto.position, slots[2].position)
	check_near(settings_item.scale.x, slots[0].size.x / slots[1].size.x, 0.001, "settings takes auto's")
	check_eq(settings_item.position, slots[0].position)
	check_eq(ts.dock.item("howard").position, slots[3].position, "howard stays")
	ts.dnd.cancel()
	check_eq(auto.scale, Vector2.ONE)


func test_layout_persists_through_settings() -> void:
	ts.state.toggle_dock()
	ts.step(1.0)
	ts.dnd.drop("dock", "howard", ts.dnd.target_at(ts.rail.item("settings").slot_center()))
	check_eq(ts.state.rail, ["auto", "howard", "settings"])
	check_eq(settings.layout()["rail"], ["auto", "howard", "settings"])
	check_eq(ts.rail.ids(), ["auto", "howard", "settings"], "rail rebuilt")
	ts.dnd.drop("rail", "auto", ts.dnd.target_at(ts.dock.item("visual").slot_center()))
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
