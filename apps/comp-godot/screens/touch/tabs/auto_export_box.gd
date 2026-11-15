class_name AutoExportBox
extends VBoxContainer

## Godot-only, in the web's Assets style (VisualTab.tsx): which auto export the
## Auto tab previews (built-in or event update, export time, whether it
## matches the robot's paths) as a 14 px paragraph colored by that trust,
## above an outline Reload Autos button.

var autos: AutosService
var summary: PwText
var reload_button: PwButton
var _t := 0.0


func _init() -> void:
	name = "AutoExport"
	add_theme_constant_override("separation", 8)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	summary = PwText.new("", 14, 400, Tokens.ZINC_400, 20.0)
	summary.name = "AutoExportSummary"
	add_child(summary)
	reload_button = PwButton.new("Reload Autos", PwButton.Style.OUTLINE)
	reload_button.name = "ReloadAutos"
	reload_button.pressed.connect(reload)
	add_child(reload_button)


func _ready() -> void:
	if autos == null:
		autos = get_node_or_null("/root/Autos") as AutosService
	if autos != null:
		autos.library_changed.connect(refresh)
	refresh()


func reload() -> void:
	if autos != null:
		autos.reload()
	refresh()


static func summary_text(lib: AutoLibrary, fresh: Dictionary = {}) -> String:
	if not lib.is_loaded():
		return "No auto export loaded"
	var where := "built-in" if lib.dir == AutoLibrary.BUILTIN_DIR else "event update"
	var extra := str(fresh.get("text", ""))
	return "%d autos · %s%s\nexported %s UTC" % [lib.names().size(), where, " · " + extra if extra != "" else "",
		AutoLibrary.short_time(lib.exported_at())]


func refresh() -> void:
	if autos == null:
		return
	var fresh := autos.freshness()
	summary.text = summary_text(autos.library, fresh)
	summary.color = ExportFreshness.color(fresh.get("level", ExportFreshness.Level.FRESH))


func _process(delta: float) -> void:
	_t += delta
	if _t >= 1.0 and is_visible_in_tree():
		_t = 0.0
		refresh()
