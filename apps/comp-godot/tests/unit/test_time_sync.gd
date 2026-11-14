extends TestCase


func test_offset_from_single_sample() -> void:
	var s := Nt4TimeSync.new()
	check(not s.has_sync())
	# Sent at local 1000, server stamped 50_000, received at local 1400 -> rtt 400.
	check(s.add_sample(1400, 1000, 50_000))
	check_eq(s.best_rtt_us, 400)
	check_eq(s.offset_us, 1400 - 200 - 50_000)
	check_eq(s.server_now_us(1400), 50_200)
	check_eq(s.server_now_us(2400), 51_200)


func test_best_of_last_ten() -> void:
	var s := Nt4TimeSync.new()
	s.add_sample(10_000, 9_000, 100_000)
	s.add_sample(20_100, 20_000, 110_500)
	s.add_sample(30_500, 30_000, 120_000)
	check_eq(s.best_rtt_us, 100)
	check_eq(s.offset_us, 20_100 - 50 - 110_500)
	for i in 10:
		s.add_sample(100_000 + i * 1000 + 300, 100_000 + i * 1000, 200_000 + i * 1000)
	check_eq(s.best_rtt_us, 300, "old best sample aged out of the window")


func test_rejects_negative_rtt_and_zero_server_time() -> void:
	var s := Nt4TimeSync.new()
	check(not s.add_sample(100, 200, 5000))
	check(not s.add_sample(300, 200, 0))
	check(not s.has_sync())


func test_reset() -> void:
	var s := Nt4TimeSync.new()
	s.add_sample(1400, 1000, 50_000)
	s.reset()
	check(not s.has_sync())
	check_eq(s.offset_us, 0)


func test_clock_freeze_and_advance() -> void:
	var c := Clock.new()
	c.freeze(5_000_000)
	check_eq(c.now_us(), 5_000_000)
	c.advance_s(1.5)
	check_eq(c.now_us(), 6_500_000)
	check_near(c.now_s(), 6.5, 1e-9)
	c.unfreeze()
	check(absi(c.now_us() - Time.get_ticks_usec()) < 100_000)
