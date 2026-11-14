extends TestCase


func _ready_model() -> MatchModel:
	var m := MatchModel.new()
	m.set_nt_ready(true, 0)
	return m


func test_has_data_and_connected() -> void:
	var m := MatchModel.new()
	check(not m.has_data() and not m.connected())
	check_eq(m.banner(), MatchModel.Banner.DISCONNECTED)
	m.set_nt_ready(true, 0)
	check(not m.connected(), "socket up, no robot data")
	check_eq(m.banner(), MatchModel.Banner.NO_DATA)
	m.ingest("seq", 0, 0)
	check(not m.has_data(), "seq 0 is not data")
	m.ingest("seq", 1, 0)
	check(m.has_data() and m.connected())
	m.step(0)
	check_eq(m.banner(), MatchModel.Banner.NONE)
	m.set_nt_ready(false, 10)
	check(not m.connected())
	check_eq(m.banner(), MatchModel.Banner.DISCONNECTED)
	m.set_nt_ready(true, 20)
	check(not m.has_data(), "values from the previous connection do not count")
	m.ingest("connected", true, 30)
	check(m.has_data() and m.connected(), "the DS-attached flag alone counts")
	m.ingest("connected", false, 40)
	check(not m.has_data())


func test_ingest_maps_enums_and_flags() -> void:
	var m := _ready_model()
	m.ingest("match_phase", 4, 0)
	m.ingest("hub_status", 3, 0)
	m.ingest("header_color", 2, 0)
	m.ingest("aim_mode", 2, 0)
	m.ingest("show_shift_indicator", true, 0)
	m.ingest("show_buffer", true, 0)
	check_eq(m.phase, MatchEnums.Phase.SHIFT2)
	check_eq(m.hub, MatchEnums.Hub.WARNING)
	check_eq(m.header, MatchEnums.Header.YELLOW)
	check_eq(m.aim, MatchEnums.Aim.MANUAL_AIMING)
	check(m.show_shift_indicator and m.show_buffer)
	m.ingest("match_phase", 99, 0)
	m.ingest("aim_mode", -4, 0)
	check_eq(m.phase, MatchEnums.Phase.PRE_MATCH, "unknown phase -> pre_match")
	check_eq(m.aim, MatchEnums.Aim.SHOOTER_DISABLED)


func test_shift_selection_both_hub_periods_use_period_time() -> void:
	var P := MatchEnums.Phase
	var H := MatchEnums.Hub
	for p: int in [P.AUTONOMOUS, P.TRANSITION, P.ENDGAME]:
		var d := MatchModel.select_shift(p, H.BOTH, 7.5, 3.0, 6.0, 0.0, false)
		check_eq(d["main"], 7.5, "phase %d uses period time" % p)
		check_eq(d["buffer"], null)
	check_eq(MatchModel.select_shift(P.AUTONOMOUS, H.BOTH, -1.0, 0.0, 0.0, 0.0, false)["main"], 0.0, "clamped at 0")


func test_shift_selection_shifts() -> void:
	var P := MatchEnums.Phase
	var H := MatchEnums.Hub
	check_eq(MatchModel.select_shift(P.SHIFT1, H.ACTIVE, 99.0, 15.4, 18.4, 0.0, false)["main"], 15.4, "active: shift time")
	check_eq(MatchModel.select_shift(P.SHIFT2, H.INACTIVE, 99.0, 12.0, 12.0, 0.0, false)["main"], 12.0, "inactive: shift time")
	var warn := MatchModel.select_shift(P.SHIFT2, H.WARNING, 99.0, 23.7, 23.7, 1.7, true)
	check_eq(warn["main"], 0.0, "warning forces 0")
	check_eq(warn["buffer"], 1.7, "warning buffer line counts buffer_remaining")
	var active_buf := MatchModel.select_shift(P.SHIFT1, H.ACTIVE, 99.0, 15.4, 18.4, 0.0, true)
	check_eq(active_buf["buffer"], 18.4, "show_buffer outside warning uses shift_time_with_buffer")
	check_eq(MatchModel.select_shift(P.SHIFT2, H.WARNING, 99.0, 23.7, 23.7, 1.7, false)["buffer"], null, "buffer line only with show_buffer")
	check_eq(MatchModel.select_shift(P.SHIFT2, H.WARNING, 99.0, 23.7, 23.7, -0.5, true)["buffer"], 0.0, "buffer clamped at 0")


func test_shift_display_uses_live_countdowns() -> void:
	var m := _ready_model()
	m.ingest("seq", 1, 0)
	m.ingest("match_phase", 3, 0)
	m.ingest("hub_status", 2, 0)
	m.ingest("shift_time_remaining_s", 15.0, 0)
	m.ingest("period_time_remaining_s", 15.0, 0)
	m.step(0)
	check_near(m.shift_display(50_000)["main"], 14.95, 1e-9)


func test_pose_trust() -> void:
	var m := _ready_model()
	m.ingest("seq", 1, 0)
	m.step(0)
	check(m.pose_trusted(), "unknown validity is trusted")
	m.ingest("robot_pose_valid", false, 0)
	check(not m.pose_trusted())
	m.ingest("robot_pose_valid", true, 0)
	check(m.pose_trusted())
	m.set_nt_ready(false, 10)
	check(not m.pose_trusted(), "no live data -> pose not current")


func test_phase_signal_and_alliance() -> void:
	var m := _ready_model()
	var seen: Array = []
	m.phase_changed.connect(func(p: MatchEnums.Phase) -> void: seen.append(p))
	m.ingest("match_phase", 1, 0)
	m.ingest("match_phase", 1, 0)
	m.ingest("match_phase", 2, 0)
	check_eq(seen, [1, 2])
	check_eq(m.is_red_alliance, null)
	m.ingest("is_red_alliance", true, 0)
	check_eq(m.is_red_alliance, true)
