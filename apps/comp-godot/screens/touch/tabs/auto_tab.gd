class_name AutoTab
extends Control

## Auto selector (AutoSelector.tsx). Left third: "No Auto" plus every exported
## auto with its display name and description; a tap views it. Right: the
## viewed auto with its Select button (Selecting..., Selected, Locked During
## Match), the robot's view of it, and the auto's exported timeline. An amber
## banner shows while the robot is enabled, a popup when another dashboard
## fights over the selection. Selection logic lives in AutoSelectionSync.

const NONE := AutoSelectionSync.NONE
const NO_AUTO_DESC := "Do not run an autonomous routine"
const NO_AUTO_DETAIL := "Do not run an autonomous routine. The robot will stay still during autonomous."
const AMBER_BG := Color(0.961, 0.62, 0.043, 0.15)
const AMBER_LINE := Color(0.984, 0.749, 0.141, 0.6)
const AMBER_TEXT := Color("#fef3c7")
const ROSE := Color("#f43f5e")
const ROSE_TEXT := Color("#fb7185")
const LIST_W_FRACTION := 1.0 / 3.0
const BANNER_H := 44.0
const DETAIL_LEFT_W := 360.0

var controls: ControlsService
var autos: AutosService
var list: PwTapList
var cards: Array[AutoCard] = []
var viewing := ""
var detail_title: Label
var detail_file: Label
var detail_desc: Label
var detail_warning: Label
var detail_robot: Label
var select_button: PwButton
var preview: AutoPreviewPanel
var banner: Control
var popup: Control
var popup_body: Label
var resync: PwButton
var _list_pane: Control
var _detail_pane: Control


func _ready() -> void:
	if controls == null:
		controls = get_node_or_null("/root/Controls") as ControlsService
	if autos == null:
		autos = get_node_or_null("/root/Autos") as AutosService
	clip_contents = true

	_list_pane = Control.new()
	_list_pane.name = "ListPane"
	_list_pane.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_list_pane)
	list = PwTapList.new(10)
	list.name = "List"
	list.item_tapped.connect(_on_card_tapped)
	_list_pane.add_child(list)

	_detail_pane = _build_detail()
	add_child(_detail_pane)
	banner = _build_banner()
	add_child(banner)
	popup = _build_popup()
	add_child(popup)

	_rebuild_cards()
	if autos != null:
		autos.library_changed.connect(_rebuild_cards)
	resized.connect(_layout)
	_layout()
	refresh()


## The lock banner pushes both panes down instead of covering the first card.
func _layout() -> void:
	var top := BANNER_H if banner.visible else 0.0
	var list_w := floorf(size.x * LIST_W_FRACTION)
	_list_pane.position = Vector2(0, top)
	_list_pane.size = Vector2(list_w, size.y - top)
	list.position = Vector2(10, 10)
	list.size = Vector2(list_w - 20, size.y - top - 20)
	_detail_pane.position = Vector2(list_w, top)
	_detail_pane.size = Vector2(size.x - list_w, size.y - top)
	banner.position = Vector2.ZERO
	banner.size = Vector2(size.x, BANNER_H)
	popup.position = Vector2.ZERO
	popup.size = size


func _names() -> PackedStringArray:
	return autos.library.names() if autos != null else PackedStringArray()


func _rebuild_cards() -> void:
	list.clear_items()
	cards.clear()
	var none := AutoCard.new(NONE, "No Auto", "", NO_AUTO_DESC)
	cards.append(none)
	list.add_item(none)
	for n in _names():
		var c := AutoCard.new(n, autos.library.display_name(n), n + ".auto", autos.library.description(n))
		cards.append(c)
		list.add_item(c)
	if viewing != NONE and not _names().has(viewing):
		viewing = ""


func _on_card_tapped(i: int) -> void:
	if i >= 0 and i < cards.size():
		view(cards[i].auto_name)


func view(auto_name: String) -> void:
	viewing = auto_name
	refresh()


func _build_detail() -> Control:
	var pane := Control.new()
	pane.name = "DetailPane"
	pane.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := UiKit.hbox(24)
	var left := UiKit.vbox(8)
	left.custom_minimum_size.x = DETAIL_LEFT_W
	detail_title = UiKit.label("", 34, 600)
	detail_title.name = "DetailTitle"
	detail_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	detail_title.clip_text = true
	detail_title.custom_minimum_size.x = DETAIL_LEFT_W
	left.add_child(detail_title)
	detail_file = UiKit.label("", 16, 400, Tokens.ZINC_500)
	detail_file.clip_text = true
	detail_file.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	detail_file.custom_minimum_size.x = DETAIL_LEFT_W
	left.add_child(detail_file)
	detail_desc = UiKit.wrapped("", 20, Tokens.ZINC_300)
	detail_desc.custom_minimum_size.x = DETAIL_LEFT_W
	detail_desc.max_lines_visible = 4
	left.add_child(detail_desc)
	var warn_row := UiKit.hbox(8)
	warn_row.name = "DetailWarningRow"
	warn_row.add_child(PwIcon.new("triangle-alert", 22, AutoCard.AMBER))
	detail_warning = UiKit.label("", 20, 500, AutoCard.AMBER)
	detail_warning.name = "DetailWarning"
	detail_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_warning.custom_minimum_size.x = DETAIL_LEFT_W - 30
	warn_row.add_child(detail_warning)
	left.add_child(warn_row)
	detail_robot = UiKit.label("", 18, 400, Tokens.ZINC_400)
	detail_robot.name = "DetailRobot"
	detail_robot.clip_text = true
	detail_robot.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	detail_robot.custom_minimum_size.x = DETAIL_LEFT_W
	left.add_child(detail_robot)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(spacer)
	select_button = PwButton.new("Select", PwButton.Style.DARK, Vector2(DETAIL_LEFT_W, 84))
	select_button.name = "Select"
	select_button.font_size = 34
	select_button.radius = 0.0
	select_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	select_button.pressed.connect(_on_select)
	left.add_child(select_button)
	row.add_child(left)

	preview = AutoPreviewPanel.new()
	preview.autos = autos
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(preview)
	pane.add_child(UiKit.full(UiKit.margin(row, 24, 24, 24, 24)))
	return pane


func _build_banner() -> Control:
	var b := PanelContainer.new()
	b.name = "LockBanner"
	var sb := StyleBoxFlat.new()
	sb.bg_color = AMBER_BG
	sb.border_color = AMBER_LINE
	sb.border_width_bottom = 1
	sb.content_margin_left = 20
	sb.content_margin_top = 8
	b.add_theme_stylebox_override("panel", sb)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := UiKit.hbox(10)
	row.add_child(PwIcon.new("lock", 20, AMBER_TEXT))
	row.add_child(UiKit.label("Auto selector locked while match is active.", 18, 600, AMBER_TEXT))
	b.add_child(row)
	b.visible = false
	return b


func _build_popup() -> Control:
	var root := Control.new()
	root.name = "ConflictPopup"
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.7)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(UiKit.full(scrim))
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(UiKit.full(center))
	var box := PanelContainer.new()
	box.name = "Box"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#1f1f1f")
	sb.border_color = Color(ROSE, 0.7)
	sb.set_border_width_all(2)
	sb.set_content_margin_all(24)
	box.add_theme_stylebox_override("panel", sb)
	box.custom_minimum_size.x = 860
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := UiKit.vbox(20)
	var top := UiKit.hbox(16)
	var icon := PwIcon.new("triangle-alert", 36, ROSE_TEXT)
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	top.add_child(icon)
	var texts := UiKit.vbox(10)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_child(UiKit.label("Auto Sync Conflict Detected", 40, 600))
	popup_body = UiKit.wrapped("", 26, Tokens.ZINC_300)
	popup_body.add_theme_color_override("font_color", Color("#f4f4f5"))
	popup_body.custom_minimum_size.x = 740
	texts.add_child(popup_body)
	texts.add_child(UiKit.wrapped("Another dashboard is likely connected and fighting for auto selection.", 22, Tokens.ZINC_300))
	top.add_child(texts)
	col.add_child(top)
	var buttons := UiKit.hbox(12)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	var dismiss := PwButton.new("Dismiss", PwButton.Style.DARK, Vector2(150, 52))
	dismiss.name = "Dismiss"
	dismiss.font_size = 22
	dismiss.pressed.connect(func() -> void:
		if controls != null:
			controls.sync.dismiss_conflict()
		refresh())
	buttons.add_child(dismiss)
	resync = PwButton.new("Resync Now", PwButton.Style.PRIMARY, Vector2(190, 52))
	resync.name = "Resync"
	resync.font_size = 22
	resync.pressed.connect(func() -> void:
		if controls != null:
			controls.sync.resync()
		refresh())
	buttons.add_child(resync)
	col.add_child(buttons)
	box.add_child(col)
	center.add_child(box)
	root.visible = false
	return root


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


func refresh() -> void:
	if controls == null:
		return
	var sync := controls.sync
	var active := sync.active_name()
	if viewing == "":
		viewing = active if active != "" else (cards[1].auto_name if cards.size() > 1 else NONE)
	for c in cards:
		c.set_state(c.auto_name == active, c.auto_name == viewing, _warning_for(c.auto_name) if c.auto_name != NONE else "")
	if banner.visible != sync.locked():
		banner.visible = sync.locked()
		_layout()
	popup.visible = sync.conflict
	resync.disabled = sync.locked()
	popup_body.text = "Robot auto changed too many times in a short window while this dashboard was trying to enforce %s." % (sync.selected if sync.selected != "" else NONE)
	_refresh_detail(active)


func _refresh_detail(active: String) -> void:
	var sync := controls.sync
	var b := sync.button_for(viewing)
	select_button.text = b["text"]
	select_button.disabled = not b["enabled"]
	select_button.variant = PwButton.Style.PRIMARY if b["selected"] else PwButton.Style.DARK
	var robot_line := "Robot: not connected"
	if sync.robot_known():
		var r := sync.robot_auto()
		robot_line = "Robot reports: %s" % ("No Auto" if r == NONE else r)
	detail_robot.text = robot_line
	var warn := _warning_for(viewing) if viewing != NONE else ""
	detail_warning.text = warn
	detail_warning.get_parent().visible = warn != ""
	if viewing == NONE:
		detail_title.text = "No Auto"
		detail_file.text = ""
		detail_desc.text = NO_AUTO_DETAIL
		preview.visible = false
		return
	if autos == null:
		return
	preview.visible = true
	if preview.auto_name != viewing:
		preview.show_auto(viewing)
	detail_title.text = autos.library.display_name(viewing)
	detail_file.text = file_line(viewing)
	detail_desc.text = autos.library.description(viewing)


func file_line(auto_name: String) -> String:
	var p := autos.library.get_auto(auto_name)
	if p == null:
		return auto_name + ".auto"
	var path := "path %.1f s" % p.duration_s if p.has_path() else "no path"
	return "%s.auto  ·  %s  ·  %s %.1f s" % [auto_name, path, "ends at" if p.ends_by_itself else "runs to", p.timeline_s()]


func card(auto_name: String) -> AutoCard:
	for c in cards:
		if c.auto_name == auto_name:
			return c
	return null


func probe() -> Dictionary:
	var card_states := {}
	for c in cards:
		card_states[c.auto_name] = c.report()
	return {
		"viewing": viewing, "button": select_button.text, "button_enabled": not select_button.disabled,
		"button_selected": select_button.variant == PwButton.Style.PRIMARY, "banner": banner.visible,
		"popup": popup.visible, "resync_enabled": not resync.disabled, "cards": card_states,
		"card_count": cards.size(), "detail_title": detail_title.text, "detail_warning": detail_warning.text,
		"detail_robot": detail_robot.text, "list_scroll": list.scroll_offset,
		"detail_file": detail_file.text, "preview": preview.probe() if preview.visible else {},
	}
