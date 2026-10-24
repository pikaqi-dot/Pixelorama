extends Control
## Number field that is changed by dragging left and right instead of typing.
## Opening the keyboard on a phone hides half the parameter panel, so touch
## devices get this strip: press it and slide, the value follows the finger.
## A plain tap changes nothing, so the panel can be scrolled past safely.

signal value_changed(new_value: float)

## Pixels of horizontal travel that cover the whole range. Dragging further
## keeps going, so a wide range is still reachable on a small strip.
const TRAVEL := 220.0
## Movement below this many pixels is treated as a tap, not a drag.
const DRAG_THRESHOLD := 3.0

var min_value := 0.0
var max_value := 1.0
var step := 1.0
## Rounds to whole numbers, which most node parameters are.
var integer := true
## Drawn after the number, like "帧".
var suffix := ""

var value := 0.0:
	get:
		return _value
	set(new_value):
		_apply(new_value, false)

var _value := 0.0
var _dragging := false
var _drag_active := false
var _start_x := 0.0
var _start_value := 0.0
var _label: Label


func _ready() -> void:
	if custom_minimum_size.y <= 0.0:
		custom_minimum_size.y = 40.0
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The press passes through, so a vertical swipe still scrolls the panel. A
	# sideways move is accepted below, which is what takes over the gesture.
	mouse_filter = Control.MOUSE_FILTER_PASS
	focus_mode = Control.FOCUS_NONE
	if tooltip_text.is_empty():
		tooltip_text = "按住左右滑动调整数值"
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 15)
	add_child(_label)
	_refresh_label()
	queue_redraw()


## Sets the allowed range and the value shown right away, before the control is
## ever added to the tree.
func set_range(
	new_min: float, new_max: float, new_step: float, as_integer: bool, current: float
) -> void:
	min_value = minf(new_min, new_max)
	max_value = maxf(new_min, new_max)
	step = maxf(new_step, 0.0001)
	integer = as_integer
	_value = clampf(current, min_value, max_value)
	_refresh_label()
	queue_redraw()


func _draw() -> void:
	var box := Rect2(Vector2.ZERO, size)
	var background := Color(0.17, 0.18, 0.21)
	if _drag_active:
		background = Color(0.23, 0.26, 0.32)
	draw_rect(box, background)
	draw_rect(box.grow(-0.5), Color(0.36, 0.4, 0.48), false, 1.0)
	# Chevrons at both ends show which way the finger has to go.
	var middle := size.y * 0.5
	var color := Color(1.0, 1.0, 1.0, 0.45 if _drag_active else 0.28)
	draw_line(Vector2(11, middle - 6), Vector2(6, middle), color, 2.0)
	draw_line(Vector2(6, middle), Vector2(11, middle + 6), color, 2.0)
	draw_line(Vector2(size.x - 11, middle - 6), Vector2(size.x - 6, middle), color, 2.0)
	draw_line(Vector2(size.x - 6, middle), Vector2(size.x - 11, middle + 6), color, 2.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_drag_active = false
				_start_x = event.position.x
				_start_value = _value
				queue_redraw()
			elif _dragging:
				_dragging = false
				_drag_active = false
				queue_redraw()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply(_value + step, true)
			accept_event()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply(_value - step, true)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		var offset: float = motion.position.x - _start_x
		if not _drag_active:
			# The press stays unhandled, so a vertical swipe still scrolls the
			# panel. Only a sideways move takes over the gesture.
			if absf(offset) < DRAG_THRESHOLD:
				return
			_drag_active = true
			# Start counting after the threshold, so the value does not jump by
			# the few pixels it took to prove this is a sideways drag.
			_start_x += signf(offset) * DRAG_THRESHOLD
			offset = motion.position.x - _start_x
			queue_redraw()
		var span := maxf(max_value - min_value, 0.0001)
		# Never finer than one step per pixel, but also never coarser than eight,
		# so a big range stays tunable and a small one stays quick.
		var per_pixel := clampf(span / TRAVEL, step, step * 8.0)
		_apply(_start_value + offset * per_pixel, true)
		accept_event()


## Applies a value, snapping it to the step and telling the page only when the
## change came from the user.
func _apply(new_value: float, from_user: bool) -> void:
	var clamped := clampf(new_value, min_value, max_value)
	var unit := maxf(step, 0.0001)
	if integer:
		clamped = roundf(clamped / unit) * unit
	else:
		clamped = snappedf(clamped, unit)
	clamped = clampf(clamped, min_value, max_value)
	var changed := not is_equal_approx(clamped, _value)
	_value = clamped
	_refresh_label()
	queue_redraw()
	if changed and from_user:
		value_changed.emit(_value)


func _refresh_label() -> void:
	if _label == null:
		return
	var text := str(roundi(_value)) if integer else String.num(_value, _decimals())
	_label.text = text + suffix


func _decimals() -> int:
	if step >= 1.0:
		return 0
	if step >= 0.1:
		return 1
	if step >= 0.01:
		return 2
	return 3
