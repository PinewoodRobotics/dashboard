class_name ExportFreshness
extends RefCounted

## Whether the preview can be trusted to match the robot's paths. A path edited
## and deployed without a re-export still has the same auto names, so the
## robot's list cannot tell. When the robot publishes the hash of its
## deploy/pathplanner folder (Topics.PP_DEPLOY_HASH) it is compared with the
## export's source_hash; otherwise the export's age is the only hint.

enum Level { FRESH, OLD, MATCHES_ROBOT, DIFFERS }

const OLD_AFTER_S := 3 * 86400


static func check(exported_at: String, source_hash: String, robot_hash: Variant, now_unix: float) -> Dictionary:
	var age := age_s(exported_at, now_unix)
	var out := {"age_s": age, "age": age_text(age)}
	if robot_hash is String and robot_hash != "":
		var same: bool = source_hash != "" and (robot_hash as String).to_lower() == source_hash.to_lower()
		out["level"] = Level.MATCHES_ROBOT if same else Level.DIFFERS
		out["text"] = "matches robot" if same else "differs from robot"
	elif age > OLD_AFTER_S:
		out["level"] = Level.OLD
		out["text"] = "%s old" % out["age"]
	else:
		out["level"] = Level.FRESH
		out["text"] = "%s ago" % out["age"] if age >= 0.0 else ""
	return out


## -1 when the time cannot be parsed.
static func age_s(exported_at: String, now_unix: float) -> float:
	var iso := exported_at.strip_edges().trim_suffix("Z")
	if iso.length() < 19:
		return -1.0
	var t := Time.get_unix_time_from_datetime_string(iso)
	if t <= 0 or t > now_unix + 60.0:
		return -1.0
	return maxf(0.0, now_unix - t)


static func age_text(s: float) -> String:
	if s < 0.0:
		return "unknown age"
	if s < 3600.0:
		return "%d min" % maxi(1, floori(s / 60.0))
	if s < 86400.0:
		return "%d h" % floori(s / 3600.0)
	return "%d d" % floori(s / 86400.0)


static func color(level: int) -> Color:
	match level:
		Level.MATCHES_ROBOT:
			return Tokens.ACCENT
		Level.DIFFERS:
			return Color("#fb7185")
		Level.OLD:
			return Color("#fbbf24")
	return Tokens.ZINC_400
