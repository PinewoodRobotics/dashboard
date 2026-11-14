class_name DevInput
extends RefCounted

## Scripted input for windowed Dev runs. Events are synthesized through
## Input.parse_input_event with the target window id, so touches go through
## the engine's touch-to-mouse emulation exactly like a real touchscreen.
## Steps (fixture "input" array), positions in design pixels of the window or
## a node path relative to the screen root (its center, plus "offset"):
##   {"tap": P}  {"swipe": {"from": P, "to": P, "ms": 250}}
##   {"hold_drag": {"from": P, "to": P, "hold_ms": 350, "ms": 300, "release": true}}
##   {"drag": {"from": P, "to": P, "ms": 300}} (no hold)   {"wait_ms": N}
##   {"mouse": true|false}  {"window": "touch"|"hud"}  {"mark": "name"}
##   {"expect": {"dotted.path": value | {"ne": v} | {"changed_since": "mark"} | {"near": v, "tol": t}}}
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
			var p := _pos(s["tap"], s)
			await _down(p)
			await _frames(2)
			await _up(p)
			await _frames(2)
		if s.has("swipe"):
			await _stroke(s["swipe"], 0.0, s)
		if s.has("drag"):
			await _stroke(s["drag"], 0.0, s)
		if s.has("hold_drag"):
			await _stroke(s["hold_drag"], float(s["hold_drag"].get("hold_ms", 350)) / 1000.0, s)
		if s.has("mark"):
			marks[str(s["mark"])] = dev.probe_state().duplicate(true)
		if s.has("call"):
			dev.call(str(s["call"]))
		if s.has("expect"):
			await _frames(1)
			_check(i, s["expect"])
		if s.has("screenshot") and prefix != "":
			await RenderingServer.frame_post_draw
			var path := "%s_%s_%s.png" % [prefix, s["screenshot"], window_key]
			_window().get_texture().get_image().save_png(path)


func _window() -> Window:
	return dev.window(window_key)


func _root() -> Node:
	return dev.screen_root(window_key)


func _pos(spec: Variant, step: Dictionary) -> Vector2:
	var off: Array = step.get("offset", [0, 0])
	if typeof(spec) == TYPE_ARRAY:
		return Vector2(spec[0], spec[1])
	var node := _root().get_node_or_null(NodePath(str(spec))) as Control
	if node == null:
		failures.append("input: node not found: %s" % spec)
		return Vector2.ZERO
	return node.get_global_rect().get_center() + Vector2(off[0], off[1])


func _to_window(p: Vector2) -> Vector2:
	return _window().get_final_transform() * p


func _stroke(spec: Dictionary, hold_s: float, step: Dictionary) -> void:
	var a := _pos(spec["from"], step)
	var b := _pos(spec["to"], spec)
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
	if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY:
		if (a as Array).size() != (b as Array).size():
			return false
		for i in (a as Array).size():
			if not same(a[i], b[i], tol):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


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
		elif typeof(want) == TYPE_DICTIONARY and (want as Dictionary).has("near"):
			ok = same(got, want["near"], float(want.get("tol", 1e-3)))
		else:
			ok = same(got, want)
		trace.append({"step": i, "expect": path, "want": want, "got": got, "ok": ok})
		if not ok:
			failures.append("step %d: %s = %s, want %s" % [i, path, var_to_str(got), var_to_str(want)])
