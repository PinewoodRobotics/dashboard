class_name CliArgs
extends RefCounted

## Parses user args (after `--`): `--key=value` and bare `--flag` (true).
static func parse(args: PackedStringArray) -> Dictionary:
	var out := {}
	for a in args:
		if not a.begins_with("--"):
			continue
		var body := a.substr(2)
		var eq := body.find("=")
		if eq < 0:
			out[body.replace("-", "_")] = true
		else:
			out[body.substr(0, eq).replace("-", "_")] = body.substr(eq + 1)
	return out


static func get_int(args: Dictionary, key: String, default: int) -> int:
	var v: Variant = args.get(key)
	return int(v) if typeof(v) == TYPE_STRING and (v as String).is_valid_int() else default


static func get_float(args: Dictionary, key: String, default: float) -> float:
	var v: Variant = args.get(key)
	return float(v) if typeof(v) == TYPE_STRING and (v as String).is_valid_float() else default
