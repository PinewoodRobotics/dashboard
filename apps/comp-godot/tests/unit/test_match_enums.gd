extends TestCase


func test_phase_mapping() -> void:
	for i in 9:
		check_eq(MatchEnums.phase(i), i)
	check_eq(MatchEnums.PHASE_NAMES[MatchEnums.phase(3)], "shift1")
	check_eq(MatchEnums.phase(8.0), MatchEnums.Phase.POST_MATCH, "integral double")


func test_unknown_values_map_to_defaults() -> void:
	for bad: Variant in [-1, 9, 42, 2.5, NAN, INF, "3", null, true, [1]]:
		check_eq(MatchEnums.phase(bad), MatchEnums.Phase.PRE_MATCH, "phase %s" % var_to_str(bad))
		check_eq(MatchEnums.hub(bad), MatchEnums.Hub.NONE, "hub %s" % var_to_str(bad))
		check_eq(MatchEnums.header(bad), MatchEnums.Header.HIDDEN, "header %s" % var_to_str(bad))
		check_eq(MatchEnums.aim(bad), MatchEnums.Aim.SHOOTER_DISABLED, "aim %s" % var_to_str(bad))
	check_eq(MatchEnums.hub(5), MatchEnums.Hub.NONE)
	check_eq(MatchEnums.header(4), MatchEnums.Header.HIDDEN)
	check_eq(MatchEnums.aim(3), MatchEnums.Aim.SHOOTER_DISABLED)


func test_enum_values_match_robot() -> void:
	check_eq(MatchEnums.hub(3), MatchEnums.Hub.WARNING)
	check_eq(MatchEnums.header(1), MatchEnums.Header.GREEN)
	check_eq(MatchEnums.header(2), MatchEnums.Header.YELLOW)
	check_eq(MatchEnums.header(3), MatchEnums.Header.PURPLE)
	check_eq(MatchEnums.aim(1), MatchEnums.Aim.GPS_AUTO)
	check_eq(MatchEnums.aim(2), MatchEnums.Aim.MANUAL_AIMING)
	check_eq(MatchEnums.HEADER_NAMES, ["hidden", "green", "yellow", "purple"])
	check_eq(MatchEnums.HUB_NAMES, ["none", "both", "active", "warning", "inactive"])
