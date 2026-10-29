extends Control
## Small drawing window for a canvas node. It is the size of the canvas instead
## of the whole editor, and it only offers what a material needs: a pencil, an
## eraser, a fill and two shapes, all in white. The palette belongs to the main
## drawing view, not here. The same tools can also be picked from a dial that two
## quick taps open on the board, which is what a thumb needs while drawing.

signal finished
## The canvas got a different size, so the window around it has to be re-fitted.
signal size_changed

const TOOLS := ["铅笔", "橡皮", "填充", "方形", "圆形"]
const TOUCH_SIZE := 40
## Snapshots kept for the undo button inside the window.
const UNDO_LIMIT := 24
## Side limits of the canvas, in pixels. The low end is what a single leaf or a
## stone needs, the high end a whole texture.
const SIZE_MIN := 1
const SIZE_MAX := 512
## Shortest a size slider may get. Two of them share one row with their arrows,
## so the track still has to be wide enough to aim a value on a phone.
const SIZE_SLIDER_MIN_WIDTH := 60.0
## Most tools the dial may hold. Five fill one ring with room to spare; past
## eight the circles would shrink below a fingertip and the ring stops reading as
## one dial.
const DIAL_MAX_SLOTS := 8
## Presses this soon after the dial opens are ignored. The finger that opened it
## is still on its way up, and it must not pick whatever happens to lie under it.
const DIAL_GUARD_MSEC := 180

var _board: Board
var _undo: Array[Image] = []
var _dirty := false
var _brush_slider: HSlider
var _brush_value: Label
var _status: Label
var _size_x: HSlider
var _size_y: HSlider
var _size_x_readout: Label
var _size_y_readout: Label
## Picture handed over before the window was ready. A popup only readies its
## children some time after the page adds them, so the painting is parked here
## and shown as soon as the board exists, instead of being dropped.
var _pending_image: Image
## Toolbar buttons, in the same order as [constant TOOLS], so a tool picked from
## the dial can light up the button that owns it.
var _tool_buttons: Array[Button] = []
## Dirty flag saved with every undo step. Undoing a stroke has to put back the
## state the window had before it, and a tap that was cancelled by opening the
## dial must not leave the window looking modified.
var _undo_dirty: Array[bool] = []
var _dial: Dial
var _dial_config: PopupPanel
## Tools offered by the dial. It is static because the choice belongs to the
## user, not to one opening of the window.
static var _dial_tools: Array[int] = [0, 1, 2, 3, 4]


func _ready() -> void:
	# The two size sliders take one row each, so the window needs more height
	# before the board is squeezed.
	custom_minimum_size = Vector2(260, 390)
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 8)
	add_child(column)
	var toolbar := HFlowContainer.new()
	toolbar.add_theme_constant_override("h_separation", 6)
	toolbar.add_theme_constant_override("v_separation", 6)
	column.add_child(toolbar)
	# First in the row on purpose: on a phone the toolbar wraps, and the dial must
	# never be the button that scrolled out of sight.
	toolbar.add_child(_make_button("◎ 拨盘", _open_dial_at_center, "在画布中间打开工具拨盘"))
	# `toggled` is used instead of `pressed`, because a group button that is
	# already selected does not emit `pressed`, and the tool must follow what the
	# button shows.
	var group := ButtonGroup.new()
	for index in TOOLS.size():
		var tool_index := index
		var button := _make_button(TOOLS[index], Callable())
		button.toggle_mode = true
		button.button_group = group
		button.toggled.connect(
			func(on: bool) -> void:
				if not on or not is_instance_valid(_board):
					return
				_board.tool = tool_index
				_update_status()
		)
		button.button_pressed = tool_index == 0
		toolbar.add_child(button)
		_tool_buttons.append(button)
	toolbar.add_child(_make_button("撤销", _undo_last))
	# One press empties the canvas, which is what drawing the next element in the
	# same window needs. It goes through the undo stack like a stroke.
	toolbar.add_child(_make_button("清空", _clear_canvas, "把整张画布擦成透明，可撤销"))
	toolbar.add_child(
		_make_button("拨盘设置…", _open_dial_config, "选择双击画布时拨盘上给出哪些工具")
	)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 13)
	# The line names the canvas size, so it has to be readable in a narrow
	# window on a phone: wrapping keeps the numbers instead of cutting them off.
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	column.add_child(_build_size_row())
	_board = Board.new()
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_board.custom_minimum_size = Vector2(120, 120)
	_board.stroke_started.connect(_remember)
	_board.stroke_finished.connect(
		func() -> void:
			_dirty = true
			_update_status()
	)
	# Two quick taps on the board ask for the tool dial instead of painting.
	_board.dial_requested.connect(_on_dial_requested)
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
		+ "「清空」把整张画布擦成透明；「改尺寸」只改边框，"
		+ "已经画好的像素留在原处、保持原来的大小，不会被拉伸，"
		+ "所以小画布上画的元素放进大画布的散布里还是那么大。"
		+ "双击画布打开工具拨盘：按在某个圆上再松手选工具，"
		+ "点空白处或中间的圆关闭；「拨盘…」决定哪些工具上盘。"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	column.add_child(hint)
	column.add_child(_make_button("完成", func() -> void: finished.emit()))
	# A window that goes away must not leave the board ignoring touches.
	visibility_changed.connect(
		func() -> void:
			if not visible:
				_close_dial()
	)
	if _pending_image != null:
		var pending := _pending_image
		_pending_image = null
		_show_image(pending)


## Canvas width and height as sliders, plus the button that applies them. The
## size is what the drawn element is worth in pixels, so it is set here and not
## by the window. Nothing here has to be typed: the track is dragged and the
## arrows move it by exactly one pixel, which works the same with a mouse and
## with a finger.
func _build_size_row() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 6)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = "画布"
	label.add_theme_font_size_override("font_size", 15)
	header.add_child(label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	header.add_child(
		_make_button(
			"改尺寸",
			_apply_resize,
			"只改画布边框：已画的像素留在原处、保持原大小，不会被放大或拉伸",
			Vector2(0, TOUCH_SIZE)
		)
	)
	block.add_child(header)
	_size_x = _make_size_slider()
	_size_x_readout = _make_size_readout(_size_x)
	block.add_child(_make_size_row("宽", _size_x, _size_x_readout))
	_size_y = _make_size_slider()
	_size_y_readout = _make_size_readout(_size_y)
	block.add_child(_make_size_row("高", _size_y, _size_y_readout))
	return block


func _make_size_slider() -> HSlider:
	var slider := HSlider.new()
	slider.min_value = SIZE_MIN
	slider.max_value = SIZE_MAX
	slider.step = 1
	slider.value = 64
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(SIZE_SLIDER_MIN_WIDTH, TOUCH_SIZE)
	return slider


## Title, one-pixel arrows and the track of a single dimension. The arrows are
## there because the track alone cannot land on an exact number on a phone.
func _make_size_row(title: String, slider: HSlider, readout: Label) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(20, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 15)
	row.add_child(label)
	row.add_child(
		_make_button(
			"−", func() -> void: _step_size(slider, -1.0), "减一像素", Vector2(34, TOUCH_SIZE)
		)
	)
	row.add_child(slider)
	row.add_child(
		_make_button(
			"+", func() -> void: _step_size(slider, 1.0), "加一像素", Vector2(34, TOUCH_SIZE)
		)
	)
	row.add_child(readout)
	return row


## Number next to a size slider. It is a plain label instead of a field, so the
## value can only come from the slider and the arrows, never from typing.
func _make_size_readout(slider: HSlider) -> Label:
	var readout := Label.new()
	readout.custom_minimum_size = Vector2(34, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	readout.add_theme_font_size_override("font_size", 15)
	readout.text = str(clampi(int(roundf(slider.value)), SIZE_MIN, SIZE_MAX))
	slider.value_changed.connect(_on_size_slider_changed.bind(readout))
	return readout


## Fills the window with the image of the layer being painted. The window may be
## handed the picture before its children are ready, so it is kept until then.
func setup(image: Image) -> void:
	_undo.clear()
	_undo_dirty.clear()
	_dirty = false
	_close_dial()
	if not is_instance_valid(_board):
		_pending_image = image
		return
	_show_image(image)


## Puts a picture on the board and syncs everything that describes it: the size
## sliders, their readouts and the status line.
func _show_image(image: Image) -> void:
	_board.set_image(image)
	_sync_size_fields()
	_update_status()


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
	_undo_dirty.append(_dirty)
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	if _undo_dirty.size() > UNDO_LIMIT:
		_undo_dirty.pop_front()


func _undo_last() -> void:
	if _undo.is_empty() or not is_instance_valid(_board):
		return
	var before := image_size()
	var snapshot: Image = _undo.pop_back()
	_board.set_image(snapshot)
	# The state before the step comes back with the picture, so undoing the only
	# stroke of a session leaves the window unmodified again.
	_dirty = bool(_undo_dirty.pop_back()) if not _undo_dirty.is_empty() else true
	_sync_size_fields()
	_update_status()
	# Undoing a change of the canvas size has to resize the window as well.
	if image_size() != before:
		size_changed.emit()


## Takes back the stroke the first tap of a double tap left behind, so opening the
## dial never costs a pixel. It is the same step 撤销 would remove.
func _drop_last_stroke() -> void:
	if _undo.is_empty() or not is_instance_valid(_board):
		return
	var before := image_size()
	var snapshot: Image = _undo.pop_back()
	_board.set_image(snapshot)
	_board.last_stroke_was_tap = false
	_dirty = bool(_undo_dirty.pop_back()) if not _undo_dirty.is_empty() else false
	_sync_size_fields()
	_update_status()
	if image_size() != before:
		size_changed.emit()


## Empties the whole canvas. The step is remembered, so 撤销 brings the picture
## back, and a second element can be drawn on the same canvas afterwards.
func _clear_canvas() -> void:
	if not is_instance_valid(_board) or _board.image == null:
		return
	_remember()
	_board.image.fill(Color(0.0, 0.0, 0.0, 0.0))
	_dirty = true
	_board.queue_redraw()
	_update_status()


## Changes the size of the canvas and keeps every pixel exactly where it is: the
## old picture is copied into the top-left corner of the new one and is never
## scaled, so a small element keeps its own number of pixels inside a larger
## canvas. A smaller canvas simply crops the part that no longer fits. A window
## that opened without a picture is filled with transparent pixels instead of
## ignoring the button, so the status line can never stay on a size that was not
## applied.
func _apply_resize() -> void:
	if not is_instance_valid(_board):
		return
	var old: Image = _board.image
	var target := _canvas_target()
	if old != null and target == Vector2i(old.get_width(), old.get_height()):
		# Nothing to change, but the status still has to describe the canvas.
		_update_status()
		return
	if old != null:
		_remember()
	var next := Image.create_empty(target.x, target.y, false, Image.FORMAT_RGBA8)
	next.fill(Color(0.0, 0.0, 0.0, 0.0))
	if old != null:
		next.blit_rect(
			old,
			Rect2i(0, 0, mini(old.get_width(), target.x), mini(old.get_height(), target.y)),
			Vector2i.ZERO
		)
	_board.set_image(next)
	_dirty = true
	_sync_size_fields()
	_update_status()
	size_changed.emit()


## Size the two sliders ask for, always inside the limits and never empty.
func _canvas_target() -> Vector2i:
	var width := 1
	var height := 1
	if is_instance_valid(_size_x):
		width = clampi(int(roundf(_size_x.value)), SIZE_MIN, SIZE_MAX)
	if is_instance_valid(_size_y):
		height = clampi(int(roundf(_size_y.value)), SIZE_MIN, SIZE_MAX)
	return Vector2i(width, height)


## Shows the real canvas size on the sliders, so they never disagree with the
## board after setup, a resize or an undone resize. The readouts are updated by
## hand because setting a slider without a signal skips the value_changed hook.
func _sync_size_fields() -> void:
	var size := image_size()
	if size.x <= 0 or size.y <= 0:
		return
	if is_instance_valid(_size_x):
		_size_x.set_value_no_signal(float(size.x))
	if is_instance_valid(_size_y):
		_size_y.set_value_no_signal(float(size.y))
	_sync_size_readouts()


## Numeric readout of both sliders, always the rounded integer they stand for.
func _sync_size_readouts() -> void:
	if is_instance_valid(_size_x) and is_instance_valid(_size_x_readout):
		_size_x_readout.text = str(clampi(int(roundf(_size_x.value)), SIZE_MIN, SIZE_MAX))
	if is_instance_valid(_size_y) and is_instance_valid(_size_y_readout):
		_size_y_readout.text = str(clampi(int(roundf(_size_y.value)), SIZE_MIN, SIZE_MAX))


func _make_button(
	text: String, callback: Callable, tooltip := "", min_size := Vector2(0, TOUCH_SIZE)
) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.custom_minimum_size = min_size
	button.add_theme_font_size_override("font_size", 15)
	if callback.is_valid():
		button.pressed.connect(callback)
	return button


## Brush size in pixels, shared by the pencil and the eraser.
func _on_brush_size_changed(value: float) -> void:
	var size := clampi(int(roundf(value)), 1, 16)
	if is_instance_valid(_board):
		_board.brush_size = size
	if is_instance_valid(_brush_value):
		_brush_value.text = str(size)
	_update_status()


## Shows the active tool, the brush and how many pixels are already painted, so
## what is on screen can be compared with what is in the image. The size shown is
## the one the picture really has; when the sliders ask for another one, that
## target is written next to it instead of being taken for the canvas.
func _update_status() -> void:
	if not is_instance_valid(_status) or not is_instance_valid(_board):
		return
	var size := _board.image_size()
	var pending := ""
	if (
		size.x > 0
		and size.y > 0
		and is_instance_valid(_size_x)
		and is_instance_valid(_size_y)
	):
		var target := _canvas_target()
		if target != size:
			pending = "（待改 %d×%d）" % [target.x, target.y]
	_status.text = "工具：%s · 笔刷 %d px · 画布 %d×%d%s · 已画 %d px" % [
		TOOLS[clampi(_board.tool, 0, TOOLS.size() - 1)],
		_board.brush_size,
		size.x,
		size.y,
		pending,
		_board.painted_count(),
	]


## A double tap on the board asks for the tool dial. The first tap of the gesture
## already put a dot down, so that step is taken back: opening the dial never
## costs a pixel.
func _on_dial_requested(_position: Vector2) -> void:
	if not is_instance_valid(_board):
		return
	if _board.last_stroke_was_tap:
		_drop_last_stroke()
	# A stroke without its release would otherwise keep the board busy and eat the
	# next tap, which on a touch screen is the usual way the dial stops opening.
	_board._cancel_stroke()
	_open_dial(_position)


## Shows the dial at the tap, or moves it there when it is already built. The
## board stops listening to the raw touch stream while it is up, because that
## stream reaches it even through a control drawn on top.
func _open_dial(where: Vector2) -> void:
	if not is_instance_valid(_board):
		return
	if not is_instance_valid(_dial):
		_dial = Dial.new()
		_dial.picked.connect(_on_dial_picked)
		_dial.dismissed.connect(_close_dial)
		add_child(_dial)
		# Full rect of the window, so the backdrop covers the toolbar and a tap
		# outside the ring is caught here instead of reaching a button.
		_dial.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dial.setup(_dial_entries(), _dial_point(where), size, _board.tool, DIAL_GUARD_MSEC)
	_dial.visible = true
	_dial.queue_redraw()
	_dial.grab_focus()
	_board.set_process_input(false)


## Opens the dial from the toolbar, for the times a gesture is awkward: a mouse
## whose double click speed is very slow, or a screen being drawn on with a pen.
func _open_dial_at_center() -> void:
	if not is_instance_valid(_board):
		return
	_open_dial(_board.size * 0.5)


func _close_dial() -> void:
	if is_instance_valid(_dial) and _dial.visible:
		_dial.visible = false
	if is_instance_valid(_board):
		_board.set_process_input(true)


## Board coordinates to dial coordinates. The two controls sit at different depths
## in the window, so the point is brought through the viewport instead of being
## added with an offset that would drift when the window is resized.
func _dial_point(where: Vector2) -> Vector2:
	if not is_instance_valid(_dial) or not is_instance_valid(_board):
		return where
	var screen_point := _board.get_global_transform() * where
	return _dial.get_global_transform().affine_inverse() * screen_point


func _on_dial_picked(tool_index: int) -> void:
	_set_tool(tool_index)
	_close_dial()


## Switches the tool and lights up the toolbar button that owns it, so the dial
## and the toolbar can never disagree about what is selected.
func _set_tool(index: int) -> void:
	if not is_instance_valid(_board):
		return
	var tool_index := clampi(index, 0, TOOLS.size() - 1)
	if tool_index < _tool_buttons.size() and is_instance_valid(_tool_buttons[tool_index]):
		# The button owns the tool through its `toggled` signal.
		_tool_buttons[tool_index].button_pressed = true
		return
	_board.tool = tool_index
	_update_status()


## The tools the dial shows, as it stores them: the index the board understands
## plus the label drawn in the circle.
func _dial_entries() -> Array:
	var entries: Array = []
	for index in _dial_tools:
		var tool_index := clampi(int(index), 0, TOOLS.size() - 1)
		var seen := false
		for entry: Dictionary in entries:
			if int(entry["index"]) == tool_index:
				seen = true
				break
		if seen:
			continue
		entries.append({"index": tool_index, "label": TOOLS[tool_index]})
	return entries


## Pushes a changed tool list into a dial that is already on screen.
func _apply_dial_tools() -> void:
	if is_instance_valid(_dial) and _dial.visible:
		_dial.set_entries(_dial_entries(), _board.tool if is_instance_valid(_board) else 0)


## Checklist of the tools that go on the dial. It is rebuilt every time it opens,
## so the ticks always describe what the dial is showing now.
func _open_dial_config() -> void:
	if is_instance_valid(_dial_config):
		_dial_config.queue_free()
		_dial_config = null
	var popup := PopupPanel.new()
	_dial_config = popup
	add_child(popup)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	popup.add_child(box)
	var title := Label.new()
	title.text = "拨盘上的工具"
	title.add_theme_font_size_override("font_size", 15)
	box.add_child(title)
	var hint := Label.new()
	hint.text = (
		"双击画布打开拨盘，按在圆上再松手选工具；点空白处或中间的圆关闭。"
		+ "最多 %d 个，至少要留一个。改动只影响拨盘，工具栏上的按钮一直都在。"
		% DIAL_MAX_SLOTS
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	hint.custom_minimum_size = Vector2(240, 0)
	box.add_child(hint)
	var boxes: Array[CheckBox] = []
	for index in TOOLS.size():
		var check := CheckBox.new()
		check.text = TOOLS[index]
		check.custom_minimum_size = Vector2(0, TOUCH_SIZE)
		check.button_pressed = _dial_tools.has(index)
		boxes.append(check)
		box.add_child(check)
	for index in boxes.size():
		var check := boxes[index]
		check.toggled.connect(
			func(on: bool) -> void:
				var picked: Array[int] = []
				for other in boxes.size():
					if boxes[other].button_pressed:
						picked.append(other)
				if picked.is_empty():
					# The dial needs at least one tool: put the last tick back.
					check.button_pressed = true
					return
				if not on or picked.size() > DIAL_MAX_SLOTS:
					check.button_pressed = not on
					if picked.size() > DIAL_MAX_SLOTS:
						Global.notification_label("拨盘最多放 %d 个工具" % DIAL_MAX_SLOTS)
					return
				_dial_tools = picked
				_apply_dial_tools()
		)
	box.add_child(_make_button("完成", func() -> void: popup.hide()))
	popup.popup_centered()


## One arrow press moves the brush size by exactly one pixel.
func _step_brush(direction: float) -> void:
	if not is_instance_valid(_brush_slider):
		return
	var step := maxf(_brush_slider.step, 0.0001)
	var next := snappedf(_brush_slider.value + step * direction, step)
	_brush_slider.value = clampf(next, _brush_slider.min_value, _brush_slider.max_value)


## One arrow press moves a canvas size slider by exactly one pixel.
func _step_size(slider: HSlider, direction: float) -> void:
	if not is_instance_valid(slider):
		return
	var step := maxf(slider.step, 0.0001)
	var next := snappedf(slider.value + step * direction, step)
	slider.value = clampf(next, slider.min_value, slider.max_value)


## Keeps the number next to a size slider in step with its track. The canvas
## itself only changes when 改尺寸 is pressed, which the status line says as well.
func _on_size_slider_changed(value: float, readout: Label) -> void:
	if is_instance_valid(readout):
		readout.text = str(clampi(int(roundf(value)), SIZE_MIN, SIZE_MAX))
	_update_status()


## Drawing surface. It keeps the pixel image, scales it up with whole pixels so
## the art stays sharp, and turns pointer positions back into pixels.
class Board extends Control:
	signal stroke_started
	signal stroke_finished
	## Two quick taps, close together, are one gesture: a request for the dial.
	## The position is in board coordinates, where the finger landed.
	signal dial_requested(position: Vector2)

	## A second tap is only part of the same gesture when it lands this close in
	## time and space. A finger on a phone is much less precise than a mouse, so
	## both numbers are generous: half a second and about a fingertip apart still
	## counts, anything slower or farther away draws as usual. A mouse does not
	## need the timer at all: the engine flags a real double click, and that flag
	## follows the double click speed set in the system.
	const DIAL_TAP_MSEC := 600
	const DIAL_TAP_DISTANCE := 28.0
	## A touch press and the mouse press emulated from it arrive as two events for
	## one finger. Anything this close is treated as the same press, not a pair.
	const DIAL_SAME_PRESS_MSEC := 60

	## 0 pencil, 1 eraser, 2 fill, 3 rectangle, 4 circle.
	var tool := 0
	## Side of the square brush the pencil and the eraser stamp, in pixels.
	var brush_size := 1
	var image: Image
	## True when the last stroke left a mark without moving, which is exactly what
	## the first tap of a double tap is. The editor takes that mark back when the
	## dial opens, so the gesture never costs a pixel.
	var last_stroke_was_tap := false

	var _scale := 1.0
	var _origin := Vector2.ZERO
	var _pressed := false
	var _last := Vector2i(-1, -1)
	var _start := Vector2i.ZERO
	var _end := Vector2i.ZERO
	var _shaping := false
	var _tap_msec := -10000
	var _tap_position := Vector2.ZERO
	var _stroke_moved := false
	## Swallows the taps that follow a gesture, so the mouse event emulated from a
	## touch cannot open the dial a second time.
	var _dial_cooldown_msec := 0

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
		if image != null and image.get_format() != Image.FORMAT_RGBA8:
			image.convert(Image.FORMAT_RGBA8)
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
		if image == null:
			return
		var rect := _image_rect()
		# The pixels are drawn straight from the image, one run of equal pixels at
		# a time. That keeps them exactly as painted: no texture filtering, no alpha
		# surprises, and a one pixel mark stays one square.
		draw_rect(rect, Color(0.12, 0.13, 0.16))
		for y in image.get_height():
			var x := 0
			while x < image.get_width():
				var color := image.get_pixel(x, y)
				if color.a <= 0.0:
					x += 1
					continue
				var run_start := x
				x += 1
				while x < image.get_width():
					var neighbour := image.get_pixel(x, y)
					if neighbour.a <= 0.0 or not neighbour.is_equal_approx(color):
						break
					x += 1
				draw_rect(
					Rect2(
						rect.position + Vector2(run_start, y) * _scale,
						Vector2(x - run_start, 1) * _scale
					),
					color
				)
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
				# The gesture check runs before anything is painted, so the second
				# tap of a double tap never leaves a mark of its own.
				if _begins_dial_gesture(event.position, event.double_click):
					accept_event()
					return
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
			return
		# Some platforms hand a finger to the control under it instead of the raw
		# touch stream. Painting is already handled there, so only the gesture is
		# read here; the timer makes the two paths agree on what one tap is.
		if event is InputEventScreenTouch:
			var touch := event as InputEventScreenTouch
			if touch.pressed and _begins_dial_gesture(touch.position):
				accept_event()
			return


	## Touch does not always arrive as emulated mouse events inside a popup, so
	## the raw touch stream is handled here as well. The checks make the two paths
	## work together: a stroke that a mouse press started is not started twice.
	func _input(event: InputEvent) -> void:
		if image == null or not is_visible_in_tree():
			return
		if event is InputEventScreenTouch:
			var touch := make_input_local(event) as InputEventScreenTouch
			if touch.pressed:
				# The gesture is read before anything else, even while a stroke is
				# still open: a finger that left the window can leave one behind,
				# and then every later tap would be swallowed and the dial would
				# never open again.
				if _begins_dial_gesture(touch.position):
					return
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


	## Records every press and reports true when this one completes a double tap.
	## A drag clears the record, so a stroke that happens to end where it started
	## can never arm a second tap, and the short cooldown stops the mouse event
	## emulated from a touch from opening the dial twice. [param double_click] is
	## the engine's own verdict for a mouse, which honours the system setting
	## instead of a timer this script invented.
	func _begins_dial_gesture(position: Vector2, double_click := false) -> bool:
		var now := Time.get_ticks_msec()
		if now < _dial_cooldown_msec:
			return false
		# One finger can arrive twice: once as a touch and once as the mouse press
		# emulated from it. That is one press, not the second half of a pair.
		var same_press := (
			now - _tap_msec < DIAL_SAME_PRESS_MSEC
			and position.distance_to(_tap_position) <= 2.0
		)
		if same_press and not double_click:
			return false
		var double_tap := (
			double_click
			or (
				now - _tap_msec <= DIAL_TAP_MSEC
				and position.distance_to(_tap_position) <= DIAL_TAP_DISTANCE
			)
		)
		_tap_position = position
		if double_tap:
			# A new pair starts right away: a third tap must not reopen the dial.
			_tap_msec = -10000
			_dial_cooldown_msec = now + DIAL_TAP_MSEC
			dial_requested.emit(position)
			return true
		_tap_msec = now
		return false


	func _begin_stroke(pixel: Vector2i) -> void:
		stroke_started.emit()
		_stroke_moved = false
		if tool == 2:
			_flood_fill(pixel)
			_refresh()
			last_stroke_was_tap = true
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
		_stroke_moved = true
		# A drag is a stroke, never the first half of a double tap.
		_tap_msec = -10000
		if _shaping:
			_end = pixel
			queue_redraw()
			return
		_paint_line(_last, pixel)
		_last = pixel
		_refresh()


	## Drops a stroke that never got its release, which a finger leaving the
	## window can cause. The dial takes this path when it opens on that finger.
	func _cancel_stroke() -> void:
		_pressed = false
		_shaping = false
		last_stroke_was_tap = false
		queue_redraw()


	func _end_stroke() -> void:
		if not _pressed:
			return
		if _shaping:
			_rasterise_shape()
			_shaping = false
		_pressed = false
		last_stroke_was_tap = not _stroke_moved
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


	func image_size() -> Vector2i:
		if image == null:
			return Vector2i.ZERO
		return Vector2i(image.get_width(), image.get_height())


	## Number of pixels that already carry a value, used by the status line.
	func painted_count() -> int:
		if image == null:
			return 0
		var total := 0
		for y in image.get_height():
			for x in image.get_width():
				if image.get_pixel(x, y).a > 0.0:
					total += 1
		return total


	func _refresh() -> void:
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


## The tool dial. It draws its own circles instead of building buttons: the ring
## has to keep one shape whatever the window size, and a tool has to be chosen by
## pressing and releasing on the same circle, not by brushing past one.
class Dial extends Control:
	signal picked(tool_index: int)
	signal dismissed

	## Radius of one tool circle. A fingertip needs about 20 px and the label has
	## to fit inside, so anything below 22 makes the ring unreadable.
	const SLOT_RADIUS := 24.0
	## The middle circle, which closes the dial.
	const HUB_RADIUS := 20.0
	## Empty space between two neighbouring circles, so a near miss picks nothing.
	const SLOT_GAP := 8.0
	## Space kept between the outer circles and the window edge.
	const EDGE_MARGIN := 8.0
	## A release this far outside the plate closes the dial. Inside this band it
	## does nothing, which stops a near miss from closing it by accident.
	const OUTSIDE_SLACK := 10.0
	const FONT_SIZE := 13

	var center := Vector2.ZERO
	var ring_radius := 56.0

	var _entries: Array = []
	var _current := 0
	var _area := Vector2.ZERO
	var _hover := -1
	var _pressed_slot := -1
	var _press_point := Vector2.ZERO
	var _pointer_down := false
	var _armed_msec := 0


	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_ALL
		# Touch does not always reach the control under the finger inside a popup,
		# so the raw stream is read here as well, the way the board does it.
		set_process_input(true)


	func setup(
		entries: Array, where: Vector2, area: Vector2, current: int, guard_msec: int
	) -> void:
		_entries = entries
		_current = current
		_area = area
		_hover = -1
		_pressed_slot = -1
		_pointer_down = false
		_layout_ring()
		_place(where)
		_armed_msec = Time.get_ticks_msec() + guard_msec
		queue_redraw()


	func set_entries(entries: Array, current: int) -> void:
		_entries = entries
		_current = current
		_hover = -1
		_pointer_down = false
		_layout_ring()
		queue_redraw()


	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED and is_inside_tree():
			_area = size
			_layout_ring()
			_place(center)
			queue_redraw()


	## Ring radius that keeps the circles apart without making the dial larger than
	## the window can hold. Five tools land on a ring of about 160 px across, which
	## is the size of a thumb roll rather than of a menu.
	func _layout_ring() -> void:
		var count := maxi(_entries.size(), 1)
		var needed := float(count) * (SLOT_RADIUS * 2.0 + SLOT_GAP) / TAU
		var smallest := HUB_RADIUS + SLOT_RADIUS + SLOT_GAP
		var room := minf(_area.x, _area.y) * 0.5 - SLOT_RADIUS - EDGE_MARGIN
		ring_radius = maxf(needed, smallest)
		ring_radius = minf(ring_radius, maxf(room, smallest))


	## Keeps the whole ring inside the window, however close to an edge the tap
	## was. A window too small for the ring simply centres it.
	func _place(where: Vector2) -> void:
		var reach := ring_radius + SLOT_RADIUS + EDGE_MARGIN
		if _area.x < reach * 2.0 or _area.y < reach * 2.0:
			center = _area * 0.5
			return
		center = Vector2(
			clampf(where.x, reach, _area.x - reach), clampf(where.y, reach, _area.y - reach)
		)


	## The first tool sits at the top, the rest run clockwise, so the ring is read
	## the way a clock is.
	func _slot_center(index: int) -> Vector2:
		var count := maxi(_entries.size(), 1)
		var angle := -PI * 0.5 + TAU * float(index) / float(count)
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
		# The backdrop makes «tap anywhere else closes it» visible and stops a
		# stroke from starting under the dial.
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.45))
		var plate := ring_radius + SLOT_RADIUS + 6.0
		draw_circle(center, plate, Color(0.10, 0.11, 0.14, 0.94))
		draw_arc(center, plate, 0.0, TAU, 72, Color(0.34, 0.39, 0.48, 0.9), 1.5, true)
		var font: Font = get_theme_font("font", "Label")
		if font == null:
			font = ThemeDB.fallback_font
		for index in _entries.size():
			var slot_center := _slot_center(index)
			var current := int(_entries[index].get("index", -1)) == _current
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
			_draw_centered(font, slot_center, str(_entries[index].get("label", "")))
		draw_circle(center, HUB_RADIUS, Color(0.20, 0.21, 0.25, 0.98))
		draw_arc(center, HUB_RADIUS, 0.0, TAU, 40, Color(0.5, 0.54, 0.62, 0.9), 1.5, true)
		_draw_centered(font, center, "关", Color(1.0, 0.86, 0.86, 0.95))


	func _draw_centered(
		font: Font, at: Vector2, text: String, color := Color(1.0, 1.0, 1.0, 0.96)
	) -> void:
		if text.is_empty():
			return
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
		var baseline := at.y + (font.get_ascent(FONT_SIZE) - font.get_descent(FONT_SIZE)) * 0.5
		draw_string(
			font,
			Vector2(at.x - width * 0.5, baseline),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			FONT_SIZE,
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


	## Raw touch, for the same reason the board reads it: inside a popup the
	## control under the finger is not always the one that receives the event.
	func _input(event: InputEvent) -> void:
		if not visible or not is_visible_in_tree():
			return
		if event is InputEventScreenTouch:
			var touch := make_input_local(event) as InputEventScreenTouch
			if touch.pressed:
				_press(touch.position)
			else:
				_release(touch.position)
			# While the dial is up it is the only thing a finger can talk to, so
			# the tap that closes it must not also press a button underneath.
			get_viewport().set_input_as_handled()
		elif event is InputEventScreenDrag:
			_move((make_input_local(event) as InputEventScreenDrag).position)
			get_viewport().set_input_as_handled()


	## A press is only remembered once the guard has elapsed: the finger that
	## opened the dial is still in the air, and it must not pick a tool on its way
	## up or close the dial by landing on the backdrop.
	func _press(point: Vector2) -> void:
		if _pointer_down or Time.get_ticks_msec() < _armed_msec:
			return
		_pointer_down = true
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
	func _release(point: Vector2) -> void:
		if not _pointer_down:
			return
		_pointer_down = false
		var slot := _slot_at(point)
		var started_inside := _inside(_press_point)
		_hover = -1
		queue_redraw()
		if slot >= 0 and (slot == _pressed_slot or started_inside):
			picked.emit(int(_entries[slot].get("index", 0)))
			return
		if started_inside and point.distance_to(center) <= HUB_RADIUS:
			dismissed.emit()
			return
		if not _inside(point):
			dismissed.emit()
