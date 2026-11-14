extends TestCase

const MS := 1000


func test_anchor_and_capped_extrapolation() -> void:
	var c := Countdown.new()
	check_eq(c.display(0, true), 0.0, "no value yet")
	c.update(100.0, 1_000_000)
	check_near(c.display(1_000_000, true), 100.0, 1e-9)
	check_near(c.display(1_000_000 + 30 * MS, true), 99.97, 1e-9, "counts down between updates")
	check_near(c.display(1_000_000 + 500 * MS, true), 99.9, 1e-9, "extrapolation capped at 100 ms")
	c.update(99.5, 1_500_000)
	check_near(c.display(1_500_000 + 10 * MS, true), 99.49, 1e-9, "re-anchors on every update")
	c.update(99.5, 1_520_000)
	check_near(c.display(1_520_000, true), 99.5, 1e-9, "an identical value re-anchors too")


func test_exact_hold_when_value_static_while_seq_advances() -> void:
	var c := Countdown.new()
	c.update(140.0, 0)
	var t := 0
	for i in 100:
		t += 20 * MS
		c.on_seq()
		check_near(c.display(t, true), 140.0 if i >= 1 else 139.98, 1e-9, "held value at %d ms" % (t / MS))
	check(c.is_held())
	c.update(139.98, t + 5 * MS)
	check(not c.is_held(), "a new value ends the hold")
	check_near(c.display(t + 15 * MS, true), 139.97, 1e-9)


func test_paused_value_never_drifts() -> void:
	var m := MatchModel.new()
	m.set_nt_ready(true, 0)
	var t := 0
	m.ingest("seq", 1, t)
	m.ingest("total_time_remaining_s", 140.0, t)
	m.ingest("period_time_remaining_s", 0.0, t)
	for i in 600:
		t += 20 * MS
		m.ingest("seq", i + 2, t)
		m.step(t)
	check_near(m.total_display(t), 140.0, 1e-9, "12 s of a held value: no drift")
	check_near(m.total_display(t + 15 * MS), 140.0, 1e-9)
	check(m.link_ok())


func test_dead_reckoning_when_link_lost() -> void:
	var m := MatchModel.new()
	m.set_nt_ready(true, 0)
	var t := 0
	for i in 10:
		m.ingest("seq", i + 1, t)
		m.ingest("total_time_remaining_s", 100.0 - t / 1e6, t)
		m.step(t)
		t += 20 * MS
	var last_t := t - 20 * MS
	var last_v := 100.0 - last_t / 1e6
	m.set_nt_ready(false, t)
	check(not m.link_ok())
	check_near(m.total_display(last_t + 2_000_000), last_v - 2.0, 1e-6, "a running timer keeps counting while disconnected")
	check_near(m.total_display(last_t + 200_000_000), 0.0, 1e-9, "clamped at 0")


func test_held_timer_stays_put_when_link_lost() -> void:
	var m := MatchModel.new()
	m.set_nt_ready(true, 0)
	m.ingest("seq", 1, 0)
	m.ingest("total_time_remaining_s", 140.0, 0)
	m.ingest("seq", 2, 20 * MS)
	m.ingest("seq", 3, 40 * MS)
	m.step(40 * MS)
	m.set_nt_ready(false, 50 * MS)
	check_near(m.total_display(5_000_000), 140.0, 1e-9)


func test_stale_seq_counts_as_link_down() -> void:
	var m := MatchModel.new()
	m.set_nt_ready(true, 0)
	m.ingest("seq", 7, 0)
	m.ingest("total_time_remaining_s", 50.0, 0)
	m.step(900 * MS)
	check(m.link_ok() and not m.stale())
	m.step(1_000 * MS)
	check(m.stale(), "seq unchanged for 1 s")
	check(not m.link_ok())
	check_eq(m.banner(), MatchModel.Banner.STALE)
	check_near(m.total_display(1_000 * MS), 49.0, 1e-9, "dead-reckons while stale")
	m.ingest("seq", 8, 1_100 * MS)
	m.step(1_100 * MS)
	check(m.link_ok() and m.banner() == MatchModel.Banner.NONE, "recovers on the next seq")
