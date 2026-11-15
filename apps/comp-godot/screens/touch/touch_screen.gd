class_name TouchScreen
extends Control

## Touchscreen window at the 1920x515 design size (TouchscreenDashboard.tsx).
## Back to front: driver view, app layers (black; 200 ms keyframe slides up
## and down), dock click-catcher, left rail, right drawer, dock, drag ghost,
## NT Disconnected pill, on-screen keyboard. TouchLayoutState holds the state;
## the chrome components animate themselves from it, this node places them,
## slides the app layers, routes swipe gestures and keeps at most one touch 3D
## view rendering (the HUD minimap is the other). A tab sliding out is a fresh
## instance, as the web remounts it (key=exit-X): its 3D views draw one frame.

const H := 515.0
const PILL_BOTTOM := 24.0

var state := TouchLayoutState.new()
var settings: SettingsService
var driver: DriverView
var orbit: RobotOrbitView
var overlay_layer: Control
var catcher: Control
var rail: LeftRail
var drawer: RightDrawer
var dock: DockDrawer
var ghost: DragGhost
var keyboard: PwKeyboard
var pill: NtPill
var dnd: TouchDnd
## Tab id -> {"node": Control, "y": UiAnim, "exit": bool}; includes tabs sliding out.
var overlays := {}
## Extra overlay ids only Dev fixtures open (widget gallery).
var dev_tabs := {}

var _swipe: SwipeRecognizer
var _swipe_target := ""
var _overlay_commit := false
var _entry_done := false
var _shown_active := ""
var _shown_panel_open := false
var _dock_phase := ""


func _ready() -> void:
	if settings == null:
		settings = get_node_or_null("/root/Settings") as SettingsService
	if DisplayServer.get_name() != "headless":
		UiAnim.enable_frame_holds()
	theme = ThemeBuilder.build()
	name = "TouchScreen"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if settings != null:
		var lay := settings.layout()
		state.rail = lay["rail"].duplicate()
		state.dock = lay["dock"].duplicate()

	var bg := PwRect.new()
	bg.color = Color.BLACK
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(UiKit.full(bg))

	driver = DriverView.new()
	driver.position = Vector2(Tokens.RAIL_W, 0)
	driver.size = Vector2(Tokens.TOUCH_DESIGN.x - Tokens.RAIL_W, H)
	add_child(driver)
	orbit = driver.orbit

	overlay_layer = Control.new()
	overlay_layer.name = "Overlays"
	overlay_layer.z_index = UiDraw.LAYER_Z
	overlay_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(UiKit.full(overlay_layer))

	catcher = Control.new()
	catcher.name = "DockCatcher"
	catcher.visible = false
	catcher.gui_input.connect(_on_catcher_input)
	add_child(UiKit.full(catcher))

	dnd = TouchDnd.new()
	dnd.name = "Dnd"
	dnd.state = state
	add_child(dnd)

	rail = LeftRail.new()
	rail.height = H
	rail.z_index = UiDraw.LAYER_Z
	rail.state = state
	rail.dnd = dnd
	rail.home_tapped.connect(state.dismiss_overlay)
	rail.dock_tapped.connect(state.toggle_dock)
	add_child(rail)

	drawer = RightDrawer.new()
	drawer.height = H
	drawer.z_index = UiDraw.LAYER_Z
	drawer.state = state
	drawer.factory = _make_panel
	drawer.panel_tapped.connect(state.toggle_panel)
	drawer.swipe_committed.connect(state.close_panel_immediate)
	add_child(drawer)

	dock = DockDrawer.new()
	dock.state = state
	dock.dnd = dnd
	dock.visible = false
	dock.z_index = 3 * UiDraw.LAYER_Z
	dock.close_finished.connect(state.finish_dock_close)
	add_child(dock)

	ghost = DragGhost.new()
	ghost.z_index = 4 * UiDraw.LAYER_Z
	add_child(ghost)
	dnd.rail = rail
	dnd.dock = dock
	dnd.ghost = ghost
	dnd.tab_tapped.connect(state.switch_tab)

	pill = NtPill.new()
	pill.z_index = 5 * UiDraw.LAYER_Z
	add_child(pill)

	keyboard = PwKeyboard.new()
	keyboard.name = "Keyboard"
	keyboard.z_index = 6 * UiDraw.LAYER_Z
	add_child(keyboard)

	if settings != null:
		settings.changed.connect(func(section: String) -> void:
			if section == "visual":
				_apply_visual())
	_apply_visual()
	state.changed.connect(_on_state_changed)
	state.lists_changed.connect(_on_lists_changed)
	_on_state_changed()
	_layout()


func _apply_visual() -> void:
	var blur := true
	if settings != null:
		blur = bool(settings.visual().get("backdrop_blur", true))
	drawer.backdrop_blur = blur
	dock.backdrop_blur = blur


func _make_panel(id: String) -> Control:
	match id:
		"showMap":
			var p := MapSettingsPanel.new()
			p.settings = settings
			return p
		"intakeSpeed":
			return IntakePanel.new()
	return PlaceholderPanel.new(str(TabDefs.PANEL_INFO.get(id, {}).get("label", id)) + " Settings")


func make_tab(id: String) -> Control:
	match id:
		"effects":
			return PlaceholderTab.new("Special effects tab")
		"auto":
			return AutoTab.new()
		"settings":
			var st := SettingsTab.new()
			st.settings = settings
			return st
		"howard":
			return HowardTab.new()
		"robot3d":
			return Robot3DTab.new()
		"visual":
			var v := VisualTab.new()
			v.settings = settings
			return v
	if dev_tabs.has(id):
		return (dev_tabs[id] as Callable).call()
	return PlaceholderTab.new(id)


func open_dev_tab(id: String, factory: Callable) -> void:
	dev_tabs[id] = factory
	state.active_tab = id
	state.prev_tab = ""
	_on_state_changed()


func _on_lists_changed() -> void:
	rail.rebuild()
	dock.rebuild()
	if settings != null:
		settings.set_layout(state.rail, state.dock)


func _on_state_changed() -> void:
	if state.active_tab != _shown_active:
		var skip_exit := state.take_skip_exit_anim()
		for id: String in overlays.keys():
			if overlays[id]["exit"]:
				_free_overlay(id, false)
		if _shown_active != "" and overlays.has(_shown_active):
			_free_overlay(_shown_active, false)
			if not skip_exit:
				var leaving := _create_overlay(_shown_active, 0.0)
				leaving["exit"] = true
				for v: CadView in _views(leaving):
					v.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
				(leaving["y"] as UiAnim).play(0.0, layer_height(), Tokens.MOTION_OVERLAY_S)
		if state.active_tab != "":
			var entry := _create_overlay(state.active_tab, layer_height())
			overlay_layer.move_child(entry["node"], -1)
			(entry["y"] as UiAnim).play(layer_height(), 0.0, Tokens.MOTION_OVERLAY_S)
			_place_overlay(entry)
		_entry_done = false
		_overlay_commit = false
		_shown_active = state.active_tab

	var skip_panel := state.take_skip_panel_anim()
	if state.panel_is_open() != _shown_panel_open or skip_panel:
		_shown_panel_open = state.panel_is_open()
		drawer.set_open(_shown_panel_open, skip_panel)
	drawer.over_driver = state.is_driver_base()

	if state.dock_open and not state.dock_closing and _dock_phase != "open":
		_dock_phase = "open"
		dock.open()
	elif state.dock_closing and _dock_phase == "open":
		_dock_phase = "closing"
		dock.close()
	elif not state.dock_open:
		_dock_phase = ""
	catcher.visible = state.dock_open and not state.dock_closing
	if not state.dock_open:
		dnd.cancel()

	rail.refresh()
	dock.refresh()
	drawer.refresh()
	_layout()


func _create_overlay(id: String, y: float) -> Dictionary:
	var holder := Control.new()
	holder.name = "Overlay_" + id
	holder.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := PwRect.new()
	bg.color = Color.BLACK
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_index = -2
	holder.add_child(bg)
	var content := make_tab(id)
	content.name = "Content"
	holder.add_child(content)
	overlay_layer.add_child(holder)
	var entry := {"node": holder, "y": UiAnim.new(y, true), "exit": false}
	overlays[id] = entry
	_place_overlay(entry)
	return entry


func _free_overlay(id: String, clear_prev: bool = true) -> void:
	var entry: Dictionary = overlays.get(id, {})
	if entry.is_empty():
		return
	overlays.erase(id)
	var node: Control = entry["node"]
	overlay_layer.remove_child(node)
	node.queue_free()
	if clear_prev and state.prev_tab == id:
		state.clear_prev_tab()


func overlay_node(id: String) -> Control:
	return (overlays[id]["node"] as Control) if overlays.has(id) else null


func tab_content(id: String) -> Control:
	var n := overlay_node(id)
	return n.get_node_or_null("Content") as Control if n != null else null


## App layers run from the rail to the drawer: `right` is the drawer's
## width, which a drawer swipe drives directly.
func overlay_rect() -> Rect2:
	return Rect2(Tokens.RAIL_W, 0, Tokens.TOUCH_DESIGN.x - Tokens.RAIL_W - drawer.occupied_width(), H)


## App layers slide by their own height (translateY(100%)).
func layer_height() -> float:
	return overlay_rect().size.y


func _place_overlay(entry: Dictionary) -> void:
	var r := overlay_rect()
	var node: Control = entry["node"]
	var y: float = (entry["y"] as UiAnim).value
	node.position = Vector2(r.position.x, y)
	node.size = Vector2(r.size.x, _uncovered_height(entry, y, r.size.y))
	for c: Control in [node.get_child(0), node.get_child(1)]:
		c.position = Vector2.ZERO
		c.size = r.size
	# The rail and drawer share the overlays' z, so their shapes batch with
	# the overlay's; overlay text sits above them and must not spill under
	# the open drawer. A tab sliding out shares the entering tab's z too, so
	# its text would show through the entering tab: it is cut off where the
	# entering tab starts, which the web gets from the later layer's opaque
	# black.
	var clip: bool = entry["exit"] or drawer.is_expanded()
	if node.clip_contents != clip:
		node.clip_contents = clip


func _uncovered_height(entry: Dictionary, y: float, h: float) -> float:
	if not entry["exit"]:
		return h
	var front: Dictionary = overlays.get(state.active_tab, {})
	if front.is_empty() or front["exit"]:
		return h
	return clampf((front["y"] as UiAnim).value - y, 0.0, h)


func entry_done() -> bool:
	return _entry_done and overlays.has(state.active_tab)


func _process(delta: float) -> void:
	step(delta)


func step(dt: float) -> void:
	drawer.step(dt)
	for id: String in overlays.keys():
		if not overlays.has(id):
			continue
		var y: UiAnim = overlays[id]["y"]
		var finished := y.step(dt)
		if id == state.active_tab:
			if _overlay_commit and not y.running:
				_overlay_commit = false
				state.dismiss_overlay_immediate()
			elif finished and y.value <= 0.0:
				_entry_done = true
		elif not y.running and y.value >= layer_height():
			_free_overlay(id)
	dock.step(dt)
	rail.step(dt)
	ghost.step(dt)
	_layout()
	_update_rendering()


## Releases every held transition and runs all of them to the end.
func settle() -> void:
	UiAnim.release_held()
	step(10.0)


func _layout() -> void:
	drawer.right_edge = Tokens.TOUCH_DESIGN.x
	for id: String in overlays:
		_place_overlay(overlays[id])
	dock.bottom_center = Vector2(Tokens.TOUCH_DESIGN.x * 0.5, H)
	pill.position = Vector2((Tokens.TOUCH_DESIGN.x - pill.size.x) * 0.5, H - PILL_BOTTOM - pill.size.y)


## One touch view renders: the active tab's (once nothing slides over it) or
## the driver view when no overlay covers it. Covered views keep their last frame.
func _update_rendering() -> void:
	var swiping_overlay := _swipe_target == "overlay" or _overlay_commit
	var driver_visible := state.active_tab == "" or swiping_overlay or not overlays.has(state.active_tab)
	# SubViewportContainer turns its viewport back on when it is shown, so
	# visibility goes first.
	driver.visible = swiping_overlay or not entry_done()
	driver.set_rendering(driver_visible)
	for id: String in overlays:
		if overlays[id]["exit"]:
			continue
		var on := id == state.active_tab and not swiping_overlay
		for v: CadView in _views(overlays[id]):
			v.set_rendering(on)


func _views(entry: Dictionary) -> Array[Node]:
	return (entry["node"] as Node).find_children("*", "CadView", true, false)


func _on_catcher_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.UP:
		state.close_dock()
	if p.kind != PointerInput.Kind.NONE:
		catcher.accept_event()


## Touch only, like the web's touch listeners: swipe down on the active app
## layer dismisses it, swipe right on the open drawer closes it. Events are
## observed, not consumed. Sliders and selectors hide some moves from the swipe
## as their stopPropagation does on the web; the Auto preview, its scrub bar
## and the keyboard veto it (pw_swipe_veto). The Robot 3D view does not: on the
## web a vertical drag there both orbits and dismisses.
func _input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.NONE:
		return
	var t := float(Time.get_ticks_msec())
	match p.kind:
		PointerInput.Kind.DOWN:
			_swipe = null
			_swipe_target = ""
			if p.is_touch:
				_begin_swipe(p.pos, t)
		PointerInput.Kind.MOVE:
			if _swipe == null:
				return
			var was := _swipe.is_tracking()
			_swipe.move(p.pos, t)
			if _swipe.is_tracking():
				if not was:
					get_tree().call_group("pw_scroll", "cancel_touch")
					get_tree().call_group("pw_hscroll", "cancel_touch")
				if not was and _swipe_target == "drawer":
					drawer.begin_swipe()
				_apply_swipe(_swipe.delta)
		PointerInput.Kind.UP:
			if _swipe == null:
				return
			_finish_swipe(_swipe.end())


func _begin_swipe(pos: Vector2, t: float) -> void:
	if keyboard.is_open() or dnd.source != null:
		return
	if dock.visible and dock.get_global_rect().has_point(pos):
		return
	if drawer.get_global_rect().has_point(pos):
		if state.panel_is_open():
			_swipe = SwipeRecognizer.new(SwipeRecognizer.Dir.RIGHT, RightDrawer.SWIPE_DIM)
			_swipe.begin(pos, t, gesture_context(drawer, pos))
			_swipe_target = "drawer"
		return
	if rail.get_global_rect().has_point(pos) or catcher.visible:
		return
	if entry_done() and overlay_rect().has_point(pos):
		_swipe = SwipeRecognizer.new(SwipeRecognizer.Dir.DOWN, layer_height())
		_swipe.begin(pos, t, gesture_context(overlay_node(state.active_tab), pos))
		_swipe_target = "overlay"


## What lies under the press inside `root`: a slider or selector, a widget
## that vetoes swipes, and scroll containers scrolled away from the top.
static func gesture_context(root: Node, pos: Vector2) -> Dictionary:
	var ctx := {"scroll_not_at_top": false, "widget": SwipeRecognizer.Widget.NONE, "vetoed": false}
	if root == null:
		return ctx
	for c: Node in root.find_children("*", "Control", true, false):
		var ctl := c as Control
		if not ctl.is_visible_in_tree() or not ctl.get_global_rect().has_point(pos):
			continue
		if ctl is PwSelector:
			ctx["widget"] = SwipeRecognizer.Widget.SELECTOR
		elif ctl.is_in_group("pw_hgrab") and ctx["widget"] == SwipeRecognizer.Widget.NONE:
			ctx["widget"] = SwipeRecognizer.Widget.SLIDER
		if ctl.is_in_group("pw_swipe_veto"):
			ctx["vetoed"] = true
		if ctl.is_in_group("pw_scroll") and float(ctl.get("scroll_offset")) > 0.0:
			ctx["scroll_not_at_top"] = true
	return ctx


func _apply_swipe(delta: float) -> void:
	if _swipe_target == "overlay" and overlays.has(state.active_tab):
		(overlays[state.active_tab]["y"] as UiAnim).jump(delta)
	elif _swipe_target == "drawer":
		drawer.swipe_to(delta)
	_layout()


func _finish_swipe(outcome: SwipeRecognizer.Outcome) -> void:
	var target := _swipe_target
	_swipe = null
	_swipe_target = ""
	if outcome == SwipeRecognizer.Outcome.NONE:
		return
	var commit := outcome == SwipeRecognizer.Outcome.COMMIT
	if target == "overlay" and overlays.has(state.active_tab):
		_overlay_commit = commit
		(overlays[state.active_tab]["y"] as UiAnim).start(layer_height() if commit else 0.0, Tokens.MOTION_OVERLAY_S)
	elif target == "drawer":
		drawer.end_swipe(commit)


func swiping() -> String:
	return _swipe_target if _swipe != null and _swipe.is_tracking() else ""


## Dev fixture "touch" section: open a state, finish every transition.
func apply_fixture(tf: Dictionary) -> void:
	if tf.has("active_tab"):
		state.switch_tab(str(tf["active_tab"]))
	if tf.get("dev_tab", "") == "gallery":
		open_dev_tab("gallery", func() -> Control: return WidgetGallery.new())
	if tf.has("open_panel"):
		state.toggle_panel(str(tf["open_panel"]))
	if tf.get("dock_open", false):
		state.toggle_dock()
	settle()
	var content := tab_content(state.active_tab)
	if tf.has("howard_index") and content is HowardTab:
		(content as HowardTab).show_index(int(tf["howard_index"]))
	if tf.has("keyboard") and content != null:
		var input := content.find_child(str(tf["keyboard"]), true, false) as PwTextInput
		if input != null:
			input.set_text(str(tf.get("keyboard_text", "")))
			input.open_keyboard()
	if tf.has("orbit_preset"):
		orbit.apply_preset(int(tf["orbit_preset"]))
	var intake := drawer.panel("intakeSpeed") as IntakePanel
	if tf.has("panel_scroll") and intake != null:
		await get_tree().process_frame
		intake.scroll.scroll_vertical = int(tf["panel_scroll"])
	if tf.has("view_auto") and content is AutoTab:
		(content as AutoTab).view(str(tf["view_auto"]))
		(content as AutoTab).list.reveal_index((content as AutoTab).cards.find((content as AutoTab).card(str(tf["view_auto"]))))
	if tf.has("tab_scroll_x") and content != null:
		var scrolls := scrollers(content)
		if not scrolls.is_empty():
			await get_tree().process_frame
			scrolls[0].scroll_horizontal = int(tf["tab_scroll_x"])


func scrollers(root: Node) -> Array[PwScroll]:
	var out: Array[PwScroll] = []
	for n in get_tree().get_nodes_in_group("pw_scroll") + get_tree().get_nodes_in_group("pw_hscroll"):
		if n is PwScroll and root.is_ancestor_of(n):
			out.append(n)
	return out


## State for Dev scripted-input expectations.
func probe() -> Dictionary:
	var out := {"touch": layout_report(), "state": state.snapshot()}
	var content := tab_content(state.active_tab)
	if content is WidgetGallery:
		var g := content as WidgetGallery
		out["gallery"] = {"speed": g.slider.value, "snap": g.snap_slider.value, "trim": g.trim.value,
			"mode": g.selector.current_value(), "msaa": g.text_selector.current_value(),
			"host": g.host.text, "port": g.port.text, "presses": g.presses}
	if content is HowardTab:
		out["howard"] = {"index": (content as HowardTab).index}
	if content is AutoTab:
		out["auto_tab"] = (content as AutoTab).probe()
	if content is SettingsTab:
		out["settings_tab"] = (content as SettingsTab).probe()
	if content is VisualTab:
		out["visual_tab"] = (content as VisualTab).probe()
	var intake := drawer.panel("intakeSpeed")
	if intake is IntakePanel and intake.visible:
		out["intake_panel"] = (intake as IntakePanel).probe()
	out["pill"] = pill.visible
	if content is Robot3DTab:
		var rows := {}
		for key: String in (content as Robot3DTab).rows:
			var r: Dictionary = (content as Robot3DTab).rows[key]
			rows[key] = {"disabled": (r["slider"] as PwRange).disabled, "value": float((r["value"] as PwText).text), "source": (r["source"] as PwText).text}
		var v := (content as Robot3DTab).view
		var t := v.cam.target
		rows["camera"] = {"theta": v.cam.theta, "phi": v.cam.phi, "dist": v.cam.dist, "target": [t.x, t.y, t.z]}
		out["robot3d"] = rows
	var scrolls := {}
	for sc in scrollers(self):
		if sc.is_visible_in_tree():
			scrolls[String(sc.name)] = {"offset": sc.scroll_offset, "max": sc.max_scroll(), "dragging": sc.dragging}
	out["scrolls"] = scrolls
	out["driver"] = {"preset": orbit.cam.preset, "theta": orbit.cam.theta, "phi": orbit.cam.phi, "dist": orbit.cam.dist,
		"gliding": orbit.cam.is_gliding(), "tweening": orbit.cam.is_tweening()}
	return out


func _overlay_ys() -> Dictionary:
	var out := {}
	for id: String in overlays:
		out[id] = snappedf((overlays[id]["y"] as UiAnim).value, 0.01)
	return out


static func _r(r: Rect2) -> Array:
	return [snappedf(r.position.x, 0.01), snappedf(r.position.y, 0.01), snappedf(r.size.x, 0.01), snappedf(r.size.y, 0.01)]


func layout_report() -> Dictionary:
	var rail_icons: Array = []
	for it: TabIcon in [rail.home] + rail.items + [rail.dock_toggle]:
		rail_icons.append({"name": String(it.name), "rect": _r(it.get_global_rect()), "active": it.active})
	var drawer_icons: Array = []
	for it: TabIcon in drawer.icons:
		drawer_icons.append({"name": String(it.name), "rect": _r(it.get_global_rect()), "active": it.active})
	var views: Array = []
	for v: CadView in get_tree().get_nodes_in_group(CadView.GROUP):
		if v.get_window() == get_window():
			views.append({"name": String(v.name), "rendering": v.is_rendering(), "scale": v.viewport.scaling_3d_scale, "msaa": v.viewport.msaa_3d})
	return {
		"state": state.snapshot(),
		"rail": {"rect": _r(rail.get_global_rect()), "icons": rail_icons, "icon_px": Tokens.ICON},
		"drawer": {"rect": _r(drawer.get_global_rect()), "expanded": drawer.is_expanded(), "edge_px": Tokens.BORDER,
			"edge_alpha": snappedf(drawer.glow.value, 0.001), "blur": drawer.over_driver and drawer.backdrop_blur, "icons": drawer_icons},
		"overlay": {"rect": _r(overlay_rect()), "tabs": overlays.keys(), "y": _overlay_ys()},
		"dock": {"visible": dock.visible, "rect": _r(dock.get_global_rect()), "items": dock.ids(), "blur": dock.backdrop_blur,
			"item_rects": dock.items.map(func(it: TabIcon) -> Array: return _r(it.get_global_rect()))},
		"pill": {"visible": pill.visible, "rect": _r(pill.get_global_rect())},
		"driver": {"rect": _r(driver.get_global_rect()), "preset": orbit.cam.preset, "rendering": orbit.is_rendering()},
		"keyboard": {"open": keyboard.is_open(), "numeric": keyboard.numeric},
		"views": views,
	}
