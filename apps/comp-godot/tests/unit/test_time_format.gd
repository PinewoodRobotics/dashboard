extends TestCase


func test_mm_ss_cc() -> void:
	check_eq(TimeFormat.mm_ss_cc(132.34), PackedStringArray(["02:12", ".34"]))
	check_eq(TimeFormat.mm_ss_cc(160.0), PackedStringArray(["02:40", ".00"]))
	check_eq(TimeFormat.mm_ss_cc(59.999), PackedStringArray(["00:59", ".99"]), "floor, never rounds up to the next second")
	check_eq(TimeFormat.mm_ss_cc(60.0), PackedStringArray(["01:00", ".00"]))
	check_eq(TimeFormat.mm_ss_cc(0.009), PackedStringArray(["00:00", ".00"]))
	check_eq(TimeFormat.mm_ss_cc(12.29), PackedStringArray(["00:12", ".29"]), "binary rounding does not drop a centisecond")
	check_eq(TimeFormat.mm_ss_cc(0.29), PackedStringArray(["00:00", ".29"]))


func test_mm_ss_cc_clamps_at_zero() -> void:
	check_eq(TimeFormat.mm_ss_cc(-3.5), PackedStringArray(["00:00", ".00"]))
	check_eq(TimeFormat.mm_ss_cc(NAN), PackedStringArray(["00:00", ".00"]))


func test_nn_dd() -> void:
	check_eq(TimeFormat.nn_dd(15.42), PackedStringArray(["15", ".42"]))
	check_eq(TimeFormat.nn_dd(1.749), PackedStringArray(["01", ".74"]), "floor, not toFixed rounding")
	check_eq(TimeFormat.nn_dd(0.0), PackedStringArray(["00", ".00"]))
	check_eq(TimeFormat.nn_dd(-1.0), PackedStringArray(["00", ".00"]))
	check_eq(TimeFormat.nn_dd(9.999), PackedStringArray(["09", ".99"]))
	check_eq(TimeFormat.nn_dd(125.5), PackedStringArray(["125", ".50"]))
