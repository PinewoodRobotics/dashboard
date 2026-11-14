class_name AutoSelectionSync
extends RefCounted

## Auto selection and its enforcement (AutoSelector.tsx). The dashboard's own
## choice wins: it is persisted, published to <shared>/<entry>/Request, and
## re-published whenever the robot's State disagrees (case-insensitive), at
## most once per THROTTLE_US. Ten State changes away from the choice within
## FLICKER_WINDOW_US raise the conflict popup (another dashboard is fighting).
## While /matchhud/state/enabled is live and true nothing is published.
## The robot's ValidNames/Autos and SelectedAutoValid add a validity warning,
## and autos the robot lists but the export lacks are selectable too.

signal selection_changed(selected: String)
signal conflict_changed(shown: bool)

const NONE := "NONE"
const THROTTLE_US := 700_000
const FLICKER_WINDOW_US := 10_000_000
const FLICKER_THRESHOLD := 10
const PENDING_TIMEOUT_US := 1_500_000
## Robot code that never publishes ValidNames/Autos: once its State has been
## live this long without the list, a stored choice outside the export is
## dropped, as it was before robot-only autos existed.
const ROBOT_LIST_WAIT_US := 3_000_000

const LOCK_TOPIC := "/matchhud/state/enabled"

enum Validity { OK, UNKNOWN, NOT_ON_ROBOT, LOAD_FAILED }

var link: ControlLink
var clock: Clock
var request_topic := ""
var state_topic := ""
var names := PackedStringArray()
## Last ValidNames/Autos the robot published, kept across disconnects.
var robot_names := PackedStringArray()
## "" = nothing chosen (mirror the robot), NONE = No Auto, else an auto name.
var selected := ""
var conflict := false
## Name whose user-initiated publish the robot has not confirmed yet.
var pending := ""
var publishes := 0
var last_wire := ""

var _pending_since_us := 0
var _was_connected := false
var _last_sync_us := -THROTTLE_US
var _prev_robot := NONE
var _mismatch_us: Array[int] = []
var _known_since_us := -1


func _init(p_link: ControlLink, p_clock: Clock, topics: Dictionary, stored: String = "") -> void:
	link = p_link
	clock = p_clock
	request_topic = topics["request"]
	state_topic = topics["state"]
	selected = stored.strip_edges()


func set_topics(topics: Dictionary) -> void:
	if topics["request"] == request_topic and topics["state"] == state_topic:
		return
	link.release(request_topic)
	request_topic = topics["request"]
	state_topic = topics["state"]
	_was_connected = false
	_last_sync_us = clock.now_us() - THROTTLE_US


## Library names. A stored choice that matches neither them nor the robot's
## auto list is cleared; until the robot's list (or its absence) is known it
## waits, unpublished.
func set_library(p_names: PackedStringArray) -> void:
	names = p_names
	_resolve_selected()


func _resolve_selected() -> void:
	_refresh_robot_names()
	if names.is_empty() or selected == "" or selected == NONE:
		return
	var m := find_match(selected, names)
	if m == "":
		m = find_match(selected, robot_names)
		if m == "" and _robot_list_settled():
			_set_selected("")
			return
	if m != "" and m != selected:
		_set_selected(m)


func _robot_list_settled() -> bool:
	if robot_list_live():
		return true
	return _known_since_us >= 0 and clock.now_us() - _known_since_us >= ROBOT_LIST_WAIT_US


func awaiting_robot_list() -> bool:
	if selected == "" or selected == NONE:
		return false
	return find_match(selected, names) == "" and find_match(selected, robot_names) == ""


func robot_list_live() -> bool:
	return link.connected() and link.live(Topics.PP_VALID_AUTOS)


func robot_list() -> PackedStringArray:
	if not robot_list_live():
		return PackedStringArray()
	var v: Variant = link.value(Topics.PP_VALID_AUTOS)
	return PackedStringArray(v) if v is PackedStringArray or v is Array else PackedStringArray()


func _refresh_robot_names() -> void:
	if robot_list_live():
		var l := robot_list()
		if l != robot_names:
			robot_names = l


## Autos the robot has (as last listed) that the export lacks, robot order.
func robot_only_names() -> PackedStringArray:
	var out := PackedStringArray()
	for n in robot_names:
		var t := n.strip_edges()
		if t != "" and t.to_upper() != NONE and find_match(t, names) == "" and find_match(t, out) == "":
			out.append(t)
	return out


func all_names() -> PackedStringArray:
	return names + robot_only_names()


## Whether the choice may be published: No Auto, a library auto, or one the
## robot lists.
func enforceable() -> bool:
	if selected == "":
		return false
	if selected == NONE or find_match(selected, names) != "":
		return true
	return find_match(selected, robot_names) != ""


## Exact name first, then a trimmed case-insensitive match (pathLibrary.ts).
static func find_match(candidate: String, list: PackedStringArray) -> String:
	var c := candidate.strip_edges()
	if c == "":
		return ""
	if list.has(c):
		return c
	var lc := c.to_lower()
	for n in list:
		if n.strip_edges().to_lower() == lc:
			return n
	return ""


static func wire_name(choice: String) -> String:
	var t := choice.strip_edges()
	return NONE if t == "" or t.to_upper() == NONE else t


static func same_auto(a: String, b: String) -> bool:
	return wire_name(a).to_lower() == wire_name(b).to_lower()


func locked() -> bool:
	return link.live(LOCK_TOPIC) and link.value(LOCK_TOPIC) == true


func robot_known() -> bool:
	return link.connected() and link.live(state_topic)


## The robot's State, trimmed; empty or "none" in any case is NONE.
func robot_auto() -> String:
	if not robot_known():
		return NONE
	var v: Variant = link.value(state_topic)
	return wire_name(v) if typeof(v) == TYPE_STRING else NONE


## What the list highlights: the local choice, else the robot's auto when it
## names a library auto.
func active_name() -> String:
	if selected == NONE:
		return NONE
	var all := all_names()
	var local := find_match(selected, all)
	if local != "":
		return local
	if robot_known():
		var r := robot_auto()
		if r == NONE:
			return ""
		return find_match(r, all)
	return ""


func robot_confirms_selection() -> bool:
	return selected != "" and robot_known() and same_auto(robot_auto(), selected)


func select(choice: String) -> bool:
	if locked():
		return false
	_set_selected(NONE if choice == NONE or choice.strip_edges() == "" else choice)
	_publish()
	_last_sync_us = clock.now_us()
	pending = selected
	_pending_since_us = clock.now_us()
	return true


func resync() -> bool:
	_set_conflict(false)
	if locked() or not enforceable():
		return false
	_publish()
	_last_sync_us = clock.now_us()
	return true


func dismiss_conflict() -> void:
	_set_conflict(false)


func _set_selected(s: String) -> void:
	if s == selected:
		return
	selected = s
	_mismatch_us.clear()
	selection_changed.emit(selected)


func _set_conflict(v: bool) -> void:
	if v == conflict:
		return
	conflict = v
	conflict_changed.emit(v)


func _publish() -> void:
	last_wire = wire_name(selected)
	publishes += 1
	link.publish(request_topic, "string", last_wire)


func update() -> void:
	var now := clock.now_us()
	var connected := link.connected()
	var just_connected := connected and not _was_connected
	_was_connected = connected
	var is_locked := locked()
	var known := robot_known()
	if not known:
		_known_since_us = -1
	elif _known_since_us < 0:
		_known_since_us = now
	var robot := robot_auto()
	_resolve_selected()
	var enforce := enforceable()

	if not connected or not enforce or is_locked:
		_mismatch_us.clear()
		_prev_robot = robot
	elif known:
		if robot != _prev_robot and not same_auto(robot, selected):
			while not _mismatch_us.is_empty() and now - _mismatch_us[0] > FLICKER_WINDOW_US:
				_mismatch_us.pop_front()
			_mismatch_us.append(now)
			if _mismatch_us.size() >= FLICKER_THRESHOLD:
				_set_conflict(true)
				_mismatch_us.clear()
		_prev_robot = robot

	if connected and enforce and not is_locked:
		var aligned := known and same_auto(robot, selected)
		if (just_connected or not aligned) and now - _last_sync_us >= THROTTLE_US:
			_publish()
			_last_sync_us = now

	if pending != "":
		if not connected or (known and same_auto(robot, pending)) or now - _pending_since_us > PENDING_TIMEOUT_US:
			pending = ""


## Whether the robot can run `auto_name`: NOT_ON_ROBOT when its live
## ValidNames/Autos list lacks it, LOAD_FAILED when it is the robot's current
## auto and SelectedAutoValid is false, UNKNOWN without live robot data.
func validity(auto_name: String) -> Validity:
	if auto_name == "" or auto_name == NONE or not link.connected():
		return Validity.UNKNOWN if auto_name != NONE else Validity.OK
	var listed := link.live(Topics.PP_VALID_AUTOS)
	if listed:
		var list: Variant = link.value(Topics.PP_VALID_AUTOS)
		if list is PackedStringArray or list is Array:
			if find_match(auto_name, PackedStringArray(list)) == "":
				return Validity.NOT_ON_ROBOT
	if robot_known() and same_auto(robot_auto(), auto_name) and link.live(Topics.PP_SELECTED_AUTO_VALID):
		if link.value(Topics.PP_SELECTED_AUTO_VALID) == false:
			return Validity.LOAD_FAILED
		return Validity.OK
	return Validity.OK if listed else Validity.UNKNOWN


static func validity_text(v: Validity) -> String:
	match v:
		Validity.NOT_ON_ROBOT:
			return "Not in the robot's auto list"
		Validity.LOAD_FAILED:
			return "Robot failed to load this auto"
	return ""


## Select button of the detail pane for the auto being viewed.
func button_for(view: String) -> Dictionary:
	if locked():
		return {"text": "Locked During Match", "enabled": false, "selected": active_name() == view}
	if pending != "":
		return {"text": "Selecting..." if pending == view else "Select", "enabled": false, "selected": active_name() == view}
	if view != "" and active_name() == view:
		return {"text": "Selected", "enabled": true, "selected": true}
	return {"text": "Select", "enabled": view != "", "selected": false}


func snapshot() -> Dictionary:
	return {
		"selected": selected, "active": active_name(), "robot": robot_auto(), "robot_known": robot_known(),
		"locked": locked(), "conflict": conflict, "pending": pending, "publishes": publishes,
		"last_wire": last_wire, "request_topic": request_topic, "state_topic": state_topic,
		"validity": Validity.keys()[validity(selected)] if selected != "" else "",
	}
