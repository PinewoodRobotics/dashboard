extends TestCase

## The M6 touchscreen views over a ControlsService on a FakeControlLink:
## auto selector cards, Select button states, lock banner and conflict popup,
## connection settings form and the intake/aim trim panel.

const REQ := "/Shared/PathPlanner/SelectedPath/Request"
const STATE := "/Shared/PathPlanner/SelectedPath/State"

var link: FakeControlLink
var settings: SettingsService
var controls: ControlsService
var host: Control
var dir := ""
var _env_before := ""


func before_each() -> void:
	dir = ProjectSettings.globalize_path("res://.scratch/unit/m6ui_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	_env_before = OS.get_environment(ConnectionSettings.ENV_PATH)
	OS.set_environment(ConnectionSettings.ENV_PATH, dir.path_join("connection-settings.json"))
	link = FakeControlLink.new()
	settings = SettingsService.new()
	settings.persist = false
	tree.root.add_child(settings)
	controls = ControlsService.new()
	controls.link = link
	controls.settings = settings
	controls.set_process(false)
	tree.root.add_child(controls)
	host = Control.new()
	host.size = Vector2(1752, 515)
	tree.root.add_child(host)


func after_each() -> void:
	for n: Node in [host, controls, settings]:
		if is_instance_valid(n):
			n.queue_free()
	OS.set_environment(ConnectionSettings.ENV_PATH, _env_before)
	await tree.process_frame
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func _auto_tab() -> AutoTab:
	var t := AutoTab.new()
	t.controls = controls
	t.size = host.size
	host.add_child(t)
	t.set_process(false)
	return t


func test_auto_list_is_no_auto_plus_every_export() -> void:
	var t := _auto_tab()
	var names := t.autos.library.names()
	check(names.size() >= 9, "exported autos: %d" % names.size())
	check_eq(t.cards.size(), names.size() + 1)
	check_eq(t.cards[0].auto_name, "NONE")
	check_eq(t.cards[0].title.text, "No Auto")
	for i in names.size():
		var c := t.cards[i + 1]
		check_eq(c.auto_name, names[i])
		check_eq(c.title.text, t.autos.library.display_name(names[i]))
		check_eq(c.desc.text, t.autos.library.description(names[i]))
	check_eq(t.card("Climber Right Left").title.text, "Climber Left to Right", "display name from auto_meta.json")


func test_tap_views_and_select_selects() -> void:
	var t := _auto_tab()
	link.up = true
	controls.step()
	t.view("Stay And Shoot")
	check_eq(t.viewing, "Stay And Shoot")
	check_eq(link.count(REQ), 0, "viewing does not select")
	check_eq(t.select_button.text, "Select")
	t._on_select()
	check_eq(link.last(REQ), "Stay And Shoot")
	check_eq(settings.controls()["selected_auto"], "Stay And Shoot", "persisted")
	check_eq(t.select_button.text, "Selecting...")
	check(t.select_button.disabled)
	link.values[STATE] = "Stay And Shoot"
	controls.step()
	t.refresh()
	check_eq(t.select_button.text, "Selected")
	check(t.probe()["cards"]["Stay And Shoot"]["active"])
	t.view("NONE")
	t._on_select()
	check_eq(link.last(REQ), "NONE", "No Auto publishes NONE")
	check_eq(settings.controls()["selected_auto"], "NONE")


func test_lock_banner_and_locked_button() -> void:
	var t := _auto_tab()
	link.up = true
	link.values["/matchhud/state/enabled"] = true
	controls.step()
	t.view("Stay And Shoot")
	check(t.banner.visible, "banner")
	check_eq(t.select_button.text, "Locked During Match")
	check(t.select_button.disabled)
	var n := link.published.size()
	t._on_select()
	check_eq(link.published.size(), n, "no publish while locked")
	check(t._list_pane.position.y >= AutoTab.BANNER_H, "banner pushes the list down")


func test_conflict_popup_dismiss_and_resync() -> void:
	var t := _auto_tab()
	link.up = true
	controls.sync.select("Ball Shooter Left")
	controls.sync.conflict = true
	t.refresh()
	check(t.popup.visible)
	check(t.popup_body.text.contains("Ball Shooter Left"))
	controls.sync.dismiss_conflict()
	t.refresh()
	check(not t.popup.visible, "Dismiss")
	controls.sync.conflict = true
	controls.sync.clock.freeze(controls.sync.clock.now_us() + 5_000_000)
	var n := link.count(REQ)
	controls.sync.resync()
	t.refresh()
	check(not t.popup.visible)
	check_eq(link.count(REQ), n + 1, "Resync Now republishes")


func test_validity_warning_on_card_and_detail() -> void:
	var t := _auto_tab()
	link.up = true
	link.values[Topics.PP_VALID_AUTOS] = PackedStringArray(["Stay And Shoot"])
	controls.sync.select("Ball Shooter Left")
	t.view("Ball Shooter Left")
	check_eq(t.card("Ball Shooter Left").warning.text, "Not in the robot's auto list")
	check_eq(t.card("Stay And Shoot").warning.text, "")
	check_eq(t.detail_warning.text, "Not in the robot's auto list")


func test_settings_form_save_and_reset() -> void:
	var nt := NtService.new()
	tree.root.add_child(nt)
	var st := SettingsTab.new()
	st.settings = settings
	st.nt = nt
	host.add_child(st)
	check(st.save.disabled, "nothing changed")
	check_eq(st.status_label.text, "Disconnected")
	check(st.reconnect.visible, "Reconnect shown while disconnected")
	st.host.set_text("127.0.0.1", true)
	check(not st.save.disabled)
	st.port.set_text("", true)
	check(st.save.disabled and st.port.invalid, "blank port")
	st.port.set_text("5811", true)
	st.table.set_text("Tbl", true)
	check_eq(st.probe()["preview"]["request"], "/Tbl/PathPlanner/SelectedPath/Request")
	st.timeout.set_value(4.0, true)
	st._on_save()
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ConnectionSettings.shared_file_path()))
	check_eq(raw["settings"]["networkTables"]["host"], "127.0.0.1")
	check_eq(raw["settings"]["networkTables"]["port"], 5811.0)
	check_eq(raw["settings"]["reconnectTimeoutSeconds"], 4.0)
	check(st.save.disabled, "saved: no changes left")
	st._on_reset()
	check_eq(st.drafts["host"], "10.47.65.2")
	check_eq(st.drafts["sharedTable"], "Shared")
	check_eq(st.timeout.value, 10.0)
	nt.queue_free()


func test_intake_panel_statuses() -> void:
	var p := IntakePanel.new()
	p.controls = controls
	p.size = Vector2(426, 475)
	host.add_child(p)
	p.refresh()
	check_eq(p.speed_status.text, IntakeSpeed.STATUS_DISCONNECTED)
	check(p.trim.disabled and p.center.disabled, "aim trim disabled when not connected")
	check_eq(p.probe()["readouts"]["Mode"], "--")
	link.up = true
	link.values["/Shared/Intake/Speed/State"] = 0.5
	controls.step()
	p.refresh()
	check_eq(p.speed_status.text, IntakeSpeed.STATUS_CONSTANT)
	check_eq(p.speed.value, 0.5)
	p.speed.set_value(0.42, true)
	check_eq(link.last("/Shared/Intake/Speed/Request"), 0.42)
	check_eq(settings.controls()["intake_speed"], 0.42)
	p.refresh()
	check_eq(p.speed_status.text, IntakeSpeed.STATUS_WAITING)
	link.values["/Shared/Intake/Speed/State"] = 0.42
	p.refresh()
	check_eq(p.speed_status.text, IntakeSpeed.STATUS_CONFIRMED)
	p.reset.pressed.emit()
	check_eq(link.last("/Shared/Intake/Speed/Request"), -1.0)
	check_eq(settings.controls()["intake_speed"], null)
	check(not p.trim.disabled)
	p.trim.set_value(2.5, true)
	check_eq(link.last(Topics.AIM_TRIM_PUBLISH), 2.5)
	p.refresh()
	check_eq(p.trim.formatted(), "2.5° L")
	check_eq(p.trim_status.text, AimTrim.STATUS_WAITING)
	p.center.pressed.emit()
	check_eq(link.last(Topics.AIM_TRIM_PUBLISH), 0.0)
	check(p.trim.reversed)
	check_eq([p.trim.min_value, p.trim.max_value, p.trim.step], [-10.0, 10.0, 0.25])
	check_eq([p.speed.min_value, p.speed.max_value, p.speed.step], [0.0, 1.0, 0.01])


func test_failed_library_shows_a_retry_row_that_reloads() -> void:
	var autos := AutosService.new()
	tree.root.add_child(autos)
	autos.library = AutoLibrary.load_best([dir.path_join("no-export")])
	var t := AutoTab.new()
	t.controls = controls
	t.autos = autos
	t.size = host.size
	host.add_child(t)
	t.set_process(false)
	check_eq(t.cards.size(), 2, "No Auto plus the status row")
	var row := t.cards[1]
	check_eq(row.auto_name, AutoTab.RETRY)
	check_eq(row.title.text, "Failed to load autos")
	check(row.desc.text.ends_with("Tap to retry."), row.desc.text)
	check_eq(t.viewing, "NONE", "nothing to view but No Auto")
	t._on_card_tapped(1)
	check(autos.library.is_loaded(), "tapping the row reloads the library")
	check_eq(t.cards.size(), autos.library.names().size() + 1, "the cards come back")
	check(t.card(AutoTab.RETRY) == null, "status row gone")
	autos.queue_free()


func _copy_export(to: String, exported_at: String, extra: String = "") -> void:
	DirAccess.make_dir_recursive_absolute(to)
	var src := ProjectSettings.globalize_path(AutoLibrary.BUILTIN_DIR)
	for f in DirAccess.get_files_at(src):
		if f.ends_with(".json"):
			DirAccess.copy_absolute(src.path_join(f), to.path_join(f))
	var idx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(to.path_join("index.json")))
	idx["exported_at"] = exported_at
	if extra != "":
		var e: Dictionary = (idx["autos"][0] as Dictionary).duplicate(true)
		var body: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(to.path_join(str(e["file"]))))
		body["name"] = extra
		e["name"] = extra
		e["file"] = extra + ".json"
		idx["autos"].append(e)
		var bf := FileAccess.open(to.path_join(extra + ".json"), FileAccess.WRITE)
		bf.store_string(JSON.stringify(body))
		bf.close()
	var out := FileAccess.open(to.path_join("index.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(idx))
	out.close()


func test_reload_autos_picks_up_a_newer_user_export() -> void:
	var user := dir.path_join("user_autos")
	var autos := AutosService.new()
	autos.library_dirs = [user, AutoLibrary.BUILTIN_DIR]
	tree.root.add_child(autos)
	var t := AutoTab.new()
	t.controls = controls
	t.autos = autos
	t.size = host.size
	host.add_child(t)
	t.set_process(false)
	check_eq(autos.library.dir, AutoLibrary.BUILTIN_DIR)
	check(t.list_summary.text.begins_with("9 autos · built-in · "), t.list_summary.text)
	_copy_export(user, "2999-01-02T03:04:05Z", "Event Fix Auto")
	t.reload_button.pressed.emit()
	check_eq(autos.library.dir, user, "Reload Autos loads the newer export")
	check_eq(t.list_summary.text, "10 autos · event update · 2999-01-02 03:04 UTC")
	check(t.card("Event Fix Auto") != null, "the new auto has a card")
	check(autos.library.get_auto("Event Fix Auto") != null)
	autos.queue_free()


func test_robot_only_autos_get_cards_without_preview() -> void:
	var autos := AutosService.new()
	tree.root.add_child(autos)
	controls.autos = autos
	controls.sync.set_library(autos.library.names())
	var t := AutoTab.new()
	t.controls = controls
	t.autos = autos
	t.size = host.size
	host.add_child(t)
	t.set_process(false)
	var base := t.cards.size()
	link.up = true
	link.values[Topics.PP_VALID_AUTOS] = PackedStringArray(autos.library.names()) + PackedStringArray(["Fresh Auto"])
	link.values[STATE] = "Stay And Shoot"
	controls.step()
	t.refresh()
	check_eq(t.cards.size(), base + 1)
	var c := t.card("Fresh Auto")
	check(c != null and c.file.text == AutoTab.ROBOT_ONLY_FILE)
	t.view("Fresh Auto")
	check(t.no_preview.visible and not t.preview.visible)
	check_eq(t.detail_title.text, "Fresh Auto")
	check_eq(t.select_button.text, "Select")
	t._on_select()
	check_eq(link.last(REQ), "Fresh Auto")
	link.up = false
	controls.step()
	t.refresh()
	check(t.card("Fresh Auto") != null, "kept while the robot is away")
	autos.queue_free()
