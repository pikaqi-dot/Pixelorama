extends Panel
## Tiled-style tilemap design page. It is a workspace of its own: a tile palette
## taken from the project tilesets or from any image, one grid per layer, and the
## usual painting tools. The map is described in this page, so it can be exported
## to PNG or saved as a map file without touching any project layer.
##
## Everything is built in code, like the node editor page, so a phone and a
## desktop get the same layout with no scene to keep in sync.

## Emitted when the close button hides the page, so the host can switch back to
## the drawing tab.
signal page_closed

const TilemapPaletteScript := preload("res://src/UI/Tilemap/TilemapPalette.gd")
const TilemapBoardScript := preload("res://src/UI/Tilemap/TilemapBoard.gd")
const TileAnimationScript := preload("res://src/Classes/TileAnimation.gd")
const ProjectFrameComposer := preload("res://src/Classes/ProjectFrameComposer.gd")

const TOUCH_SIZE := 40
const TOUCH_FONT_SIZE := 15
const MIN_ZOOM := 0.1
const MAX_ZOOM := 16.0
## Below this width the side panel moves under the map instead of beside it.
const NARROW_WIDTH := 760
const MAP_MIN := 1
const MAP_MAX := 256
const TILE_MIN := 1
const TILE_MAX := 128
## How many map snapshots the undo history keeps.
const UNDO_LIMIT := 80
## A tileset image is never cut into more tiles than this, so a 1 px tile size
## does not try to build a palette with a million entries.
const MAX_PALETTE_TILES := 4096
## Animated tiles keep one atlas per drawing frame, so the count is capped to
## keep a long animation from eating memory.
const MAX_ANIM_FRAMES := 48
## Tools, in the order of the toolbar.
const TOOLS := ["铅笔", "橡皮", "填充", "矩形", "直线", "取色"]
const TOOL_PENCIL := 0
const TOOL_ERASER := 1
const TOOL_FILL := 2
const TOOL_RECT := 3
const TOOL_LINE := 4
const TOOL_PICKER := 5
const TOOL_TIPS := [
	"左键放图块，拖动连续绘制",
	"左键或右键擦成空格",
	"填充连通区域，右键用空白填充",
	"拖出矩形，一次填满",
	"拖出一条直线，一次画完",
	"点画布上的图块，把它选进调色板",
]
const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.08)
const BOARD_BACKDROP := Color(0.09, 0.1, 0.12)
const CHECKER_LIGHT := Color(0.16, 0.17, 0.2)
const CHECKER_DARK := Color(0.125, 0.135, 0.165)
const MAP_BORDER := Color(0.45, 0.5, 0.6)
const HOVER_COLOR := Color(1.0, 1.0, 1.0, 0.85)

## Tile index 0 is the empty tile, exactly like [TileSetCustom] uses it.
## Index 1 and above are palette entries.
var _tiles: Array[Image] = [null]
var _atlas_image: Image
var _atlas_texture: ImageTexture
var _atlas_rects: Array[Rect2i] = [Rect2i()]
## Original picture of an image tileset, kept so the tile size can cut it again.
var _source_image: Image
var _source_name := ""
## One picture per animation frame; more than one means the tiles animate.
var _source_frames: Array[Image] = []
## Animated atlas: clocks, per frame textures and the shared rectangles.
var _tile_anim = TileAnimationScript.new()
var _anim_play_button: Button
var _anim_fps_slider: HSlider
var _tile_size := Vector2i(16, 16)

## One grid per layer, bottom to top. A layer is
## {"name": String, "visible": bool, "cells": Dictionary[Vector2i, int]}.
var _layers: Array[Dictionary] = []
var _current_layer := 0
var _layer_serial := 0
var _map_size := Vector2i(30, 20)

var _zoom := 2.0
var _pan := Vector2.ZERO
var _show_grid := true
var _hover := Vector2i(-1, -1)

var _tool := TOOL_PENCIL
var _selected_tile := 1
var _stroke_active := false
var _stroke_erase := false
var _stroke_changed := false
var _last_cell := Vector2i(-1, -1)
var _rect_active := false
var _rect_start := Vector2i.ZERO
var _rect_end := Vector2i.ZERO
var _panning := false

var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _can_draw_before := true

var _board
var _body: GridContainer
var _side_panel: Control
var _status: Label
## Header line under the title: which tileset is loaded and how big the map is.
var _subtitle: Label
## Zoom readout in the tools row, kept in step with [member _zoom].
var _zoom_label: Label
## Colour behind the map, chosen by the user like the game page backdrop.
var _board_color := BOARD_BACKDROP
var _tile_preview: TextureRect
var _tile_preview_label: Label
var _tileset_option: OptionButton
var _palette
var _palette_hint: Label
var _layer_list: ItemList
var _tool_buttons: Array[Button] = []
var _grid_button: Button
var _undo_button: Button
var _redo_button: Button
var _slice_button: Button
var _size_cols: HSlider
var _size_rows: HSlider
var _size_cols_readout: Label
var _size_rows_readout: Label
var _tile_w: HSlider
var _tile_h: HSlider
var _tile_w_readout: Label
var _tile_h_readout: Label

var _map_open_dialog: FileDialog
var _map_save_dialog: FileDialog
var _png_dialog: FileDialog
var _image_dialog: FileDialog


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_reset_map()
	_refresh_all()
	resized.connect(_apply_layout)
	_apply_layout()
	hide()


## Side by side on a wide window, stacked when it is narrow, so the map keeps
## most of a phone screen instead of sharing it with a fixed side panel.
func _apply_layout() -> void:
	if not is_instance_valid(_body):
		return
	var narrow := size.x < NARROW_WIDTH
	_body.columns = 1 if narrow else 2
	if is_instance_valid(_side_panel):
		_side_panel.custom_minimum_size.x = 0.0 if narrow else 230.0


#region Lifecycle


func open_page() -> void:
	if not visible:
		_can_draw_before = Global.can_draw
	Global.can_draw = false
	_refresh_tileset_options()
	_adopt_current_tileset()
	_refresh_palette()
	_refresh_layers()
	_refresh_all()
	show()
	_fit_view()


func close_page() -> void:
	if not visible:
		return
	Global.can_draw = _can_draw_before
	hide()
	page_closed.emit()


func is_open() -> bool:
	return visible


## Only animated tiles need a per frame tick; a static tileset returns at once,
## so the page costs nothing while idle.
func _process(delta: float) -> void:
	if not visible or _tile_anim.frame_count() <= 1:
		return
	if not _tile_anim.advance(delta):
		return
	if is_instance_valid(_board):
		_board.queue_redraw()
	if is_instance_valid(_palette):
		_palette.queue_redraw()
	_refresh_tile_preview()


## Hides the page while another view tab is shown. The map and the palette stay,
## so switching back is instant.
func pause_page() -> void:
	if not visible:
		return
	Global.can_draw = _can_draw_before
	hide()


## Shows the page again after [method pause_page], without reloading anything.
func resume_page() -> void:
	Global.can_draw = false
	show()
	_refresh_all()


#endregion


#region UI


func _build_ui() -> void:
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.11, 0.11, 0.13)
	add_theme_stylebox_override("panel", background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	root.add_child(_build_header())
	root.add_child(_build_toolbar())
	root.add_child(_build_tools_row())

	var short_hint := Label.new()
	short_hint.text = "左键绘制 · 右键擦除 · 滚轮缩放 · 中键或空格拖动平移 · Ctrl+Z 撤销"
	short_hint.add_theme_font_size_override("font_size", 12)
	short_hint.modulate = Color(1.0, 1.0, 1.0, 0.65)
	short_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(short_hint)

	_body = GridContainer.new()
	_body.columns = 2
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("h_separation", 8)
	_body.add_theme_constant_override("v_separation", 8)
	root.add_child(_body)
	_body.add_child(_build_canvas_column())
	_side_panel = _build_side_panel()
	_body.add_child(_side_panel)


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	# Title plus a second line of context, so the header says what is loaded
	# instead of only where the page is.
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 0)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := Label.new()
	title.text = "Tilemap 设计"
	title.add_theme_font_size_override("font_size", 17)
	titles.add_child(title)
	_subtitle = Label.new()
	_subtitle.add_theme_font_size_override("font_size", 12)
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle.modulate = Color(1.0, 1.0, 1.0, 0.6)
	titles.add_child(_subtitle)
	row.add_child(titles)
	row.add_child(
		_make_button(
			"作为图层添加",
			_add_map_as_layer,
			"把整张地图渲染成一张图，加到当前帧的新图层上",
			Vector2(0, TOUCH_SIZE)
		)
	)
	row.add_child(
		_make_button(
			"关闭",
			close_page,
			"回到绘画页；地图会留在这里，随时可以再打开",
			Vector2(0, TOUCH_SIZE)
		)
	)
	return row


func _build_toolbar() -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	var label := Label.new()
	label.text = "图块集"
	label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	row.add_child(label)
	_tileset_option = OptionButton.new()
	_tileset_option.custom_minimum_size = Vector2(220, TOUCH_SIZE)
	_tileset_option.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_tileset_option.item_selected.connect(_on_tileset_selected)
	row.add_child(_tileset_option)
	row.add_child(
		_make_button(
			"从绘画区载入",
			_load_tileset_from_project,
			"把绘画区当前帧的可见图层当作图块来源，不用先导出图片"
		)
	)
	row.add_child(
		_make_button("从图片载入…", _pick_tileset_image, "把一张图片切成一格一格的图块")
	)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_make_button("打开地图…", _open_map_file, "读取保存过的 .tmap 地图"))
	row.add_child(_make_button("保存地图…", _save_map_file, "把地图存成 .tmap 文件"))
	row.add_child(_make_button("导出 PNG…", _export_png, "把整张地图渲染成图片"))
	return row


func _build_canvas_column() -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	_board = TilemapBoardScript.new()
	_board.page = self
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_board.custom_minimum_size = Vector2(240, 200)
	column.add_child(_board)
	column.add_child(_build_map_size_block())
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 13)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	return column


func _build_map_size_block() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 6)
	var header := HBoxContainer.new()
	var label := Label.new()
	label.text = "地图尺寸"
	label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	header.add_child(label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	header.add_child(
		_make_button(
			"应用尺寸",
			_apply_map_size,
			"按滑条改地图大小：超出的图块会被裁掉，新增的区域留空",
			Vector2(0, TOUCH_SIZE)
		)
	)
	block.add_child(header)
	var cols := _make_slider_row(
		"列", MAP_MIN, MAP_MAX, 30, func(_value: float) -> void: _update_status()
	)
	_size_cols = cols["slider"]
	_size_cols_readout = cols["readout"]
	block.add_child(cols["row"])
	var rows := _make_slider_row(
		"行", MAP_MIN, MAP_MAX, 20, func(_value: float) -> void: _update_status()
	)
	_size_rows = rows["slider"]
	_size_rows_readout = rows["readout"]
	block.add_child(rows["row"])
	return block


func _build_side_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(230, 0)
	panel.add_theme_constant_override("separation", 6)

	var palette_title := Label.new()
	palette_title.text = "图块"
	palette_title.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	panel.add_child(palette_title)
	_palette_hint = Label.new()
	_palette_hint.text = (
		"还没有图块。\n「从绘画区载入」会取用绘画区的所有帧，"
		+ "多帧时图块自动变成动画；也可以「从图片载入…」或选一个项目图块集。"
	)
	_palette_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_palette_hint.add_theme_font_size_override("font_size", 13)
	_palette_hint.modulate = Color(1.0, 1.0, 1.0, 0.65)
	panel.add_child(_palette_hint)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 110)
	panel.add_child(scroll)
	# One control draws the whole atlas, so even thousands of tiles cost one
	# node instead of one button per tile.
	_palette = TilemapPaletteScript.new()
	_palette.page = self
	_palette.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_palette)

	# Preview of the brush tile, so the small palette highlight is not the only clue.
	var preview_row := HBoxContainer.new()
	preview_row.add_theme_constant_override("separation", 8)
	_tile_preview = TextureRect.new()
	_tile_preview.custom_minimum_size = Vector2(48, 48)
	_tile_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_tile_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_tile_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview_row.add_child(_tile_preview)
	_tile_preview_label = Label.new()
	_tile_preview_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_tile_preview_label.add_theme_font_size_override("font_size", 13)
	_tile_preview_label.modulate = Color(1.0, 1.0, 1.0, 0.75)
	preview_row.add_child(_tile_preview_label)
	panel.add_child(preview_row)

	panel.add_child(HSeparator.new())
	var tile_title := Label.new()
	tile_title.text = "图块尺寸"
	tile_title.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	panel.add_child(tile_title)
	var width_row := _make_slider_row(
		"宽", TILE_MIN, TILE_MAX, 16, func(value: float) -> void: _on_tile_size_changed()
	)
	_tile_w = width_row["slider"]
	_tile_w_readout = width_row["readout"]
	panel.add_child(width_row["row"])
	var height_row := _make_slider_row(
		"高", TILE_MIN, TILE_MAX, 16, func(value: float) -> void: _on_tile_size_changed()
	)
	_tile_h = height_row["slider"]
	_tile_h_readout = height_row["readout"]
	panel.add_child(height_row["row"])
	_slice_button = _make_button(
		"切分图块", _slice_source_tiles, "按上面的宽高重新切分载入的图片"
	)
	panel.add_child(_slice_button)

	panel.add_child(HSeparator.new())
	var anim_title := Label.new()
	anim_title.text = "动画"
	anim_title.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	panel.add_child(anim_title)
	var fps_row := _make_slider_row(
		"帧率",
		1,
		24,
		int(round(_tile_anim.fps)),
		func(value: float) -> void: _tile_anim.fps = value
	)
	_anim_fps_slider = fps_row["slider"]
	panel.add_child(fps_row["row"])
	_anim_play_button = _make_button("暂停动画", _toggle_anim_play, "暂停或继续图块的帧动画")
	panel.add_child(_anim_play_button)

	panel.add_child(HSeparator.new())
	var layers_title := Label.new()
	layers_title.text = "图层"
	layers_title.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	panel.add_child(layers_title)
	_layer_list = ItemList.new()
	_layer_list.custom_minimum_size = Vector2(0, 96)
	_layer_list.item_selected.connect(_on_layer_selected)
	panel.add_child(_layer_list)
	var layer_buttons := HFlowContainer.new()
	layer_buttons.add_theme_constant_override("h_separation", 4)
	layer_buttons.add_theme_constant_override("v_separation", 4)
	layer_buttons.add_child(_make_button("新建", _add_layer, "在当前图层上方新建一层"))
	layer_buttons.add_child(_make_button("复制", _duplicate_layer, "复制当前图层到它上面"))
	layer_buttons.add_child(_make_button("删除", _remove_layer, "删除当前图层"))
	layer_buttons.add_child(_make_button("清空", _clear_layer, "擦掉当前图层上的所有图块"))
	layer_buttons.add_child(_make_button("显示/隐藏", _toggle_layer_visible, "切换当前图层是否显示"))
	layer_buttons.add_child(_make_button("上移", func() -> void: _move_layer(1), "把当前图层往上挪"))
	layer_buttons.add_child(_make_button("下移", func() -> void: _move_layer(-1), "把当前图层往下挪"))
	panel.add_child(layer_buttons)

	panel.add_child(HSeparator.new())
	var board_title := Label.new()
	board_title.text = "画板"
	board_title.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	panel.add_child(board_title)
	var color_row := HBoxContainer.new()
	color_row.add_theme_constant_override("separation", 6)
	var color_label := Label.new()
	color_label.text = "底色"
	color_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	color_label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	color_row.add_child(color_label)
	var picker := ColorPickerButton.new()
	picker.color = _board_color
	picker.edit_alpha = false
	picker.focus_mode = Control.FOCUS_NONE
	picker.custom_minimum_size = Vector2(58, TOUCH_SIZE)
	picker.tooltip_text = "地图外的画板底色，深色和浅色图块都能看清"
	picker.color_changed.connect(func(color: Color) -> void: _set_board_color(color))
	color_row.add_child(picker)
	panel.add_child(color_row)
	return panel


func _build_tool_buttons(row: HFlowContainer) -> void:
	var group := ButtonGroup.new()
	# The current tool gets a solid accent, which reads much faster than a
	# slightly darker button on a dark theme.
	var accent := StyleBoxFlat.new()
	accent.bg_color = Color(0.22, 0.42, 0.72)
	accent.corner_radius_top_left = 4
	accent.corner_radius_top_right = 4
	accent.corner_radius_bottom_left = 4
	accent.corner_radius_bottom_right = 4
	for i in TOOLS.size():
		var tool := i
		var button := _make_button(TOOLS[i], Callable(), TOOL_TIPS[i])
		button.toggle_mode = true
		button.button_group = group
		button.add_theme_stylebox_override("pressed", accent)
		button.toggled.connect(
			func(on: bool) -> void:
				if on:
					_tool = tool
					_update_status()
		)
		button.button_pressed = tool == _tool
		row.add_child(button)
		_tool_buttons.append(button)


func _build_tools_row() -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	_build_tool_buttons(row)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_grid_button = _make_button("网格", _toggle_grid, "显示或隐藏格子线")
	_grid_button.toggle_mode = true
	_grid_button.button_pressed = _show_grid
	row.add_child(_grid_button)
	_undo_button = _make_button("撤销", _undo_step, "Ctrl+Z")
	_redo_button = _make_button("重做", _redo_step, "Ctrl+Y")
	row.add_child(_undo_button)
	row.add_child(_redo_button)
	# A live readout makes the zoom buttons answerable: press, then read.
	_zoom_label = Label.new()
	_zoom_label.custom_minimum_size = Vector2(54, TOUCH_SIZE)
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zoom_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_zoom_label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_zoom_label.text = "%d%%" % int(round(_zoom * 100.0))
	row.add_child(_zoom_label)
	row.add_child(
		_make_button("−", func() -> void: _zoom_center(1.0 / 1.2), "缩小", Vector2(34, TOUCH_SIZE))
	)
	row.add_child(
		_make_button("＋", func() -> void: _zoom_center(1.2), "放大", Vector2(34, TOUCH_SIZE))
	)
	row.add_child(_make_button("1:1", _zoom_one_to_one, "回到 100% 缩放"))
	row.add_child(_make_button("适应窗口", _fit_view, "把整张地图放进窗口"))
	return row


func _toggle_grid() -> void:
	_show_grid = _grid_button.button_pressed
	_board.queue_redraw()


## Board colour chosen in the side panel; only the empty area changes.
func _set_board_color(color: Color) -> void:
	_board_color = color
	if is_instance_valid(_board):
		_board.queue_redraw()


## Pauses or resumes the tile animation; the button text follows the state.
func _toggle_anim_play() -> void:
	_tile_anim.playing = not _tile_anim.playing
	if is_instance_valid(_anim_play_button):
		_anim_play_button.text = "暂停动画" if _tile_anim.playing else "播放动画"
	if is_instance_valid(_board):
		_board.queue_redraw()


func _make_button(
	text: String, callback: Callable, tooltip := "", min_size := Vector2(0, TOUCH_SIZE)
) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.custom_minimum_size = min_size
	button.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	button.focus_mode = Control.FOCUS_NONE
	if callback.is_valid():
		button.pressed.connect(callback)
	return button


## Row with a title, one-pixel arrows, a slider and a read-only number. The same
## shape is used for the map size and for the tile size, so nothing has to be
## typed, which keeps the page usable with a finger.
func _make_slider_row(
	title: String,
	min_value: float,
	max_value: float,
	value: float,
	on_changed: Callable
) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(26, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	row.add_child(label)
	# The slider exists before the arrow buttons capture it.
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = 1
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(68, TOUCH_SIZE)
	row.add_child(
		_make_button(
			"−",
			func() -> void: _step_slider(slider, -1.0),
			"减一",
			Vector2(34, TOUCH_SIZE)
		)
	)
	row.add_child(slider)
	row.add_child(
		_make_button(
			"+",
			func() -> void: _step_slider(slider, 1.0),
			"加一",
			Vector2(34, TOUCH_SIZE)
		)
	)
	var readout := Label.new()
	readout.custom_minimum_size = Vector2(38, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	readout.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	readout.text = str(int(round(value)))
	row.add_child(readout)
	slider.value_changed.connect(
		func(new_value: float) -> void:
			readout.text = str(int(round(new_value)))
			on_changed.call(new_value)
	)
	return {"row": row, "slider": slider, "readout": readout}


func _step_slider(slider: HSlider, direction: float) -> void:
	if not is_instance_valid(slider):
		return
	var step := maxf(slider.step, 0.0001)
	var next := snappedf(slider.value + step * direction, step)
	slider.value = clampf(next, slider.min_value, slider.max_value)


func _sync_slider_row(slider: HSlider, readout: Label, value: int) -> void:
	if not is_instance_valid(slider):
		return
	slider.set_value_no_signal(float(value))
	if is_instance_valid(readout):
		readout.text = str(value)


#endregion


#region Tileset


## Fills the tileset picker with the project tilesets plus the loaded image, if
## there is one. The metadata of every item says where that entry comes from.
func _refresh_tileset_options() -> void:
	if not is_instance_valid(_tileset_option):
		return
	_tileset_option.clear()
	if _source_image != null:
		_tileset_option.add_item(_source_name)
		_tileset_option.set_item_metadata(0, -1)
	var project := Global.current_project
	if project == null:
		if _tileset_option.item_count == 0:
			_tileset_option.add_item("没有可用的图块集")
			_tileset_option.set_item_metadata(0, -2)
		return
	for i in project.tilesets.size():
		var tileset: TileSetCustom = project.tilesets[i]
		if tileset == null:
			continue
		var index := _tileset_option.item_count
		_tileset_option.add_item(
			"%d · %s（%d×%d）" % [i + 1, tileset.name, tileset.tile_size.x, tileset.tile_size.y]
		)
		_tileset_option.set_item_metadata(index, i)


## Uses the tileset of the selected tilemap layer the first time the page is
## opened, so designing starts with the tiles the artwork already uses.
func _adopt_current_tileset() -> void:
	if _tiles.size() > 1:
		return
	var project := Global.current_project
	if project == null:
		return
	if project.layers.is_empty():
		return
	var layer := project.layers[clampi(project.current_layer, 0, project.layers.size() - 1)]
	if not layer is LayerTileMap:
		return
	var tile_layer := layer as LayerTileMap
	if tile_layer.tileset == null:
		return
	var tileset: TileSetCustom = tile_layer.tileset
	for i in project.tilesets.size():
		if project.tilesets[i] == tileset:
			_tileset_option.select(i if _source_image == null else i + 1)
			_apply_project_tileset(tileset)
			return


func _on_tileset_selected(index: int) -> void:
	var meta: Variant = _tileset_option.get_item_metadata(index)
	if typeof(meta) != TYPE_INT:
		return
	var tileset_index := int(meta)
	if tileset_index == -1:
		_use_source_tiles()
	elif tileset_index >= 0:
		var project := Global.current_project
		if project == null or tileset_index >= project.tilesets.size():
			return
		_apply_project_tileset(project.tilesets[tileset_index])


func _apply_project_tileset(tileset: TileSetCustom) -> void:
	_tiles.clear()
	_tiles.append(null)
	for i in range(1, tileset.tiles.size()):
		_tiles.append(tileset.tiles[i].image)
	_tile_size = tileset.tile_size
	_source_image = null
	_source_name = ""
	_source_frames.clear()
	if is_instance_valid(_slice_button):
		_slice_button.disabled = true
	_set_tile_size_enabled(false)
	_sync_slider_row(_tile_w, _tile_w_readout, _tile_size.x)
	_sync_slider_row(_tile_h, _tile_h_readout, _tile_size.y)
	_selected_tile = 1
	_rebuild_atlas()
	# A project tileset is one picture per tile, so it has a single frame.
	_tile_anim.restore(_atlas_image, [], _atlas_rects)
	_refresh_palette()
	_refresh_all()


func _use_source_tiles() -> void:
	if _source_image == null:
		return
	if is_instance_valid(_slice_button):
		_slice_button.disabled = false
	_set_tile_size_enabled(true)
	_slice_source_tiles()


func _pick_tileset_image() -> void:
	if not is_instance_valid(_image_dialog):
		_image_dialog = _make_file_dialog(
			"载入图块图片", FileDialog.FILE_MODE_OPEN_FILE, ["*.png ; PNG 图片"]
		)
		_image_dialog.file_selected.connect(_load_tileset_image)
	_image_dialog.popup_centered_ratio(0.6)


func _load_tileset_image(path: String) -> void:
	var image: Image = Image.load_from_file(path)
	if image == null or image.is_empty():
		Global.notification_label("读不到这张图片")
		return
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	_source_frames = [image]
	_source_image = image
	_source_name = "图片：%s" % path.get_file()
	_slice_button.disabled = false
	_set_tile_size_enabled(true)
	_refresh_tileset_options()
	if _tileset_option.item_count > 0 and _tileset_option.get_item_metadata(0) == -1:
		_tileset_option.select(0)
	_slice_source_tiles()


## Uses the drawing area itself as the tile source: the visible layers of the
## current frame are blended with their alpha kept, so what was painted can be
## cut into tiles without exporting it first.
func _load_tileset_from_project() -> void:
	var project := Global.current_project
	if project == null:
		Global.notification_label("还没有打开的项目")
		return
	# Every frame of the drawing area is kept, so a tile that changes from one
	# frame to the next becomes an animated tile for free.
	var frames: Array[Image] = []
	for index in project.frames.size():
		var frame_image: Image = ProjectFrameComposer.frame_image(project, index)
		if frame_image != null and not frame_image.is_empty():
			frames.append(frame_image)
	if frames.is_empty():
		Global.notification_label("绘画区没有可以取用的画面")
		return
	_source_frames = frames
	_source_image = frames[0]
	_source_name = "绘画区：%s · %d 帧" % [project.name, frames.size()]
	_slice_button.disabled = false
	_set_tile_size_enabled(true)
	_refresh_tileset_options()
	if _tileset_option.item_count > 0 and _tileset_option.get_item_metadata(0) == -1:
		_tileset_option.select(0)
	_slice_source_tiles()


## Cuts the loaded pictures into tiles of the current size and builds the
## palette. Every frame of the drawing area is cut with the same rectangles, so
## a cell whose art changes between frames becomes an animated tile.
func _slice_source_tiles() -> void:
	if _source_image == null:
		return
	var tile_width := maxi(int(round(_tile_w.value)) if is_instance_valid(_tile_w) else 16, 1)
	var tile_height := maxi(int(round(_tile_h.value)) if is_instance_valid(_tile_h) else 16, 1)
	var tile := Vector2i(tile_width, tile_height)
	_tile_size = tile
	if _source_frames.is_empty():
		_source_frames = [_source_image]
	if _source_frames.size() > MAX_ANIM_FRAMES:
		_source_frames = _source_frames.slice(0, MAX_ANIM_FRAMES)
	if not _tile_anim.build_from_sources(_source_frames, tile):
		Global.notification_label("图块切不出来，试试别的图块尺寸")
		return
	var count: int = _tile_anim.rects.size() - 1
	if count > MAX_PALETTE_TILES:
		_tile_anim.clear()
		Global.notification_label("图块太多（%d），先把图块尺寸调大" % count)
		return
	_atlas_rects = _tile_anim.rects
	_atlas_image = _tile_anim.atlases[0]
	_atlas_texture = _tile_anim.textures[0]
	_tiles.clear()
	_tiles.append(null)
	for region in _atlas_rects.slice(1):
		_tiles.append(_source_frames[0].get_region(region))
	_selected_tile = 1
	_refresh_palette()
	_refresh_all()


## Packs every tile into one atlas, so the board and the palette share a single
## texture and every cell is one draw call.
func _rebuild_atlas() -> void:
	_atlas_rects.clear()
	_atlas_rects.append(Rect2i())
	_atlas_image = null
	_atlas_texture = null
	if _tiles.size() <= 1:
		return
	var cell := Vector2i(1, 1)
	for i in range(1, _tiles.size()):
		var image: Image = _tiles[i]
		if image == null:
			continue
		cell.x = maxi(cell.x, image.get_width())
		cell.y = maxi(cell.y, image.get_height())
	if cell.x < 1 or cell.y < 1:
		return
	var columns := maxi(int(ceil(sqrt(float(_tiles.size() - 1)))), 1)
	var rows := maxi(int(ceil(float(_tiles.size() - 1) / float(columns))), 1)
	var atlas := Image.create_empty(columns * cell.x, rows * cell.y, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0.0, 0.0, 0.0, 0.0))
	for i in range(1, _tiles.size()):
		var image: Image = _tiles[i]
		if image == null:
			_atlas_rects.append(Rect2i())
			continue
		var slot := i - 1
		var position := Vector2i(
			(slot % columns) * cell.x, floori(float(slot) / float(columns)) * cell.y
		)
		atlas.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), position)
		_atlas_rects.append(Rect2i(position, image.get_size()))
	_atlas_image = atlas
	_atlas_texture = ImageTexture.create_from_image(atlas)


func _on_tile_size_changed() -> void:
	if not is_instance_valid(_tile_w) or not is_instance_valid(_tile_h):
		return
	_tile_size = Vector2i(int(round(_tile_w.value)), int(round(_tile_h.value)))
	# A project tileset has a fixed tile size; only an image can be cut again.
	if is_instance_valid(_slice_button):
		_slice_button.disabled = _source_image == null
	_board.queue_redraw()
	_update_status()


func _set_tile_size_enabled(enabled: bool) -> void:
	for slider in [_tile_w, _tile_h]:
		if is_instance_valid(slider):
			slider.editable = enabled


#endregion


#region Palette


func _refresh_palette() -> void:
	if not is_instance_valid(_palette):
		return
	var has_tiles := _tiles.size() > 1
	if has_tiles:
		_selected_tile = clampi(_selected_tile, 1, _tiles.size() - 1)
	if is_instance_valid(_palette_hint):
		_palette_hint.visible = not has_tiles
	_palette.visible = has_tiles
	_palette.refresh()
	_refresh_tile_preview()
	_update_status()


func _refresh_palette_selection() -> void:
	if is_instance_valid(_palette):
		_palette.refresh()
	_refresh_tile_preview()


## Big preview of the brush tile, rebuilt only when the selection changes.
func _refresh_tile_preview() -> void:
	if not is_instance_valid(_tile_preview):
		return
	if _atlas_texture == null or tile_count() <= 0:
		_tile_preview.texture = null
		_tile_preview_label.text = "还没有图块"
		return
	var rect: Rect2i = tile_rect(_selected_tile)
	var region := AtlasTexture.new()
	region.atlas = _atlas_texture
	region.region = Rect2(rect)
	_tile_preview.texture = region
	_tile_preview_label.text = (
		"当前 %d / %d\n%d×%d px" % [_selected_tile, tile_count(), rect.size.x, rect.size.y]
	)


## Called by the palette when a tile is clicked or picked from the board.
func set_selected_tile(index: int) -> void:
	_selected_tile = clampi(index, 1, maxi(_tiles.size() - 1, 1))
	_refresh_tile_preview()
	_update_status()


func selected_tile() -> int:
	return _selected_tile


## Number of palette entries. Index 0 is the empty tile and is not drawn.
func tile_count() -> int:
	return maxi(_tiles.size() - 1, 0)


## Atlas texture of the frame that should be drawn right now, so the palette and
## the board animate together.
func atlas_texture() -> Texture2D:
	var current: Texture2D = _tile_anim.texture()
	return current if current != null else _atlas_texture


func tile_rect(index: int) -> Rect2i:
	if index < 0 or index >= _atlas_rects.size():
		return Rect2i()
	return _atlas_rects[index]


#endregion


#region Layers


func _current_cells() -> Dictionary:
	if _current_layer < 0 or _current_layer >= _layers.size():
		return {}
	return _layers[_current_layer]["cells"] as Dictionary


func _reset_map() -> void:
	_layers.clear()
	_layer_serial = 0
	_append_layer()
	_current_layer = 0
	_map_size = Vector2i(30, 20)
	_zoom = 2.0
	_pan = Vector2.ZERO
	_undo.clear()
	_redo.clear()


func _append_layer() -> void:
	_layer_serial += 1
	_layers.append(
		{
			"name": "图层 %d" % _layer_serial,
			"visible": true,
			"cells": {},
		}
	)


func _refresh_layers() -> void:
	if not is_instance_valid(_layer_list):
		return
	_layer_list.clear()
	for i in _layers.size():
		var layer: Dictionary = _layers[i]
		var text := str(layer["name"])
		if not bool(layer["visible"]):
			text += "（隐藏）"
		_layer_list.add_item(text)
		if i == _current_layer:
			_layer_list.select(i)


func _on_layer_selected(index: int) -> void:
	if index < 0 or index >= _layers.size():
		return
	_current_layer = index
	_board.queue_redraw()
	_update_status()


func _add_layer() -> void:
	_remember()
	_layer_serial += 1
	_layers.insert(
		_current_layer + 1,
		{
			"name": "图层 %d" % _layer_serial,
			"visible": true,
			"cells": {},
		}
	)
	_current_layer += 1
	_after_layers_changed()


func _duplicate_layer() -> void:
	if _current_layer < 0 or _current_layer >= _layers.size():
		return
	_remember()
	var source: Dictionary = _layers[_current_layer]
	_layers.insert(
		_current_layer + 1,
		{
			"name": "%s 副本" % str(source["name"]),
			"visible": bool(source["visible"]),
			"cells": (source["cells"] as Dictionary).duplicate(true),
		}
	)
	_current_layer += 1
	_after_layers_changed()


func _remove_layer() -> void:
	if _layers.size() <= 1:
		# The last layer stays, but its tiles are cleared instead.
		_remember()
		_layers[0]["cells"] = {}
		_after_layers_changed()
		return
	_remember()
	_layers.remove_at(_current_layer)
	_current_layer = clampi(_current_layer, 0, _layers.size() - 1)
	_after_layers_changed()


func _clear_layer() -> void:
	if _current_layer < 0 or _current_layer >= _layers.size():
		return
	if (_layers[_current_layer]["cells"] as Dictionary).is_empty():
		return
	_remember()
	_layers[_current_layer]["cells"] = {}
	_after_layers_changed()


func _toggle_layer_visible() -> void:
	if _current_layer < 0 or _current_layer >= _layers.size():
		return
	_remember()
	var layer: Dictionary = _layers[_current_layer]
	layer["visible"] = not bool(layer["visible"])
	_after_layers_changed()


func _move_layer(direction: int) -> void:
	var target := _current_layer + direction
	if target < 0 or target >= _layers.size():
		return
	_remember()
	var layer: Dictionary = _layers[_current_layer]
	_layers.remove_at(_current_layer)
	_layers.insert(target, layer)
	_current_layer = target
	_after_layers_changed()


func _after_layers_changed() -> void:
	_refresh_layers()
	_board.queue_redraw()
	_update_status()
	_refresh_history_buttons()


#endregion


#region Map editing


func _apply_map_size() -> void:
	if not is_instance_valid(_size_cols) or not is_instance_valid(_size_rows):
		return
	var size := Vector2i(
		clampi(int(round(_size_cols.value)), MAP_MIN, MAP_MAX),
		clampi(int(round(_size_rows.value)), MAP_MIN, MAP_MAX)
	)
	if size == _map_size:
		_update_status()
		return
	_remember()
	for layer in _layers:
		var cells: Dictionary = layer["cells"]
		var kept := {}
		for cell: Vector2i in cells:
			if cell.x >= 0 and cell.y >= 0 and cell.x < size.x and cell.y < size.y:
				kept[cell] = cells[cell]
		layer["cells"] = kept
	_map_size = size
	_redo.clear()
	_refresh_history_buttons()
	_board.queue_redraw()
	_update_status()


func _cell_pixels() -> Vector2:
	return Vector2(maxi(_tile_size.x, 1), maxi(_tile_size.y, 1)) * _zoom


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < _map_size.x and cell.y < _map_size.y


func _board_cell(position: Vector2) -> Vector2i:
	var cell_px := _cell_pixels()
	var local := (position - _pan) / cell_px
	return Vector2i(floori(local.x), floori(local.y))


func _cell_index(cell: Vector2i) -> int:
	var cells := _current_cells()
	return int(cells.get(cell, 0))


func _paint_cell(cell: Vector2i, erase: bool) -> void:
	if not _in_bounds(cell):
		return
	var cells := _current_cells()
	var value := 0
	if not erase and _tiles.size() > 1:
		value = clampi(_selected_tile, 1, _tiles.size() - 1)
	if value == 0:
		if cells.has(cell):
			cells.erase(cell)
			_stroke_changed = true
	elif int(cells.get(cell, 0)) != value:
		cells[cell] = value
		_stroke_changed = true
	_board.queue_redraw()


func _begin_stroke(cell: Vector2i, erase := false) -> void:
	if not _in_bounds(cell):
		return
	if _tool == TOOL_PICKER:
		var index := _cell_index(cell)
		if index > 0 and index < _tiles.size():
			_selected_tile = index
			_refresh_palette_selection()
			_update_status()
		return
	if _tiles.size() <= 1:
		Global.notification_label("先载入一个图块集再绘制")
		return
	_remember()
	_stroke_active = true
	_stroke_erase = erase
	_stroke_changed = false
	_last_cell = cell
	match _tool:
		TOOL_RECT, TOOL_LINE:
			_rect_active = true
			_rect_start = cell
			_rect_end = cell
			_board.queue_redraw()
		TOOL_FILL:
			_flood_fill(cell, erase)
			_end_stroke()
		_:
			_paint_cell(cell, erase or _tool == TOOL_ERASER)
			_update_status()


func _continue_stroke(cell: Vector2i) -> void:
	if not _stroke_active:
		return
	if _rect_active and (_tool == TOOL_RECT or _tool == TOOL_LINE):
		if _in_bounds(cell):
			_rect_end = cell
			_board.queue_redraw()
		return
	if not _in_bounds(cell):
		return
	if cell != _last_cell and _last_cell.x >= 0:
		for step: Vector2i in _line_cells(_last_cell, cell):
			_paint_cell(step, _stroke_erase or _tool == TOOL_ERASER)
	else:
		_paint_cell(cell, _stroke_erase or _tool == TOOL_ERASER)
	_last_cell = cell
	_update_status()


func _end_stroke() -> void:
	if not _stroke_active:
		return
	if _rect_active:
		if _tool == TOOL_RECT:
			var rect := _rect_cells()
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					_paint_cell(Vector2i(x, y), _stroke_erase)
		elif _tool == TOOL_LINE:
			for cell: Vector2i in _line_cells(_rect_start, _rect_end):
				_paint_cell(cell, _stroke_erase)
	_rect_active = false
	_stroke_active = false
	if not _stroke_changed:
		# Nothing moved under the pointer, so the snapshot is thrown away.
		if not _undo.is_empty():
			_undo.pop_back()
	else:
		_redo.clear()
	_refresh_history_buttons()
	_board.queue_redraw()
	_update_status()


## Stops a stroke without painting a pending rectangle or line, which is what a
## second finger on the board turns into a pan or a pinch.
func cancel_stroke() -> void:
	if not _stroke_active:
		return
	_rect_active = false
	_stroke_active = false
	if not _stroke_changed and not _undo.is_empty():
		_undo.pop_back()
	_refresh_history_buttons()
	_board.queue_redraw()
	_update_status()


func _rect_cells() -> Rect2i:
	var left := mini(_rect_start.x, _rect_end.x)
	var top := mini(_rect_start.y, _rect_end.y)
	var right := maxi(_rect_start.x, _rect_end.x)
	var bottom := maxi(_rect_start.y, _rect_end.y)
	return Rect2i(left, top, right - left + 1, bottom - top + 1)


## Tiles between two cells, so a fast drag does not leave gaps.
func _line_cells(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var delta := to - from
	var steps := maxi(absi(delta.x), absi(delta.y))
	if steps <= 0:
		cells.append(to)
		return cells
	# The start cell is included, so the line tool paints both ends.
	for step in range(0, steps + 1):
		var ratio := float(step) / float(steps)
		cells.append(
			Vector2i(
				roundi(lerpf(float(from.x), float(to.x), ratio)),
				roundi(lerpf(float(from.y), float(to.y), ratio))
			)
		)
	return cells


func _flood_fill(start: Vector2i, erase: bool) -> void:
	var target := _cell_index(start)
	var value := 0
	if not erase:
		value = clampi(_selected_tile, 1, maxi(_tiles.size() - 1, 1))
	if target == value:
		return
	var seen := {}
	var stack: Array[Vector2i] = [start]
	while not stack.is_empty():
		var cell: Vector2i = stack.pop_back()
		if not _in_bounds(cell) or seen.has(cell):
			continue
		seen[cell] = true
		if _cell_index(cell) != target:
			continue
		_paint_cell(cell, value == 0)
		stack.append(cell + Vector2i(1, 0))
		stack.append(cell + Vector2i(-1, 0))
		stack.append(cell + Vector2i(0, 1))
		stack.append(cell + Vector2i(0, -1))


#endregion


#region History


func _snapshot() -> Dictionary:
	var layers := []
	for layer in _layers:
		layers.append(
			{
				"name": layer["name"],
				"visible": layer["visible"],
				"cells": (layer["cells"] as Dictionary).duplicate(true),
			}
		)
	return {"layers": layers, "size": _map_size, "current": _current_layer}


func _restore(snapshot: Dictionary) -> void:
	var layers: Array = snapshot.get("layers", [])
	if layers.is_empty():
		return
	_layers.clear()
	for layer in layers:
		_layers.append(
			{
				"name": str(layer.get("name", "图层")),
				"visible": bool(layer.get("visible", true)),
				"cells": (layer.get("cells", {}) as Dictionary).duplicate(true),
			}
		)
	var size: Vector2i = snapshot.get("size", _map_size)
	_map_size = size
	_current_layer = clampi(int(snapshot.get("current", 0)), 0, _layers.size() - 1)
	_sync_map_size_sliders()
	_refresh_layers()
	_refresh_history_buttons()
	_board.queue_redraw()
	_update_status()


func _remember() -> void:
	_undo.append(_snapshot())
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_redo.append(_snapshot())
	_restore(_undo.pop_back())


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_snapshot())
	_restore(_redo.pop_back())


func _refresh_history_buttons() -> void:
	if is_instance_valid(_undo_button):
		_undo_button.disabled = _undo.is_empty()
	if is_instance_valid(_redo_button):
		_redo_button.disabled = _redo.is_empty()


#endregion


#region View


func zoom_at(position: Vector2, factor: float) -> void:
	var before := (position - _pan) / _zoom
	_zoom = clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	_pan = position - before * _zoom
	_refresh_view()


## Moves the map under the fingers. Used by the two finger pan, and kept apart
## from zooming so one gesture can do both.
func pan_by(delta: Vector2) -> void:
	_pan += delta
	if is_instance_valid(_board):
		_board.queue_redraw()


func _zoom_center(factor: float) -> void:
	if not is_instance_valid(_board):
		return
	zoom_at(_board.size * 0.5, factor)


## Fits the whole map in the board, which is what opening the page should show.
func _fit_view() -> void:
	if not is_instance_valid(_board):
		return
	if _board.size.x < 10.0 or _board.size.y < 10.0:
		await get_tree().process_frame
		if not is_instance_valid(_board):
			return
	var map_px := Vector2(_map_size) * Vector2(maxi(_tile_size.x, 1), maxi(_tile_size.y, 1))
	if map_px.x <= 0.0 or map_px.y <= 0.0:
		return
	var fit := minf(_board.size.x / map_px.x, _board.size.y / map_px.y) * 0.92
	_zoom = clampf(fit, MIN_ZOOM, MAX_ZOOM)
	_pan = (_board.size - map_px * _zoom) * 0.5
	_refresh_view()


## 100% zoom anchored at the top left, which is what a pixel artist wants when
## judging how big a tile really is.
func _zoom_one_to_one() -> void:
	_zoom = 1.0
	_pan = Vector2.ZERO
	_refresh_view()


func _refresh_view() -> void:
	_board.queue_redraw()
	if is_instance_valid(_zoom_label):
		_zoom_label.text = "%d%%" % int(round(_zoom * 100.0))
	_update_status()


#endregion


#region Board drawing


func draw_board(board: Control) -> void:
	board.draw_rect(Rect2(Vector2.ZERO, board.size), _board_color)
	var cell_px := _cell_pixels()
	if cell_px.x <= 0.0 or cell_px.y <= 0.0:
		return
	var bounds := _visible_bounds(board, cell_px)
	if bounds.is_empty():
		return
	var first: Vector2i = bounds["first"]
	var last: Vector2i = bounds["last"]
	# Checker under the tiles, so transparent cells read as empty.
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var color := CHECKER_LIGHT if (x + y) % 2 == 0 else CHECKER_DARK
			board.draw_rect(
				Rect2(_pan + Vector2(x, y) * cell_px, cell_px), color
			)
	var atlas := atlas_texture()
	if atlas != null:
		# Only the cells on screen are looked up, so a big map costs the same as
		# a small one instead of walking every painted cell on each redraw.
		for layer in _layers:
			if not bool(layer["visible"]):
				continue
			var cells: Dictionary = layer["cells"]
			for y in range(first.y, last.y + 1):
				for x in range(first.x, last.x + 1):
					var index := int(cells.get(Vector2i(x, y), 0))
					if index <= 0 or index >= _atlas_rects.size():
						continue
					board.draw_texture_rect_region(
						atlas,
						Rect2(_pan + Vector2(x, y) * cell_px, cell_px),
						Rect2(_atlas_rects[index])
					)
	board.draw_rect(
		Rect2(_pan, Vector2(_map_size) * cell_px), MAP_BORDER, false, 1.0
	)
	if _show_grid and cell_px.x >= 6.0:
		for x in range(first.x, last.x + 2):
			var px := _pan.x + x * cell_px.x
			board.draw_line(
				Vector2(px, _pan.y + first.y * cell_px.y),
				Vector2(px, _pan.y + (last.y + 1) * cell_px.y),
				GRID_COLOR,
				1.0
			)
		for y in range(first.y, last.y + 2):
			var py := _pan.y + y * cell_px.y
			board.draw_line(
				Vector2(_pan.x + first.x * cell_px.x, py),
				Vector2(_pan.x + (last.x + 1) * cell_px.x, py),
				GRID_COLOR,
				1.0
			)
	if _rect_active and _tool == TOOL_RECT:
		var rect := _rect_cells()
		board.draw_rect(
			Rect2(_pan + Vector2(rect.position) * cell_px, Vector2(rect.size) * cell_px),
			Color(1.0, 1.0, 1.0, 0.9),
			false,
			2.0
		)
	elif _rect_active and _tool == TOOL_LINE:
		board.draw_line(
			_pan + (Vector2(_rect_start) + Vector2(0.5, 0.5)) * cell_px,
			_pan + (Vector2(_rect_end) + Vector2(0.5, 0.5)) * cell_px,
			Color(1.0, 1.0, 1.0, 0.9),
			2.0
		)
	if _in_bounds(_hover):
		var hover_rect := Rect2(_pan + Vector2(_hover) * cell_px, cell_px)
		board.draw_rect(hover_rect, HOVER_COLOR, false, 2.0)
		# Coordinates next to the cursor save a lot of counting while editing.
		board.draw_string(
			ThemeDB.fallback_font,
			hover_rect.position + Vector2(2.0, -4.0),
			"%d,%d" % [_hover.x, _hover.y],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			12,
			Color(1.0, 1.0, 1.0, 0.75)
		)


## Range of cells inside the board, or an empty dictionary when the map is off
## screen. Only that range is drawn, so a large map stays cheap.
func _visible_bounds(board: Control, cell_px: Vector2) -> Dictionary:
	if _map_size.x <= 0 or _map_size.y <= 0:
		return {}
	var first := Vector2i(
		clampi(floori((-_pan.x) / cell_px.x), 0, _map_size.x - 1),
		clampi(floori((-_pan.y) / cell_px.y), 0, _map_size.y - 1)
	)
	var last := Vector2i(
		clampi(floori((board.size.x - _pan.x) / cell_px.x), 0, _map_size.x - 1),
		clampi(floori((board.size.y - _pan.y) / cell_px.y), 0, _map_size.y - 1)
	)
	if last.x < first.x or last.y < first.y:
		return {}
	return {"first": first, "last": last}


#endregion


#region Board input


func handle_board_input(board: Control, event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		match mouse.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mouse.pressed:
					zoom_at(mouse.position, 1.2)
					board.accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mouse.pressed:
					zoom_at(mouse.position, 1.0 / 1.2)
					board.accept_event()
			MOUSE_BUTTON_MIDDLE:
				_panning = mouse.pressed
				board.accept_event()
			MOUSE_BUTTON_LEFT:
				if Input.is_key_pressed(KEY_SPACE):
					_panning = mouse.pressed
				elif mouse.pressed:
					_begin_stroke(_board_cell(mouse.position))
				else:
					_end_stroke()
				board.accept_event()
			MOUSE_BUTTON_RIGHT:
				if mouse.pressed:
					_begin_stroke(_board_cell(mouse.position), true)
				else:
					_end_stroke()
				board.accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _panning:
			_pan += motion.relative
			board.queue_redraw()
		elif _stroke_active:
			_continue_stroke(_board_cell(motion.position))
		var hover := _board_cell(motion.position)
		if hover != _hover:
			_hover = hover
			board.queue_redraw()
		board.accept_event()


## Shortcuts are read here instead of in the unhandled pass, so the page keeps
## its own undo stack instead of undoing a project action underneath it.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if key.ctrl_pressed:
		match key.keycode:
			KEY_Z:
				_undo_step()
				get_viewport().set_input_as_handled()
			KEY_Y:
				_redo_step()
				get_viewport().set_input_as_handled()
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	match key.keycode:
		KEY_B:
			_select_tool(TOOL_PENCIL)
			get_viewport().set_input_as_handled()
		KEY_E:
			_select_tool(TOOL_ERASER)
			get_viewport().set_input_as_handled()
		KEY_G:
			_select_tool(TOOL_FILL)
			get_viewport().set_input_as_handled()
		KEY_R:
			_select_tool(TOOL_RECT)
			get_viewport().set_input_as_handled()
		KEY_L:
			_select_tool(TOOL_LINE)
			get_viewport().set_input_as_handled()
		KEY_I:
			_select_tool(TOOL_PICKER)
			get_viewport().set_input_as_handled()


func _select_tool(tool: int) -> void:
	_tool = clampi(tool, 0, TOOLS.size() - 1)
	for i in _tool_buttons.size():
		_tool_buttons[i].button_pressed = i == _tool
	_update_status()


#endregion


#region Files


func _make_file_dialog(title: String, mode: FileDialog.FileMode, filters: Array) -> FileDialog:
	var dialog := FileDialog.new()
	dialog.title = title
	dialog.file_mode = mode
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(filters)
	dialog.use_native_dialog = true
	add_child(dialog)
	return dialog


func _open_map_file() -> void:
	if not is_instance_valid(_map_open_dialog):
		_map_open_dialog = _make_file_dialog(
			"打开地图", FileDialog.FILE_MODE_OPEN_FILE, ["*.tmap ; Tilemap 地图"]
		)
		_map_open_dialog.file_selected.connect(_load_map)
	_map_open_dialog.popup_centered_ratio(0.6)


func _save_map_file() -> void:
	if not is_instance_valid(_map_save_dialog):
		_map_save_dialog = _make_file_dialog(
			"保存地图", FileDialog.FILE_MODE_SAVE_FILE, ["*.tmap ; Tilemap 地图"]
		)
		_map_save_dialog.file_selected.connect(_save_map)
	_map_save_dialog.current_file = "tilemap.tmap"
	_map_save_dialog.popup_centered_ratio(0.6)


func _export_png() -> void:
	if not is_instance_valid(_png_dialog):
		_png_dialog = _make_file_dialog(
			"导出地图 PNG", FileDialog.FILE_MODE_SAVE_FILE, ["*.png ; PNG 图片"]
		)
		_png_dialog.file_selected.connect(_save_png)
	_png_dialog.current_file = "tilemap.png"
	_png_dialog.popup_centered_ratio(0.6)


func _save_png(path: String) -> void:
	var image := _render_map()
	if image == null or image.is_empty():
		Global.notification_label("地图是空的，没有可以导出的图块")
		return
	var error := image.save_png(path)
	if error != OK:
		Global.notification_label("保存 PNG 失败（错误 %d）" % error)
		return
	Global.notification_label("已导出 %s" % path.get_file())


## Renders the map into a new pixel layer of the current frame, as one undo
## step. This is the way back: the drawing area can feed the palette, and the
## finished map can go back into the drawing area.
func _add_map_as_layer() -> void:
	var project := Global.current_project
	if project == null:
		Global.notification_label("还没有打开的项目")
		return
	var image := _render_map()
	if image == null or image.is_empty():
		Global.notification_label("地图是空的，先放几块图块")
		return
	if project.frames.is_empty():
		Global.notification_label("项目里没有可以放图的帧")
		return
	var layer := PixelLayer.new(project, "Tilemap")
	var cels: Array = []
	for f in project.frames.size():
		cels.append(layer.new_empty_cel())
	var frame_index := clampi(project.current_frame, 0, project.frames.size() - 1)
	var cel: BaseCel = cels[frame_index]
	if cel is PixelCel:
		(cel as PixelCel).image = _make_cel_image(image, project)
		cel.update_texture()
	var current_layer: BaseLayer = project.layers[
		clampi(project.current_layer, 0, project.layers.size() - 1)
	]
	layer.parent = current_layer.parent
	var new_layer_index := project.current_layer + 1
	project.undo_redo.create_action("Add Tilemap Layer")
	project.undo_redo.add_do_method(project.add_layers.bind([layer], [new_layer_index], [cels]))
	project.undo_redo.add_undo_method(project.remove_layers.bind([new_layer_index]))
	project.undo_redo.add_do_method(project.change_cel.bind(-1, new_layer_index))
	project.undo_redo.add_undo_method(project.change_cel.bind(-1, project.current_layer))
	project.undo_redo.add_do_method(Global.undo_or_redo.bind(false))
	project.undo_redo.add_undo_method(Global.undo_or_redo.bind(true))
	project.undo_redo.commit_action()
	Global.notification_label("地图已作为「Tilemap」图层加入当前帧")
	close_page()


## Cel image of the project. Indexed projects need the palette conversion and
## the transparency restored afterwards, exactly like the node editor does.
static func _make_cel_image(image: Image, project: Project) -> ImageExtended:
	var result := ImageExtended.create_from_image(image, project.is_indexed())
	if result.is_indexed:
		result.convert_rgb_to_indexed()
		for y in result.get_height():
			for x in result.get_width():
				if image.get_pixel(x, y).a < 0.5:
					result.set_pixel(x, y, Color(0, 0, 0, 0))
	return result


## Renders every visible layer into one picture at map size, which is what both
## the PNG export and the map preview need.
func _render_map() -> Image:
	var map_px := _map_size * _tile_size
	if map_px.x <= 0 or map_px.y <= 0:
		return null
	var image := Image.create_empty(map_px.x, map_px.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var empty := true
	for layer in _layers:
		if not bool(layer["visible"]):
			continue
		var cells: Dictionary = layer["cells"]
		for cell: Vector2i in cells:
			if cell.x < 0 or cell.y < 0 or cell.x >= _map_size.x or cell.y >= _map_size.y:
				continue
			var index := int(cells[cell])
			if index <= 0 or index >= _tiles.size():
				continue
			var tile: Image = _tiles[index]
			if tile == null:
				continue
			if tile.get_size() != _tile_size:
				tile = tile.duplicate() as Image
				tile.resize(_tile_size.x, _tile_size.y, Image.INTERPOLATE_NEAREST)
			image.blend_rect(tile, Rect2i(Vector2i.ZERO, _tile_size), cell * _tile_size)
			empty = false
	if empty:
		return null
	return image


## The map as plain data, which is what the .tmap file stores and what the Game
## page imports directly when both pages are open. An empty dictionary means
## nothing has been designed yet.
func map_data() -> Dictionary:
	var has_cells := false
	for layer in _layers:
		if not (layer["cells"] as Dictionary).is_empty():
			has_cells = true
			break
	if not has_cells:
		return {}
	var data := {
		"version": 2,
		"map_size": [_map_size.x, _map_size.y],
		"tile_size": [_tile_size.x, _tile_size.y],
		"layer_serial": _layer_serial,
		"layers": [],
		"atlas": "",
		"atlas_rects": [],
		"atlas_frames": _tile_anim.encoded_frames(),
		"anim_fps": _tile_anim.fps,
	}
	if _atlas_image != null:
		data["atlas"] = Marshalls.raw_to_base64(_atlas_image.save_png_to_buffer())
	for i in range(1, _atlas_rects.size()):
		var rect: Rect2i = _atlas_rects[i]
		data["atlas_rects"].append([rect.position.x, rect.position.y, rect.size.x, rect.size.y])
	for layer in _layers:
		var cells := {}
		var source: Dictionary = layer["cells"]
		for cell: Vector2i in source:
			cells["%d,%d" % [cell.x, cell.y]] = int(source[cell])
		data["layers"].append(
			{"name": layer["name"], "visible": layer["visible"], "cells": cells}
		)
	return data


func _save_map(path: String) -> void:
	var data := map_data()
	if data.is_empty():
		Global.notification_label("地图还是空的，先放几块图块")
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		Global.notification_label("写不了这个位置")
		return
	file.store_string(JSON.stringify(data))
	Global.notification_label("已保存 %s" % path.get_file())


func _load_map(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		Global.notification_label("这不是有效的地图文件")
		return
	if _apply_map_dictionary(parsed):
		Global.notification_label("已打开 %s" % path.get_file())


## Turns map data into the live map. The open dialog, the project restore and the
## Game page all land here, so they share one parser.
func _apply_map_dictionary(data: Dictionary) -> bool:
	var map_size = data.get("map_size", [30, 20])
	var tile_size = data.get("tile_size", [16, 16])
	_map_size = Vector2i(
		clampi(int(map_size[0]), MAP_MIN, MAP_MAX), clampi(int(map_size[1]), MAP_MIN, MAP_MAX)
	)
	_tile_size = Vector2i(
		clampi(int(tile_size[0]), TILE_MIN, TILE_MAX),
		clampi(int(tile_size[1]), TILE_MIN, TILE_MAX)
	)
	# The atlas travels with the file, so the map opens with its own tiles even
	# when the project has no matching tileset.
	_atlas_image = null
	_atlas_texture = null
	_atlas_rects.clear()
	_atlas_rects.append(Rect2i())
	_tiles.clear()
	_tiles.append(null)
	var atlas_data := str(data.get("atlas", ""))
	if not atlas_data.is_empty():
		var bytes := Marshalls.base64_to_raw(atlas_data)
		var atlas := Image.new()
		if not bytes.is_empty() and atlas.load_png_from_buffer(bytes) == OK:
			if atlas.get_format() != Image.FORMAT_RGBA8:
				atlas.convert(Image.FORMAT_RGBA8)
			_atlas_image = atlas
			_atlas_texture = ImageTexture.create_from_image(atlas)
			var rects: Array = data.get("atlas_rects", [])
			for rect_data in rects:
				var rect := Rect2i(
					int(rect_data[0]), int(rect_data[1]), int(rect_data[2]), int(rect_data[3])
				)
				if rect.size.x <= 0 or rect.size.y <= 0:
					_atlas_rects.append(Rect2i())
					_tiles.append(null)
					continue
				_atlas_rects.append(rect)
				_tiles.append(atlas.get_region(rect))
	# Animated tiles travel as extra atlas frames next to the base atlas.
	_tile_anim.restore(_atlas_image, data.get("atlas_frames", []), _atlas_rects)
	_tile_anim.fps = clampf(float(data.get("anim_fps", 6.0)), 1.0, 24.0)
	if is_instance_valid(_anim_fps_slider):
		_anim_fps_slider.set_value_no_signal(_tile_anim.fps)
	_layers.clear()
	var layers: Array = data.get("layers", [])
	for layer_data in layers:
		var cells := {}
		var raw: Dictionary = layer_data.get("cells", {})
		for key in raw:
			var parts := str(key).split(",")
			if parts.size() != 2:
				continue
			cells[Vector2i(int(parts[0]), int(parts[1]))] = int(raw[key])
		_layers.append(
			{
				"name": str(layer_data.get("name", "图层")),
				"visible": bool(layer_data.get("visible", true)),
				"cells": cells,
			}
		)
	if _layers.is_empty():
		_append_layer()
	_current_layer = 0
	_layer_serial = maxi(int(data.get("layer_serial", _layers.size())), _layers.size())
	_source_image = null
	_source_name = ""
	_slice_button.disabled = true
	_set_tile_size_enabled(false)
	_sync_slider_row(_tile_w, _tile_w_readout, _tile_size.x)
	_sync_slider_row(_tile_h, _tile_h_readout, _tile_size.y)
	_selected_tile = 1
	_undo.clear()
	_redo.clear()
	_refresh_tileset_options()
	_refresh_palette()
	_refresh_layers()
	_refresh_all()
	_fit_view()
	return true


## The Tilemap page keeps its work inside the project file. Only the data that
## takes real effort (the map, the animated frames, the board colour) is stored.
func save_state() -> Dictionary:
	var state := {
		"board_color": _board_color.to_html(),
		"show_grid": _show_grid,
		"anim_playing": _tile_anim.playing,
	}
	var map := map_data()
	if not map.is_empty():
		state["map"] = map
	return state


## Called when a project is opened, or the page is created for one. An empty
## state means the project never used this page, so the page keeps its default.
func load_state(state: Dictionary) -> void:
	if state.is_empty():
		# A project that never used this page must not show the previous
		# project's level, so the page starts from a clean map.
		_reset_map()
		_tiles.clear()
		_tiles.append(null)
		_atlas_image = null
		_atlas_texture = null
		_atlas_rects.clear()
		_atlas_rects.append(Rect2i())
		_tile_anim.clear()
		_source_image = null
		_source_name = ""
		_source_frames.clear()
		_refresh_palette()
		_refresh_all()
		if is_instance_valid(_board):
			_board.queue_redraw()
		return
	var color_html := str(state.get("board_color", ""))
	if not color_html.is_empty():
		_set_board_color(Color(color_html))
	_show_grid = bool(state.get("show_grid", _show_grid))
	if is_instance_valid(_grid_button):
		_grid_button.set_pressed_no_signal(_show_grid)
	_tile_anim.playing = bool(state.get("anim_playing", true))
	var map: Dictionary = state.get("map", {})
	if not map.is_empty():
		_apply_map_dictionary(map)
	if is_instance_valid(_board):
		_board.queue_redraw()
	_update_status()


#endregion


#region Refresh


func _refresh_all() -> void:
	_sync_map_size_sliders()
	_refresh_layers()
	_refresh_history_buttons()
	_refresh_palette()
	_set_tile_size_enabled(_source_image != null)
	_sync_slider_row(_tile_w, _tile_w_readout, _tile_size.x)
	_sync_slider_row(_tile_h, _tile_h_readout, _tile_size.y)
	if is_instance_valid(_board):
		_board.queue_redraw()
	_update_status()


func _sync_map_size_sliders() -> void:
	_sync_slider_row(_size_cols, _size_cols_readout, _map_size.x)
	_sync_slider_row(_size_rows, _size_rows_readout, _map_size.y)


func _update_status() -> void:
	if not is_instance_valid(_status):
		return
	# The subtitle repeats the headline numbers, so the header answers "what am
	# I editing" without reading the status line.
	if is_instance_valid(_subtitle):
		var source := "未载入图块"
		if tile_count() > 0:
			source = "%d 块图块" % tile_count()
			if not _source_name.is_empty():
				source = "%s · %s" % [_source_name, source]
		var zoom_pct := int(round(_zoom * 100.0))
		var anim_text := ""
		if _tile_anim.frame_count() > 1:
			anim_text = " · 动画 %d 帧 @ %d fps" % [
				_tile_anim.frame_count(), int(round(_tile_anim.fps))
			]
		_subtitle.text = "%s · 地图 %d×%d · 图块 %d×%d px · 缩放 %d%%%s" % [
			source, _map_size.x, _map_size.y, _tile_size.x, _tile_size.y, zoom_pct, anim_text
		]
	var pending := ""
	if is_instance_valid(_size_cols) and is_instance_valid(_size_rows):
		var target := Vector2i(
			clampi(int(round(_size_cols.value)), MAP_MIN, MAP_MAX),
			clampi(int(round(_size_rows.value)), MAP_MIN, MAP_MAX)
		)
		if target != _map_size:
			pending = "（待改 %d×%d）" % [target.x, target.y]
	var layer_text := "无图层"
	var placed := 0
	if _current_layer >= 0 and _current_layer < _layers.size():
		layer_text = str(_layers[_current_layer]["name"])
		placed = (_layers[_current_layer]["cells"] as Dictionary).size()
	var palette_text := "无图块"
	if _tiles.size() > 1:
		palette_text = "图块 %d/%d" % [_selected_tile, _tiles.size() - 1]
	_status.text = (
		"地图 %d×%d%s · 图块 %d×%d px · 缩放 %d%% · %s · 已放 %d 格 · 工具 %s · %s"
		% [
			_map_size.x,
			_map_size.y,
			pending,
			_tile_size.x,
			_tile_size.y,
			int(round(_zoom * 100.0)),
			layer_text,
			placed,
			TOOLS[clampi(_tool, 0, TOOLS.size() - 1)],
			palette_text,
		]
	)


#endregion


