extends Control
## Draws and edits the control points of a path node.
##
## Every vertex is a cubic bezier vertex with an in and an out handle. Tapping an
## empty spot creates a real bezier vertex: its handles are derived from the
## neighbours, so the curve bends right away instead of needing two extra drags.
## Two modes stay supported: a plain point list (Follow Path, which smooths them
## itself) and the bezier vertex list used by the Path node.

const ShaderGraphScript := preload("res://src/Classes/ShaderComposer/ShaderGraph.gd")

signal points_changed(points: Array)

const HANDLE_RADIUS := 8.0
## Radius in pixels that still counts as hitting a point, sized for fingers.
const HANDLE_TOUCH := 24.0
## Handles get a slightly wider touch area, they are the fiddliest target here.
const BEZIER_TOUCH := 20.0
## Tapping this close to the curve inserts a vertex there instead of at the end.
const SEGMENT_TOUCH := 16.0
const SEGMENT_STEPS := 12
const SAMPLE_STEPS := 16
## Holding a point still for this long removes it, which is the touch version of
## right click.
const HOLD_DELETE_MSEC := 600
## A press that travels further than this is a drag, not a long press.
const HOLD_MOVE_TOLERANCE := 14.0
## Handle length of an automatically smoothed vertex, as a share of the distance
## between its neighbours.
const SMOOTH_FACTOR := 0.25

## Control points, always stored as {point, in, out} dictionaries.
var _entries: Array[Dictionary] = []
## True when the in/out handles are drawn and can be dragged.
var handles := false
## Dragging one handle mirrors the other, which keeps a vertex smooth.
var smooth_handles := true
var closed := false
## Position of the marker that shows where the pattern currently is.
var phase := 0.0

var _dragging := -1
var _dragging_handle := ""
var _selected := -1
## Bookkeeping for the long press that deletes a vertex.
var _press_index := -1
var _press_position := Vector2.ZERO
var _press_msec := 0
var _background := Color(0.09, 0.09, 0.12)
var _grid := Color(1.0, 1.0, 1.0, 0.07)
var _border := Color(1.0, 1.0, 1.0, 0.2)
var _curve := Color(0.55, 0.8, 1.0)
var _handle := Color(0.85, 0.85, 0.9)
var _handle_selected := Color(1.0, 0.85, 0.35)
var _handle_line := Color(0.55, 0.8, 1.0, 0.55)
var _marker := Color(1.0, 0.35, 0.35)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(200, 180)


## Plain point list mode, used by Follow Path.
func set_points(new_points: Array, new_phase := 0.0) -> void:
	handles = false
	closed = false
	_entries.clear()
	for point in new_points:
		_entries.append({"point": point, "in": Vector2.ZERO, "out": Vector2.ZERO})
	phase = fposmod(new_phase, 1.0)
	_reset_drag()


## Bezier mode: every entry has a "point" and the "in" / "out" handles.
func set_bezier(new_entries: Array, new_closed: bool, new_phase := 0.0) -> void:
	handles = true
	closed = new_closed
	_entries.clear()
	for entry in new_entries:
		if entry is not Dictionary:
			continue
		_entries.append(
			{
				"point": entry.get("point", Vector2(0.5, 0.5)),
				"in": entry.get("in", Vector2.ZERO),
				"out": entry.get("out", Vector2.ZERO),
			}
		)
	phase = fposmod(new_phase, 1.0)
	_reset_drag()


## A start shape: a shallow arc for bezier paths, a loop for plain points.
func reset_to_square() -> void:
	if handles:
		_entries = default_bezier()
	else:
		_entries.clear()
		for point in default_points():
			_entries.append({"point": point, "in": Vector2.ZERO, "out": Vector2.ZERO})
	_reset_drag()
	points_changed.emit(payload())


func remove_selected() -> void:
	if _selected < 0 or _selected >= _entries.size():
		return
	_entries.remove_at(_selected)
	_reset_drag()
	points_changed.emit(payload())


## Rebuilds the handles of every vertex from its neighbours, turning a polyline
## into one flowing curve. The main reason to do it is after dragging points
## around: the tangents still point at the old neighbours.
func smooth_all() -> void:
	for index in _entries.size():
		_smooth_vertex(index)
	queue_redraw()
	points_changed.emit(payload())


## Flips the direction of travel, which is what decides where a Follow Path
## pattern starts and which way it moves. The in and out handles swap with the
## vertices, so the curve keeps its exact shape.
func reverse_points() -> void:
	_entries.reverse()
	for index in _entries.size():
		var entry: Dictionary = _entries[index]
		var swap: Vector2 = entry["in"]
		entry["in"] = entry["out"]
		entry["out"] = swap
		_entries[index] = entry
	_selected = -1
	queue_redraw()
	points_changed.emit(payload())


func set_phase(value: float) -> void:
	phase = fposmod(value, 1.0)
	queue_redraw()


static func default_points() -> Array:
	return [
		Vector2(0.3, 0.3),
		Vector2(0.7, 0.3),
		Vector2(0.7, 0.7),
		Vector2(0.3, 0.7),
	]


static func default_bezier() -> Array:
	return [
		{"point": Vector2(0.2, 0.75), "in": Vector2.ZERO, "out": Vector2(0.1, -0.15)},
		{"point": Vector2(0.5, 0.3), "in": Vector2(-0.12, 0.12), "out": Vector2(0.12, -0.12)},
		{"point": Vector2(0.8, 0.75), "in": Vector2(-0.1, -0.15), "out": Vector2.ZERO},
	]


## Points in the shape the node stores: plain vectors, or dictionaries with
## handles when the editor is in bezier mode.
func payload() -> Array:
	var result: Array = []
	if handles:
		for entry in _entries:
			result.append(entry.duplicate())
	else:
		for entry in _entries:
			result.append(entry["point"])
	return result


func copy_points() -> Array:
	var copy: Array = []
	for entry in _entries:
		copy.append(entry["point"])
	return copy


## Number of vertices, so the interface can warn when there are too few.
func vertex_count() -> int:
	return _entries.size()


func _reset_drag() -> void:
	_selected = -1
	_dragging = -1
	_dragging_handle = ""
	_press_index = -1
	queue_redraw()


## Gives [param index] tangents that point along the line between its neighbours.
## This is what makes a freshly tapped vertex a real bezier vertex.
func _smooth_vertex(index: int) -> void:
	var count := _entries.size()
	if index < 0 or index >= count:
		return
	var entry: Dictionary = _entries[index]
	if count < 2:
		entry["in"] = Vector2.ZERO
		entry["out"] = Vector2.ZERO
		_entries[index] = entry
		return
	var current: Vector2 = entry["point"]
	var previous := current
	var following := current
	if index > 0:
		previous = _entries[index - 1]["point"]
	elif closed:
		previous = _entries[count - 1]["point"]
	if index < count - 1:
		following = _entries[index + 1]["point"]
	elif closed:
		following = _entries[0]["point"]
	var tangent := (following - previous) * SMOOTH_FACTOR
	entry["out"] = tangent
	entry["in"] = -tangent
	_entries[index] = entry


## Inserts a vertex at [param local], either on the segment under the finger or
## at the end of the path. Returns the new index.
func _insert_vertex(local: Vector2) -> int:
	var target := _to_normalized(local)
	var index := _entries.size()
	if handles and _entries.size() >= 2:
		var hit := _segment_at(local)
		if not hit.is_empty():
			target = hit["point"]
			index = int(hit["index"]) + 1
	_entries.insert(index, {"point": target, "in": Vector2.ZERO, "out": Vector2.ZERO})
	_smooth_vertex(index)
	return index


## Closest point on the drawn curve, with the index of the segment it belongs to.
func _segment_at(local: Vector2) -> Dictionary:
	var flat := ShaderGraphScript.flatten_path(_entries, closed, SEGMENT_STEPS)
	if flat.size() < 2:
		return {}
	var count := _entries.size()
	var found := {}
	var best := SEGMENT_TOUCH
	for index in range(flat.size() - 1):
		var from_point := _to_local(flat[index])
		var to_point := _to_local(flat[index + 1])
		var closest := Geometry2D.get_closest_point_to_segment(local, from_point, to_point)
		var distance := closest.distance_to(local)
		if distance >= best:
			continue
		best = distance
		found = {
			"point": _to_normalized(closest),
			"index": clampi(int(floorf(float(index) / SEGMENT_STEPS)), 0, count - 1),
		}
	return found


## Deletes the vertex under a long press, which is how a phone removes one.
func _process(_delta: float) -> void:
	if _press_index < 0:
		return
	if Time.get_ticks_msec() - _press_msec < HOLD_DELETE_MSEC:
		return
	var index := _press_index
	_press_index = -1
	if index < 0 or index >= _entries.size():
		return
	if _entries.size() <= 1:
		return
	_entries.remove_at(index)
	_reset_drag()
	points_changed.emit(payload())


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _background)
	if size.x <= 1.0 or size.y <= 1.0:
		return
	var step := size / 4.0
	for i in range(1, 4):
		draw_line(Vector2(step.x * i, 0.0), Vector2(step.x * i, size.y), _grid, 1.0)
		draw_line(Vector2(0.0, step.y * i), Vector2(size.x, step.y * i), _grid, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size), _border, false, 1.0)
	if _entries.size() >= 2:
		var flat := ShaderGraphScript.flatten_path(_entries, closed, SAMPLE_STEPS)
		var curve := PackedVector2Array()
		for point in flat:
			curve.append(_to_local(point))
		if curve.size() >= 2:
			draw_polyline(curve, _curve, 2.0, true)
	if handles:
		for index in _entries.size():
			var entry: Dictionary = _entries[index]
			var origin := _to_local(entry["point"])
			for key in ["in", "out"]:
				var offset: Vector2 = entry[key]
				if offset == Vector2.ZERO:
					continue
				var tip := _to_local((entry["point"] as Vector2) + offset)
				var active: bool = index == _selected and _dragging_handle == key
				draw_line(origin, tip, _handle_line, 2.0 if active else 1.0, true)
				draw_circle(tip, 5.0, _handle_selected if active else _handle_line)
	for index in _entries.size():
		var label := _to_local(_entries[index]["point"])
		draw_circle(label, HANDLE_RADIUS, _handle_selected if index == _selected else _handle)
		# A ring makes the vertex readable against a bright curve on a phone.
		draw_arc(label, HANDLE_RADIUS, 0.0, TAU, 20, _background, 2.0, true)
	if _entries.size() >= 2:
		var marker := ShaderGraphScript.sample_path_point(_entries, closed, phase)
		draw_circle(_to_local(marker), 6.0, _marker)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_RIGHT:
			if button.pressed:
				var right_hit := _point_at(button.position)
				if right_hit >= 0:
					_selected = right_hit
					remove_selected()
			accept_event()
			return
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			var handle_hit := _handle_at(button.position)
			if not handle_hit.is_empty():
				_selected = int(handle_hit["index"])
				_dragging = _selected
				_dragging_handle = str(handle_hit["key"])
			else:
				var index := _point_at(button.position)
				if index < 0:
					index = _insert_vertex(button.position)
					points_changed.emit(payload())
				_selected = index
				_dragging = index
				_dragging_handle = ""
				_press_index = index
				_press_position = button.position
				_press_msec = Time.get_ticks_msec()
			queue_redraw()
		else:
			_dragging = -1
			_dragging_handle = ""
			_press_index = -1
		accept_event()
		return
	if event is InputEventMouseMotion and _dragging >= 0 and _dragging < _entries.size():
		var motion := event as InputEventMouseMotion
		if _press_index >= 0 and motion.position.distance_to(_press_position) > HOLD_MOVE_TOLERANCE:
			# Moving means the press is a drag, so it will not delete the point.
			_press_index = -1
		var pointer := _to_normalized(motion.position)
		var entry: Dictionary = _entries[_dragging]
		if _dragging_handle.is_empty():
			# Move the point, the handles stay relative to it.
			entry["point"] = pointer
		else:
			var offset := pointer - (entry["point"] as Vector2)
			entry[_dragging_handle] = offset
			if smooth_handles:
				var opposite := "in" if _dragging_handle == "out" else "out"
				entry[opposite] = -offset
		_entries[_dragging] = entry
		queue_redraw()
		points_changed.emit(payload())
		accept_event()


func _to_local(point: Vector2) -> Vector2:
	return Vector2(point.x * size.x, point.y * size.y)


func _to_normalized(local: Vector2) -> Vector2:
	if size.x <= 1.0 or size.y <= 1.0:
		return Vector2(0.5, 0.5)
	return Vector2(
		clampf(local.x / size.x, 0.0, 1.0), clampf(local.y / size.y, 0.0, 1.0)
	)


func _point_at(local: Vector2) -> int:
	for index in range(_entries.size() - 1, -1, -1):
		if _to_local(_entries[index]["point"]).distance_to(local) <= HANDLE_TOUCH:
			return index
	return -1


## Returns {index, key} of the bezier handle under [param local], or an empty
## dictionary. Handles win over points, so a handle sitting on its point is still
## grabbable.
func _handle_at(local: Vector2) -> Dictionary:
	if not handles:
		return {}
	for index in _entries.size():
		var entry: Dictionary = _entries[index]
		for key in ["out", "in"]:
			var offset: Vector2 = entry[key]
			if offset == Vector2.ZERO:
				continue
			var tip := _to_local((entry["point"] as Vector2) + offset)
			if tip.distance_to(local) <= BEZIER_TOUCH:
				return {"index": index, "key": key}
	return {}
