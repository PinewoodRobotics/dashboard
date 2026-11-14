class_name AutoScrubBar
extends Control

## Preview timeline: interval commands as labelled spans packed into lanes,
## instant commands as ticks on the track, path segments as a lighter track,
## progress fill and knob. Press or drag anywhere seeks the shared clock to the
## pointer (absolute, not relative like PwSlider). It is a grab widget, so a
## drag on it never starts the overlay's swipe-dismiss.

const PAD_X := 14.0
const LANE_H := 20.0
const LANE_GAP := 3.0
const MAX_LANES := 3
const TRACK_H := 10.0
const KNOB_R := 11.0
const TICK_HALF := 13.0
const LABEL_PX := 13
const DIAMOND := 6.0

var clock: AutoClock
var duration := 0.0
var path_ranges: Array = []
var spans: Array = []
var ticks: Array = []
var lanes := 0
var _pressed := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("pw_grab")
	custom_minimum_size = Vector2(0, 92)


func set_auto(m: AutoMechanisms) -> void:
	spans.clear()
	ticks.clear()
	path_ranges.clear()
	duration = m.duration if m != null else 0.0
	if m != null:
		for s: Dictionary in m.playback.segments:
			if s.get("type") == "path":
				path_ranges.append([float(s["t0"]), float(s["t1"])])
		var lane_end: Array[float] = []
		for it: Dictionary in m.items:
			if it["instant"]:
				ticks.append(it)
				continue
			var lane := -1
			for i in lane_end.size():
				if lane_end[i] <= it["t0"] + 1e-6:
					lane = i
					break
			if lane < 0:
				lane = mini(lane_end.size(), MAX_LANES - 1)
				if lane >= lane_end.size():
					lane_end.append(0.0)
			lane_end[lane] = maxf(lane_end[lane], it["t1"])
			var span := it.duplicate()
			span["lane"] = lane
			spans.append(span)
		lanes = lane_end.size()
	custom_minimum_size.y = maxi(lanes, 1) * (LANE_H + LANE_GAP) + 6.0 + DIAMOND * 2.0 + TICK_HALF * 2.0 + 4.0
	queue_redraw()


func track_y() -> float:
	return size.y - TICK_HALF - 4.0


func track_x0() -> float:
	return PAD_X


func track_x1() -> float:
	return size.x - PAD_X


func t_to_x(t: float) -> float:
	if duration <= 0.0:
		return track_x0()
	return lerpf(track_x0(), track_x1(), clampf(t / duration, 0.0, 1.0))


func x_to_t(x: float) -> float:
	var w := track_x1() - track_x0()
	return clampf((x - track_x0()) / w, 0.0, 1.0) * duration if w > 0.0 else 0.0


func _lane_rect(lane: int, t0: float, t1: float) -> Rect2:
	var y := lane * (LANE_H + LANE_GAP)
	var x0 := t_to_x(t0)
	return Rect2(x0, y, maxf(t_to_x(t1) - x0, 3.0), LANE_H)


static func short_name(n: String) -> String:
	var s := n.trim_suffix("Command").trim_prefix("Continuous")
	var out := ""
	for i in s.length():
		var c := s[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower() and s[i - 1] == s[i - 1].to_lower():
			out += " "
		out += c
	return out if out != "" else n


func _gui_input(event: InputEvent) -> void:
	var p := PointerInput.from_event(event)
	if p.kind == PointerInput.Kind.NONE or clock == null or duration <= 0.0:
		return
	match p.kind:
		PointerInput.Kind.DOWN:
			_pressed = true
			clock.begin_scrub()
			clock.seek(x_to_t(p.pos.x))
		PointerInput.Kind.MOVE:
			if _pressed:
				clock.seek(x_to_t(p.pos.x))
		PointerInput.Kind.UP:
			if _pressed:
				_pressed = false
				clock.seek(x_to_t(p.pos.x))
				clock.end_scrub()
	accept_event()
	queue_redraw()


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func _draw() -> void:
	UiDraw.begin(self)
	var ci := get_canvas_item()
	var font := Tokens.inter(500)
	var ty := track_y()
	for s: Dictionary in spans:
		var r := _lane_rect(s["lane"], s["t0"], s["t1"])
		var col := AutoPathOverlay.kind_color(s)
		UiDraw.box(ci, r, Color(col, 0.85) if s["runs"] else Color(col, 0.18), 4.0, 0 if s["runs"] else 1, col)
		var label: String = short_name(s["name"]) + ("  (" + s["note"] + ")" if s["note"] != "" else "")
		var text_col: Color = Color.BLACK if s["runs"] else Tokens.ZINC_300
		var max_w := r.size.x - 10.0
		if max_w > 24.0:
			UiDraw.text(self, font, Vector2(r.position.x + 6.0, r.position.y + LANE_H * 0.5 + LABEL_PX * 0.36), label, LABEL_PX, text_col, HORIZONTAL_ALIGNMENT_LEFT, max_w)
	var x0 := track_x0()
	var x1 := track_x1()
	UiDraw.rect(ci, Rect2(x0, ty - TRACK_H * 0.5, x1 - x0, TRACK_H), Tokens.ZINC_800)
	for pr: Array in path_ranges:
		UiDraw.rect(ci, Rect2(t_to_x(pr[0]), ty - TRACK_H * 0.5, t_to_x(pr[1]) - t_to_x(pr[0]), TRACK_H), Tokens.ZINC_700)
	var t := clock.t if clock != null else 0.0
	UiDraw.rect(ci, Rect2(x0, ty - TRACK_H * 0.5, t_to_x(t) - x0, TRACK_H), Color(Tokens.ACCENT, 0.9))
	for k: Dictionary in ticks:
		var x := t_to_x(k["t0"])
		var col := AutoPathOverlay.kind_color(k)
		UiDraw.rect(ci, Rect2(x - 1.5, ty - TICK_HALF, 3.0, TICK_HALF * 2.0), col)
		UiDraw.diamond(ci, Vector2(x, ty - TICK_HALF - DIAMOND), int(DIAMOND), col, 0.0 if k["runs"] else 2.0)
	var kx := t_to_x(t)
	UiDraw.circle(ci, Vector2(kx, ty), KNOB_R, Color.WHITE)
	UiDraw.circle(ci, Vector2(kx, ty), KNOB_R - 3.0, Tokens.ACCENT if clock != null and clock.playing else Tokens.ZINC_400)


func report() -> Dictionary:
	var out_ticks: Array = []
	for k: Dictionary in ticks:
		out_ticks.append({"name": k["name"], "t": k["t0"], "x": t_to_x(k["t0"]), "runs": k["runs"]})
	var out_spans: Array = []
	for s: Dictionary in spans:
		var r := _lane_rect(s["lane"], s["t0"], s["t1"])
		out_spans.append({"name": s["name"], "t0": s["t0"], "t1": s["t1"], "x0": r.position.x, "x1": r.end.x, "lane": s["lane"], "runs": s["runs"]})
	return {"duration": duration, "x0": track_x0(), "x1": track_x1(), "ticks": out_ticks, "spans": out_spans,
		"lanes": lanes, "progress_x": t_to_x(clock.t if clock != null else 0.0), "rect": [get_global_rect().position.x, get_global_rect().position.y, size.x, size.y]}
