extends TestCase

## HUD against the real robot code. Without --match the sim sits disabled in
## pre-match; with run_sim_e2e.sh --match a scripted DriverStationSim match
## runs through MatchStatusCalculator and every phase is checked.

const START_TOPIC := "/pwrup_test/sim_match/start"
const TOTAL := "/matchhud/state/total_time_remaining_s"
const ROBOT_TIME := "/matchhud/state/robot_time_us"

var nt: NtService
var ms: MatchService
var hud: HudScreen


func before_each() -> void:
	if SimEnv.port() == 0:
		fail("PWRUP_SIM_PORT not set; run tools/test/run_sim_e2e.sh")
		return
	nt = NtHarness.make_service(tree, SimEnv.port())
	nt.subscribe_groups(Topics.subscription_groups(ConnectionSettings.DEFAULT_NT))
	ms = MatchService.new()
	ms.nt = nt
	tree.root.add_child(ms)
	hud = HudScreen.new()
	hud.match_service = ms
	hud.size = HudLayout.DESIGN
	tree.root.add_child(hud)
	nt.start()


func after_each() -> void:
	for n: Node in [hud, ms]:
		if is_instance_valid(n):
			n.queue_free()
	NtHarness.dispose(nt)
	await next_frame()


static func parse_mm_ss_cc(s: String) -> float:
	return s.substr(0, 2).to_int() * 60 + s.substr(3, 2).to_int() + s.substr(6, 2).to_int() / 100.0


func test_hud_connects_to_the_sim() -> void:
	if nt == null:
		return
	check(await wait_until(func() -> bool: return ms.model.link_ok(), 15.0) >= 0.0, "robot data live from the sim (seq advancing)")
	var t0 := now_s()
	var rt0 := int(nt.value(ROBOT_TIME, 0))
	await wait_s(1.5)
	var rate := (int(nt.value(ROBOT_TIME, 0)) - rt0) / (now_s() - t0)
	if OS.get_environment("PWRUP_SIM_MATCH") == "1":
		check_near(rate / 1e6, 1.0, 0.1, "patched scratch copy publishes robot_time_us in microseconds (%.0f per s)" % rate)
	elif rate > 1e8:
		note("ROBOT BUG: robot_time_us advances %.0f per second (nanoseconds); MatchStatusSubsystem passes RobotController.getTime(), which is ns in WPILib 2027, so the match clock runs 1000x fast" % rate)
	var m := ms.model
	check(m.link_ok() and m.banner() == MatchModel.Banner.NONE, "no banner: seq keeps advancing (banner %s)" % MatchModel.Banner.keys()[m.banner()])
	check(m.seq > 50, "seq %d" % m.seq)
	check(m.is_red_alliance != null, "alliance published")
	check(m.pose_valid != null, "robot_pose_valid published (%s)" % m.pose_valid)
	if OS.get_environment("PWRUP_SIM_MATCH") != "1":
		check_eq(m.phase, MatchEnums.Phase.PRE_MATCH, "disabled sim is in pre-match")
		check_eq(hud.displayed_total(), "00:00.00")
		check(not hud.header.visible and not hud.shift.visible, "pre-match: no header, no shift indicator")


func test_full_sim_match() -> void:
	if nt == null or OS.get_environment("PWRUP_SIM_MATCH") != "1":
		return
	check(await wait_until(func() -> bool: return ms.model.link_ok(), 15.0) >= 0.0, "robot data live from the sim")
	var start := nt.publisher(START_TOPIC, "boolean")
	start.set_value(true)
	var phases: Array[int] = []
	var hubs := {}
	var headers := {}
	var samples: Array = []
	var stale_frames := 0
	var next_sample := now_s() + 2.0
	var deadline := now_s() + 200.0
	while now_s() < deadline:
		await next_frame()
		var m := ms.model
		if phases.is_empty() or phases[-1] != m.phase:
			phases.append(m.phase)
			note("%.1f s: %s" % [now_s(), MatchEnums.PHASE_NAMES[m.phase]])
		hubs[m.hub] = true
		if hud.header.visible:
			headers[hud.header.color.to_html(false)] = true
		if m.banner() != MatchModel.Banner.NONE:
			stale_frames += 1
		if now_s() >= next_sample:
			next_sample = now_s() + 9.0
			samples.append({"shown": parse_mm_ss_cc(hud.displayed_total()), "published": float(nt.value(TOTAL, 0.0)), "phase": m.phase})
		if m.phase == MatchEnums.Phase.POST_MATCH:
			break
	check_eq(phases.slice(phases.find(MatchEnums.Phase.AUTONOMOUS)), [1, 2, 3, 4, 5, 6, 7, 8], "auto through post-match in order")
	check(hubs.has(MatchEnums.Hub.WARNING) and hubs.has(MatchEnums.Hub.INACTIVE) and hubs.has(MatchEnums.Hub.ACTIVE), "hub warning, inactive, active from the robot")
	check(headers.has("70cd35") and headers.has("ffd900") and headers.has("a600ff"), "green, yellow, purple headers: %s" % [headers.keys()])
	check_eq(stale_frames, 0, "no banner frames during the match")
	var worst := 0.0
	for s: Dictionary in samples:
		worst = maxf(worst, absf(s["shown"] - s["published"]))
	note("max |shown - published| = %.3f s over %d samples" % [worst, samples.size()])
	check(samples.size() >= 10, "10 samples")
	check(worst <= 0.05, "displayed total within 0.05 s of the latest published value")
