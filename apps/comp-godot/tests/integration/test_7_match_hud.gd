extends TestCase

## Full scripted match from the fake robot at 8x through the real NT client,
## Match service and HUD screen.

const SPEED := 8.0
const TOTAL := "/matchhud/state/total_time_remaining_s"

var robot: FakeRobotProc
var nt: NtService
var ms: MatchService
var hud: HudScreen
var speed_pub: NtPublisher


func before_each() -> void:
	robot = FakeRobotProc.from_env()
	if robot == null:
		fail("PWRUP_FAKE_ROBOT_PORT not set; run tools/test/run_integration.sh")
		return
	nt = NtHarness.make_service(tree, robot.port)
	nt.subscribe_groups(Topics.subscription_groups(ConnectionSettings.DEFAULT_NT))
	ms = MatchService.new()
	ms.nt = nt
	tree.root.add_child(ms)
	hud = HudScreen.new()
	hud.match_service = ms
	hud.size = HudLayout.DESIGN
	tree.root.add_child(hud)
	speed_pub = nt.publisher("/fake/control/match_speed", "double")
	nt.start()
	await wait_until(func() -> bool: return ms.model.link_ok(), 5.0)


func after_each() -> void:
	if speed_pub != null and nt != null and nt.is_ready():
		speed_pub.set_value(0.0)
		await wait_s(0.3)
	for n: Node in [hud, ms]:
		if is_instance_valid(n):
			n.queue_free()
	NtHarness.dispose(nt)
	await next_frame()


static func parse_mm_ss_cc(s: String) -> float:
	var mm := s.substr(0, 2).to_int()
	var ss := s.substr(3, 2).to_int()
	var cc := s.substr(6, 2).to_int()
	return mm * 60 + ss + cc / 100.0


func test_full_match_at_8x() -> void:
	if nt == null:
		return
	check(ms.model.link_ok(), "connected to the fake robot")
	speed_pub.set_value(SPEED)
	var phases: Array[int] = []
	var hubs := {}
	var headers := {}
	var samples: Array = []
	var held_samples := 0
	var banner_frames := 0
	var toasts_before := ms.model.toast.fire_count
	var next_sample := now_s() + 1.0
	var deadline := now_s() + 40.0
	while now_s() < deadline:
		await next_frame()
		var m := ms.model
		if phases.is_empty() or phases[-1] != m.phase:
			phases.append(m.phase)
		hubs[m.hub] = true
		if hud.header.visible:
			headers[hud.header.color.to_html(false)] = true
		if m.banner() != MatchModel.Banner.NONE:
			banner_frames += 1
		var shown := parse_mm_ss_cc(hud.displayed_total())
		var published := float(nt.value(TOTAL, 0.0))
		var counts := (m.countdowns["total_time_remaining_s"] as Countdown)
		if counts.is_held() and published > 1.0 and held_samples < 3:
			held_samples += 1
			samples.append({"t": now_s(), "shown": shown, "published": published, "held": true, "phase": m.phase})
		elif now_s() >= next_sample and samples.size() - held_samples < 10 and m.phase != MatchEnums.Phase.PRE_MATCH:
			next_sample = now_s() + 1.8
			samples.append({"t": now_s(), "shown": shown, "published": published, "held": counts.is_held(), "phase": m.phase})
		if m.phase == MatchEnums.Phase.POST_MATCH and samples.size() - held_samples >= 10:
			break

	var names: Array[String] = []
	for p in phases:
		names.append(MatchEnums.PHASE_NAMES[p])
	note("phases: " + ", ".join(names))
	check_eq(phases.slice(phases.find(MatchEnums.Phase.AUTONOMOUS)), [1, 2, 3, 4, 5, 6, 7, 8], "auto through post-match in order")
	check(phases.has(MatchEnums.Phase.PRE_MATCH), "started in pre-match")
	check_eq(phases.size(), 9, "all 9 phases, each once")
	check(hubs.has(MatchEnums.Hub.WARNING) and hubs.has(MatchEnums.Hub.INACTIVE) and hubs.has(MatchEnums.Hub.ACTIVE), "hub warning, inactive and active seen")
	check(headers.has("70cd35") and headers.has("ffd900") and headers.has("a600ff"), "green, yellow and purple headers seen: %s" % [headers.keys()])
	check_eq(banner_frames, 0, "no banner while the robot streams")
	check(ms.model.toast.fire_count > toasts_before, "lane alignment toasts fired")

	var regular := samples.filter(func(s: Dictionary) -> bool: return not s["held"])
	check(regular.size() >= 10, "10 sampled instants (got %d)" % regular.size())
	var worst := 0.0
	for s: Dictionary in samples:
		var err := absf(s["shown"] - s["published"])
		worst = maxf(worst, err)
		check(err <= 0.05, "shown %.2f vs published %.3f (phase %d, held %s)" % [s["shown"], s["published"], s["phase"], s["held"]])
	note("max |shown - published| = %.3f s over %d samples (%d held)" % [worst, samples.size(), held_samples])
	check(held_samples >= 1, "sampled the held total during the disabled gap")
	for s: Dictionary in samples:
		if s["held"] and s["published"] > 1.0:
			check_near(s["shown"], s["published"], 0.0101, "held value shown exactly (floored to centiseconds)")
