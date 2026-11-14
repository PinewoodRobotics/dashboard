class_name TestCase
extends RefCounted

var tree: SceneTree
var failures: Array[String] = []
var notes: Array[String] = []


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func fail(msg: String) -> void:
	failures.append(msg)


func note(msg: String) -> void:
	notes.append(msg)
	print("      note: ", msg)


func check(cond: bool, msg: String = "check failed") -> bool:
	if not cond:
		failures.append(msg)
	return cond


func check_eq(actual: Variant, expected: Variant, msg: String = "") -> bool:
	if typeof(actual) == typeof(expected) and actual == expected:
		return true
	if (typeof(actual) == TYPE_INT or typeof(actual) == TYPE_FLOAT) and (typeof(expected) == TYPE_INT or typeof(expected) == TYPE_FLOAT) and actual == expected:
		return true
	failures.append("%sexpected %s (%s), got %s (%s)" % [msg + ": " if msg != "" else "", var_to_str(expected), type_string(typeof(expected)), var_to_str(actual), type_string(typeof(actual))])
	return false


func check_near(actual: float, expected: float, tol: float, msg: String = "") -> bool:
	if absf(actual - expected) <= tol:
		return true
	failures.append("%sexpected %s within %s, got %s" % [msg + ": " if msg != "" else "", expected, tol, actual])
	return false


func now_s() -> float:
	return Time.get_ticks_usec() / 1_000_000.0


func next_frame() -> void:
	await tree.process_frame


func wait_s(seconds: float, pump: Callable = Callable()) -> void:
	var end := now_s() + seconds
	while now_s() < end:
		if pump.is_valid():
			pump.call()
		await tree.process_frame


## Waits until cond returns true or timeout; returns elapsed seconds or -1 on timeout.
func wait_until(cond: Callable, timeout_s: float, pump: Callable = Callable()) -> float:
	var start := now_s()
	while true:
		if pump.is_valid():
			pump.call()
		if cond.call():
			return now_s() - start
		if now_s() - start > timeout_s:
			return -1.0
		await tree.process_frame
	return -1.0
