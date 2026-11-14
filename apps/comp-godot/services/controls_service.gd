class_name ControlsService
extends Node

## The robot controls of the touchscreen: auto selection, intake speed and aim
## trim, each a pure controller in core/controls updated once per frame. Binds
## them to the NT autoload, persists the selected auto and the intake override
## in Settings, follows the auto library and moves the request topics when the
## connection settings change.

var nt: NtService
var settings: SettingsService
var autos: AutosService
var clock := Clock.new()
var link: ControlLink
var sync: AutoSelectionSync
var intake: IntakeSpeed
var trim: AimTrim


func _init() -> void:
	process_priority = -800


func _ready() -> void:
	if nt == null:
		nt = get_node_or_null("/root/NT") as NtService
	if settings == null:
		settings = get_node_or_null("/root/Settings") as SettingsService
	if autos == null:
		autos = get_node_or_null("/root/Autos") as AutosService
	if link == null:
		link = NtControlLink.new(nt)
	var conn := _nt_conf()
	var stored := settings.controls() if settings != null else AppSettings.DEFAULT_CONTROLS
	sync = AutoSelectionSync.new(link, clock, Topics.selected_auto_topics(conn), str(stored.get("selected_auto", "")))
	intake = IntakeSpeed.new(link, Topics.intake_speed_topics(conn), stored.get("intake_speed"))
	trim = AimTrim.new(link)
	if autos != null:
		sync.set_library(autos.library.names())
		autos.library_changed.connect(func() -> void: sync.set_library(autos.library.names()))
	sync.selection_changed.connect(func(s: String) -> void: _persist({"selected_auto": s}))
	intake.requested_changed.connect(func(r: Variant) -> void: _persist({"intake_speed": r}))
	if settings != null:
		settings.changed.connect(_on_settings_changed)


func _nt_conf() -> Dictionary:
	return settings.connection()["nt"] if settings != null else ConnectionSettings.DEFAULT_NT


func _persist(patch: Dictionary) -> void:
	if settings != null:
		settings.set_controls(patch)


func _on_settings_changed(section: String) -> void:
	if section != "connection":
		return
	var conn := _nt_conf()
	sync.set_topics(Topics.selected_auto_topics(conn))
	intake.set_topics(Topics.intake_speed_topics(conn))


func _process(_delta: float) -> void:
	step()


func step() -> void:
	sync.update()
	intake.update()
	trim.update()


func readouts() -> Array:
	return ShooterReadouts.rows(link)


## Dev fixture "controls": {"selected_auto", "intake_speed", "conflict", "trim_requested"}.
func apply_fixture(fx: Dictionary) -> void:
	if fx.has("selected_auto"):
		sync.selected = str(fx["selected_auto"])
	if fx.has("intake_speed"):
		intake.requested = fx["intake_speed"]
	if fx.get("conflict", false):
		sync.conflict = true
		sync.conflict_changed.emit(true)
	if fx.has("trim_requested"):
		trim.requested = float(fx["trim_requested"])
		trim.last_sent = trim.requested


func snapshot() -> Dictionary:
	return {"auto": sync.snapshot(), "intake": intake.snapshot(), "trim": trim.snapshot(), "readouts": readouts()}
