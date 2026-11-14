extends TestCase

## Time to READY after the robot's NT server becomes reachable again, through
## tools/sim/net_proxy.py: refused connects, dropped SYNs, a hung upgrade, a
## silently dead link, a real fake-robot restart, and manual Reconnect from
## every client state. Outages vary so the server returns at different points
## of the client's backoff and connect watchdog cycle.

const SEQ := "/matchhud/state/seq"
const READY_BOUND_S := 1.5
const MANUAL_BOUND_S := 0.3
const CALL_BOUND_MS := 5.0

var proxy: NetProxyCtl
var robot: FakeRobotProc
var nt: NtService


func before_each() -> void:
	proxy = NetProxyCtl.from_env()
	robot = FakeRobotProc.from_env()
	if proxy == null or robot == null:
		fail("PWRUP_NET_PROXY_* or PWRUP_FAKE_ROBOT_PORT not set; run tools/test/run_integration.sh")
		return
	check(proxy.mode("forward"), "proxy reachable")
	proxy.send("reset")
	nt = NtHarness.make_service(tree, proxy.port, ConnectionSettings.DEFAULT_RECONNECT_TIMEOUT_S)
	nt.subscribe_groups(Topics.subscription_groups(ConnectionSettings.DEFAULT_NT))


func after_each() -> void:
	NtHarness.dispose(nt)
	if proxy != null:
		proxy.mode("forward")
		proxy.send("reset")
		proxy.close()
	await next_frame()


func _ready_or_fail() -> bool:
	if nt.client.get_state() == Nt4Client.State.IDLE:
		nt.start()
	return check(await wait_until(func() -> bool: return nt.is_ready(), 10.0) >= 0.0, "READY before the outage")


## Breaks the link with `down`, waits outage_s, restores it with `up` and
## returns the seconds from `up` to READY (-1 on timeout).
func _outage(down: Callable, outage_s: float, up: Callable) -> float:
	if not await _ready_or_fail():
		return -1.0
	down.call()
	await wait_s(outage_s)
	check(not nt.is_ready() or outage_s < 1.0, "left READY during a %.1f s outage" % outage_s)
	up.call()
	return await wait_until(func() -> bool: return nt.is_ready(), 15.0)


func _summary(label: String, times: Array[float], bound_s: float) -> void:
	var sorted := times.duplicate()
	sorted.sort()
	var parts := PackedStringArray()
	for t: float in times:
		parts.append("%.3f" % t)
	note("%s: max %.3f s, median %.3f s [%s]" % [label, sorted[-1], sorted[sorted.size() / 2], ", ".join(parts)])
	for t: float in times:
		check(t >= 0.0 and t <= bound_s, "%s: READY within %.1f s (took %.3f)" % [label, bound_s, t])


func test_refused_while_server_down() -> void:
	if nt == null:
		return
	var times: Array[float] = []
	for outage_s: float in [0.7, 1.3, 2.1, 2.9, 3.6, 4.4, 5.3]:
		times.append(await _outage(func() -> void: proxy.mode("refuse"), outage_s, func() -> void: proxy.mode("forward")))
	_summary("refused (RST) then listening", times, READY_BOUND_S)


func test_syn_dropped_while_robot_boots() -> void:
	if nt == null:
		return
	var times: Array[float] = []
	for outage_s: float in [4.1, 4.6, 5.0, 5.5, 6.2, 6.8]:
		var down := func() -> void:
			proxy.send("freeze")
			proxy.mode("drop")
		var up := func() -> void:
			proxy.mode("forward")
		times.append(await _outage(down, outage_s, up))
		proxy.send("reset")
	_summary("power cycle (old link dead, SYNs dropped) then listening", times, READY_BOUND_S)


func test_hung_upgrade_then_listening() -> void:
	if nt == null:
		return
	var times: Array[float] = []
	for outage_s: float in [3.1, 3.7, 4.3, 4.8, 5.6]:
		var down := func() -> void:
			proxy.mode("silent")
			proxy.send("reset")
		times.append(await _outage(down, outage_s, func() -> void: proxy.mode("forward")))
	_summary("TCP accepted, upgrade unanswered, then listening", times, ConnectionSettings.DEFAULT_RECONNECT_TIMEOUT_S + 0.3)


func test_silently_dead_link_recovers() -> void:
	if nt == null:
		return
	var times: Array[float] = []
	for outage_s: float in [4.2, 5.1, 6.0]:
		var down := func() -> void:
			proxy.send("freeze")
			proxy.mode("drop")
		var up := func() -> void:
			proxy.send("thaw")
			proxy.mode("forward")
		times.append(await _outage(down, outage_s, up))
	_summary("link silently dead (no FIN) then back", times, READY_BOUND_S)


func test_short_link_glitch_keeps_connection() -> void:
	if nt == null or not await _ready_or_fail():
		return
	var reconnects: int = nt.client.reconnects
	var left := [false]
	var on_change := func(ok: bool) -> void:
		if not ok:
			left[0] = true
	nt.connection_changed.connect(on_change)
	proxy.send("freeze")
	proxy.mode("drop")
	await wait_s(1.0)
	proxy.send("thaw")
	proxy.mode("forward")
	await wait_s(1.5)
	nt.connection_changed.disconnect(on_change)
	check(not left[0], "a 1 s glitch did not drop the connection")
	check_eq(nt.client.reconnects, reconnects, "no reconnect after a 1 s glitch")
	check(nt.is_ready(), "still READY")


func test_dead_link_detected_while_server_reachable() -> void:
	if nt == null or not await _ready_or_fail():
		return
	var t0 := now_s()
	proxy.send("freeze")
	var left := await wait_until(func() -> bool: return not nt.is_ready(), 10.0)
	var back := await wait_until(func() -> bool: return nt.is_ready(), 10.0)
	note("frozen link: left READY after %.3f s, READY again %.3f s after the freeze" % [left, now_s() - t0])
	check(left >= 0.0 and back >= 0.0, "liveness fired and the client reconnected")
	check(back >= 0.0 and back <= 0.5, "reconnect after liveness took %.3f s" % back)
	check_eq(nt.client.liveness_fires, 1)


func test_fake_robot_killed_and_restarted() -> void:
	if nt == null:
		return
	var direct := NtHarness.make_service(tree, robot.port, ConnectionSettings.DEFAULT_RECONNECT_TIMEOUT_S)
	direct.subscribe_groups(Topics.subscription_groups(ConnectionSettings.DEFAULT_NT))
	direct.start()
	var times: Array[float] = []
	for down_s: float in [0.4, 1.5, 2.6]:
		check(await wait_until(func() -> bool: return direct.is_ready(), 10.0) >= 0.0, "READY before the kill")
		check(robot.kill(), "fake robot killed")
		check(await wait_until(func() -> bool: return not robot.is_listening(), 5.0) >= 0.0, "fake robot gone")
		await wait_s(down_s)
		check(robot.restart() > 0, "fake robot restarted")
		check(await wait_until(func() -> bool: return robot.is_listening(), 20.0) >= 0.0, "fake robot listening again")
		times.append(await wait_until(func() -> bool: return direct.is_ready(), 15.0))
	NtHarness.dispose(direct)
	_summary("fake robot killed and restarted, from listening", times, READY_BOUND_S)


## Puts the client in `state` with the proxy in `mode`, switches the proxy to
## forwarding and presses Reconnect.
func _manual(state: int, mode: String, settle_s: float) -> void:
	await _ready_or_fail()
	if state == Nt4Client.State.IDLE:
		nt.stop()
	elif state != Nt4Client.State.READY:
		proxy.mode(mode)
		proxy.send("reset")
		check(await wait_until(func() -> bool: return nt.client.get_state() == state, 10.0) >= 0.0,
			"reached %s" % Nt4Client.STATE_NAMES[state])
		await wait_s(settle_s)
		if state == Nt4Client.State.BACKOFF:
			check(await wait_until(func() -> bool: return nt.client.get_state() == state, 10.0) >= 0.0, "back in BACKOFF")
		proxy.mode("forward")
	var name: String = Nt4Client.STATE_NAMES[nt.client.get_state()]
	var attempt_before: int = nt.client.diagnostics()["attempt"]
	var t0 := Time.get_ticks_usec()
	nt.reconnect()
	var call_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var after := nt.client.get_state()
	var ready := await wait_until(func() -> bool: return nt.is_ready(), 10.0)
	note("Reconnect from %s (attempt %d): call %.2f ms, then %s, READY after %.3f s" % [
		name, attempt_before, call_ms, Nt4Client.STATE_NAMES[after], ready])
	check(after == Nt4Client.State.CONNECTING or after == Nt4Client.State.SYNCING, "connecting on the same frame from %s" % name)
	check(call_ms <= CALL_BOUND_MS, "Reconnect from %s returned in %.2f ms" % [name, call_ms])
	check(ready >= 0.0 and ready <= MANUAL_BOUND_S, "READY %.3f s after Reconnect from %s" % [ready, name])


func test_manual_reconnect_from_ready() -> void:
	if nt != null:
		await _manual(Nt4Client.State.READY, "", 0.0)


func test_manual_reconnect_from_idle() -> void:
	if nt != null:
		await _manual(Nt4Client.State.IDLE, "", 0.0)


func test_manual_reconnect_from_backoff() -> void:
	if nt != null:
		await _manual(Nt4Client.State.BACKOFF, "refuse", 2.5)


func test_manual_reconnect_from_connecting() -> void:
	if nt != null:
		await _manual(Nt4Client.State.CONNECTING, "drop", 0.3)


func test_manual_reconnect_from_syncing() -> void:
	if nt != null:
		await _manual(Nt4Client.State.SYNCING, "handshake", 0.3)
