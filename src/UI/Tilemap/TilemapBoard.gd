extends Control
## Drawing surface of the tilemap page. It keeps the view transform and turns
## pointer positions into cells; the page owns the map, so the board only draws
## and forwards input.
##
## The page is kept untyped on purpose: this script is loaded by the page with
## preload, and calling back through [code]call()[/code] avoids a circular type
## reference between the two files.


var page

## Latest position of every finger, so two of them can pan and pinch.
var _touches: Dictionary = {}
var _gesture := false
var _gesture_distance := 0.0
var _gesture_mid := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	# Nearest filtering keeps the tiles crisp when zoomed in.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	resized.connect(queue_redraw)


func _draw() -> void:
	if page != null:
		page.draw_board(self)


func _gui_input(event: InputEvent) -> void:
	if page != null:
		page.handle_board_input(self, event)


## Raw touch: one finger paints, two fingers pan and zoom. Raw events are used
## because a page does not always receive emulated mouse events.
func _input(event: InputEvent) -> void:
	if page == null or not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		var touch := make_input_local(event) as InputEventScreenTouch
		if touch.pressed:
			_touches[touch.index] = touch.position
			if _touches.size() >= 2:
				_gesture = true
				page.call("cancel_stroke")
				_measure_gesture(false)
			else:
				page.call("_begin_stroke", page.call("_board_cell", touch.position))
		else:
			_touches.erase(touch.index)
			if _gesture:
				if _touches.size() >= 2:
					_measure_gesture(false)
				else:
					_gesture = false
			else:
				page.call("_end_stroke")
		return
	if event is InputEventScreenDrag:
		var drag := make_input_local(event) as InputEventScreenDrag
		var known := _touches.has(drag.index)
		_touches[drag.index] = drag.position
		if _touches.size() >= 2:
			_gesture = true
			_measure_gesture(true)
		elif known and not _gesture:
			page.call("_continue_stroke", page.call("_board_cell", drag.position))


## Applies the pan and pinch between the first two fingers and remembers the new
## reference, so the next move is only the difference.
func _measure_gesture(apply: bool) -> void:
	var keys := _touches.keys()
	if keys.size() < 2:
		return
	var a: Vector2 = _touches[keys[0]]
	var b: Vector2 = _touches[keys[1]]
	var mid := (a + b) * 0.5
	var distance := a.distance_to(b)
	if apply and _gesture_distance > 0.0:
		var delta := mid - _gesture_mid
		if delta.length_squared() > 0.0:
			page.call("pan_by", delta)
		var factor := distance / _gesture_distance
		if absf(factor - 1.0) > 0.002:
			page.call("zoom_at", mid, factor)
	_gesture_mid = mid
	_gesture_distance = distance
