class_name DndRules
extends RefCounted

## Drop rules of the rail/dock editor (useTouchscreenDnd.ts handleDragEnd).
## The dock is the master list (order only); the rail is a user subset.
## A target is {"zone": "rail"|"dock"|"", "id": item under the pointer or ""}.


static func apply_drop(rail: Array, dock: Array, src_zone: String, src_id: String, target: Dictionary) -> Dictionary:
	var r := rail.duplicate()
	var d := dock.duplicate()
	var zone := str(target.get("zone", ""))
	var over := str(target.get("id", ""))
	match [src_zone, zone]:
		["rail", "rail"]:
			r = _move(r, src_id, over)
		["dock", "dock"]:
			d = _move(d, src_id, over)
		["dock", "rail"]:
			if not r.has(src_id):
				var at := r.find(over) if over != "" else -1
				if at < 0:
					r.append(src_id)
				else:
					r.insert(at, src_id)
		["rail", "dock"]:
			r.erase(src_id)
	return {"rail": r, "dock": d, "changed": r != rail or d != dock}


## arrayMove(list, from, index of over); over "" moves to the end.
static func _move(list: Array, id: String, over: String) -> Array:
	var from := list.find(id)
	if from < 0 or over == id:
		return list
	var to := list.find(over) if over != "" else list.size() - 1
	if to < 0:
		return list
	list.remove_at(from)
	list.insert(to, id)
	return list


## Item whose center is nearest the point (dnd-kit closestCenter), or "".
static func closest(ids: Array, centers: Array, point: Vector2) -> String:
	var best := ""
	var best_d := INF
	for i in mini(ids.size(), centers.size()):
		var dd := (centers[i] as Vector2).distance_squared_to(point)
		if dd < best_d:
			best_d = dd
			best = ids[i]
	return best


## Rail target in a vertical list: the closest item, or "" (append) when the
## point is below the last item's center, so dropping under the list appends.
static func rail_target(ids: Array, centers: Array, point: Vector2) -> String:
	if ids.is_empty():
		return ""
	if point.y > (centers[centers.size() - 1] as Vector2).y:
		return ""
	return closest(ids, centers, point)
