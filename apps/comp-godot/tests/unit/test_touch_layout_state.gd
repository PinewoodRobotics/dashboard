extends TestCase

## Every transition of useTouchscreenLayoutState.ts (touchscreen.md 1.2).

var s: TouchLayoutState


func before_each() -> void:
	s = TouchLayoutState.new()


func test_tab_toggle() -> void:
	check(s.is_driver_base())
	s.switch_tab("auto")
	check_eq(s.active_tab, "auto")
	check_eq(s.prev_tab, "", "nothing slides out from the driver base")
	s.switch_tab("auto")
	check_eq(s.active_tab, "", "same tab again returns to the driver base")
	check_eq(s.prev_tab, "auto", "and slides out")
	check(s.is_driver_base())


func test_tab_replace() -> void:
	s.switch_tab("auto")
	s.switch_tab("visual")
	check_eq(s.active_tab, "visual")
	check_eq(s.prev_tab, "auto")
	s.clear_prev_tab()
	check_eq(s.prev_tab, "")


func test_unknown_tab_is_ignored() -> void:
	s.switch_tab("record")
	check_eq(s.active_tab, "")


func test_dismiss_and_immediate_dismiss() -> void:
	s.switch_tab("howard")
	s.dismiss_overlay()
	check_eq(s.active_tab, "")
	check_eq(s.prev_tab, "howard")
	check(not s.take_skip_exit_anim(), "dismiss animates the exit")
	s.switch_tab("howard")
	s.dismiss_overlay_immediate()
	check_eq(s.active_tab, "")
	check_eq(s.prev_tab, "", "immediate dismiss leaves nothing to animate")
	check(s.take_skip_exit_anim())
	check(not s.take_skip_exit_anim(), "one-shot")


func test_single_right_panel_and_kept_content() -> void:
	s.toggle_panel("showMap")
	check_eq(s.open_panel, "showMap")
	s.toggle_panel("intakeSpeed")
	check_eq(s.open_panel, "intakeSpeed", "opening another panel replaces the first")
	s.toggle_panel("intakeSpeed")
	check_eq(s.open_panel, "")
	check_eq(s.display_panel(), "intakeSpeed", "content stays while the drawer collapses")
	s.toggle_panel("nope")
	check_eq(s.open_panel, "")


func test_close_panel_immediate_skips_the_width_animation() -> void:
	s.toggle_panel("showMap")
	check(not s.take_skip_panel_anim())
	s.close_panel_immediate()
	check_eq(s.open_panel, "")
	check(s.take_skip_panel_anim())


func test_dock_open_close() -> void:
	s.toggle_dock()
	check(s.dock_open and not s.dock_closing)
	s.toggle_dock()
	check(s.dock_open and s.dock_closing, "closing keeps it mounted until the slide-down ends")
	s.finish_dock_close()
	check(not s.dock_open and not s.dock_closing)
	s.toggle_dock()
	s.toggle_dock()
	s.toggle_dock()
	check(s.dock_open and not s.dock_closing, "reopening while closing cancels the close")


func test_tab_and_panel_actions_close_the_dock() -> void:
	s.toggle_dock()
	s.toggle_panel("showMap")
	check(s.dock_closing, "panel toggle closes the dock")
	s.finish_dock_close()
	s.toggle_dock()
	s.switch_tab("auto")
	check(s.dock_closing, "tab switch closes the dock")
	s.finish_dock_close()
	s.toggle_dock()
	s.dismiss_overlay()
	check(s.dock_closing, "dismiss closes the dock")


func test_rail_drag_only_in_edit_mode() -> void:
	check(not s.can_drag("rail"))
	check(not s.can_drag("dock"))
	s.toggle_dock()
	check(s.can_drag("rail"))
	check(s.can_drag("dock"))
	s.toggle_dock()
	check(not s.can_drag("rail"), "not while the dock slides away")


func test_set_lists_sanitizes() -> void:
	var seen := [0]
	s.lists_changed.connect(func() -> void: seen[0] += 1)
	s.set_lists(["visual", "record", "visual", 3], ["howard", "record"])
	check_eq(s.rail, ["visual"])
	check_eq(s.dock, ["howard", "auto", "settings", "effects", "robot3d", "visual"])
	check_eq(seen[0], 1)
	s.set_lists(["visual"], s.dock)
	check_eq(seen[0], 1, "no signal without a change")
