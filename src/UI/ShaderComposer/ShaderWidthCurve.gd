extends Control
## Curve strip for the line width along a stroke. The x axis is the position on
## the curve and the y axis is a multiplier of the base width, so dragging a
## point down thins that part of the line. Five samples are enough for a taper,
## a bulge or a chunky middle without needing a full curve editor.

signal changed(values: Array)

const SAMPLES := 5
const MIN_HEIGHT := 96
const HANDLE_RADIUS := 6.0

var values: Array = [1.0, 1.0, 1.0, 1.0, 1.0]
var _dragging := -1


func _ready() -> void:
	if custom_minimum_size.y <= 0.0:
		custom_minimum_size.y = MIN_HEIGHT
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	if tooltip_text.is_empty():
		tooltip_text = "拖动圆点调整该处的线宽"
	_normalise()
	queue_redraw()


## Loads a saved profile, padding it with ones so an older graph still draws a
## constant width.
func set_profile(profile: Array) -> void:
	values = []
	for value in profile:
		values.append(clampf(float(value), 0.0, 1.0))
	_normalise()
	queue_redraw()


func _normalise() -> void:
	while values.size() < SAMPLES:
		values.append(1.0)
	if values.size() > SAMPLES:
		values.resize(SAMPLES)


## Position of one sample on the strip. The ends are kept away from the border by
## the handle radius so the circles stay fully visible.
func _point_at(index: int) -> Vector2:
	var step := size.x / float(SAMPLES - 1)
	var margin := HANDLE_RADIUS + 2.0
	var x := step * float(index)
	var y := lerpf(size.y - margin, margin, clampf(float(values[index]), 0.0, 1.0))
	return Vector2(x, y)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.14, 0.15, 0.18))
	draw_rect(Rect2(Vector2.ZERO, size).grow(-0.5), Color(0.32, 0.35, 0.42), false, 1.0)
	var step := size.x / float(SAMPLES - 1)
	for index in range(SAMPLES):
		var x := step * float(index)
		draw_line(Vector2(x, 2), Vector2(x, size.y - 2), Color(1.0, 1.0, 1.0, 0.06), 1.0)
	var points := PackedVector2Array()
	for index in range(SAMPLES):
		points.append(_point_at(index))
	for index in range(points.size() - 1):
		draw_line(points[index], points[index + 1], Color(0.55, 0.8, 1.0), 2.0)
	for index in range(points.size()):
		var point := points[index]
		var color := Color(0.75, 0.9, 1.0) if index == _dragging else Color(0.4, 0.6, 0.8)
		draw_circle(point, HANDLE_RADIUS, color)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = _nearest(event.position)
			if _dragging >= 0:
				_apply(event.position)
				accept_event()
		elif _dragging >= 0:
			_dragging = -1
			queue_redraw()
			accept_event()
	elif event is InputEventMouseMotion and _dragging >= 0:
		var motion := event as InputEventMouseMotion
		_apply(motion.position)
		accept_event()


## Nearest sample to [param position]. Anywhere in a column counts, so the strip
## stays usable with a finger even though the handles are small.
func _nearest(position: Vector2) -> int:
	var best := 0
	var best_distance := 1e20
	for index in range(SAMPLES):
		var point := _point_at(index)
		var distance := absf(position.x - point.x)
		if distance < best_distance:
			best_distance = distance
			best = index
	return best


func _apply(position: Vector2) -> void:
	var margin := HANDLE_RADIUS + 2.0
	var span := maxf(size.y - margin * 2.0, 1.0)
	var value := clampf((size.y - margin - position.y) / span, 0.0, 1.0)
	if is_equal_approx(value, float(values[_dragging])):
		return
	values[_dragging] = value
	queue_redraw()
	changed.emit(values.duplicate())
