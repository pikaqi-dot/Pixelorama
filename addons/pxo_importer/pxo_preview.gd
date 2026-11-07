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

const ExportScript := preload("res://addons/pxo_importer/pxo_export.gd")
const ReaderScript := preload("res://addons/pxo_importer/pxo_reader.gd")

var project: PxoProject

var _note: Label
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

	_note = Label.new()
	_note.text = "从 .pxo 导入的只读资源：改动请编辑源文件，保存后 Godot 会自动重新导入。"
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_font_size_override("font_size", 11)
	_note.add_theme_color_override("font_color", Color(0.68, 0.72, 0.8))
	add_child(_note)

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

	# The two files Godot's own tools can open: the animation editor needs a
	# SpriteFrames, the sprite and tile tools need one image to slice.
	var frames_button := Button.new()
	frames_button.text = "帧资源"
	frames_button.tooltip_text = "生成 SpriteFrames 资源：可在 SpriteFrames 面板里编辑，直接给 AnimatedSprite2D 用"
	frames_button.pressed.connect(_on_export_sprite_frames)
	controls.add_child(frames_button)
	var sheet_button := Button.new()
	sheet_button.text = "精灵表"
	sheet_button.tooltip_text = "把所有帧拼成一张 PNG：Sprite2D 用 hframes/vframes 切片，TileSet 当图集"
	sheet_button.pressed.connect(_on_export_sheet)
	controls.add_child(sheet_button)

	# The tile side only means something for a project that has tilesets, and a
	# greyed-out button says "not this project" better than a file that comes out
	# empty — as long as it also says why, or it reads like a broken button.
	var has_tiles := project != null and project.has_tilesets()
	var tile_set_button := Button.new()
	tile_set_button.text = "图块集"
	tile_set_button.disabled = not has_tiles
	tile_set_button.tooltip_text = (
		"把工程里的图块拼成图集，生成 TileSet 资源（含自动图块地形）"
		if has_tiles
		else _no_tiles_reason()
	)
	tile_set_button.pressed.connect(_on_export_tile_set)
	controls.add_child(tile_set_button)
	var tile_map_button := Button.new()
	tile_map_button.text = "地图"
	tile_map_button.disabled = not has_tiles
	tile_map_button.tooltip_text = (
		"把当前帧的图块层放成 TileMapLayer 场景，格子已经摆好"
		if has_tiles
		else _no_tiles_reason()
	)
	tile_map_button.pressed.connect(_on_export_tile_map)
	controls.add_child(tile_map_button)

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
	_info.text = "画布 %d×%d · %d 帧 · %s fps · %d 层\n%s%s%s" % [
		project.canvas_size.x,
		project.canvas_size.y,
		project.frames.size(),
		str(project.fps),
		project.layer_names.size(),
		"、".join(project.layer_names),
		_tileset_line(),
		_shader_line(),
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


## Writes the SpriteFrames resource next to the `.pxo` and shows it in the
## FileSystem dock, so it can be dragged onto an AnimatedSprite2D or opened in the
## SpriteFrames panel.
func _on_export_sprite_frames() -> void:
	if project == null:
		return
	var path := ExportScript.default_sprite_frames_path(project.source_path)
	var err: Error = ExportScript.export_sprite_frames(project, path)
	_reported(path, err, "双击它就能在 SpriteFrames 面板里编辑")


## Writes the grid image next to the `.pxo`.
func _on_export_sheet() -> void:
	if project == null:
		return
	var path := ExportScript.default_sheet_path(project.source_path)
	var err: Error = ExportScript.export_sheet(project, path)
	_reported(path, err, "Sprite2D 设 hframes=%d、vframes=1 即可切片" % project.frames.size())


## Writes the TileSet resource next to the `.pxo`.
func _on_export_tile_set() -> void:
	if project == null:
		return
	var path := ExportScript.default_tile_set_path(project.source_path)
	var err: Error = ExportScript.export_tile_set(project, path)
	_reported(path, err, "拖到 TileMapLayer 的 Tile Set 上即可开始画")


## Writes one frame's tilemap layers as a scene next to the `.pxo`.
func _on_export_tile_map() -> void:
	if project == null:
		return
	var path := ExportScript.default_tile_map_path(project.source_path)
	var err: Error = ExportScript.export_tile_map(project, _current, path)
	var cells := 0
	var frame := project.get_frame(_current)
	if frame != null:
		for layer_index in project.tile_layers.size():
			cells += frame.get_tile_cells(int(project.tile_layers[layer_index]["layer"])).size()
	_reported(path, err, "第 %d 帧，%d 个格子已经摆好" % [_current, cells])


## Whether the resource was built by an older reader. Godot only re-imports when
## the source file changes, so a `.pxo` imported before the tile work keeps its
## empty tile fields forever — and an empty field looks exactly like a project
## that has no tilesets.
func _is_stale() -> bool:
	return project != null and project.reader_version < ReaderScript.READER_VERSION


## Why the two tile buttons are grey: either the resource is from an older
## reader, or the project was never drawn with a TileMap layer — a decision made
## in Pixelorama, not here.
func _no_tiles_reason() -> String:
	if _is_stale():
		return "这个资源是旧版导入器导入的：右键 .pxo → 重新导入，图块信息才会进来"
	return "这个 .pxo 里没有图块集：Pixelorama 里没建 TileMap 图层，只有普通图层"


## "· 1 个图块集 53 块（16×16）· 图块层 1 个", or a line saying why there is none.
func _tileset_line() -> String:
	if project == null:
		return ""
	if _is_stale():
		return "\n这个资源是旧版导入器导入的：右键 .pxo → 重新导入 才有图块信息"
	if not project.has_tilesets():
		return "\n没有图块集：这个工程在 Pixelorama 里没有 TileMap 图层"
	var counts: Array[String] = []
	for entry: Dictionary in project.tilesets:
		# The size is stored as Pixelorama prints it, "(16, 16)"; the brackets are
		# already around it here.
		var size_text := str(entry.get("tile_size", "")).strip_edges()
		size_text = size_text.trim_prefix("(").trim_suffix(")")
		counts.append(
			"%s %d 块（%s）" % [
				str(entry.get("name", "")),
				int(entry.get("tile_amount", 0)),
				size_text,
			]
		)
	var layers := project.tile_layer_names()
	var tail := ""
	if not layers.is_empty():
		tail = " · 图块层 %d 个：%s" % [layers.size(), "、".join(layers)]
	return "\n图块集 %d 个：%s%s" % [project.tilesets.size(), "；".join(counts), tail]


## A line about the Shader Composer layers this file has, or "" when it has none.
##
## Their pixels are only a static bake of a graph Pixelorama evaluates live, so
## the preview (and the imported frames) legitimately differ from the editor —
## saying so here stops that from looking like a bug.
func _shader_line() -> String:
	if project == null:
		return ""
	if _is_stale():
		return ""
	if not project.has_shader_layers():
		return ""
	return (
		"\n着色器图层 %d 个（%s）没有参与帧合成：像素只是静态烘焙，"
		% [project.shader_layer_names.size(), "、".join(project.shader_layer_names)]
		+ "与编辑器的实时效果不同。要逐像素一致，请在 Pixelorama 保存时勾上「包含合成图」"
	)


func _reported(path: String, err: Error, hint: String) -> void:
	if err != OK:
		_note.text = "生成失败：%s（错误 %d）" % [path, err]
		return
	_note.text = "已生成 %s —— %s" % [path, hint]
	if Engine.is_editor_hint():
		# The new file has to show up in the FileSystem dock before it can be
		# dragged anywhere, and a scan is the only reliable way for a file that
		# did not exist a moment ago.
		EditorInterface.get_resource_filesystem().scan()


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
