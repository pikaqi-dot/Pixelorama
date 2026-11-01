@tool
extends VBoxContainer
## The picture the Inspector shows for an imported project.
##
## A .pxo imports into a resource with no built-in viewer, so selecting one used
## to show nothing but a read-only property list. This puts the frames and the
## layers of the selected frame on top of that list, with a play button that
## cycles them at the project's own fps.

const THUMB := 96
const CAPTION_HEIGHT := 26

var project: PxoProject

var _info: Label
var _frames_row: HBoxContainer
var _layers_row: HBoxContainer
var _play: Button
var _timer: Timer
var _frame_buttons: Array[Button] = []
var _current := 0


## Called by the inspector plugin once, with the resource being inspected.
func setup(source: PxoProject) -> void:
	project = source
	if is_instance_valid(_timer):
		_timer.queue_free()
	_build()
	_refresh()


func _build() -> void:
	add_theme_constant_override("separation", 6)

	var note := Label.new()
	note.text = "从 .pxo 导入的只读资源：改动请编辑源文件，保存后 Godot 会自动重新导入。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", Color(0.68, 0.72, 0.8))
	add_child(note)

	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.add_theme_font_size_override("font_size", 12)
	add_child(_info)

	var controls := HBoxContainer.new()
	add_child(controls)
	_play = Button.new()
	_play.text = "播放"
	_play.toggle_mode = true
	_play.tooltip_text = "按工程的 fps 轮播各帧"
	_play.toggled.connect(_on_play_toggled)
	controls.add_child(_play)

	_timer = Timer.new()
	_timer.wait_time = 1.0 / max(0.001, project.fps if project != null else 12.0)
	_timer.timeout.connect(_next_frame)
	add_child(_timer)

	_frames_row = _strip("帧")
	_layers_row = _strip("图层（当前帧）")
	_refresh()


## A titled horizontal strip that scrolls on its own.
func _strip(title: String) -> HBoxContainer:
	var heading := Label.new()
	heading.text = title
	heading.add_theme_font_size_override("font_size", 11)
	heading.add_theme_color_override("font_color", Color(0.68, 0.72, 0.8))
	add_child(heading)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, THUMB + CAPTION_HEIGHT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	scroll.add_child(row)
	return row


func _refresh() -> void:
	if project == null:
		return
	_info.text = "画布 %d×%d · %d 帧 · %s fps · %d 层\n%s" % [
		project.canvas_size.x,
		project.canvas_size.y,
		project.frames.size(),
		str(project.fps),
		project.layer_names.size(),
		"、".join(project.layer_names),
	]
	for child in _frames_row.get_children():
		child.queue_free()
	_frame_buttons.clear()
	var index := 0
	for frame: PxoFrame in project.frames:
		var button := _thumb_button(frame.composite if frame != null else null, "%d" % index)
		button.toggle_mode = true
		button.pressed.connect(_show_frame.bind(index))
		_frames_row.add_child(button)
		_frame_buttons.append(button)
		index += 1
	_show_frame(0)


func _show_frame(index: int) -> void:
	if project == null or project.frames.is_empty():
		return
	_current = clampi(index, 0, project.frames.size() - 1)
	for i in _frame_buttons.size():
		if is_instance_valid(_frame_buttons[i]):
			_frame_buttons[i].set_pressed_no_signal(i == _current)
	for child in _layers_row.get_children():
		child.queue_free()
	var frame: PxoFrame = project.frames[_current]
	for layer_index in project.layer_names.size():
		var texture: Texture2D = null
		if frame != null:
			texture = frame.get_layer_image(layer_index)
		_layers_row.add_child(_thumb_button(texture, project.layer_names[layer_index]))


## One thumbnail with a caption under it. A null texture still gets a frame, so
## a layer without pixels (a group, a tilemap) is visible as such instead of
## silently missing.
func _thumb_button(texture: Texture2D, caption: String) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(THUMB + 8, THUMB + CAPTION_HEIGHT)
	button.tooltip_text = caption
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 2)
	button.add_child(column)
	var picture := TextureRect.new()
	picture.texture = texture
	picture.custom_minimum_size = Vector2(THUMB, THUMB)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Pixel art: nearest keeps the grid visible at every zoom.
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(picture)
	var label := Label.new()
	label.text = caption if texture != null else "%s（无像素）" % caption
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(label)
	return button


func _on_play_toggled(pressed: bool) -> void:
	if not is_instance_valid(_timer):
		return
	_play.text = "暂停" if pressed else "播放"
	if pressed:
		_timer.start()
	else:
		_timer.stop()


func _next_frame() -> void:
	if project == null or project.frames.is_empty():
		return
	_show_frame((_current + 1) % project.frames.size())
