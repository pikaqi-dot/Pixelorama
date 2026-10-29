class_name ToolDial
extends Control
## Ring of tools that two quick taps on the drawing view open. It draws its own
## circles instead of building buttons: the ring has to keep one shape whatever
## the window size, and a tool is chosen by pressing and releasing on the same
## circle, never by brushing past one. It carries the icons of the side toolbar,
## so the dial and the panel always show the same tools.

signal picked(tool_name: String)
signal dismissed

## Radius of one tool circle. A fingertip needs about 20 px, and the icon has to
## stay readable inside, so anything below 22 makes the ring unusable.
const SLOT_RADIUS := 23.0
## The middle circle, which closes the dial.
const HUB_RADIUS := 20.0
## Empty space between two neighbouring circles, so a near miss picks nothing.
const SLOT_GAP := 8.0
## Space kept between the outer circles and the window edge.
const EDGE_MARGIN := 10.0
## A release this far outside the plate closes the dial. Inside this band it does
## nothing, which stops a near miss from closing it by accident.
const OUTSIDE_SLACK := 12.0
## Icon drawn inside a circle, in pixels.
const ICON_SIZE := 30.0
const LABEL_FONT_SIZE := 12

var center := Vector2.ZERO
var ring_radius := 60.0

var _entries: Array = []
var _active := ""
## Index of the tool in use. The ring is turned so that entry sits on the right,
## which keeps the thumb path to the current tool the same every time it opens.
var _active_index := 0
var _area := Vector2.ZERO
var _hover := -1
var _pressed_slot := -1
var _press_point := Vector2.ZERO
var _pointer_down := false
var _armed_msec := 0
## Index of the finger that owns the dial, so a second finger of a pinch cannot
## pick a tool or close it by lifting.
var _touch_index := -1


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	# Touch does not always reach the control under the finger, so the raw stream
	# is read here as well.
	set_process_input(true)


## Shows the dial. [param entries] are dictionaries with `tool`, `texture` and
## `label`; [param active] is the tool the left mouse button currently uses.
func setup(
	entries: Array, where: Vector2, area: Vector2, active: String, guard_msec: int
) -> void:
	_entries = entries
	_active = active
	_sync_active_index()
	_area = area
	_hover = -1
	_pressed_slot = -1
	_pointer_down = false
	_layout_ring()
	_place(where)
	_armed_msec = Time.get_ticks_msec() + guard_msec
	visible = true
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_inside_tree():
		_area = size
		_layout_ring()
		_place(center)
		queue_redraw()


## Ring radius that keeps the circles apart without making the dial larger than
## the window can hold. Eight tools land on a ring of about 180 px across, which
## is the size of a thumb roll rather than of a menu.
func _layout_ring() -> void:
	var count := maxi(_entries.size(), 1)
	var needed := float(count) * (SLOT_RADIUS * 2.0 + SLOT_GAP) / TAU
	var smallest := HUB_RADIUS + SLOT_RADIUS + SLOT_GAP
	var room := minf(_area.x, _area.y) * 0.5 - SLOT_RADIUS - EDGE_MARGIN
	ring_radius = maxf(needed, smallest)
	ring_radius = minf(ring_radius, maxf(room, smallest))


## Keeps the whole ring inside the window, however close to an edge the tap was.
## A window too small for the ring simply centres it.
func _place(where: Vector2) -> void:
	var reach := ring_radius + SLOT_RADIUS + EDGE_MARGIN
	if _area.x < reach * 2.0 or _area.y < reach * 2.0:
		center = _area * 0.5
		return
	center = Vector2(
		clampf(where.x, reach, _area.x - reach), clampf(where.y, reach, _area.y - reach)
	)


## Finds the entry the ring is turned around.
func _sync_active_index() -> void:
	_active_index = 0
	for index in _entries.size():
		if str(_entries[index].get("tool", "")) == _active:
			_active_index = index
			return


## The tool in use sits on the right, the rest run clockwise from it, so the ring
## is read the way a clock is and the current tool is always where the thumb
## expects it.
func _slot_center(index: int) -> Vector2:
	var count := maxi(_entries.size(), 1)
	var angle := TAU * float(index - _active_index) / float(count)
	return center + Vector2(cos(angle), sin(angle)) * ring_radius


## Circle under [param point], or -1. A point between two circles picks nothing,
## which is what keeps a slightly off tap from choosing a tool.
func _slot_at(point: Vector2) -> int:
	for index in _entries.size():
		if point.distance_to(_slot_center(index)) <= SLOT_RADIUS:
			return index
	return -1


func _inside(point: Vector2) -> bool:
	return point.distance_to(center) <= ring_radius + SLOT_RADIUS + OUTSIDE_SLACK


func _draw() -> void:
	# The backdrop makes «tap anywhere else closes it» visible and keeps the tools
	# from drawing under the dial.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.42))
	var plate := ring_radius + SLOT_RADIUS + 6.0
	draw_circle(center, plate, Color(0.10, 0.11, 0.14, 0.94))
	draw_arc(center, plate, 0.0, TAU, 72, Color(0.34, 0.39, 0.48, 0.9), 1.5, true)
	var font: Font = get_theme_font("font", "Label")
	if font == null:
		font = ThemeDB.fallback_font
	for index in _entries.size():
		var slot_center := _slot_center(index)
		var current := str(_entries[index].get("tool", "")) == _active
		var fill := Color(0.17, 0.19, 0.23, 0.98)
		if current:
			fill = Color(0.23, 0.40, 0.60, 1.0)
		if index == _hover:
			fill = fill.lightened(0.18)
		draw_circle(slot_center, SLOT_RADIUS, fill)
		var rim := Color(0.42, 0.46, 0.55, 0.9)
		if current:
			rim = Color(0.55, 0.78, 1.0, 1.0)
		if index == _hover:
			rim = Color(0.88, 0.94, 1.0, 1.0)
		draw_arc(slot_center, SLOT_RADIUS, 0.0, TAU, 48, rim, 1.5, true)
		var texture: Texture2D = _entries[index].get("texture", null)
		if texture != null:
			var half := ICON_SIZE * 0.5
			draw_texture_rect(
				texture,
				Rect2(slot_center - Vector2(half, half), Vector2(ICON_SIZE, ICON_SIZE)),
				false
			)
		else:
			_draw_centered(font, slot_center, str(_entries[index].get("label", "")))
	draw_circle(center, HUB_RADIUS, Color(0.20, 0.21, 0.25, 0.98))
	draw_arc(center, HUB_RADIUS, 0.0, TAU, 40, Color(0.5, 0.54, 0.62, 0.9), 1.5, true)
	_draw_centered(font, center, "关", Color(1.0, 0.86, 0.86, 0.95))


func _draw_centered(
	font: Font, at: Vector2, text: String, color := Color(1.0, 1.0, 1.0, 0.96)
) -> void:
	if text.is_empty():
		return
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE).x
	var baseline := (
		at.y + (font.get_ascent(LABEL_FONT_SIZE) - font.get_descent(LABEL_FONT_SIZE)) * 0.5
	)
	draw_string(
		font,
		Vector2(at.x - width * 0.5, baseline),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		LABEL_FONT_SIZE,
		color
	)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var button := event as InputEventMouseButton
		if button.pressed:
			_press(button.position)
		else:
			_release(button.position)
		accept_event()
		return
	if event is InputEventMouseMotion:
		_move((event as InputEventMouseMotion).position)
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		dismissed.emit()
		accept_event()


## Raw touch, for the same reason the canvas reads it: the control under the
## finger is not always the one that receives the event.
func _input(event: InputEvent) -> void:
	if not visible or not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		var touch := make_input_local(event) as InputEventScreenTouch
		if touch.pressed:
			_press(touch.position, touch.index)
		else:
			_release(touch.position, touch.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var drag := make_input_local(event) as InputEventScreenDrag
		if _touch_index == -1 or drag.index == _touch_index:
			_move(drag.position)
		get_viewport().set_input_as_handled()


## A press is only remembered once the guard has elapsed: the finger that opened
## the dial is still in the air, and it must not pick a tool on its way up or
## close the dial by landing on the backdrop.
func _press(point: Vector2, index := -1) -> void:
	if _pointer_down or Time.get_ticks_msec() < _armed_msec:
		return
	_pointer_down = true
	_touch_index = index
	_press_point = point
	_pressed_slot = _slot_at(point)
	_hover = _pressed_slot
	queue_redraw()


func _move(point: Vector2) -> void:
	if not _pointer_down:
		return
	var slot := _slot_at(point)
	if slot != _hover:
		_hover = slot
		queue_redraw()


## The tool is taken on release, and only when the finger let go over the same
## circle it went down on, or was dragged onto one from inside the dial. A
## release outside closes the dial; a release between two circles does nothing,
## so a near miss neither picks nor closes.
func _release(point: Vector2, index := -1) -> void:
	if not _pointer_down:
		return
	# A finger that did not open the dial cannot pick from it or close it.
	if index != -1 and _touch_index != -1 and index != _touch_index:
		return
	_pointer_down = false
	_touch_index = -1
	var slot := _slot_at(point)
	var started_inside := _inside(_press_point)
	_hover = -1
	queue_redraw()
	if slot >= 0 and (slot == _pressed_slot or started_inside):
		picked.emit(str(_entries[slot].get("tool", "")))
		return
	if started_inside and point.distance_to(center) <= HUB_RADIUS:
		dismissed.emit()
		return
	if not _inside(point):
		dismissed.emit()
