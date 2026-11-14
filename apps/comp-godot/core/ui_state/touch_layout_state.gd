class_name TouchLayoutState
extends RefCounted

## Touchscreen layout state machine (useTouchscreenLayoutState.ts). "" means
## none: active_tab "" is the driver base, open_panel "" a collapsed drawer.
## Views animate from this state and report animation ends back.

signal changed
signal lists_changed

var active_tab := ""
## The tab sliding out after a replace or dismiss, until clear_prev_tab().
var prev_tab := ""
var open_panel := ""
## Panel whose content stays rendered while the drawer collapses.
var last_panel := ""
var dock_open := false
var dock_closing := false
## One-shot: the next drawer width change jumps (a swipe already animated it).
var skip_panel_anim := false
## One-shot: the next dismissal has no exit animation (a swipe already animated it).
var skip_exit_anim := false
var rail: Array = TabDefs.DEFAULT_RAIL.duplicate()
var dock: Array = TabDefs.TABS.duplicate()


func is_driver_base() -> bool:
	return active_tab == ""


func display_panel() -> String:
	return open_panel if open_panel != "" else last_panel


func panel_is_open() -> bool:
	return open_panel != ""


## Dock items are draggable whenever shown; rail items only in edit mode (dock open).
func can_drag(zone: String) -> bool:
	if zone == "rail":
		return dock_open and not dock_closing
	return zone == "dock" and dock_open


func switch_tab(id: String) -> void:
	if not TabDefs.is_tab(id):
		return
	_begin_dock_close()
	skip_exit_anim = false
	if id == active_tab:
		prev_tab = id
		active_tab = ""
	else:
		prev_tab = active_tab
		active_tab = id
	changed.emit()


func dismiss_overlay() -> void:
	_begin_dock_close()
	if active_tab != "":
		prev_tab = active_tab
		active_tab = ""
		skip_exit_anim = false
	changed.emit()


func dismiss_overlay_immediate() -> void:
	_begin_dock_close()
	if active_tab != "":
		prev_tab = ""
		active_tab = ""
		skip_exit_anim = true
	changed.emit()


func clear_prev_tab() -> void:
	if prev_tab == "":
		return
	prev_tab = ""
	changed.emit()


func toggle_panel(id: String) -> void:
	if not TabDefs.is_panel(id):
		return
	_begin_dock_close()
	skip_panel_anim = false
	if open_panel == id:
		open_panel = ""
	else:
		open_panel = id
		last_panel = id
	changed.emit()


func close_panel_immediate() -> void:
	if open_panel == "":
		return
	open_panel = ""
	skip_panel_anim = true
	changed.emit()


func toggle_dock() -> void:
	if dock_open and not dock_closing:
		dock_closing = true
	else:
		dock_open = true
		dock_closing = false
	changed.emit()


func close_dock() -> void:
	if dock_open and not dock_closing:
		dock_closing = true
		changed.emit()


## Called when the dock's slide-down animation ends.
func finish_dock_close() -> void:
	if not dock_closing:
		return
	dock_closing = false
	dock_open = false
	changed.emit()


func set_lists(new_rail: Array, new_dock: Array) -> void:
	var r := TabDefs.sanitize_ids(new_rail)
	var d := TabDefs.normalize_dock(new_dock)
	if r == rail and d == dock:
		return
	rail = r
	dock = d
	lists_changed.emit()
	changed.emit()


func take_skip_panel_anim() -> bool:
	var v := skip_panel_anim
	skip_panel_anim = false
	return v


func take_skip_exit_anim() -> bool:
	var v := skip_exit_anim
	skip_exit_anim = false
	return v


func snapshot() -> Dictionary:
	return {
		"active_tab": active_tab,
		"prev_tab": prev_tab,
		"open_panel": open_panel,
		"display_panel": display_panel(),
		"dock_open": dock_open,
		"dock_closing": dock_closing,
		"rail": rail.duplicate(),
		"dock": dock.duplicate(),
	}


func _begin_dock_close() -> void:
	if dock_open:
		dock_closing = true
