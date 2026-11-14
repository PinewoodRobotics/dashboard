extends TestCase

const T := {"request": "/Shared/PathPlanner/SelectedPath/Request", "state": "/Shared/PathPlanner/SelectedPath/State"}
const NAMES := ["Ball Shooter Left", "Ball Shooter Right", "Stay And Shoot"]
const LOCK := "/matchhud/state/enabled"

var link: FakeControlLink
var clock: Clock


func before_each() -> void:
	link = FakeControlLink.new()
	clock = Clock.new()
	clock.freeze(1_000_000_000)


func _sync(stored: String = "") -> AutoSelectionSync:
	var s := AutoSelectionSync.new(link, clock, T, stored)
	s.set_library(PackedStringArray(NAMES))
	return s


func _tick(s: AutoSelectionSync, seconds: float, step_s: float = 0.02) -> void:
	var n := int(round(seconds / step_s))
	for i in n:
		clock.advance_s(step_s)
		s.update()


func test_publishes_stored_selection_on_connect() -> void:
	var s := _sync("Ball Shooter Left")
	s.update()
	check_eq(link.count(T["request"]), 0, "nothing while disconnected")
	link.up = true
	s.update()
	check_eq(link.count(T["request"]), 1, "published on connect")
	check_eq(link.last(T["request"]), "Ball Shooter Left")
	link.values[T["state"]] = "Ball Shooter Left"
	_tick(s, 3.0)
	check_eq(link.count(T["request"]), 1, "no republish once State agrees")
	link.up = false
	s.update()
	link.up = true
	s.update()
	check_eq(link.count(T["request"]), 2, "published again on reconnect")


func test_nothing_chosen_publishes_nothing_and_mirrors_robot() -> void:
	var s := _sync("")
	link.up = true
	link.values[T["state"]] = "ball shooter right"
	_tick(s, 2.0)
	check_eq(link.published.size(), 0)
	check_eq(s.active_name(), "Ball Shooter Right", "mirrors the robot's auto when nothing is chosen")


func test_republish_when_state_differs_at_most_every_700ms() -> void:
	var s := _sync("Ball Shooter Left")
	link.up = true
	link.values[T["state"]] = "Ball Shooter Left"
	s.update()
	var base := link.count(T["request"])
	link.values[T["state"]] = "Stay And Shoot"
	_tick(s, 0.68)
	check_eq(link.count(T["request"]) - base, 0, "throttled inside 700 ms of the connect publish")
	_tick(s, 0.04)
	check_eq(link.count(T["request"]) - base, 1, "republished once 700 ms passed")
	_tick(s, 0.66)
	check_eq(link.count(T["request"]) - base, 1, "no second publish inside 700 ms")
	_tick(s, 0.06)
	check_eq(link.count(T["request"]) - base, 2)
	_tick(s, 7.0)
	check(link.count(T["request"]) - base <= 2 + 10, "at most one per 700 ms over 7 s (%d)" % (link.count(T["request"]) - base))
	check_eq(link.last(T["request"]), "Ball Shooter Left")


func test_case_insensitive_match_counts_as_aligned() -> void:
	var s := _sync("Ball Shooter Left")
	link.up = true
	s.update()
	link.values[T["state"]] = "  BALL shooter left "
	var n := link.count(T["request"])
	_tick(s, 3.0)
	check_eq(link.count(T["request"]), n)
	check(s.robot_confirms_selection())


func test_no_auto_publishes_none_and_accepts_empty_state() -> void:
	var s := _sync("")
	link.up = true
	s.update()
	check(s.select(AutoSelectionSync.NONE))
	check_eq(link.last(T["request"]), "NONE")
	check_eq(s.selected, "NONE")
	link.values[T["state"]] = ""
	var n := link.count(T["request"])
	_tick(s, 2.0)
	check_eq(link.count(T["request"]), n, "empty State is NONE")
	link.values[T["state"]] = "Stay And Shoot"
	_tick(s, 0.6)
	check_eq(link.count(T["request"]), n + 1, "republished when the robot runs something")
	check_eq(s.active_name(), "NONE")


func test_select_publishes_immediately_and_persists() -> void:
	var s := _sync("")
	var seen: Array = []
	s.selection_changed.connect(func(v: String) -> void: seen.append(v))
	link.up = true
	s.update()
	check(s.select("Stay And Shoot"))
	check_eq(link.last(T["request"]), "Stay And Shoot")
	check_eq(seen, ["Stay And Shoot"])
	check_eq(s.button_for("Stay And Shoot")["text"], "Selecting...")
	check_eq(s.button_for("Stay And Shoot")["enabled"], false)
	check_eq(s.button_for("Ball Shooter Left")["enabled"], false, "every Select waits for the pending one")
	link.values[T["state"]] = "Stay And Shoot"
	s.update()
	check_eq(s.pending, "")
	check_eq(s.button_for("Stay And Shoot"), {"text": "Selected", "enabled": true, "selected": true})
	check_eq(s.button_for("Ball Shooter Left"), {"text": "Select", "enabled": true, "selected": false})


func test_pending_times_out() -> void:
	var s := _sync("")
	link.up = true
	s.select("Stay And Shoot")
	_tick(s, 1.4)
	check_eq(s.pending, "Stay And Shoot")
	_tick(s, 0.2)
	check_eq(s.pending, "")


func test_lock_while_enabled_and_live() -> void:
	var s := _sync("Ball Shooter Left")
	link.up = true
	link.values[T["state"]] = "Stay And Shoot"
	link.values[LOCK] = true
	var n := link.count(T["request"])
	_tick(s, 3.0)
	check_eq(link.count(T["request"]), n, "no enforcement while locked")
	check(s.locked())
	check(not s.select("Ball Shooter Right"), "select refused")
	check_eq(s.selected, "Ball Shooter Left")
	check(not s.resync(), "resync refused")
	check_eq(s.button_for("Ball Shooter Left"), {"text": "Locked During Match", "enabled": false, "selected": true})
	check_eq(link.count(T["request"]), n)
	for i in 12:
		link.values[T["state"]] = "Ball Shooter Right" if i % 2 == 0 else "Stay And Shoot"
		_tick(s, 0.1)
	check(not s.conflict, "no conflict counting while locked")
	link.values[LOCK] = false
	_tick(s, 0.1)
	check_eq(link.count(T["request"]), n + 1, "enforcement resumes after the match")


func test_enabled_without_live_value_does_not_lock() -> void:
	var s := _sync("Ball Shooter Left")
	link.up = false
	link.values[LOCK] = true
	check(not s.locked(), "stale enabled (not live) does not lock")
	link.up = true
	check(s.locked())


func _flip(s: AutoSelectionSync, times: int, gap_s: float) -> void:
	for i in times:
		link.values[T["state"]] = "Ball Shooter Left"
		_tick(s, gap_s * 0.5, gap_s * 0.5)
		link.values[T["state"]] = "Stay And Shoot" if i % 2 == 0 else "Ball Shooter Right"
		_tick(s, gap_s * 0.5, gap_s * 0.5)


func test_conflict_after_ten_mismatching_changes_in_ten_seconds() -> void:
	var s := _sync("Ball Shooter Left")
	link.up = true
	link.values[T["state"]] = "Ball Shooter Left"
	s.update()
	var shown: Array = []
	s.conflict_changed.connect(func(v: bool) -> void: shown.append(v))
	_flip(s, 9, 0.8)
	check(not s.conflict, "9 mismatches do not trigger")
	_flip(s, 1, 0.8)
	check(s.conflict, "10th mismatch within 10 s triggers the popup")
	check_eq(shown, [true])
	s.dismiss_conflict()
	check(not s.conflict)
	_flip(s, 9, 0.8)
	check(not s.conflict, "counter restarted after the popup")
	_flip(s, 1, 0.8)
	check(s.conflict)
	var n := link.count(T["request"])
	clock.advance_s(1.0)
	check(s.resync(), "resync")
	check(not s.conflict, "resync hides the popup")
	check_eq(link.count(T["request"]), n + 1, "resync republishes the selection")
	check_eq(link.last(T["request"]), "Ball Shooter Left")


func test_slow_flips_never_conflict() -> void:
	var s := _sync("Ball Shooter Left")
	link.up = true
	_flip(s, 20, 1.2)
	check(not s.conflict, "one mismatch per 1.2 s stays under 10 per 10 s")


func test_library_clears_unknown_and_fixes_case() -> void:
	var s := AutoSelectionSync.new(link, clock, T, "Gone Auto")
	var seen: Array = []
	s.selection_changed.connect(func(v: String) -> void: seen.append(v))
	s.set_library(PackedStringArray(NAMES))
	check_eq(s.selected, "Gone Auto", "kept until the robot's list can confirm it")
	check(not s.enforceable(), "an unconfirmed choice is never published")
	link.up = true
	link.values[T["state"]] = "Stay And Shoot"
	_tick(s, 1.0)
	check_eq(link.count(T["request"]), 0, "nothing published while the robot's list is missing")
	link.values[Topics.PP_VALID_AUTOS] = PackedStringArray(NAMES)
	s.update()
	check_eq(s.selected, "")
	check_eq(seen, [""])
	check_eq(link.count(T["request"]), 0)
	var s2 := AutoSelectionSync.new(link, clock, T, "stay and shoot")
	s2.set_library(PackedStringArray(NAMES))
	check_eq(s2.selected, "Stay And Shoot")
	var s3 := AutoSelectionSync.new(link, clock, T, "NONE")
	s3.set_library(PackedStringArray(NAMES))
	check_eq(s3.selected, "NONE", "No Auto survives a library change")


func test_validity_from_robot_lists() -> void:
	var s := _sync("Ball Shooter Left")
	check_eq(s.validity("Ball Shooter Left"), AutoSelectionSync.Validity.UNKNOWN, "unknown while disconnected")
	link.up = true
	link.values[Topics.PP_VALID_AUTOS] = PackedStringArray(["Ball Shooter Right"])
	check_eq(s.validity("Ball Shooter Left"), AutoSelectionSync.Validity.NOT_ON_ROBOT)
	check_eq(s.validity("ball shooter right"), AutoSelectionSync.Validity.OK)
	link.values[Topics.PP_VALID_AUTOS] = ["Ball Shooter Left", "Ball Shooter Right"]
	link.values[T["state"]] = "Ball Shooter Left"
	link.values[Topics.PP_SELECTED_AUTO_VALID] = false
	check_eq(s.validity("Ball Shooter Left"), AutoSelectionSync.Validity.LOAD_FAILED)
	check_eq(s.validity("Ball Shooter Right"), AutoSelectionSync.Validity.OK, "SelectedAutoValid only speaks for the robot's current auto")
	link.values[Topics.PP_SELECTED_AUTO_VALID] = true
	check_eq(s.validity("Ball Shooter Left"), AutoSelectionSync.Validity.OK)
	check_eq(s.validity("NONE"), AutoSelectionSync.Validity.OK)
	check_eq(AutoSelectionSync.validity_text(AutoSelectionSync.Validity.LOAD_FAILED), "Robot failed to load this auto")


func test_topic_change_releases_old_publisher() -> void:
	var s := _sync("Ball Shooter Left")
	link.up = true
	s.update()
	s.set_topics({"request": "/T/X/Request", "state": "/T/X/State"})
	check_eq(link.released, PackedStringArray([T["request"]]))
	s.update()
	check_eq(link.last("/T/X/Request"), "Ball Shooter Left", "published on the new topic")


func test_robot_only_autos_are_selectable_and_enforced() -> void:
	var s := _sync("")
	link.up = true
	link.values[T["state"]] = "Stay And Shoot"
	link.values[Topics.PP_VALID_AUTOS] = PackedStringArray(["Ball Shooter Left", "New Auto", "ball shooter right", "none", " "])
	s.update()
	check_eq(s.robot_only_names(), PackedStringArray(["New Auto"]), "library names match case-insensitively; blanks and none are skipped")
	check_eq(s.all_names(), PackedStringArray(NAMES + ["New Auto"]))
	check_eq(s.validity("New Auto"), AutoSelectionSync.Validity.OK)
	check(s.select("New Auto"))
	check_eq(link.last(T["request"]), "New Auto")
	check_eq(s.active_name(), "New Auto")
	check_eq(s.button_for("New Auto")["text"], "Selecting...")
	link.values[T["state"]] = "New Auto"
	_tick(s, 0.1)
	check_eq(s.button_for("New Auto"), {"text": "Selected", "enabled": true, "selected": true})
	link.values[T["state"]] = "Stay And Shoot"
	var before := link.count(T["request"])
	_tick(s, 1.0)
	check(link.count(T["request"]) > before, "a robot-only choice is enforced like a library one")
	check_eq(link.last(T["request"]), "New Auto")


func test_robot_only_choice_survives_a_restart_without_the_robot() -> void:
	var s := AutoSelectionSync.new(link, clock, T, "New Auto")
	s.set_library(PackedStringArray(NAMES))
	check_eq(s.selected, "New Auto")
	check_eq(s.active_name(), "", "not highlighted before the robot lists it")
	link.up = true
	link.values[T["state"]] = "NONE"
	link.values[Topics.PP_VALID_AUTOS] = PackedStringArray(["new auto", "Stay And Shoot"])
	s.update()
	check_eq(s.selected, "new auto", "takes the robot's spelling")
	check_eq(link.last(T["request"]), "new auto", "published on connect once confirmed")
	link.up = false
	s.update()
	check_eq(s.robot_only_names(), PackedStringArray(["new auto"]), "the last list is kept while disconnected")
	check_eq(s.active_name(), "new auto")


func test_robot_auto_outside_the_export_is_highlighted() -> void:
	var s := _sync("")
	link.up = true
	link.values[T["state"]] = "New Auto"
	link.values[Topics.PP_VALID_AUTOS] = PackedStringArray(["New Auto"])
	s.update()
	check_eq(s.active_name(), "New Auto")
