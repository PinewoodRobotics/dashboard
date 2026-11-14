extends TestCase


func _swipe(dir: SwipeRecognizer.Dir, dim: float, pts: Array, ctx: Dictionary = {}) -> SwipeRecognizer:
	var r := SwipeRecognizer.new(dir, dim)
	r.begin(pts[0][0], pts[0][1], ctx)
	for i in range(1, pts.size()):
		r.move(pts[i][0], pts[i][1])
	return r


func test_intent_threshold() -> void:
	var r := _swipe(SwipeRecognizer.Dir.DOWN, 515, [[Vector2(500, 100), 0.0], [Vector2(500, 107.9), 10.0]])
	check_eq(r.state, SwipeRecognizer.State.PENDING, "under 8 px nothing is decided")
	r.move(Vector2(500, 108), 20.0)
	check_eq(r.state, SwipeRecognizer.State.TRACKING)
	check_eq(r.delta, 8.0)


func test_axis_lock() -> void:
	var r := _swipe(SwipeRecognizer.Dir.DOWN, 515, [[Vector2(0, 0), 0.0], [Vector2(9, 5), 10.0]])
	check_eq(r.state, SwipeRecognizer.State.REJECTED, "cross axis dominates")
	r.move(Vector2(0, 200), 30.0)
	check_eq(r.state, SwipeRecognizer.State.REJECTED, "rejected for the whole touch")
	var up := _swipe(SwipeRecognizer.Dir.DOWN, 515, [[Vector2(0, 100), 0.0], [Vector2(0, 90), 10.0]])
	check_eq(up.state, SwipeRecognizer.State.REJECTED, "wrong direction")
	var t := _swipe(SwipeRecognizer.Dir.DOWN, 515, [[Vector2(0, 0), 0.0], [Vector2(2, 20), 10.0], [Vector2(300, 60), 20.0]])
	check_eq(t.state, SwipeRecognizer.State.TRACKING)
	check_eq(t.delta, 60.0, "once tracking only the main axis counts")
	var right := _swipe(SwipeRecognizer.Dir.RIGHT, 456, [[Vector2(0, 0), 0.0], [Vector2(20, 3), 10.0], [Vector2(600, 3), 20.0]])
	check_eq(right.delta, 456.0, "clamped to the dimension")


func test_commit_at_35_percent_when_slow() -> void:
	var r := _swipe(SwipeRecognizer.Dir.DOWN, 515, [[Vector2(0, 0), 0.0], [Vector2(0, 100), 1000.0], [Vector2(0, 181), 2000.0]])
	check_eq(r.end(), SwipeRecognizer.Outcome.COMMIT, "181 >= 0.35 * 515")
	var s := _swipe(SwipeRecognizer.Dir.DOWN, 515, [[Vector2(0, 0), 0.0], [Vector2(0, 100), 1000.0], [Vector2(0, 179), 2000.0]])
	check_eq(s.end(), SwipeRecognizer.Outcome.SNAP_BACK, "179 < 180.25, slow: snap back")


func test_commit_on_velocity() -> void:
	var r := _swipe(SwipeRecognizer.Dir.RIGHT, 456, [[Vector2(0, 0), 0.0], [Vector2(20, 0), 10.0], [Vector2(40, 0), 50.0], [Vector2(70, 0), 100.0]])
	check(r.velocity() >= 0.5, "70 px in 100 ms")
	check_eq(r.end(), SwipeRecognizer.Outcome.COMMIT, "a short fast flick commits")
	var slow := _swipe(SwipeRecognizer.Dir.RIGHT, 456, [[Vector2(0, 0), 0.0], [Vector2(20, 0), 100.0], [Vector2(40, 0), 200.0], [Vector2(70, 0), 300.0]])
	check(slow.velocity() < 0.5)
	check_eq(slow.end(), SwipeRecognizer.Outcome.SNAP_BACK)


func test_velocity_uses_last_five_samples() -> void:
	var pts := [[Vector2(0, 0), 0.0]]
	for i in range(1, 6):
		pts.append([Vector2(0, 10 * i), 1000.0 * i])
	for i in range(6, 11):
		pts.append([Vector2(0, 50 + 30 * (i - 5)), 5000.0 + 10.0 * (i - 5)])
	var r := _swipe(SwipeRecognizer.Dir.DOWN, 515, pts)
	check_near(r.velocity(), 3.0, 1e-6, "only the recent fast part counts")


func test_untracked_release_does_nothing() -> void:
	var r := _swipe(SwipeRecognizer.Dir.DOWN, 515, [[Vector2(0, 0), 0.0], [Vector2(0, 5), 10.0]])
	check_eq(r.end(), SwipeRecognizer.Outcome.NONE)


func test_blocking_contexts() -> void:
	check(SwipeRecognizer.blocks(SwipeRecognizer.Dir.DOWN, {"scroll_not_at_top": true}), "scroll container not at top blocks swipe down")
	check(not SwipeRecognizer.blocks(SwipeRecognizer.Dir.RIGHT, {"scroll_not_at_top": true}))
	check(SwipeRecognizer.blocks(SwipeRecognizer.Dir.RIGHT, {"on_horizontal_widget": true}), "sliders and selectors win horizontal drags")
	check(not SwipeRecognizer.blocks(SwipeRecognizer.Dir.DOWN, {"on_horizontal_widget": true}), "a vertical drag on a slider still dismisses")
	check(SwipeRecognizer.blocks(SwipeRecognizer.Dir.DOWN, {"on_grab_widget": true}))
	var r := _swipe(SwipeRecognizer.Dir.DOWN, 515, [[Vector2(0, 0), 0.0], [Vector2(0, 300), 10.0]], {"scroll_not_at_top": true})
	check_eq(r.state, SwipeRecognizer.State.REJECTED)
	check_eq(r.end(), SwipeRecognizer.Outcome.NONE)
