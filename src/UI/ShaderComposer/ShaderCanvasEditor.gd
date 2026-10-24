extends Control
## Small drawing window for a canvas node. It is the size of the canvas instead
## of the whole editor, and it only offers what a material needs: a pencil, an
## eraser, a fill and two shapes, all in white. The palette belongs to the main
## drawing view, not here.

signal finished

const TOOLS := ["铅笔", "橡皮", "填充", "方形", "圆形"]
const TOUCH_SIZE := 40
## Snapshots kept for the undo button inside the window.
const UNDO_LIMIT := 24

var _board: Board
var _undo: Array[Image] = []
var _dirty := false
var _brush_slider: HSlider
var _brush_value: Label


func _ready() -> void:
	custom_minimum_size = Vector2(260, 300)
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 8)
	add_child(column)
	var toolbar := HFlowContainer.new()
	toolbar.add_theme_constant_override("h_separation", 6)
	toolbar.add_theme_constant_override("v_separation", 6)
	column.add_child(toolbar)
	var group := ButtonGroup.new()
	for index in TOOLS.size():
		var tool_index := index
		var button := _make_button(TOOLS[index], func() -> void: _board.tool = tool_index)
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = tool_index == 0
		toolbar.add_child(button)
	toolbar.add_child(_make_button("撤销", _undo_last))
	_board = Board.new()
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_board.custom_minimum_size = Vector2(120, 120)
	_board.stroke_started.connect(_remember)
	_board.stroke_finished.connect(func() -> void: _dirty = true)
	column.add_child(_board)
	# Brush size row: the arrows step by exactly one pixel, the slider covers
	# everything in between.
	var brush_row := HBoxContainer.new()
	brush_row.add_theme_constant_override("separation", 6)
	var brush_label := Label.new()
	brush_label.text = "画笔"
	brush_row.add_child(brush_label)
	brush_row.add_child(
		_make_button("−", func() -> void: _step_brush(-1.0), "减一像素", Vector2(34, TOUCH_SIZE))
	)
	_brush_slider = HSlider.new()
	_brush_slider.min_value = 1
	_brush_slider.max_value = 16
	_brush_slider.step = 1
	_brush_slider.value = 1
	_brush_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_brush_slider.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	_brush_slider.value_changed.connect(_on_brush_size_changed)
	brush_row.add_child(_brush_slider)
	brush_row.add_child(
		_make_button("+", func() -> void: _step_brush(1.0), "加一像素", Vector2(34, TOUCH_SIZE))
	)
	_brush_value = Label.new()
	_brush_value.custom_minimum_size = Vector2(34, 0)
	_brush_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	brush_row.add_child(_brush_value)
	column.add_child(brush_row)
	_on_brush_size_changed(_brush_slider.value)
	var hint := Label.new()
	hint.text = (
		"只用白色绘制，橡皮擦掉透明度；完成后写回这个节点读取的图层。"
		+ "窗口按画布比例打开，深色底是透明区域。"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	column.add_child(hint)
	column.add_child(_make_button("完成", func() -> void: finished.emit()))


## Fills the window with the image of the layer being painted.
func setup(image: Image) -> void:
	if not is_instance_valid(_board):
		return
	_undo.clear()
	_dirty = false
	_board.set_image(image)


func image_size() -> Vector2i:
	if not is_instance_valid(_board) or _board.image == null:
		return Vector2i.ZERO
	return Vector2i(_board.image.get_width(), _board.image.get_height())


func take_result() -> Image:
	if not is_instance_valid(_board):
		return null
	return _board.image


func is_modified() -> bool:
	return _dirty


func _remember() -> void:
	if not is_instance_valid(_board) or _board.image == null:
		return
	_undo.append(_board.image.duplicate())
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()


func _undo_last() -> void:
	if _undo.is_empty() or not is_instance_valid(_board):
		return
	var snapshot: Image = _undo.pop_back()
	_board.set_image(snapshot)
	_dirty = true


func _make_button(
	text: String, callback: Callable, tooltip := "", min_size := Vector2(0, TOUCH_SIZE)
) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.custom_minimum_size = min_size
	button.add_theme_font_size_override("font_size", 15)
	button.pressed.connect(callback)
	return button


## Brush size in pixels, shared by the pencil and the eraser.
func _on_brush_size_changed(value: float) -> void:
	var size := clampi(int(roundf(value)), 1, 16)
	if is_instance_valid(_board):
		_board.brush_size = size
	if is_instance_valid(_brush_value):
		_brush_value.text = str(size)


## One arrow press moves the brush size by exactly one pixel.
func _step_brush(direction: float) -> void:
	if not is_instance_valid(_brush_slider):
		return
	var step := maxf(_brush_slider.step, 0.0001)
	var next := snappedf(_brush_slider.value + step * direction, step)
	_brush_slider.value = clampf(next, _brush_slider.min_value, _brush_slider.max_value)


## Drawing surface. It keeps the pixel image, scales it up with whole pixels so
## the art stays sharp, and turns pointer positions back into pixels.
class Board extends Control:
	signal stroke_started
	signal stroke_finished

	## 0 pencil, 1 eraser, 2 fill, 3 rectangle, 4 circle.
	var tool := 0
	## Side of the square brush the pencil and the eraser stamp, in pixels.
	var brush_size := 1
	var image: Image
	var texture: ImageTexture

	var _scale := 1.0
	var _origin := Vector2.ZERO
	var _pressed := false
	var _last := Vector2i(-1, -1)
	var _start := Vector2i.ZERO
	var _end := Vector2i.ZERO
	var _shaping := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		# Nearest filtering keeps the pixels square instead of smearing them.
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		# The raw touch stream is handled in _input, next to the emulated mouse
		# events, so a finger drag keeps drawing on every platform.
		set_process_input(true)
		resized.connect(_layout)
		_layout()


	func set_image(source: Image) -> void:
		image = source
		if image == null:
			texture = null
			queue_redraw()
			return
		if image.get_format() != Image.FORMAT_RGBA8:
			image.convert(Image.FORMAT_RGBA8)
		texture = ImageTexture.create_from_image(image)
		_layout()
		queue_redraw()


	func _layout() -> void:
		if image == null or size.x <= 1.0 or size.y <= 1.0:
			return
		var fit := minf(size.x / float(image.get_width()), size.y / float(image.get_height()))
		# Whole pixels keep the artwork crisp; very large canvases fall back to a
		# fraction so the whole image still fits.
		_scale = floorf(fit) if fit >= 1.0 else fit
		_scale = maxf(_scale, 0.05)
		var drawn := Vector2(image.get_width(), image.get_height()) * _scale
		_origin = ((size - drawn) * 0.5).floor()


	func _image_rect() -> Rect2:
		if image == null:
			return Rect2()
		return Rect2(_origin, Vector2(image.get_width(), image.get_height()) * _scale)


	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.09, 0.1, 0.12))
		if texture == null:
			return
		var rect := _image_rect()
		draw_texture_rect(texture, rect, false)
		draw_rect(rect, Color(0.4, 0.44, 0.52), false, 1.0)
		if _shaping:
			_draw_preview(rect)


	func _draw_preview(rect: Rect2) -> void:
		var color := Color(1.0, 1.0, 1.0, 0.85)
		var from := rect.position + (Vector2(_start) + Vector2(0.5, 0.5)) * _scale
		var to := rect.position + (Vector2(_end) + Vector2(0.5, 0.5)) * _scale
		if tool == 3:
			var box := Rect2(from, Vector2.ZERO).expand(to)
			draw_rect(box, color, false, 1.0)
			return
		var center := (from + to) * 0.5
		var radius := Vector2(absf(to.x - from.x), absf(to.y - from.y)) * 0.5
		var points := PackedVector2Array()
		for step in 49:
			var angle := TAU * float(step) / 48.0
			points.append(center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y))
		for index in range(points.size() - 1):
			draw_line(points[index], points[index + 1], color, 1.0)


	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var pixel := _to_pixel(event.position)
				if pixel.x < 0:
					return
				_begin_stroke(pixel)
				accept_event()
			elif _pressed:
				_end_stroke()
				accept_event()
			return
		if event is InputEventMouseMotion and _pressed:
			var motion := event as InputEventMouseMotion
			var pixel := _to_pixel(motion.position)
			if pixel.x < 0:
				return
			_continue_stroke(pixel)
			accept_event()


	## Touch does not always arrive as emulated mouse events inside a popup, so
	## the raw touch stream is handled here as well. The checks make the two paths
	## work together: a stroke that a mouse press started is not started twice.
	func _input(event: InputEvent) -> void:
		if image == null or not is_visible_in_tree():
			return
		if event is InputEventScreenTouch:
			var touch := make_input_local(event) as InputEventScreenTouch
			if touch.pressed:
				if _pressed:
					return
				var pixel := _to_pixel(touch.position)
				if pixel.x >= 0:
					_begin_stroke(pixel)
			else:
				_end_stroke()
		elif event is InputEventScreenDrag and _pressed:
			var drag := make_input_local(event) as InputEventScreenDrag
			var pixel := _to_pixel(drag.position)
			if pixel.x >= 0:
				_continue_stroke(pixel)


	func _begin_stroke(pixel: Vector2i) -> void:
		stroke_started.emit()
		if tool == 2:
			_flood_fill(pixel)
			_refresh()
			stroke_finished.emit()
			return
		_pressed = true
		_last = pixel
		_start = pixel
		_end = pixel
		if tool >= 3:
			_shaping = true
			queue_redraw()
			return
		_paint(pixel)
		_refresh()


	func _continue_stroke(pixel: Vector2i) -> void:
		if _shaping:
			_end = pixel
			queue_redraw()
			return
		_paint_line(_last, pixel)
		_last = pixel
		_refresh()


	func _end_stroke() -> void:
		if not _pressed:
			return
		if _shaping:
			_rasterise_shape()
			_shaping = false
		_pressed = false
		_refresh()
		stroke_finished.emit()
		queue_redraw()


	## Pixel under [param position], or (-1, -1) when the position is outside the
	## image. The check uses the drawn rectangle, not the whole control.
	func _to_pixel(position: Vector2) -> Vector2i:
		if image == null or _scale <= 0.0:
			return Vector2i(-1, -1)
		var local := (position - _origin) / _scale
		var pixel := Vector2i(floori(local.x), floori(local.y))
		if (
			pixel.x < 0
			or pixel.y < 0
			or pixel.x >= image.get_width()
			or pixel.y >= image.get_height()
		):
			return Vector2i(-1, -1)
		return pixel


	func _refresh() -> void:
		if image != null:
			# Updating the texture in place avoids allocating one per pointer
			# event, which is what makes a fast stroke on a phone feel chopped.
			if (
				texture == null
				or texture.get_width() != image.get_width()
				or texture.get_height() != image.get_height()
			):
				texture = ImageTexture.create_from_image(image)
			else:
				texture.update(image)
		queue_redraw()


	func _paint(pixel: Vector2i) -> void:
		var white := tool == 0
		var brush := maxi(brush_size, 1)
		var start := Vector2i(-(brush / 2), -(brush / 2))
		for offset_y in brush:
			for offset_x in brush:
				_set_pixel(pixel.x + start.x + offset_x, pixel.y + start.y + offset_y, white)


	func _paint_line(from: Vector2i, to: Vector2i) -> void:
		var delta := to - from
		var steps := maxi(absi(delta.x), absi(delta.y))
		if steps == 0:
			_paint(to)
			return
		for step in steps + 1:
			var ratio := float(step) / float(steps)
			var x := roundi(lerpf(float(from.x), float(to.x), ratio))
			var y := roundi(lerpf(float(from.y), float(to.y), ratio))
			_set_pixel(x, y, tool == 0)


	func _set_pixel(x: int, y: int, white: bool) -> void:
		if image == null:
			return
		if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
			return
		var color := Color(1.0, 1.0, 1.0, 1.0) if white else Color(0.0, 0.0, 0.0, 0.0)
		image.set_pixel(x, y, color)


	## Fills the connected area of the same opacity. Clicking a transparent spot
	## paints white, clicking a painted spot clears it, which works like a fill
	## eraser without adding another tool.
	func _flood_fill(start: Vector2i) -> void:
		if image == null:
			return
		var width := image.get_width()
		var height := image.get_height()
		var fill_white := image.get_pixel(start.x, start.y).a < 0.5
		var seen := {}
		var stack: Array[Vector2i] = [start]
		while not stack.is_empty():
			var point: Vector2i = stack.pop_back()
			if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
				continue
			var key := point.y * width + point.x
			if seen.has(key):
				continue
			seen[key] = true
			var opaque := image.get_pixel(point.x, point.y).a >= 0.5
			if opaque == fill_white:
				continue
			_set_pixel(point.x, point.y, fill_white)
			stack.append(Vector2i(point.x + 1, point.y))
			stack.append(Vector2i(point.x - 1, point.y))
			stack.append(Vector2i(point.x, point.y + 1))
			stack.append(Vector2i(point.x, point.y - 1))


	func _rasterise_shape() -> void:
		if image == null:
			return
		if tool == 3:
			var left := mini(_start.x, _end.x)
			var right := maxi(_start.x, _end.x)
			var top := mini(_start.y, _end.y)
			var bottom := maxi(_start.y, _end.y)
			for x in range(left, right + 1):
				_set_pixel(x, top, true)
				_set_pixel(x, bottom, true)
			for y in range(top, bottom + 1):
				_set_pixel(left, y, true)
				_set_pixel(right, y, true)
			return
		_rasterise_ellipse()


	func _rasterise_ellipse() -> void:
		var left := mini(_start.x, _end.x)
		var right := maxi(_start.x, _end.x)
		var top := mini(_start.y, _end.y)
		var bottom := maxi(_start.y, _end.y)
		var rx := float(right - left) * 0.5
		var ry := float(bottom - top) * 0.5
		if rx < 0.5 or ry < 0.5:
			_set_pixel(left, top, true)
			return
		var center := Vector2(float(left) + rx, float(top) + ry)
		var x := 0.0
		var y := ry
		var dx := 2.0 * ry * ry * x
		var dy := 2.0 * rx * rx * y
		var d1 := ry * ry - rx * rx * ry + 0.25 * rx * rx
		while dx < dy:
			_plot_ellipse(center, x, y)
			x += 1.0
			dx += 2.0 * ry * ry
			if d1 < 0.0:
				d1 += dx + ry * ry
			else:
				y -= 1.0
				dy -= 2.0 * rx * rx
				d1 += dx - dy + ry * ry
		var d2 := (
			ry * ry * (x + 0.5) * (x + 0.5)
			+ rx * rx * (y - 1.0) * (y - 1.0)
			- rx * rx * ry * ry
		)
		while y >= 0.0:
			_plot_ellipse(center, x, y)
			y -= 1.0
			dy -= 2.0 * rx * rx
			if d2 > 0.0:
				d2 += rx * rx - dy
			else:
				x += 1.0
				dx += 2.0 * ry * ry
				d2 += dx - dy + rx * rx


	func _plot_ellipse(center: Vector2, x: float, y: float) -> void:
		_set_pixel(roundi(center.x + x), roundi(center.y + y), true)
		_set_pixel(roundi(center.x - x), roundi(center.y + y), true)
		_set_pixel(roundi(center.x + x), roundi(center.y - y), true)
		_set_pixel(roundi(center.x - x), roundi(center.y - y), true)
