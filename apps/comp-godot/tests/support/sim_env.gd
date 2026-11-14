class_name SimEnv
extends RefCounted

const GOLDEN_HANDSHAKE := "res://tests/golden/sim_handshake.json"
const GOLDEN_AIMTRIM := "res://tests/golden/sim_aimtrim_readback.json"


static func port() -> int:
	var p := OS.get_environment("PWRUP_SIM_PORT")
	return int(p) if p != "" else 0


static func capture_golden() -> bool:
	return OS.get_environment("PWRUP_SIM_CAPTURE_GOLDEN") == "1"


static func write_json(res_path: String, data: Variant) -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(res_path), FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  ") + "\n")
	f.close()
