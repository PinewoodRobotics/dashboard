class_name AutoTab
extends Control

## Auto selector (AutoSelector.tsx). Left third (PathListPane.tsx): "No Auto",
## then every exported auto, then the autos the robot lists that the export
## lacks (selectable, no preview); a tap views one. The rest
## (PathDetailPane.tsx): its left half has the viewed auto's title, file and
## description over the Select button (Selecting..., Selected, Locked During
## Match); its right half the preview box with the realtime 3D preview, or
## the Howard error picture when the auto has no preview. The preview can
## expand over the whole tab. An amber banner covers the top while the robot
## is enabled, a popup when another dashboard fights over the selection.
## Selection logic lives in AutoSelectionSync; the export summary and Reload
## Autos are on the Settings tab.

const NONE := AutoSelectionSync.NONE
const NO_AUTO_DESC := "Do not run an autonomous routine"
## The status row after the cards when the library is empty or failed to load
## (PathListPane.tsx); tapping it reloads.
const RETRY := "<retry>"
const RETRY_TEXT := "Failed to load. Tap to retry."
const EMPTY_TEXT := "No paths found"
const NO_AUTO_DETAIL := "Do not run an autonomous routine. The robot will stay still during autonomous."
const ROBOT_ONLY_FILE := "On the robot: no preview, not exported"
const ROBOT_ONLY_DETAIL := "The robot has this auto, but the dashboard's export does not, so there is no preview."
const UNCONFIRMED_FILE := "Saved choice: not exported, robot list unknown"
const UNCONFIRMED_DETAIL := "This saved choice is not in the dashboard's export. It is held back until the robot's auto list confirms it, and dropped if the robot does not have it."
const AMBER_BG := Color(0.961, 0.62, 0.043, 0.15)
const AMBER_LINE := Color(0.984, 0.749, 0.141, 0.6)
const AMBER_TEXT := Color("#fef3c7")
const ROSE := Color("#f43f5e")
const ROSE_TEXT := Color("#fb7185")
const PAD := 16
const DESC_MAX_W := 660.0

var controls: ControlsService
var autos: AutosService
var list: PwTapList
var cards: Array[AutoCard] = []
var status_row: AutoStatusRow
var viewing := ""
var detail_title: PwText
var detail_file: PwText
var detail_desc: PwText
var select_button: PwButton
var preview: AutoPreviewPanel
var no_preview: Control
var howard: HowardError
var expanded := false
var banner: Control
var popup: Control
var popup_body: PwText
var resync: PwButton
var _list_pane: Control
var _detail_left: Control
var _detail_right: Control
var _detail_top: VBoxContainer
var _robot_only_key := ""
var _fresh_level := -1
var _fresh_age := ""
var _fresh_ms := 0
var _no_preview_key: Variant = null
var _warning := ""


func _ready() -> void:
	if controls == null:
		controls = get_node_or_null("/root/Controls") as ControlsService
	if autos == null:
		autos = get_node_or_null("/root/Autos") as AutosService

	add_child(UiKit.full(PwRect.new(Tokens.PANEL)))
	list = PwTapList.new(10, 10)
	list.name = "List"
	list.item_tapped.connect(_on_card_tapped)
	_list_pane = list
	add_child(list)
	_build_detail()
	banner = _build_banner()
	add_child(banner)
	popup = _build_popup()
	add_child(popup)

	_rebuild_cards()
	if autos != null:
		autos.library_changed.connect(_rebuild_cards)
	resized.connect(_layout)
	_detail_left.minimum_size_changed.connect(_layout)
	_layout()
	refresh()


func _layout() -> void:
	var list_w := 0.0 if expanded else size.x / 3.0
	list.visible = not expanded
	_detail_left.visible = not expanded
	list.position = Vector2.ZERO
	list.size = Vector2(list_w, size.y)
	var detail_w := size.x - list_w
	var left_w := 0.0 if expanded else detail_w * 0.5
	_detail_left.position = Vector2(list_w, 0)
	_detail_left.size = Vector2(left_w, size.y)
	_detail_right.position = Vector2(list_w + left_w, 0)
	_detail_right.size = Vector2(detail_w - left_w, size.y)
	banner.position = Vector2.ZERO
	banner.size = Vector2(size.x, banner.get_combined_minimum_size().y)
	popup.position = Vector2.ZERO
	popup.size = size
	_fit_desc()


func _names() -> PackedStringArray:
	return autos.library.names() if autos != null else PackedStringArray()


func _robot_only() -> PackedStringArray:
	return controls.sync.robot_only_names() if controls != null else PackedStringArray()


func _unconfirmed() -> PackedStringArray:
	if controls == null or not controls.sync.awaiting_robot_list():
		return PackedStringArray()
	return PackedStringArray([controls.sync.selected])


func _extra_names() -> PackedStringArray:
	return _robot_only() + _unconfirmed()


func _all_names() -> PackedStringArray:
	return _names() + _extra_names()


func is_robot_only(auto_name: String) -> bool:
	return auto_name != NONE and auto_name != "" and not _names().has(auto_name) and _extra_names().has(auto_name)


func _rebuild_cards() -> void:
	list.clear_items()
	cards.clear()
	status_row = null
	var none := AutoCard.new(NONE, "No Auto", "", NO_AUTO_DESC)
	cards.append(none)
	list.add_item(none)
	for n in _names():
		var c := AutoCard.new(n, autos.library.display_name(n), n + ".auto", autos.library.description(n))
		cards.append(c)
		list.add_item(c)
	var robot_only := _robot_only()
	_robot_only_key = "\n".join(_extra_names())
	for n in _extra_names():
		var c := AutoCard.new(n, n, ROBOT_ONLY_FILE if robot_only.has(n) else UNCONFIRMED_FILE, "")
		cards.append(c)
		list.add_item(c)
	if autos != null and _names().is_empty():
		var failed := not autos.library.is_loaded()
		status_row = AutoStatusRow.new(RETRY_TEXT if failed else EMPTY_TEXT, ROSE_TEXT if failed else Tokens.ZINC_500)
		list.add_item(status_row)
	if viewing != NONE and not _all_names().has(viewing):
		viewing = ""


func _on_card_tapped(i: int) -> void:
	if i >= 0 and i < cards.size():
		view(cards[i].auto_name)
	elif status_row != null and i == cards.size():
		if autos != null:
			autos.reload()


func view(auto_name: String) -> void:
	viewing = auto_name
	refresh()


func _build_detail() -> void:
	var col := UiKit.vbox(0)
	_detail_top = UiKit.vbox(10)
	var head := UiKit.vbox(0)
	detail_title = PwText.new("", 34, 600, Tokens.TEXT, 34.0)
	detail_title.name = "DetailTitle"
	head.add_child(detail_title)
	detail_file = PwText.new("", 16, 400, Tokens.ZINC_500, 20.8)
	detail_file.name = "DetailFile"
	head.add_child(UiKit.margin(detail_file, 0, 4, 0, 0))
	_detail_top.add_child(head)
	detail_desc = PwText.new("", 22, 400, Tokens.TEXT, 26.4)
	detail_desc.name = "DetailDescription"
	_detail_top.add_child(detail_desc)
	col.add_child(_detail_top)
	var push := Control.new()
	push.mouse_filter = Control.MOUSE_FILTER_IGNORE
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(push)
	select_button = PwButton.new("Select", PwButton.Style.DARK)
	select_button.name = "Select"
	select_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	select_button.pressed.connect(_on_select)
	col.add_child(select_button)
	_detail_left = UiKit.margin(col, PAD, PAD, PAD, PAD)
	_detail_left.name = "DetailLeft"
	add_child(_detail_left)

	var right := Control.new()
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview = AutoPreviewPanel.new()
	preview.autos = autos
	preview.expand_toggled.connect(set_expanded)
	right.add_child(UiKit.full(preview))
	no_preview = ImageBox.new()
	no_preview.name = "NoPreview"
	howard = HowardError.new()
	(no_preview as ImageBox).add_content(UiKit.full(howard))
	no_preview.visible = false
	right.add_child(UiKit.full(no_preview))
	_detail_right = UiKit.margin(right, PAD, PAD, PAD, PAD)
	_detail_right.name = "DetailRight"
	add_child(_detail_right)


func _show_no_preview(key: String) -> void:
	no_preview.visible = true
	if _no_preview_key == key:
		return
	_no_preview_key = key
	howard.roll()


func set_expanded(on: bool) -> void:
	if on == expanded:
		return
	expanded = on
	preview.set_expanded_icon(on)
	_layout()


func _build_banner() -> Control:
	var b := PanelContainer.new()
	b.name = "LockBanner"
	b.z_index = UiDraw.LAYER_Z
	var sb := PwBox.new()
	sb.bg_color = AMBER_BG
	sb.border_color = AMBER_LINE
	sb.border_width_bottom = 1
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8 + 1
	b.add_theme_stylebox_override("panel", sb)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var text := PwText.new("Auto selector locked while match is active.", 18, 600, AMBER_TEXT, 21.6)
	text.wrap = PwText.Wrap.NONE
	b.add_child(text)
	b.visible = false
	return b


func _build_popup() -> Control:
	var root := Control.new()
	root.name = "ConflictPopup"
	root.z_index = UiDraw.LAYER_Z
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var scrim := PwRect.new()
	scrim.color = Color(0, 0, 0, 0.7)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(UiKit.full(scrim))
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(UiKit.full(UiKit.margin(center, 24, 24, 24, 24)))
	var box := PanelContainer.new()
	box.name = "Box"
	var sb := PwBox.new()
	sb.bg_color = Color("#1f1f1f")
	sb.border_color = Color(ROSE, 0.7)
	sb.set_border_width_all(2)
	sb.set_content_margin_all(2 + 24)
	sb.shadow_color = Color(0, 0, 0, 0.25)
	sb.shadow_size = 25
	box.add_theme_stylebox_override("panel", sb)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.resized.connect(func() -> void: box.custom_minimum_size.x = minf(860.0, root.size.x - 48.0))
	var col := UiKit.vbox(0)
	var top := UiKit.hbox(16)
	var icon := PwIcon.new("triangle-alert", 32, ROSE_TEXT)
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	top.add_child(UiKit.margin(icon, 0, 4, 0, 0))
	var texts := UiKit.vbox(0)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_child(PwText.new("Auto Sync Conflict Detected", 40, 600, Tokens.TEXT, 40.0))
	popup_body = PwText.new("", 26, 400, Color("#f4f4f5"), 32.5)
	texts.add_child(UiKit.margin(popup_body, 0, 12, 0, 0))
	texts.add_child(UiKit.margin(PwText.new("Another dashboard is likely connected and fighting for auto selection.", 22, 400, Tokens.ZINC_300, 27.5), 0, 8, 0, 0))
	top.add_child(texts)
	col.add_child(top)
	var buttons := UiKit.hbox(12)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	var dismiss := PwButton.new("Dismiss", PwButton.Style.DIALOG)
	dismiss.name = "Dismiss"
	dismiss.pressed.connect(func() -> void:
		if controls != null:
			controls.sync.dismiss_conflict()
		refresh())
	buttons.add_child(dismiss)
	resync = PwButton.new("Resync Now", PwButton.Style.DIALOG_PRIMARY)
	resync.name = "Resync"
	resync.pressed.connect(func() -> void:
		if controls != null:
			controls.sync.resync()
		refresh())
	buttons.add_child(resync)
	col.add_child(UiKit.margin(buttons, 0, 24, 0, 0))
	box.add_child(col)
	center.add_child(box)
	root.visible = false
	return root


func _set_popup_body(selected: String) -> void:
	var key := selected if selected != "" else NONE
	if popup_body.has_meta(&"key") and popup_body.get_meta(&"key") == key:
		return
	popup_body.set_meta(&"key", key)
	popup_body.spans = [
		{"text": "Robot auto changed too many times in a short window while this dashboard was trying to enforce "},
		{"text": key, "font": Tokens.inter(600)},
		{"text": "."},
	]
	popup_body.text = "Robot auto changed too many times in a short window while this dashboard was trying to enforce %s." % key


func _on_select() -> void:
	if controls == null or viewing == "":
		return
	controls.sync.select(viewing)
	refresh()


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		refresh()


func _warning_for(auto_name: String) -> String:
	if controls == null:
		return ""
	return AutoSelectionSync.validity_text(controls.sync.validity(auto_name))


## The robot's validity warning first, then a broken export file.
func _card_warning(auto_name: String) -> String:
	var w := _warning_for(auto_name)
	if w != "" or autos == null or not _names().has(auto_name):
		return w
	if autos.library.auto_error(auto_name) != "":
		return "Preview failed to load"
	if autos.library.auto_note(auto_name) != "":
		return "Event copy broken: older preview"
	return ""


const PATHS_DIFFER := "The robot's paths differ from this export: the preview may be out of date"
const EXPORT_OLD := "This export is %s old: re-export the autos if a path changed"


func refresh() -> void:
	if controls == null:
		return
	var sync := controls.sync
	var active := sync.active_name()
	if _robot_only_key != "\n".join(_extra_names()):
		_rebuild_cards()
	if viewing == "":
		viewing = active if active != "" else (_names()[0] if not _names().is_empty() else NONE)
	for c in cards:
		c.set_state(c.auto_name == active, c.auto_name == viewing)
	banner.visible = sync.locked()
	popup.visible = sync.conflict
	resync.disabled = sync.locked()
	_set_popup_body(sync.selected)
	if autos != null and Time.get_ticks_msec() >= _fresh_ms:
		_fresh_ms = Time.get_ticks_msec() + 1000
		var fresh := autos.freshness()
		_fresh_level = fresh.get("level", -1)
		_fresh_age = str(fresh.get("age", ""))
	_refresh_detail()


func _refresh_detail() -> void:
	var sync := controls.sync
	var b := sync.button_for(viewing)
	select_button.text = b["text"]
	select_button.disabled = not b["enabled"]
	select_button.selected = b["selected"]
	var robot_line := "Robot: not connected"
	if sync.robot_known():
		var r := sync.robot_auto()
		robot_line = "Robot reports: %s" % ("No Auto" if r == NONE else r)
	var robot_only := is_robot_only(viewing)
	if viewing == NONE:
		detail_title.text = "No Auto"
		detail_file.get_parent().visible = false
		detail_desc.text = NO_AUTO_DETAIL
		detail_desc.color = Tokens.ZINC_300
		_detail_right.visible = false
		set_expanded(false)
		_fit_desc()
		return
	_detail_right.visible = true
	detail_desc.color = Tokens.TEXT
	detail_file.get_parent().visible = true
	_warning = _card_warning(viewing)
	if robot_only:
		var listed := _robot_only().has(viewing)
		detail_title.text = viewing
		detail_file.text = ROBOT_ONLY_FILE if listed else UNCONFIRMED_FILE
		detail_desc.text = ROBOT_ONLY_DETAIL if listed else UNCONFIRMED_DETAIL
		preview.visible = false
		_show_no_preview("robot:" + viewing)
		set_expanded(false)
		_fit_desc()
		return
	if autos == null:
		return
	var failed := autos.library.auto_error(viewing)
	if _warning == "" and _fresh_level == ExportFreshness.Level.DIFFERS:
		_warning = PATHS_DIFFER
	elif _warning == "" and _fresh_level == ExportFreshness.Level.OLD:
		_warning = EXPORT_OLD % _fresh_age
	preview.visible = failed == ""
	if failed != "":
		_show_no_preview("failed:" + viewing)
		set_expanded(false)
	else:
		no_preview.visible = false
		_no_preview_key = null
		if preview.auto_name != viewing:
			preview.show_auto(viewing)
		preview.set_notes(robot_line, _warning,
			autos.start_check(viewing) if autos.pre_match() and not sync.locked() else {})
	detail_title.text = autos.library.display_name(viewing)
	detail_file.text = viewing + ".auto"
	detail_desc.text = autos.library.description(viewing)
	_fit_desc()


## The description takes whatever height is left above Select, so a long one
## is cut only when it truly cannot fit.
func _fit_desc() -> void:
	if detail_desc == null:
		return
	detail_desc.visible = detail_desc.text != ""
	if _detail_left == null or _detail_left.size.y <= 0.0:
		return
	detail_desc.custom_minimum_size.x = 0.0
	var w := minf(_detail_left.size.x - 2.0 * PAD, DESC_MAX_W)
	detail_desc.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	detail_desc.custom_minimum_size.x = maxf(w, 0.0)
	var head_h := (_detail_top.get_child(0) as Control).get_combined_minimum_size().y
	var avail := _detail_left.size.y - 2.0 * PAD - head_h - 10.0 - select_button.get_combined_minimum_size().y
	var lines := maxi(1, floori(avail / detail_desc.line_px()))
	if detail_desc.max_lines != lines:
		detail_desc.max_lines = lines
		detail_desc.update_minimum_size()
		detail_desc.queue_redraw()


func card(auto_name: String) -> AutoCard:
	for c in cards:
		if c.auto_name == auto_name:
			return c
	return null


func probe() -> Dictionary:
	var card_states := {}
	for c in cards:
		card_states[c.auto_name] = c.report()
	var lib_summary := AutoExportBox.summary_text(autos.library, autos.freshness()) if autos != null else ""
	return {
		"viewing": viewing, "button": select_button.text, "button_enabled": not select_button.disabled,
		"button_selected": select_button.selected, "banner": banner.visible,
		"popup": popup.visible, "resync_enabled": not resync.disabled, "cards": card_states,
		"card_count": cards.size(), "detail_title": detail_title.text, "warning": _warning if preview.visible else "",
		"robot_line": preview.robot_line.text.text if preview.visible and preview.robot_line.visible else "",
		"list_scroll": list.scroll_offset, "status_row": status_row.text.text if status_row != null else "",
		"detail_file": detail_file.text, "preview": preview.probe() if preview.visible else {},
		"expanded": expanded, "list_visible": list.visible, "no_preview": no_preview.visible,
		"no_preview_title": howard.heading.text if no_preview.visible else "",
		"start_chip": preview.start_chip.text.text if preview.start_chip.visible else "", "start_level": preview.start_chip.level,
		"summary": lib_summary, "fresh_level": _fresh_level, "robot_only": Array(_robot_only()), "unconfirmed": Array(_unconfirmed()),
		"title_lines": detail_title.line_count(), "desc_lines": detail_desc.line_count(),
		"desc_clipped": detail_desc._para != null and detail_desc._para.get_line_count() > detail_desc.line_count(),
	}
