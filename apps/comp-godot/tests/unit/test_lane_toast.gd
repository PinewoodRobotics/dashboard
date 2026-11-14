extends TestCase

const S := 1_000_000


func test_first_value_silent_then_changes_fire() -> void:
	var t := LaneToast.new()
	check(not t.observe(true, 0), "first value is stored silently")
	check(not t.is_visible(0))
	check(not t.observe(true, S), "same value does nothing")
	check(t.observe(false, 2 * S), "change fires")
	check(t.is_visible(2 * S) and not t.visible_on)
	check(t.observe(true, 3 * S))
	check_eq(t.fire_count, 2)


func test_duration_and_replace_in_place() -> void:
	var t := LaneToast.new()
	t.observe(false, 0)
	t.observe(true, 10 * S)
	check(t.is_visible(10 * S + 1_790_000))
	check(not t.is_visible(10 * S + 1_800_000), "1.8 s lifetime")
	t.observe(false, 20 * S)
	t.observe(true, 21 * S)
	check(t.visible_on, "the newest toast replaces the previous one")
	check(t.is_visible(21 * S + 1_700_000), "replacing restarts the 1.8 s")
	check(not t.is_visible(21 * S + 1_800_000))
	check_near(t.progress(21 * S + 900_000), 0.5, 1e-9)
	check_eq(t.progress(30 * S), -1.0)


func test_reset_in_pre_match() -> void:
	var m := MatchModel.new()
	m.set_nt_ready(true, 0)
	var fired: Array = []
	m.toast_fired.connect(func(on: bool) -> void: fired.append(on))
	m.ingest("lane_alignment", false, 0)
	m.ingest("lane_alignment", true, S)
	check_eq(fired, [true])
	m.ingest("match_phase", 3, 2 * S)
	m.ingest("match_phase", 0, 3 * S)
	m.ingest("lane_alignment", false, 4 * S)
	check_eq(fired, [true], "first value after returning to pre-match is silent")
	m.ingest("lane_alignment", true, 5 * S)
	check_eq(fired, [true, true], "later changes in pre-match fire")
	m.ingest("match_phase", 1, 6 * S)
	m.ingest("lane_alignment", false, 7 * S)
	check_eq(fired, [true, true, false], "no reset outside pre-match")
