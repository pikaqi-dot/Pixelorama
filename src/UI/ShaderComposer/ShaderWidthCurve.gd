extends Control
## Curve strip for the line width along a stroke. The x axis is the position on
## the curve and the y axis is a multiplier of the base width, so dragging a
## point down thins that part of the line. Five samples are enough for a taper,
## a bulge or a chunky middle without needing a full curve editor.
##
## The picture is painted from the same interpolation the rasteriser uses, so the
## strip is a true preview of the stroke instead of a sketch of it: the filled
## area is the width, and the line is the multiplier along the path.

signal changed(values: Array)

const ShaderGraphScript := preload("res://src/Classes/ShaderComposer/ShaderGraph.gd")

const SAMPLES := 5
const MIN_HEIGHT := 104
const HANDLE_RADIUS := 6.0
## How far the curve is kept from the sides, so the end handles stay whole.
const SIDE_MARGIN := 9.0
## Points used to draw the smooth strip. Enough for a soft curve at any width.
const CURVE_STEPS := 72

var values: Array = [1.0, 1.0, 1.0, 1.0, 1.0]
var _dragging := -1


func _ready() -> void:
	if custom_minimum_size.y <= 0.0:
		custom_minimum_size.y = MIN_HEIGHT
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	if tooltip_text.is_empty():
		tooltip_text = "左右拖动圆点调整该处的线宽"
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


## Replaces the whole profile. A preset button uses this, and [param notify] makes
## it behave like a drag so the graph and the preview follow.
func set_values(new_values: Array, notify := true) -> void:
	values = []
	for value in new_values:
		values.append(clampf(float(value), 0.0, 1.0))
	_normalise()
	queue_redraw()
	if notify:
		changed.emit(values.duplicate())


## Mirrors the profile, which is how a taper becomes the other taper.
func reverse() -> void:
	var flipped: Array = []
	for index in range(values.size() - 1, -1, -1):
		flipped.append(float(values[index]))
	set_values(flipped)


func _normalise() -> void:
	while values.size() < SAMPLES:
		values.append(1.0)
	if values.size() > SAMPLES:
		values.resize(SAMPLES)


## X of one sample. The ends are held away from the border so a whole handle
## stays visible and reachable with a finger.
func _x_at(index: int) -> float:
	if SAMPLES <= 1:
		return size.x * 0.5
	var span := maxf(size.x - SIDE_MARGIN * 2.0, 1.0)
	return SIDE_MARGIN + span * float(index) / float(SAMPLES - 1)


## Y of a width multiplier. 1.0 sits at the top of the box and 0.0 at the bottom.
func _y_at(value: float) -> float:
	var margin := HANDLE_RADIUS + 3.0
	return lerpf(size.y - margin, margin, clampf(value, 0.0, 1.0))


func _point_at(index: int) -> Vector2:
	return Vector2(_x_at(index), _y_at(float(values[index])))


## Width multiplier at [param t], taken from the same function the stroke is
## rasterised with.
func _value_at(t: float) -> float:
	return ShaderGraphScript.profile_at(values, t)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.14, 0.15, 0.18))
	# Quarter guides, so a width can be aimed at 25 / 50 / 75 percent.
	for step in range(1, 4):
		var y := _y_at(float(step) / 4.0)
		draw_line(Vector2(2, y), Vector2(size.x - 2, y), Color(1.0, 1.0, 1.0, 0.05), 1.0)
	# A column under every sample, which is what the drag snaps to.
	for index in range(SAMPLES):
		var x := _x_at(index)
		draw_line(Vector2(x, 3), Vector2(x, size.y - 3), Color(1.0, 1.0, 1.0, 0.07), 1.0)

	var top := PackedVector2Array()
	for step in range(CURVE_STEPS + 1):
		var t := float(step) / float(CURVE_STEPS)
		var x := lerpf(_x_at(0), _x_at(SAMPLES - 1), t)
		top.append(Vector2(x, _y_at(_value_at(t))))
	# The filled area is the stroke: its height at every x is the line width.
	var area := PackedVector2Array(top)
	area.append(Vector2(top[top.size() - 1].x, size.y - 2.0))
	area.append(Vector2(top[0].x, size.y - 2.0))
	draw_colored_polygon(area, Color(0.32, 0.62, 0.9, 0.22))
	for step in range(top.size() - 1):
		draw_line(top[step], top[step + 1], Color(0.55, 0.8, 1.0), 2.0)

	for index in range(SAMPLES):
		var point := _point_at(index)
		var active := index == _dragging
		var fill := Color(0.78, 0.92, 1.0) if active else Color(0.4, 0.6, 0.8)
		var radius := HANDLE_RADIUS + (2.0 if active else 0.0)
		draw_circle(point, radius, Color(0.1, 0.12, 0.15))
		draw_circle(point, HANDLE_RADIUS, fill)
	if _dragging >= 0:
		_draw_readout(_dragging)
	_draw_end_labels()


## Percentage of the dragged sample, right above its handle. The exact number is
## what makes a width easy to repeat by hand.
func _draw_readout(index: int) -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var point := _point_at(index)
	var text := "%d%%" % int(roundf(float(values[index]) * 100.0))
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var left := clampf(point.x - width * 0.5, 2.0, maxf(size.x - width - 2.0, 2.0))
	var top := maxf(point.y - HANDLE_RADIUS - 15.0, 12.0)
	draw_string(
		font,
		Vector2(left, top),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		12,
		Color(0.9, 0.96, 1.0)
	)


## Marks which end of the path is which, so a taper is not added backwards.
func _draw_end_labels() -> void:
	if size.x < 140.0:
		return
	var font := get_theme_default_font()
	if font == null:
		return
	var color := Color(1.0, 1.0, 1.0, 0.45)
	draw_string(
		font, Vector2(4, size.y - 5), "起", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color
	)
	var text := "终"
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	draw_string(
		font,
		Vector2(size.x - width - 4, size.y - 5),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		11,
		color
	)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var button := event as InputEventMouseButton
		if button.pressed:
			_dragging = _nearest(button.position)
			_apply(button.position)
			accept_event()
		elif _dragging >= 0:
			_dragging = -1
			queue_redraw()
			accept_event()
		return
	if event is InputEventMouseMotion and _dragging >= 0:
		_apply((event as InputEventMouseMotion).position)
		accept_event()
		return
	# Raw touch, for the screens where the event is not turned into a mouse one.
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_dragging = _nearest(touch.position)
			_apply(touch.position)
			accept_event()
		elif _dragging >= 0:
			_dragging = -1
			queue_redraw()
			accept_event()
		return
	if event is InputEventScreenDrag and _dragging >= 0:
		_apply((event as InputEventScreenDrag).position)
		accept_event()


## Nearest sample to [param position]. The whole column counts, so the strip
## stays usable with a finger even though the handles are small.
func _nearest(position: Vector2) -> int:
	var best := 0
	var best_distance := 1e20
	for index in range(SAMPLES):
		var distance := absf(position.x - _x_at(index))
		if distance < best_distance:
			best_distance = distance
			best = index
	return best


func _apply(position: Vector2) -> void:
	var margin := HANDLE_RADIUS + 3.0
	var span := maxf(size.y - margin * 2.0, 1.0)
	var value := clampf((size.y - margin - position.y) / span, 0.0, 1.0)
	if _dragging < 0 or is_equal_approx(value, float(values[_dragging])):
		return
	values[_dragging] = value
	queue_redraw()
	changed.emit(values.duplicate())
