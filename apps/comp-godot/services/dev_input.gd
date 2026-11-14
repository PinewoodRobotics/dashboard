class_name DevInput
extends RefCounted

## Scripted input for windowed Dev runs. Events are synthesized through
## Input.parse_input_event with the target window id, so touches go through
## the engine's touch-to-mouse emulation exactly like a real touchscreen.
## Steps (fixture "input" array). A position P is [x, y] in design pixels of
## the window, a node path relative to the screen root ("find:Name/Child"
## searches by name) meaning its center, or {"node": path, "at": [x, y]} (from
## the node's top-left) / {"node": path, "offset": [dx, dy]} (from its center):
##   {"tap": P}  {"swipe": {"from": P, "to": P, "ms": 250}}
##   {"hold_drag": {"from": P, "to": P, "hold_ms": 350, "ms": 300, "release": true}}
##   {"drag": {"from": P, "to": P, "ms": 300}} (no hold)   {"release": P}   {"wait_ms": N}
##   {"pinch": {"at": P, "from": px, "to": px, "pan": [dx, dy], "ms": 300}} two touches
##     spread horizontally from `from` to `to` px apart while their midpoint moves by pan
##   {"mouse": true|false}  {"window": "touch"|"hud"}  {"mark": "name"}
##   {"expect": {"dotted.path": value | {"ne": v} | {"le": v} | {"ge": v} | {"near": v, "tol": t}
##     | {"changed_since": "mark"} | {"same_as": "mark", "tol": t} | {"ratio_since": "mark", "ge": r}}}
##   {"wait_for": {same as expect}, "timeout_ms": 3000} polls every frame until all
##     hold (elapsed ms goes to the trace) or fails at the timeout
##   {"inject": {topic: value}} offline NT values, as a fixture's nt_steps
##   {"screenshot": "name"}  {"call": "save_settings"}
## A failed expectation is recorded with the step index; the run continues.

var dev: DevService
var tree: SceneTree
var mouse := false
var window_key := "touch"
var marks := {}
var failures: PackedStringArray = []
var trace: Array = []
var _mouse_down := false


func _init(owner: DevService) -> void:
	dev = owner
	tree = owner.get_tree()


func run(steps: Array, prefix: String) -> void:
	await _settle_focus()
	for i in steps.size():
		var s: Dictionary = steps[i]
		trace.append({"step": i, "do": s.keys()})
		if s.has("mouse"):
			mouse = bool(s["mouse"])
		if s.has("window"):
			window_key = str(s["window"])
		if s.has("wait_ms"):
			await _sleep(float(s["wait_ms"]) / 1000.0)
		if s.has("tap"):
			var p := _pos(s["tap"])
			await _down(p)
			await _frames(2)
			await _up(p)
			await _frames(2)
		if s.has("release"):
			await _up(_pos(s["release"]))
			await _frames(2)
		if s.has("swipe"):
			await _stroke(s["swipe"], 0.0)
		if s.has("drag"):
			await _stroke(s["drag"], 0.0)
		if s.has("pinch"):
			await _pinch(s["pinch"])
		if s.has("hold_drag"):
			await _stroke(s["hold_drag"], float(s["hold_drag"].get("hold_ms", 350)) / 1000.0)
		if s.has("mark"):
			marks[str(s["mark"])] = dev.probe_state().duplicate(true)
		if s.has("call"):
			dev.call(str(s["call"]))
		if s.has("inject"):
			dev.inject_nt(s["inject"])
			await _frames(2)
		if s.has("wait_for"):
			await _wait_for(i, s["wait_for"], float(s.get("timeout_ms", 3000)))
		if s.has("expect"):
			await _frames(1)
			_check(i, s["expect"])
		if s.has("screenshot") and prefix != "":
			await RenderingServer.frame_post_draw
			var path := "%s_%s_%s.png" % [prefix, s["screenshot"], window_key]
			_window().get_texture().get_image().save_png(path)


## A window launched from a terminal becomes active some time after it shows;
## macOS then releases every pressed button (Input.release_pressed_events), which
## would cut a synthesized drag short. Wait for focus first, then a little more.
func _settle_focus() -> void:
	var wid := _window().get_window_id()
	DisplayServer.window_move_to_foreground(wid)
	var end := Time.get_ticks_msec() + 3000
	while not DisplayServer.window_is_focused(wid) and Time.get_ticks_msec() < end:
		await tree.process_frame
	await _sleep(0.3)


func _window() -> Window:
	return dev.window(window_key)


func _root() -> Node:
	return dev.screen_root(window_key)


func _pos(spec: Variant) -> Vector2:
	if typeof(spec) == TYPE_ARRAY:
		return Vector2(spec[0], spec[1])
	var path := str(spec.get("node", "")) if typeof(spec) == TYPE_DICTIONARY else str(spec)
	var node := _find(path)
	if node == null:
		failures.append("input: node not found: %s" % path)
		return Vector2.ZERO
	var r := node.get_global_rect()
	if typeof(spec) == TYPE_DICTIONARY and spec.has("at"):
		return r.position + Vector2(spec["at"][0], spec["at"][1])
	if typeof(spec) == TYPE_DICTIONARY and spec.has("offset"):
		return r.get_center() + Vector2(spec["offset"][0], spec["offset"][1])
	return r.get_center()


func _find(path: String) -> Control:
	var root := _root()
	if not path.begins_with("find:"):
		return root.get_node_or_null(NodePath(path)) as Control
	var parts := path.trim_prefix("find:").split("/", true, 1)
	var n := root.find_child(parts[0], true, false)
	if n != null and parts.size() > 1:
		var child := n.get_node_or_null(NodePath(parts[1]))
		n = child if child != null else n.find_child(parts[1], true, false)
	return n as Control


func _to_window(p: Vector2) -> Vector2:
	return _window().get_final_transform() * p


func _stroke(spec: Dictionary, hold_s: float) -> void:
	var a := _pos(spec["from"])
	var b := _pos(spec["to"])
	var ms := float(spec.get("ms", 250))
	var n := maxi(2, int(spec.get("steps", 12)))
	await _down(a)
	if hold_s > 0.0:
		await _sleep(hold_s)
	var prev := a
	for k in range(1, n + 1):
		var p := a.lerp(b, float(k) / n)
		_move(p, p - prev)
		prev = p
		await _sleep(ms / 1000.0 / n)
	if spec.get("release", true):
		await _frames(1)
		await _up(b)
	await _frames(2)


func _pinch(spec: Dictionary) -> void:
	var c0 := _pos(spec["at"])
	var pan: Array = spec.get("pan", [0, 0])
	var c1 := c0 + Vector2(pan[0], pan[1])
	var d0 := float(spec.get("from", 200)) * 0.5
	var d1 := float(spec.get("to", 200)) * 0.5
	var ms := float(spec.get("ms", 300))
	var n := maxi(2, int(spec.get("steps", 12)))
	var wid := _window().get_window_id()
	var finger := func(i: int, c: Vector2, d: float) -> Vector2: return c + Vector2(d if i == 1 else -d, 0)
	for i in 2:
		var t := InputEventScreenTouch.new()
		t.window_id = wid
		t.index = i
		t.pressed = true
		t.position = _to_window(finger.call(i, c0, d0))
		Input.parse_input_event(t)
		await _frames(1)
	for k in range(1, n + 1):
		var f := float(k) / n
		for i in 2:
			var prev: Vector2 = finger.call(i, c0.lerp(c1, float(k - 1) / n), lerpf(d0, d1, float(k - 1) / n))
			var now: Vector2 = finger.call(i, c0.lerp(c1, f), lerpf(d0, d1, f))
			var e := InputEventScreenDrag.new()
			e.window_id = wid
			e.index = i
			e.position = _to_window(now)
			e.relative = _window().get_final_transform().basis_xform(now - prev)
			Input.parse_input_event(e)
		await _sleep(ms / 1000.0 / n)
	for i in [1, 0]:
		var t := InputEventScreenTouch.new()
		t.window_id = wid
		t.index = i
		t.pressed = false
		t.position = _to_window(finger.call(i, c1, d1))
		Input.parse_input_event(t)
		await _frames(1)
	await _frames(2)


func _down(p: Vector2) -> void:
	_send_button(p, true)
	await _frames(1)


func _up(p: Vector2) -> void:
	_send_button(p, false)
	await _frames(1)


func _send_button(p: Vector2, pressed: bool) -> void:
	var wid := _window().get_window_id()
	var wp := _to_window(p)
	if mouse:
		var e := InputEventMouseButton.new()
		e.device = 0
		e.window_id = wid
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		e.position = wp
		e.global_position = wp
		Input.parse_input_event(e)
	else:
		var t := InputEventScreenTouch.new()
		t.window_id = wid
		t.index = 0
		t.pressed = pressed
		t.position = wp
		Input.parse_input_event(t)
	_mouse_down = pressed


func _move(p: Vector2, rel: Vector2) -> void:
	var wid := _window().get_window_id()
	var wp := _to_window(p)
	var wrel := _window().get_final_transform().basis_xform(rel)
	if mouse:
		var e := InputEventMouseMotion.new()
		e.device = 0
		e.window_id = wid
		e.position = wp
		e.global_position = wp
		e.relative = wrel
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if _mouse_down else 0
		Input.parse_input_event(e)
	else:
		var d := InputEventScreenDrag.new()
		d.window_id = wid
		d.index = 0
		d.position = wp
		d.relative = wrel
		Input.parse_input_event(d)


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func _sleep(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await tree.process_frame


static func dig(d: Variant, path: String) -> Variant:
	var cur: Variant = d
	for part in path.split("."):
		if typeof(cur) == TYPE_DICTIONARY and (cur as Dictionary).has(part):
			cur = cur[part]
		elif typeof(cur) == TYPE_ARRAY and part.is_valid_int() and int(part) < (cur as Array).size():
			cur = cur[int(part)]
		else:
			return null
	return cur


static func same(a: Variant, b: Variant, tol: float = 1e-4) -> bool:
	var num := func(v: Variant) -> bool: return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT
	if num.call(a) and num.call(b):
		return absf(float(a) - float(b)) <= tol
	if typeof(a) == TYPE_DICTIONARY and typeof(b) == TYPE_DICTIONARY:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for k: Variant in a:
			if not (b as Dictionary).has(k) or not same(a[k], b[k], tol):
				return false
		return true
	if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY:
		if (a as Array).size() != (b as Array).size():
			return false
		for i in (a as Array).size():
			if not same(a[i], b[i], tol):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


func _wait_for(i: int, exp: Dictionary, timeout_ms: float) -> void:
	var t0 := Time.get_ticks_msec()
	while true:
		var st := dev.probe_state()
		var all := true
		for path: String in exp:
			if not _holds(st, path, exp[path]):
				all = false
				break
		if all:
			trace.append({"step": i, "wait_for": exp.keys(), "ms": Time.get_ticks_msec() - t0, "ok": true})
			return
		if Time.get_ticks_msec() - t0 > timeout_ms:
			break
		await tree.process_frame
	trace.append({"step": i, "wait_for": exp.keys(), "ms": Time.get_ticks_msec() - t0, "ok": false})
	_check(i, exp)


func _holds(st: Dictionary, path: String, want: Variant) -> bool:
	var got: Variant = dig(st, path)
	if typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("ne"):
		return not same(got, want["ne"])
	if typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("le"):
		return got != null and float(got) <= float(want["le"])
	if typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("ge"):
		return got != null and float(got) >= float(want["ge"])
	if typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("near"):
		return same(got, want["near"], float(want.get("tol", 1e-3)))
	return same(got, want)


func _check(i: int, exp: Dictionary) -> void:
	var st := dev.probe_state()
	for path: String in exp:
		var want: Variant = exp[path]
		var got: Variant = dig(st, path)
		var ok := true
		if typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("ne"):
			ok = not same(got, want["ne"])
		elif typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("changed_since"):
			ok = not same(got, dig(marks.get(str(want["changed_since"]), {}), path), 1e-6)
		elif typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("same_as"):
			ok = same(got, dig(marks.get(str(want["same_as"]), {}), path), float(want.get("tol", 1e-4)))
		elif typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("ratio_since"):
			var before: Variant = dig(marks.get(str(want["ratio_since"]), {}), path)
			ok = got != null and before != null and float(before) > 0.0 and float(got) / float(before) >= float(want["ge"])
		elif typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("le"):
			ok = got != null and float(got) <= float(want["le"])
		elif typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("ge"):
			ok = got != null and float(got) >= float(want["ge"])
		elif typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("near"):
			ok = same(got, want["near"], float(want.get("tol", 1e-3)))
		else:
			ok = same(got, want)
		trace.append({"step": i, "expect": path, "want": want, "got": got, "ok": ok})
		if not ok:
			failures.append("step %d: %s = %s, want %s" % [i, path, var_to_str(got), var_to_str(want)])
