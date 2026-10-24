extends Control
## Draws and edits the control points of a path node.
##
## Two modes are supported: a plain list of points (used by Follow Path, which
## smooths them itself) and cubic bezier points with in/out handles (used by the
## Path node). Points are stored normalized (0..1), so the path keeps its shape
## when the canvas size changes.

const ShaderGraphScript := preload("res://src/Classes/ShaderComposer/ShaderGraph.gd")

signal points_changed(points: Array)

const HANDLE_RADIUS := 8.0
## Radius in pixels that still counts as hitting a handle, sized for fingers.
const HANDLE_TOUCH := 20.0
const BEZIER_TOUCH := 14.0
const SAMPLE_STEPS := 16

## Control points, always stored as {point, in, out} dictionaries.
var _entries: Array[Dictionary] = []
## True when the in/out handles are drawn and can be dragged.
var handles := false
var closed := false
## Position of the marker that shows where the pattern currently is.
var phase := 0.0

var _dragging := -1
var _dragging_handle := ""
var _selected := -1
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
	_selected = -1
	_dragging = -1
	_dragging_handle = ""
	queue_redraw()


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
	_selected = -1
	_dragging = -1
	_dragging_handle = ""
	queue_redraw()


## A start shape: a shallow arc for bezier paths, a loop for plain points.
func reset_to_square() -> void:
	if handles:
		_entries = default_bezier()
	else:
		_entries.clear()
		for point in default_points():
			_entries.append({"point": point, "in": Vector2.ZERO, "out": Vector2.ZERO})
	_selected = -1
	_dragging = -1
	_dragging_handle = ""
	queue_redraw()
	points_changed.emit(payload())


func remove_selected() -> void:
	if _selected < 0 or _selected >= _entries.size():
		return
	_entries.remove_at(_selected)
	_selected = -1
	_dragging = -1
	_dragging_handle = ""
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
				draw_circle(tip, 4.0, _handle_selected if active else _handle_line)
	for index in _entries.size():
		draw_circle(
			_to_local(_entries[index]["point"]),
			HANDLE_RADIUS,
			_handle_selected if index == _selected else _handle
		)
	if _entries.size() >= 2:
		var marker := ShaderGraphScript.sample_path_point(_entries, closed, phase)
		draw_circle(_to_local(marker), 6.0, _marker)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_RIGHT:
			if button.pressed:
				var hit := _point_at(button.position)
				if hit >= 0:
					_selected = hit
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
					_entries.append(
						{
							"point": _to_normalized(button.position),
							"in": Vector2.ZERO,
							"out": Vector2.ZERO,
						}
					)
					index = _entries.size() - 1
					points_changed.emit(payload())
				_selected = index
				_dragging = index
				_dragging_handle = ""
			queue_redraw()
		else:
			_dragging = -1
			_dragging_handle = ""
		accept_event()
		return
	if event is InputEventMouseMotion and _dragging >= 0 and _dragging < _entries.size():
		var pointer := _to_normalized((event as InputEventMouseMotion).position)
		var entry: Dictionary = _entries[_dragging]
		if _dragging_handle.is_empty():
			# Move the point together with its handles.
			entry["point"] = pointer
		else:
			entry[_dragging_handle] = pointer - (entry["point"] as Vector2)
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
