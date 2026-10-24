extends Control
## Draws and edits the control points of a Follow Path node.
##
## Points are stored normalized (0..1) so the path keeps its shape when the
## canvas size changes. Tapping empty space appends a point, dragging moves one,
## a right click or the panel button removes the selected one.

const ShaderGraphScript := preload("res://src/Classes/ShaderComposer/ShaderGraph.gd")

signal points_changed(points: Array)

const HANDLE_RADIUS := 8.0
## Radius in pixels that still counts as hitting a handle, sized for fingers.
const HANDLE_TOUCH := 20.0
const SAMPLE_COUNT := 128

## Control points in 0..1 canvas units.
var points: Array = []
## Position of the marker that shows where the pattern currently is.
var phase := 0.0

var _dragging := -1
var _selected := -1
var _background := Color(0.09, 0.09, 0.12)
var _grid := Color(1.0, 1.0, 1.0, 0.07)
var _border := Color(1.0, 1.0, 1.0, 0.2)
var _curve := Color(0.55, 0.8, 1.0)
var _handle := Color(0.85, 0.85, 0.9)
var _handle_selected := Color(1.0, 0.85, 0.35)
var _marker := Color(1.0, 0.35, 0.35)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(200, 180)


func set_points(new_points: Array, new_phase := 0.0) -> void:
	points.clear()
	for point in new_points:
		points.append(point)
	phase = fposmod(new_phase, 1.0)
	_selected = -1
	_dragging = -1
	queue_redraw()


## Closed loop around the middle, used when a graph has no custom points yet.
func reset_to_square() -> void:
	points = default_points()
	_selected = -1
	_dragging = -1
	queue_redraw()
	points_changed.emit(copy_points())


func remove_selected() -> void:
	if _selected < 0 or _selected >= points.size():
		return
	points.remove_at(_selected)
	_selected = -1
	_dragging = -1
	queue_redraw()
	points_changed.emit(copy_points())


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


func copy_points() -> Array:
	var copy: Array = []
	for point in points:
		copy.append(point)
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
	if points.size() >= 2:
		var curve := PackedVector2Array()
		for i in range(SAMPLE_COUNT + 1):
			var t := float(i) / float(SAMPLE_COUNT)
			curve.append(_to_local(ShaderGraphScript.sample_custom_path(points, t)))
		draw_polyline(curve, _curve, 2.0, true)
	for index in points.size():
		draw_circle(
			_to_local(points[index]),
			HANDLE_RADIUS,
			_handle_selected if index == _selected else _handle
		)
	if points.size() >= 2:
		draw_circle(
			_to_local(ShaderGraphScript.sample_custom_path(points, phase)), 6.0, _marker
		)


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
			var index := _point_at(button.position)
			if index < 0:
				points.append(_to_normalized(button.position))
				index = points.size() - 1
				points_changed.emit(copy_points())
			_selected = index
			_dragging = index
			queue_redraw()
		else:
			_dragging = -1
		accept_event()
		return
	if event is InputEventMouseMotion and _dragging >= 0 and _dragging < points.size():
		points[_dragging] = _to_normalized((event as InputEventMouseMotion).position)
		queue_redraw()
		points_changed.emit(copy_points())
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
	for index in range(points.size() - 1, -1, -1):
		if _to_local(points[index]).distance_to(local) <= HANDLE_TOUCH:
			return index
	return -1
