extends Panel
## Small game playground. It takes a map designed in the Tilemap page (or a
## .tmap file) and the frames of the drawing area, then lets a hero walk, jump
## and land on the tiles with a simple platformer physics step.
##
## All of it is page local: nothing is written into the project, so trying a
## level never changes the artwork.

signal page_closed

const FrameComposer := preload("res://src/Classes/ProjectFrameComposer.gd")
const TileAnimationScript := preload("res://src/Classes/TileAnimation.gd")

const TOUCH_SIZE := 40
const TOUCH_FONT_SIZE := 15
## Below this width the controls move under the world instead of beside it.
const NARROW_WIDTH := 760
## How long a jump press is remembered before landing, in seconds.
const COYOTE_TIME := 0.1
const JUMP_BUFFER := 0.12
## Fall speed cap, in tiles per second.
const MAX_FALL_TILES := 40.0
## Scene editing modes. One at a time, so a click always has one meaning.
const MODE_NONE := 0
const MODE_SPRITE := 1
const MODE_SOLID := 2
const MODE_SPAWN := 3

var _board
var _body: GridContainer
var _side_panel: Control
var _status: Label
var _play_button: Button
var _sprite_mode_button: Button
var _solid_mode_button: Button
var _spawn_mode_button: Button
var _collision_button: Button
## Header and tools bar, hidden together in the immersive view.
var _header_bar: Control
var _tools_bar: Control
var _overlay_exit: Button
var _immersive := false

## Map, decoded from the Tilemap page data. The picture is composed once, so a
## frame only draws one texture.
var _layers: Array[Dictionary] = []
var _map_size := Vector2i.ZERO
var _tile_size := Vector2i(16, 16)
var _atlas_image: Image
var _atlas_rects: Array[Rect2i] = [Rect2i()]
## Animated tiles: extra atlas frames that the map may carry, plus their clock.
var _tile_anim = TileAnimationScript.new()
## Last imported map data, kept so the scene can be saved inside the project.
var _map_source: Dictionary = {}
var _solid: Dictionary = {}
var _map_image: Image
var _map_texture: ImageTexture

## Frames of the drawing area, used for the hero animation and for placed
## sprites.
var _frames: Array[Image] = []
var _frame_textures: Array[ImageTexture] = []
var _frame_time := 0.0
var _frame_index := 0

var _player_pos := Vector2.ZERO
var _player_velocity := Vector2.ZERO
var _on_ground := false
var _coyote := 0.0
var _jump_buffer := 0.0
var _jump_held := false
var _facing := 1.0

## Placed frame images: {"cell": Vector2i, "size": float, "texture": ImageTexture}.
var _decorations: Array[Dictionary] = []
## Solid blocks added in the game page, cell -> tile index (0 = plain block).
var _placed_solids: Dictionary = {}
## Tile used for new solid blocks, from the imported atlas.
var _brush_tile := 1
var _brush_strip: HFlowContainer
var _brush_atlas_texture: ImageTexture
## One AtlasTexture per tile, shared by the strip buttons and the map drawing.
var _brush_textures: Array[AtlasTexture] = []
## Where the hero appears. (-1, -1) means "find a free spot on the map".
var _spawn_cell := Vector2i(-1, -1)
var _edit_mode := MODE_NONE

var _hero_tiles := 1.0
var _fps := 8.0
var _move_speed := 6.0
var _jump_speed := 9.0
var _gravity := 28.0

var _scale := 1.0
## Multiplier over the "fit the whole map" scale, so a big level can be zoomed
## in on. 1.0 is exactly the fitted view.
var _view_zoom := 1.0
var _origin := Vector2.ZERO
var _playing := true
## When true only the top visible layer collides, so background art can be
## shown without blocking the hero.
var _top_layer_only := false
var _can_draw_before := true
var _status_accum := 0.0

## Immersion: smooth camera, landing shake, squash and dust particles.
var _elapsed := 0.0
var _camera_center := Vector2.ZERO
var _shake := 0.0
var _squash := 0.0
var _particles: Array[Dictionary] = []
var _dust_timer := 0.0

## Analog direction from the on screen wheel: -1 is full left, 1 is full
## right. A light push walks, a full push runs.
var _touch_axis := 0.0
var _touch_jump := false
## On screen stick buttons drawn over the world, so a phone needs no keyboard.
var _touch_pad
var _touch_buttons_visible := false
var _touch_toggle: Button

## Gamepad state, polled once per frame while the page is visible.
var _pad_axis := 0.0
var _pad_jump := false
var _pad_name := ""
var _pad_pause_held := false
var _pad_reset_held := false
var _pad_zoom_in_held := false
var _pad_zoom_out_held := false

## Scene look: a two stop gradient behind the map, both stops chosen by the
## user from the side panel.
var _backdrop_top := Color(0.11, 0.13, 0.22)
var _backdrop_bottom := Color(0.03, 0.04, 0.07)
var _backdrop_top_picker: ColorPickerButton
var _backdrop_bottom_picker: ColorPickerButton
## One tap themes, so a nice background needs no colour hunting.
var _backdrop_presets := [
	{"name": "夜色", "top": Color(0.11, 0.13, 0.22), "bottom": Color(0.03, 0.04, 0.07)},
	{"name": "黄昏", "top": Color(0.45, 0.24, 0.33), "bottom": Color(0.12, 0.07, 0.13)},
	{"name": "森林", "top": Color(0.1, 0.26, 0.19), "bottom": Color(0.02, 0.07, 0.05)},
	{"name": "深海", "top": Color(0.06, 0.2, 0.33), "bottom": Color(0.01, 0.03, 0.09)},
	{"name": "纸白", "top": Color(0.93, 0.94, 0.97), "bottom": Color(0.7, 0.75, 0.84)},
]

var _map_dialog: FileDialog


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Phones and tablets open with the on screen controls already on; a desktop
	# can switch them on from the toolbar to try them with the mouse.
	_touch_buttons_visible = (
		DisplayServer.is_touchscreen_available()
		or OS.has_feature("mobile")
		or OS.has_feature("web_android")
		or OS.has_feature("web_ios")
	)
	_build_ui()
	_sync_touch_buttons()
	resized.connect(_apply_layout)
	_apply_layout()
	hide()


#region Lifecycle


func open_page() -> void:
	if not visible:
		_can_draw_before = Global.can_draw
	Global.can_draw = false
	_playing = true
	_view_zoom = 1.0
	_sync_play_button()
	_reload_frames()
	if _map_texture == null:
		_import_from_tilemap(true)
	_reset_player()
	show()
	update_view()
	_update_status()


func close_page() -> void:
	if not visible:
		return
	_playing = false
	_clear_input()
	Global.can_draw = _can_draw_before
	hide()
	page_closed.emit()


func is_open() -> bool:
	return visible


## Keeps the map and the hero where they are, and stops the simulation, so
## switching tabs is cheap.
func pause_page() -> void:
	if not visible:
		return
	_clear_input()
	Global.can_draw = _can_draw_before
	hide()


func resume_page() -> void:
	Global.can_draw = false
	show()
	update_view()
	_update_status()


#endregion


#region UI


func _apply_layout() -> void:
	if not is_instance_valid(_body):
		return
	var narrow := size.x < NARROW_WIDTH or _immersive
	_body.columns = 1 if narrow else 2
	if is_instance_valid(_side_panel):
		_side_panel.custom_minimum_size.x = 0.0 if narrow else 250.0


func _build_ui() -> void:
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.09, 0.1, 0.12)
	add_theme_stylebox_override("panel", background)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)
	_header_bar = _build_header()
	_tools_bar = _build_tools()
	root.add_child(_header_bar)
	root.add_child(_tools_bar)
	_body = GridContainer.new()
	_body.columns = 2
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("h_separation", 8)
	_body.add_theme_constant_override("v_separation", 8)
	root.add_child(_body)
	_body.add_child(_build_world_column())
	_side_panel = _build_side_panel()
	_body.add_child(_side_panel)


func _build_header() -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	var title := Label.new()
	title.text = "游戏试玩"
	title.add_theme_font_size_override("font_size", 17)
	row.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(
		_make_button(
			"用 Tilemap 页地图",
			func() -> void: _import_from_tilemap(false),
			"直接读取 Tilemap 页正在设计的地图"
		)
	)
	row.add_child(_make_button("导入地图…", _open_map_dialog, "读取保存过的 .tmap 地图"))
	row.add_child(_make_button("重新取帧", _reload_frames, "重新读取绘画区的帧图片与帧动画"))
	row.add_child(_make_button("关闭", close_page, "回到绘画页"))
	return row


func _build_tools() -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	_play_button = _make_button("暂停", _toggle_play, "暂停或继续物理与动画")
	row.add_child(_play_button)
	row.add_child(
		_make_button("−", func() -> void: zoom_view(1.0 / 1.2), "缩小视图", Vector2(34, TOUCH_SIZE))
	)
	row.add_child(
		_make_button("＋", func() -> void: zoom_view(1.2), "放大视图", Vector2(34, TOUCH_SIZE))
	)
	row.add_child(_make_button("适应视图", _fit_view, "把整张地图放进窗口"))
	_sprite_mode_button = _make_button(
		"放置精灵", _toggle_sprite_mode, "打开后左键放置当前帧，右键删除"
	)
	_sprite_mode_button.toggle_mode = true
	row.add_child(_sprite_mode_button)
	_solid_mode_button = _make_button(
		"放置实心块", _toggle_solid_mode, "左键加一块可站立的实心块，右键删除"
	)
	_solid_mode_button.toggle_mode = true
	row.add_child(_solid_mode_button)
	_spawn_mode_button = _make_button(
		"设置出生点", _toggle_spawn_mode, "左键点一格作为出生点，右键清除"
	)
	_spawn_mode_button.toggle_mode = true
	row.add_child(_spawn_mode_button)
	row.add_child(_make_button("清空场景", _clear_scene, "删除所有放置的精灵与实心块"))
	row.add_child(_make_button("重置主角", _reset_player, "把主角放回出生点"))
	_collision_button = _make_button("显示碰撞", Callable(), "把实心图块半透明标出来")
	_collision_button.toggle_mode = true
	_collision_button.toggled.connect(
		func(_on: bool) -> void:
			if is_instance_valid(_board):
				_board.queue_redraw()
	)
	row.add_child(_collision_button)
	_touch_toggle = _make_button(
		"触屏按键", _toggle_touch_buttons, "在画面底部显示方向转轮与跳跃按钮"
	)
	_touch_toggle.toggle_mode = true
	_touch_toggle.button_pressed = _touch_buttons_visible
	row.add_child(_touch_toggle)
	row.add_child(_make_button("沉浸", _toggle_immersive, "隐藏工具栏和侧栏，只看画面；Esc 或再点一次退出"))
	return row


## Shows or hides the on screen buttons. They are off on a desktop unless the
## user asks for them, and on by default on a phone.
func _toggle_touch_buttons() -> void:
	_set_touch_buttons(is_instance_valid(_touch_toggle) and _touch_toggle.button_pressed)


func _set_touch_buttons(on: bool) -> void:
	_touch_buttons_visible = on
	if is_instance_valid(_touch_toggle):
		_touch_toggle.set_pressed_no_signal(on)
	_sync_touch_buttons()


func _sync_touch_buttons() -> void:
	if not is_instance_valid(_touch_pad):
		return
	_touch_pad.visible = _touch_buttons_visible
	if not _touch_buttons_visible:
		_touch_pad.call("release_all")


func touch_controls_shown() -> bool:
	return (
		_touch_buttons_visible
		and is_instance_valid(_touch_pad)
		and _touch_pad.visible
	)


## Called by the on screen wheel. [param axis] is analog, so the hero walks
## near the centre of the wheel and runs near its edge; a second finger on the
## jump button works at the same time.
func set_touch_axis(axis: float, jump: bool) -> void:
	_touch_axis = clampf(axis, -1.0, 1.0)
	_touch_jump = jump


func _over_touch_controls(position: Vector2) -> bool:
	return touch_controls_shown() and _touch_pad.call("role_at", position) != ""


## Drops every held input when the page is hidden, so a key, a finger or a pad
## button that is still down cannot make the hero walk on its own later.
func _clear_input() -> void:
	_touch_axis = 0.0
	_touch_jump = false
	_pad_axis = 0.0
	_pad_jump = false
	_pad_pause_held = false
	_pad_reset_held = false
	_pad_zoom_in_held = false
	_pad_zoom_out_held = false
	if is_instance_valid(_touch_pad):
		_touch_pad.call("release_all")


func _build_world_column() -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	_board = Board.new()
	_board.page = self
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_board.custom_minimum_size = Vector2(240, 200)
	column.add_child(_board)
	# The on screen buttons live on top of the world, so a phone plays with the
	# thumbs where the action is instead of reaching for the side panel.
	_touch_pad = TouchPad.new()
	_touch_pad.page = self
	_board.add_child(_touch_pad)
	_touch_pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_touch_pad.visible = false
	# Only shown in the immersive view, where the toolbar is hidden.
	_overlay_exit = _make_button(
		"退出沉浸", func() -> void: _set_immersive(false), "重新显示工具栏和侧栏"
	)
	_board.add_child(_overlay_exit)
	_overlay_exit.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_overlay_exit.offset_left = -130.0
	_overlay_exit.offset_top = 10.0
	_overlay_exit.offset_right = -10.0
	_overlay_exit.offset_bottom = 50.0
	_overlay_exit.visible = false
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 13)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	return column


func _build_side_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(250, 0)
	panel.add_theme_constant_override("separation", 6)
	panel.add_child(_section_label("主角"))
	var hero_row := _make_slider_row(
		"大小", 1.0, 4.0, _hero_tiles, func(value: float) -> void: _hero_tiles = value
	)
	panel.add_child(hero_row["row"])
	var fps_row := _make_slider_row(
		"帧率", 1.0, 24.0, _fps, func(value: float) -> void: _fps = value
	)
	panel.add_child(fps_row["row"])
	panel.add_child(_section_label("物理"))
	var speed_row := _make_slider_row(
		"移动", 1.0, 16.0, _move_speed, func(value: float) -> void: _move_speed = value
	)
	panel.add_child(speed_row["row"])
	var jump_row := _make_slider_row(
		"跳跃", 2.0, 20.0, _jump_speed, func(value: float) -> void: _jump_speed = value
	)
	panel.add_child(jump_row["row"])
	var gravity_row := _make_slider_row(
		"重力", 4.0, 60.0, _gravity, func(value: float) -> void: _gravity = value
	)
	panel.add_child(gravity_row["row"])
	var solid_check := CheckBox.new()
	solid_check.text = "只用最上层碰撞"
	solid_check.tooltip_text = "背景层只显示不挡路；打开后只在最上面的可见图层上碰撞"
	solid_check.button_pressed = _top_layer_only
	solid_check.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	solid_check.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	solid_check.toggled.connect(
		func(on: bool) -> void:
			_top_layer_only = on
			_rebuild_solid()
			if _collides(_hero_rect()):
				_reset_player()
			if is_instance_valid(_board):
				_board.queue_redraw()
			_update_status()
	)
	panel.add_child(solid_check)
	panel.add_child(_section_label("实心块"))
	var brush_scroll := ScrollContainer.new()
	brush_scroll.custom_minimum_size = Vector2(0, 90)
	brush_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(brush_scroll)
	_brush_strip = HFlowContainer.new()
	_brush_strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_brush_strip.add_theme_constant_override("h_separation", 4)
	_brush_strip.add_theme_constant_override("v_separation", 4)
	brush_scroll.add_child(_brush_strip)
	panel.add_child(_section_label("背景"))
	var backdrop_row := HBoxContainer.new()
	backdrop_row.add_theme_constant_override("separation", 10)
	panel.add_child(backdrop_row)
	_add_backdrop_color_row(backdrop_row, "顶部", _backdrop_top, true)
	_add_backdrop_color_row(backdrop_row, "底部", _backdrop_bottom, false)
	var preset_row := HFlowContainer.new()
	preset_row.add_theme_constant_override("h_separation", 4)
	preset_row.add_theme_constant_override("v_separation", 4)
	for preset: Dictionary in _backdrop_presets:
		var chosen: Dictionary = preset
		preset_row.add_child(
			_make_button(
				str(chosen["name"]),
				func() -> void: _apply_backdrop_preset(chosen),
				"一键换成这个背景色",
				Vector2(0, TOUCH_SIZE)
			)
		)
	panel.add_child(preset_row)
	panel.add_child(_section_label("操作"))
	var hint := Label.new()
	hint.text = (
		"键盘：A/D 或 ←/→ 移动，空格/W/↑ 跳跃，R 重置主角，F 切换沉浸，Esc 退出沉浸\n"
		+ "手柄：左摇杆/十字键移动，A 或 ↑ 跳跃，START 暂停，"
		+ "BACK 或 Y 重置，LB/RB 缩放\n"
		+ "触屏：工具栏打开「触屏按键」后，左下是方向转轮（按住拖动，"
		+ "推得越远跑得越快），右下是跳跃；两指捏合缩放。\n"
		+ "搭场景：工具栏选「放置精灵 / 放置实心块 / 设置出生点」（快捷键 1/2/3），"
		+ "左键放置、右键删除；实心块的样子从上面的图块条里选。\n"
		+ "背景：点「顶部 / 底部」色块自己挑渐变两端的颜色，"
		+ "或直接点夜色、黄昏、森林、深海、纸白一键换。"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1.0, 1.0, 1.0, 0.65)
	panel.add_child(hint)
	return panel


func _section_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	return label


## Swatch button that opens the engine colour picker, so a background colour can
## be chosen without typing anything.
func _add_backdrop_color_row(
	parent: Control, title: String, color: Color, is_top: bool
) -> void:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = title
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	box.add_child(label)
	var picker := ColorPickerButton.new()
	picker.color = color
	picker.edit_alpha = false
	picker.focus_mode = Control.FOCUS_NONE
	picker.custom_minimum_size = Vector2(58, TOUCH_SIZE)
	picker.tooltip_text = "点击选%s颜色" % title
	picker.color_changed.connect(
		func(new_color: Color) -> void: _set_backdrop_color(is_top, new_color)
	)
	box.add_child(picker)
	if is_top:
		_backdrop_top_picker = picker
	else:
		_backdrop_bottom_picker = picker
	parent.add_child(box)


func _set_backdrop_color(is_top: bool, color: Color) -> void:
	if is_top:
		_backdrop_top = color
	else:
		_backdrop_bottom = color
	if is_instance_valid(_board):
		_board.queue_redraw()


## One tap theme: both stops at once, and the swatches follow.
func _apply_backdrop_preset(preset: Dictionary) -> void:
	_backdrop_top = preset["top"]
	_backdrop_bottom = preset["bottom"]
	_sync_backdrop_pickers()
	if is_instance_valid(_board):
		_board.queue_redraw()


func _sync_backdrop_pickers() -> void:
	if is_instance_valid(_backdrop_top_picker):
		_backdrop_top_picker.color = _backdrop_top
	if is_instance_valid(_backdrop_bottom_picker):
		_backdrop_bottom_picker.color = _backdrop_bottom


## Slider row with arrows and a read-only number, the same shape used by the
## other pages so nothing has to be typed on a phone.
func _make_slider_row(
	title: String, min_value: float, max_value: float, value: float, on_changed: Callable
) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(32, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = 1
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(60, TOUCH_SIZE)
	row.add_child(
		_make_button(
			"−", func() -> void: _step_slider(slider, -1.0), "减一", Vector2(34, TOUCH_SIZE)
		)
	)
	row.add_child(slider)
	row.add_child(
		_make_button(
			"+", func() -> void: _step_slider(slider, 1.0), "加一", Vector2(34, TOUCH_SIZE)
		)
	)
	var readout := Label.new()
	readout.custom_minimum_size = Vector2(34, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	readout.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	readout.text = str(int(round(value)))
	row.add_child(readout)
	slider.value_changed.connect(
		func(new_value: float) -> void:
			readout.text = str(int(round(new_value)))
			on_changed.call(new_value)
			_update_status()
	)
	return {"row": row, "slider": slider, "readout": readout}


func _step_slider(slider: HSlider, direction: float) -> void:
	var step := maxf(slider.step, 0.0001)
	slider.value = clampf(
		snappedf(slider.value + step * direction, step), slider.min_value, slider.max_value
	)


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


func _toggle_play() -> void:
	_playing = not _playing
	_sync_play_button()
	_update_status()


func _sync_play_button() -> void:
	if is_instance_valid(_play_button):
		_play_button.text = "暂停" if _playing else "继续"


func _toggle_sprite_mode() -> void:
	_set_edit_mode(
		MODE_SPRITE if is_instance_valid(_sprite_mode_button) and _sprite_mode_button.button_pressed else MODE_NONE
	)


func _toggle_solid_mode() -> void:
	_set_edit_mode(
		MODE_SOLID if is_instance_valid(_solid_mode_button) and _solid_mode_button.button_pressed else MODE_NONE
	)


func _toggle_spawn_mode() -> void:
	_set_edit_mode(
		MODE_SPAWN if is_instance_valid(_spawn_mode_button) and _spawn_mode_button.button_pressed else MODE_NONE
	)


## One editing mode at a time; the three toggle buttons follow it.
func _set_edit_mode(mode: int) -> void:
	_edit_mode = mode
	_sync_mode_buttons()
	_update_status()


func _sync_mode_buttons() -> void:
	if is_instance_valid(_sprite_mode_button):
		_sprite_mode_button.set_pressed_no_signal(_edit_mode == MODE_SPRITE)
	if is_instance_valid(_solid_mode_button):
		_solid_mode_button.set_pressed_no_signal(_edit_mode == MODE_SOLID)
	if is_instance_valid(_spawn_mode_button):
		_spawn_mode_button.set_pressed_no_signal(_edit_mode == MODE_SPAWN)


## Immersive view: the world keeps the whole page and only a small way back is
## left on screen.
func _toggle_immersive() -> void:
	_set_immersive(not _immersive)


func _set_immersive(on: bool) -> void:
	_immersive = on
	if is_instance_valid(_header_bar):
		_header_bar.visible = not on
	if is_instance_valid(_tools_bar):
		_tools_bar.visible = not on
	if is_instance_valid(_side_panel):
		_side_panel.visible = not on
	if is_instance_valid(_status):
		_status.visible = not on
	if is_instance_valid(_overlay_exit):
		_overlay_exit.visible = on
	_apply_layout()
	update_view()
	if is_instance_valid(_board):
		_board.queue_redraw()


#endregion


#region Sources


## Frames of the drawing area. One frame is a still picture, several of them are
## an animation, so the same control covers both cases.
func _reload_frames() -> void:
	_frames.clear()
	_frame_textures.clear()
	var project := Global.current_project
	if project != null:
		for index in project.frames.size():
			var image: Image = FrameComposer.frame_image(project, index)
			if image == null or image.is_empty():
				continue
			_frames.append(image)
			_frame_textures.append(ImageTexture.create_from_image(image))
	_frame_time = 0.0
	_frame_index = 0
	_update_status()


## Pulls the map from the Tilemap page, so a level can be tried without saving
## it first. The page hands over plain data, the same a .tmap file holds.
func _import_from_tilemap(quiet: bool) -> void:
	var parent := get_parent()
	var data: Dictionary = {}
	if parent != null and parent.has_method("tilemap_map_data"):
		data = parent.call("tilemap_map_data")
	if data.is_empty():
		if not quiet:
			Global.notification_label("Tilemap 页还没有可用的地图")
		return
	if apply_map_data(data) and not quiet:
		Global.notification_label("已导入 Tilemap 页的地图")


func _open_map_dialog() -> void:
	if not is_instance_valid(_map_dialog):
		_map_dialog = FileDialog.new()
		_map_dialog.title = "导入地图"
		_map_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_map_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_map_dialog.filters = PackedStringArray(["*.tmap ; Tilemap 地图"])
		_map_dialog.use_native_dialog = true
		_map_dialog.file_selected.connect(_load_map_file)
		add_child(_map_dialog)
	_map_dialog.popup_centered_ratio(0.6)


func _load_map_file(path: String) -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		Global.notification_label("这不是有效的地图文件")
		return
	if apply_map_data(parsed):
		Global.notification_label("已导入 %s" % path.get_file())


## Decodes the map data shared with the Tilemap page: sizes, atlas, layers and
## cells. Solid cells are the non-empty ones of every visible layer.
func apply_map_data(data: Dictionary) -> bool:
	var map_size: Array = data.get("map_size", [])
	var tile_size: Array = data.get("tile_size", [])
	if map_size.size() < 2 or tile_size.size() < 2:
		Global.notification_label("地图数据不完整")
		return false
	_map_size = Vector2i(maxi(int(map_size[0]), 1), maxi(int(map_size[1]), 1))
	_tile_size = Vector2i(maxi(int(tile_size[0]), 1), maxi(int(tile_size[1]), 1))
	# The scene keeps a copy of the imported map, so the project can carry the
	# whole level instead of depending on a .tmap file next to it.
	_map_source = data.duplicate(true)
	_atlas_image = null
	_atlas_rects.clear()
	_atlas_rects.append(Rect2i())
	var atlas_data := str(data.get("atlas", ""))
	if not atlas_data.is_empty():
		var bytes := Marshalls.base64_to_raw(atlas_data)
		var atlas := Image.new()
		if not bytes.is_empty() and atlas.load_png_from_buffer(bytes) == OK:
			if atlas.get_format() != Image.FORMAT_RGBA8:
				atlas.convert(Image.FORMAT_RGBA8)
			_atlas_image = atlas
			for rect_data in data.get("atlas_rects", []):
				_atlas_rects.append(
					Rect2i(
						int(rect_data[0]),
						int(rect_data[1]),
						int(rect_data[2]),
						int(rect_data[3])
					)
				)
	# Animated tiles: a map may carry extra atlas frames beside the base one.
	_tile_anim.restore(_atlas_image, data.get("atlas_frames", []), _atlas_rects)
	_tile_anim.fps = clampf(float(data.get("anim_fps", 6.0)), 1.0, 24.0)
	_layers.clear()
	for layer_data in data.get("layers", []):
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
		_layers.append({"name": "图层 1", "visible": true, "cells": {}})
	# A new map starts with a clean scene, so old blocks do not float over it.
	_decorations.clear()
	_placed_solids.clear()
	_spawn_cell = Vector2i(-1, -1)
	_rebuild_solid()
	_map_image = _compose_map_image()
	_map_texture = null
	if _map_image != null:
		_map_texture = ImageTexture.create_from_image(_map_image)
	_particles.clear()
	_shake = 0.0
	_squash = 0.0
	_view_zoom = 1.0
	_refresh_brush_strip()
	_reset_player()
	update_view()
	_update_status()
	return true


## Rebuilds the solid set from the layers. Every visible layer is used by
## default; with "only the top layer" a background can be drawn without the
## hero walking into it.
func _rebuild_solid() -> void:
	_solid.clear()
	var layers: Array = []
	if _top_layer_only:
		for index in range(_layers.size() - 1, -1, -1):
			if bool(_layers[index]["visible"]) and not (_layers[index]["cells"] as Dictionary).is_empty():
				layers.append(_layers[index])
				break
	else:
		for layer in _layers:
			if bool(layer["visible"]):
				layers.append(layer)
	for layer in layers:
		var cells: Dictionary = layer["cells"]
		for cell: Vector2i in cells:
			if int(cells[cell]) > 0:
				_solid[cell] = true
	# Blocks placed in the game page collide on top of the imported map.
	for cell: Vector2i in _placed_solids:
		_solid[cell] = true


## Draws every visible layer onto one picture at map size, once. Drawing the
## world is then a single texture instead of one quad per tile per frame.
func _compose_map_image() -> Image:
	var map_px := _map_size * _tile_size
	if map_px.x <= 0 or map_px.y <= 0:
		return null
	var image := Image.create_empty(map_px.x, map_px.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	if _atlas_image == null:
		return image
	for layer in _layers:
		if not bool(layer["visible"]):
			continue
		var cells: Dictionary = layer["cells"]
		for cell: Vector2i in cells:
			var index := int(cells[cell])
			if index <= 0 or index >= _atlas_rects.size():
				continue
			var rect: Rect2i = _atlas_rects[index]
			if rect.size.x <= 0 or rect.size.y <= 0:
				continue
			var source := Rect2i(
				rect.position,
				Vector2i(mini(rect.size.x, _tile_size.x), mini(rect.size.y, _tile_size.y))
			)
			image.blend_rect(_atlas_image, source, cell * _tile_size)
	return image


#endregion


#region Simulation


func _process(delta: float) -> void:
	if not visible:
		return
	_poll_gamepad()
	if not _playing:
		return
	_advance_animation(delta)
	if _map_texture != null:
		# Fixed small steps keep a fast fall from skipping over a one tile floor
		# and make the jump feel the same on a slow frame.
		var remaining := minf(delta, 0.1)
		while remaining > 0.0:
			var step := minf(remaining, 1.0 / 120.0)
			_tick_physics(step)
			remaining -= step
	_update_effects(delta)
	if _map_texture != null:
		update_view()
	_status_accum += delta
	if _status_accum >= 0.1:
		_status_accum = 0.0
		_update_status()
	if is_instance_valid(_board):
		_board.queue_redraw()


## Reads the first connected pad. Movement is polled every frame, the actions
## (pause, reset, zoom) only on the frame the button goes down, so holding START
## does not flip the pause every frame.
func _poll_gamepad() -> void:
	var pads := Input.get_connected_joypads()
	_pad_axis = 0.0
	_pad_jump = false
	if pads.is_empty():
		_pad_name = ""
		_pad_pause_held = false
		_pad_reset_held = false
		_pad_zoom_in_held = false
		_pad_zoom_out_held = false
		return
	var pad := int(pads[0])
	_pad_name = Input.get_joy_name(pad)
	var axis := Input.get_joy_axis(pad, JOY_AXIS_LEFT_X)
	if absf(axis) < 0.25:
		axis = 0.0
	var dpad := 0.0
	if Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_RIGHT):
		dpad += 1.0
	if Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_LEFT):
		dpad -= 1.0
	_pad_axis = dpad if dpad != 0.0 else axis
	_pad_jump = (
		Input.is_joy_button_pressed(pad, JOY_BUTTON_A)
		or Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_UP)
	)
	var pause := Input.is_joy_button_pressed(pad, JOY_BUTTON_START)
	if pause and not _pad_pause_held:
		_toggle_play()
	_pad_pause_held = pause
	var reset := (
		Input.is_joy_button_pressed(pad, JOY_BUTTON_BACK)
		or Input.is_joy_button_pressed(pad, JOY_BUTTON_Y)
	)
	if reset and not _pad_reset_held:
		_reset_player()
		_update_status()
	_pad_reset_held = reset
	var zoom_in := Input.is_joy_button_pressed(pad, JOY_BUTTON_RIGHT_SHOULDER)
	var zoom_out := Input.is_joy_button_pressed(pad, JOY_BUTTON_LEFT_SHOULDER)
	if zoom_in and not _pad_zoom_in_held:
		zoom_view(1.2)
	if zoom_out and not _pad_zoom_out_held:
		zoom_view(1.0 / 1.2)
	_pad_zoom_in_held = zoom_in
	_pad_zoom_out_held = zoom_out


func _advance_animation(delta: float) -> void:
	if _frame_textures.is_empty():
		return
	_frame_time += delta
	var fps := maxf(_fps, 0.1)
	_frame_index = int(_frame_time * fps) % _frame_textures.size()


## One platformer step: horizontal input with acceleration, jump with coyote
## time and a small buffer, gravity, then axis separated collision so a corner
## does not stop both directions.
func _tick_physics(delta: float) -> void:
	var tile := Vector2(maxi(_tile_size.x, 1), maxi(_tile_size.y, 1))
	var direction := _input_axis()
	var target := direction * _move_speed * tile.x
	var accel := 40.0 * tile.x
	if direction != 0.0:
		_player_velocity.x = move_toward(_player_velocity.x, target, accel * delta)
		_facing = signf(direction)
	else:
		_player_velocity.x = move_toward(_player_velocity.x, 0.0, accel * 0.7 * delta)

	var jump_down := _jump_held_input()
	if jump_down and not _jump_held:
		_jump_buffer = JUMP_BUFFER
	_jump_held = jump_down
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_coyote = maxf(_coyote - delta, 0.0)
	if _jump_buffer > 0.0 and (_on_ground or _coyote > 0.0):
		_player_velocity.y = -_jump_speed * tile.y
		_jump_buffer = 0.0
		_coyote = 0.0
		_on_ground = false
		_spawn_dust(_feet_position(), 3, Color(1.0, 1.0, 1.0, 0.4), tile.y * 1.4)
	if not jump_down and _player_velocity.y < 0.0:
		# Letting go of the jump early cuts it, so short hops are possible.
		_player_velocity.y = maxf(_player_velocity.y, -_jump_speed * tile.y * 0.45)

	_player_velocity.y += _gravity * tile.y * delta
	_player_velocity.y = minf(_player_velocity.y, MAX_FALL_TILES * tile.y)

	var size := tile * _hero_tiles
	_player_pos.x += _player_velocity.x * delta
	if _collides(Rect2(_player_pos, size)):
		if _player_velocity.x > 0.0:
			_player_pos.x = floorf((_player_pos.x + size.x) / tile.x) * tile.x - size.x
		elif _player_velocity.x < 0.0:
			_player_pos.x = (floorf(_player_pos.x / tile.x) + 1.0) * tile.x
		_player_velocity.x = 0.0

	var falling := _player_velocity.y > 0.0
	var impact := 0.0
	_player_pos.y += _player_velocity.y * delta
	_on_ground = false
	if _collides(Rect2(_player_pos, size)):
		if falling:
			impact = _player_velocity.y
			_player_pos.y = floorf((_player_pos.y + size.y) / tile.y) * tile.y - size.y
			_on_ground = true
		else:
			_player_pos.y = (floorf(_player_pos.y / tile.y) + 1.0) * tile.y
		_player_velocity.y = 0.0
	elif falling and _collides(Rect2(_player_pos + Vector2(0.0, 1.0), size)):
		# A sliver below keeps the hero grounded while standing still.
		_on_ground = true
	if _on_ground:
		_coyote = COYOTE_TIME
		# A hard landing shakes the screen, squashes the hero and kicks up dust.
		if impact > tile.y * 8.0:
			var strength := clampf(impact / (tile.y * 30.0), 0.25, 1.0)
			_shake = maxf(_shake, 6.0 * strength)
			_squash = 1.0
			_spawn_dust(
				_feet_position(), 8, Color(1.0, 1.0, 1.0, 0.5), tile.y * 2.0 * strength + 18.0
			)
		var run_speed := _move_speed * tile.x * 0.35
		if absf(_player_velocity.x) > run_speed:
			_dust_timer -= delta
			if _dust_timer <= 0.0:
				_dust_timer = 0.11
				_spawn_dust(_feet_position(), 1, Color(1.0, 1.0, 1.0, 0.3), tile.y * 0.8)
		else:
			_dust_timer = 0.0

	var map_px := Vector2(_map_size) * tile
	_player_pos.x = clampf(_player_pos.x, 0.0, maxf(map_px.x - size.x, 0.0))
	if _player_pos.y > map_px.y + size.y * 2.0:
		_reset_player()


## Middle of the hero's feet, where dust and shadows are anchored.
func _feet_position() -> Vector2:
	return _player_pos + Vector2(
		_tile_size.x * _hero_tiles * 0.5, _tile_size.y * _hero_tiles
	)


## Dust is drawn in world space, so it sticks to the spot where it was born.
func _spawn_dust(position: Vector2, count: int, color: Color, speed: float) -> void:
	if _particles.size() > 140:
		return
	for i in count:
		var angle := randf_range(-PI, 0.0)
		var life := randf_range(0.25, 0.5)
		_particles.append(
			{
				"pos": position + Vector2(randf_range(-4.0, 4.0), randf_range(-2.0, 2.0)),
				"vel": Vector2(cos(angle), sin(angle)) * randf_range(speed * 0.3, speed),
				"life": life,
				"max": life,
				"size": randf_range(1.5, 3.0),
				"color": color,
			}
		)


## Advances the immersion layer: camera smoothing, landing shake, squash and the
## dust particles.
func _update_effects(delta: float) -> void:
	_elapsed += delta
	_tile_anim.advance(delta)
	_shake = maxf(_shake - delta * 24.0, 0.0)
	_squash = maxf(_squash - delta * 5.0, 0.0)
	var target := _hero_rect().get_center()
	_camera_center = _camera_center.lerp(target, 1.0 - exp(-9.0 * delta))
	for index in range(_particles.size() - 1, -1, -1):
		var particle: Dictionary = _particles[index]
		var life := float(particle["life"]) - delta
		if life <= 0.0:
			_particles.remove_at(index)
			continue
		particle["life"] = life
		particle["vel"] = (particle["vel"] as Vector2) + Vector2(0.0, 900.0) * delta
		particle["pos"] = (particle["pos"] as Vector2) + (particle["vel"] as Vector2) * delta


## Horizontal intent from every source at once: the keys give -1/1, the pad
## sticks give their own analog value and the wheel adds its own, so mixing
## them never fights. The result is clamped, and the physics uses it as a speed
## scale as well, which is why a light wheel push walks instead of running.
func _input_axis() -> float:
	var axis := _touch_axis
	if absf(_pad_axis) > 0.01:
		axis += _pad_axis
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		axis -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		axis += 1.0
	return clampf(axis, -1.0, 1.0)


func _jump_held_input() -> bool:
	return (
		Input.is_key_pressed(KEY_SPACE)
		or Input.is_key_pressed(KEY_W)
		or Input.is_key_pressed(KEY_UP)
		or _touch_jump
		or _pad_jump
	)


func _hero_rect() -> Rect2:
	return Rect2(_player_pos, Vector2(_tile_size) * _hero_tiles)


## True when any solid cell overlaps [param rect]. Only the tiles the rectangle
## touches are looked up.
func _collides(rect: Rect2) -> bool:
	if _solid.is_empty():
		return false
	var tile := Vector2(maxi(_tile_size.x, 1), maxi(_tile_size.y, 1))
	var first := Vector2i(floori(rect.position.x / tile.x), floori(rect.position.y / tile.y))
	var last := Vector2i(
		floori((rect.end.x - 0.001) / tile.x), floori((rect.end.y - 0.001) / tile.y)
	)
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			if _solid.has(Vector2i(x, y)):
				return true
	return false


func _reset_player() -> void:
	_player_velocity = Vector2.ZERO
	_on_ground = false
	_coyote = 0.0
	_jump_buffer = 0.0
	_jump_held = false
	_player_pos = _spawn_position()
	# The camera starts on the hero instead of sliding in from an old spot.
	_camera_center = _hero_rect().get_center()
	_squash = 0.0
	_shake = 0.0
	if is_instance_valid(_board):
		_board.queue_redraw()


## Finds a free column near the middle of the map and puts the hero on top of
## the first platform in it, so a spawn point under a ceiling cannot trap it.
func _spawn_position() -> Vector2:
	var tile := Vector2(maxi(_tile_size.x, 1), maxi(_tile_size.y, 1))
	var size := tile * _hero_tiles
	var map_px := Vector2(_map_size) * tile
	if _map_size.x <= 0 or _map_size.y <= 0:
		return Vector2.ZERO
	# A spawn point chosen in the scene editor wins when it is still free.
	if _in_map(_spawn_cell):
		var chosen := Vector2(_spawn_cell) * tile
		if not _collides(Rect2(chosen, size)):
			return chosen
	var center := int(_map_size.x / 2)
	var offsets: Array[int] = [0]
	for distance in range(1, _map_size.x):
		offsets.append(distance)
		offsets.append(-distance)
	for offset in offsets:
		var column := center + offset
		if column < 0 or column >= _map_size.x:
			continue
		var top := -1
		for row in _map_size.y:
			if _solid.has(Vector2i(column, row)):
				top = row
				break
		var y := 0.0 if top < 0 else maxf(float(top) * tile.y - size.y, 0.0)
		var candidate := Vector2(float(column) * tile.x, y)
		if not _collides(Rect2(candidate, size)):
			return candidate
	return Vector2(maxf(map_px.x * 0.5 - size.x * 0.5, 0.0), 0.0)


func _clear_scene() -> void:
	_decorations.clear()
	_placed_solids.clear()
	_rebuild_solid()
	if is_instance_valid(_board):
		_board.queue_redraw()
	_update_status()


## The scene belongs to the project: the map it imported, the blocks and sprites
## that were placed, the spawn point and the backdrop. A texture cannot live in a
## file, so a placed sprite keeps the frame index it was made from.
func save_state() -> Dictionary:
	var solids := {}
	for cell: Vector2i in _placed_solids:
		solids["%d,%d" % [cell.x, cell.y]] = int(_placed_solids[cell])
	var decorations := []
	for decoration in _decorations:
		var cell: Vector2i = decoration["cell"]
		decorations.append(
			{
				"cell": [cell.x, cell.y],
				"size": float(decoration["size"]),
				"frame": int(decoration.get("frame", 0)),
			}
		)
	return {
		"map": _map_source,
		"backdrop_top": _backdrop_top.to_html(),
		"backdrop_bottom": _backdrop_bottom.to_html(),
		"solids": solids,
		"decorations": decorations,
		"spawn": [_spawn_cell.x, _spawn_cell.y],
	}


## Called when a project is opened, or this page is created for one. The map is
## restored first, because it clears the scene, and the placed work comes after.
func load_state(state: Dictionary) -> void:
	if state.is_empty():
		# Back to an empty playground, so another project's level cannot linger.
		_layers.clear()
		_layers.append({"name": "图层 1", "visible": true, "cells": {}})
		_map_size = Vector2i.ZERO
		_map_image = null
		_map_texture = null
		_map_source = {}
		_atlas_image = null
		_atlas_rects.clear()
		_atlas_rects.append(Rect2i())
		_tile_anim.clear()
		_spawn_cell = Vector2i(-1, -1)
		_backdrop_top = Color(0.11, 0.13, 0.22)
		_backdrop_bottom = Color(0.03, 0.04, 0.07)
		_sync_backdrop_pickers()
		_clear_scene()
		_reset_player()
		update_view()
		if is_instance_valid(_board):
			_board.queue_redraw()
		_update_status()
		return
	var map: Dictionary = state.get("map", {})
	if not map.is_empty():
		apply_map_data(map)
	var top_html := str(state.get("backdrop_top", ""))
	if not top_html.is_empty():
		_backdrop_top = Color(top_html)
	var bottom_html := str(state.get("backdrop_bottom", ""))
	if not bottom_html.is_empty():
		_backdrop_bottom = Color(bottom_html)
	_sync_backdrop_pickers()
	_placed_solids.clear()
	var solids: Dictionary = state.get("solids", {})
	for key in solids:
		var parts := str(key).split(",")
		if parts.size() == 2:
			_placed_solids[Vector2i(int(parts[0]), int(parts[1]))] = int(solids[key])
	_decorations.clear()
	for entry in state.get("decorations", []):
		var cell_data: Array = entry.get("cell", [])
		if cell_data.size() < 2:
			continue
		_decorations.append(
			{
				"cell": Vector2i(int(cell_data[0]), int(cell_data[1])),
				"size": float(entry.get("size", _hero_tiles)),
				"texture": null,
				"frame": int(entry.get("frame", 0)),
			}
		)
	var spawn: Array = state.get("spawn", [])
	if spawn.size() >= 2:
		_spawn_cell = Vector2i(int(spawn[0]), int(spawn[1]))
	_rebuild_solid()
	_reset_player()
	update_view()
	if is_instance_valid(_board):
		_board.queue_redraw()
	_update_status()


## Tile strip for the solid block brush. It shares the imported atlas, so added
## platforms look like the rest of the level instead of grey boxes.
func _refresh_brush_strip() -> void:
	if not is_instance_valid(_brush_strip):
		return
	for child in _brush_strip.get_children():
		_brush_strip.remove_child(child)
		child.queue_free()
	_brush_atlas_texture = null
	_brush_textures.clear()
	if _atlas_image == null or _atlas_rects.size() <= 1:
		var hint := Label.new()
		hint.text = "地图没有图块，实心块会画成灰色。"
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", 12)
		hint.modulate = Color(1.0, 1.0, 1.0, 0.6)
		_brush_strip.add_child(hint)
		_brush_tile = 0
		return
	_brush_atlas_texture = ImageTexture.create_from_image(_atlas_image)
	# Built once and reused, so drawing a hundred placed blocks costs no
	# resource allocation per frame.
	for index in _atlas_rects.size():
		var region := AtlasTexture.new()
		region.atlas = _brush_atlas_texture
		region.region = Rect2(_atlas_rects[index])
		_brush_textures.append(region)
	_brush_tile = clampi(_brush_tile, 1, _atlas_rects.size() - 1)
	var group := ButtonGroup.new()
	for index in range(1, mini(_atlas_rects.size(), 65)):
		var tile_index := index
		var button := Button.new()
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size = Vector2(34, 34)
		button.focus_mode = Control.FOCUS_NONE
		button.tooltip_text = "图块 %d" % tile_index
		button.icon = _brush_textures[index]
		button.expand_icon = true
		button.toggled.connect(
			func(on: bool) -> void:
				if on:
					_brush_tile = tile_index
					_update_status()
		)
		button.button_pressed = tile_index == _brush_tile
		_brush_strip.add_child(button)


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).keycode:
		KEY_R:
			_reset_player()
			_update_status()
			get_viewport().set_input_as_handled()
		KEY_1:
			_set_edit_mode(MODE_SPRITE if _edit_mode != MODE_SPRITE else MODE_NONE)
			get_viewport().set_input_as_handled()
		KEY_2:
			_set_edit_mode(MODE_SOLID if _edit_mode != MODE_SOLID else MODE_NONE)
			get_viewport().set_input_as_handled()
		KEY_3:
			_set_edit_mode(MODE_SPAWN if _edit_mode != MODE_SPAWN else MODE_NONE)
			get_viewport().set_input_as_handled()
		KEY_F:
			_toggle_immersive()
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			if _immersive:
				_set_immersive(false)
				get_viewport().set_input_as_handled()


#endregion


#region View and drawing


## Fits the map, applies the zoom and keeps the hero in sight. A map that is
## bigger than the view scrolls with the hero instead of shrinking to nothing.
func update_view() -> void:
	if not is_instance_valid(_board):
		return
	var map_px := Vector2(_map_size) * Vector2(_tile_size)
	if map_px.x <= 0.0 or map_px.y <= 0.0:
		return
	if _board.size.x < 10.0 or _board.size.y < 10.0:
		return
	var fit := minf(_board.size.x / map_px.x, _board.size.y / map_px.y) * 0.96
	_scale = clampf(fit * _view_zoom, 0.01, 16.0)
	var drawn := map_px * _scale
	# The camera lags a little behind the hero, which reads as weight instead of
	# a hard cut every time the hero moves.
	if _camera_center == Vector2.ZERO:
		_camera_center = _hero_rect().get_center()
	var center := _camera_center * _scale
	_origin.x = _follow_axis(center.x, drawn.x, _board.size.x)
	_origin.y = _follow_axis(center.y, drawn.y, _board.size.y)
	if _shake > 0.01:
		var amount := _shake * clampf(_scale, 0.2, 1.0)
		_origin += Vector2(randf_range(-amount, amount), randf_range(-amount, amount))


## Offset of one axis: centred when the map is smaller than the board, else
## following the hero and clamped so the map never leaves a gap.
func _follow_axis(center_px: float, drawn_size: float, view_size: float) -> float:
	if drawn_size <= view_size:
		return (view_size - drawn_size) * 0.5
	return clampf(
		view_size * 0.5 - center_px, view_size - drawn_size, 0.0
	)


## Wheel and pinch zoom. 1.0 is the fitted view; higher zooms follow the hero.
func zoom_view(factor: float) -> void:
	_view_zoom = clampf(_view_zoom * factor, 0.5, 8.0)
	update_view()
	if is_instance_valid(_board):
		_board.queue_redraw()
	_update_status()


func _fit_view() -> void:
	_view_zoom = 1.0
	update_view()
	if is_instance_valid(_board):
		_board.queue_redraw()
	_update_status()


func _world_to_screen(position: Vector2) -> Vector2:
	return _origin + position * _scale


func _screen_to_world(position: Vector2) -> Vector2:
	return (position - _origin) / _scale


func draw_world(board: Control) -> void:
	# The area around the map keeps a darker copy of the backdrop, so a level
	# smaller than the view still looks like one scene.
	board.draw_rect(
		Rect2(Vector2.ZERO, board.size), Color(_backdrop_bottom.darkened(0.55), 1.0)
	)
	var map_px := Vector2(_map_size) * Vector2(_tile_size)
	if map_px.x <= 0.0 or map_px.y <= 0.0:
		return
	var map_rect := Rect2(_world_to_screen(Vector2.ZERO), map_px * _scale)
	_draw_backdrop(board, map_rect)
	if _map_texture != null:
		board.draw_texture_rect(_map_texture, map_rect, false)
		# Animated tiles are redrawn over the composed map for the current frame.
		_tile_anim.draw_cells(board, _layers, _tile_size, _origin, _scale)
	if is_instance_valid(_collision_button) and _collision_button.button_pressed:
		_draw_collision(board)
	_draw_placed_solids(board)
	for decoration in _decorations:
		_draw_decoration(board, decoration)
	_draw_player(board)
	_draw_particles(board)
	_draw_spawn_marker(board)
	_draw_brush_preview(board)
	board.draw_rect(map_rect, Color(0.45, 0.5, 0.6), false, 1.0)


## Sky gradient plus slow motes, so the world never sits on a flat black
## rectangle.
func _draw_backdrop(board: Control, map_rect: Rect2) -> void:
	var top := _backdrop_top
	var bottom := _backdrop_bottom
	var steps := 16
	for index in steps:
		var t := float(index) / float(steps - 1)
		var band := Rect2(
			Vector2(map_rect.position.x, map_rect.position.y + map_rect.size.y * t),
			Vector2(map_rect.size.x, map_rect.size.y / float(steps) + 1.0)
		)
		board.draw_rect(band, top.lerp(bottom, t))
	var area := board.size
	if area.x < 10.0 or area.y < 10.0:
		return
	# A light backdrop needs dark motes, otherwise they vanish into the sky.
	var mote := Color(0.2, 0.24, 0.34) if top.get_luminance() > 0.55 else Color(0.72, 0.86, 1.0)
	for index in 28:
		var speed := 5.0 + float(index % 5) * 2.5
		var x := fposmod(float(index) * 113.0 + _elapsed * speed, area.x)
		var y := fposmod(
			float(index) * 71.0 + sin(_elapsed * 0.8 + float(index)) * 20.0, area.y
		)
		mote.a = 0.04 + 0.05 * (0.5 + 0.5 * sin(_elapsed * 1.4 + float(index)))
		board.draw_circle(Vector2(x, y), 1.0 + float(index % 3) * 0.6, mote)


func _draw_collision(board: Control) -> void:
	var tile := Vector2(_tile_size) * _scale
	for cell: Vector2i in _solid:
		board.draw_rect(
			Rect2(_world_to_screen(Vector2(cell) * Vector2(_tile_size)), tile),
			Color(1.0, 0.25, 0.25, 0.18)
		)


## Blocks placed in the game page. They use the picked atlas tile, so an added
## platform matches the imported map instead of looking like a grey box.
func _draw_placed_solids(board: Control) -> void:
	if _placed_solids.is_empty():
		return
	var tile := Vector2(_tile_size) * _scale
	for cell: Vector2i in _placed_solids:
		var rect := Rect2(_world_to_screen(Vector2(cell) * Vector2(_tile_size)), tile)
		var index := int(_placed_solids[cell])
		if index >= 0 and index < _brush_textures.size():
			var region: AtlasTexture = _brush_textures[index]
			if region != null and region.region.size.x > 0.0:
				board.draw_texture_rect_region(
					region.atlas, rect, region.region, Color(1.0, 1.0, 1.0, 0.98)
				)
				continue
		board.draw_rect(rect, Color(0.42, 0.45, 0.52))
		board.draw_rect(rect, Color(0.6, 0.65, 0.72, 0.7), false, 1.0)


func _draw_particles(board: Control) -> void:
	for particle in _particles:
		var life := float(particle["life"])
		var total := maxf(float(particle["max"]), 0.001)
		var color: Color = particle["color"]
		color.a *= clampf(life / total, 0.0, 1.0)
		var radius := float(particle["size"]) * clampf(_scale, 0.35, 2.0)
		board.draw_circle(_world_to_screen(particle["pos"]), maxf(radius, 0.7), color)


## Bright green cell with a small arrow, so the chosen spawn point is easy to
## spot while editing the scene.
func _draw_spawn_marker(board: Control) -> void:
	if not _in_map(_spawn_cell):
		return
	var tile := Vector2(_tile_size) * _scale
	var rect := Rect2(_world_to_screen(Vector2(_spawn_cell) * Vector2(_tile_size)), tile)
	board.draw_rect(rect, Color(0.35, 1.0, 0.45, 0.18))
	board.draw_rect(rect, Color(0.35, 1.0, 0.45, 0.85), false, 2.0)
	var mid := rect.position + Vector2(rect.size.x * 0.5, -2.0)
	board.draw_colored_polygon(
		PackedVector2Array(
			[
				mid + Vector2(-rect.size.x * 0.2, -rect.size.y * 0.32),
				mid + Vector2(rect.size.x * 0.2, -rect.size.y * 0.32),
				mid,
			]
		),
		Color(0.35, 1.0, 0.45, 0.9)
	)


## Ghost cell under the cursor, so a click never lands in a surprise spot.
func _draw_brush_preview(board: Control) -> void:
	if _edit_mode == MODE_NONE or not _playing:
		return
	var mouse := board.get_local_mouse_position()
	if not Rect2(Vector2.ZERO, board.size).has_point(mouse):
		return
	if _over_touch_controls(mouse):
		return
	var cell := _world_cell(_screen_to_world(mouse))
	if not _in_map(cell):
		return
	var rect := Rect2(
		_world_to_screen(Vector2(cell) * Vector2(_tile_size)), Vector2(_tile_size) * _scale
	)
	var fill := Color(0.4, 0.9, 1.0, 0.16)
	if _edit_mode == MODE_SPAWN:
		fill = Color(0.35, 1.0, 0.45, 0.2)
	elif _edit_mode == MODE_SOLID and _placed_solids.has(cell):
		fill = Color(1.0, 0.45, 0.35, 0.2)
	board.draw_rect(rect, fill)
	board.draw_rect(rect, Color(1.0, 1.0, 1.0, 0.45), false, 1.0)


func _draw_decoration(board: Control, decoration: Dictionary) -> void:
	var texture: Texture2D = decoration["texture"]
	if texture == null:
		# A decoration restored from the project stores a frame index, because a
		# texture cannot live in the file.
		var frame := int(decoration.get("frame", -1))
		if frame >= 0 and frame < _frame_textures.size():
			texture = _frame_textures[frame]
			decoration["texture"] = texture
	if texture == null:
		return
	var cell: Vector2i = decoration["cell"]
	var size := float(decoration["size"])
	var rect := Rect2(
		_world_to_screen(Vector2(cell) * Vector2(_tile_size)),
		Vector2(_tile_size) * size * _scale
	)
	board.draw_texture_rect(texture, rect, false)


func _draw_player(board: Control) -> void:
	var base := Vector2(_tile_size) * _hero_tiles * _scale
	# Landing squashes the hero for a moment, a jump stretches it a little.
	var squash := _squash * 0.3
	if _playing and not _on_ground:
		squash -= 0.05
	var drawn := Vector2(base.x * (1.0 + squash), base.y * (1.0 - squash))
	var feet := _world_to_screen(_feet_position())
	var rect := Rect2(feet - Vector2(drawn.x * 0.5, drawn.y), drawn)
	# A flat contact shadow tells the eye how high the hero is.
	board.draw_set_transform(feet - Vector2(0.0, 1.0), 0.0, Vector2(1.0, 0.3))
	board.draw_circle(Vector2.ZERO, maxf(drawn.x * 0.36, 1.0), Color(0.0, 0.0, 0.0, 0.26))
	board.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if _frame_textures.is_empty():
		# Without artwork the hero is still visible, so the physics can be tried.
		board.draw_rect(rect, Color(0.95, 0.8, 0.3))
		board.draw_rect(rect, Color(1.0, 1.0, 1.0, 0.8), false, 1.0)
		return
	var texture: Texture2D = _frame_textures[clampi(_frame_index, 0, _frame_textures.size() - 1)]
	if _facing < 0.0:
		# Mirror around the hero's own centre instead of moving it.
		board.draw_set_transform(
			rect.position + Vector2(rect.size.x, 0.0), 0.0, Vector2(-1.0, 1.0)
		)
		board.draw_texture_rect(texture, Rect2(Vector2.ZERO, rect.size), false)
		board.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		board.draw_texture_rect(texture, rect, false)


#endregion


#region Placement


func handle_world_input(board: Control, event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if mouse.button_index == MOUSE_BUTTON_WHEEL_UP:
		if mouse.pressed:
			zoom_view(1.15)
			board.accept_event()
		return
	if mouse.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if mouse.pressed:
			zoom_view(1.0 / 1.15)
			board.accept_event()
		return
	if not mouse.pressed:
		return
	if _over_touch_controls(mouse.position):
		# The press belongs to the on screen buttons, not to the world.
		return
	var world := _screen_to_world(mouse.position)
	var cell := _world_cell(world)
	if mouse.button_index == MOUSE_BUTTON_LEFT and _edit_mode != MODE_NONE:
		match _edit_mode:
			MODE_SPRITE:
				_place_decoration(world)
			MODE_SOLID:
				_toggle_solid(cell)
			MODE_SPAWN:
				_set_spawn_cell(cell)
		board.accept_event()
	elif mouse.button_index == MOUSE_BUTTON_RIGHT:
		if _edit_mode == MODE_SPAWN and _spawn_cell.x >= 0:
			_spawn_cell = Vector2i(-1, -1)
			_update_status()
		elif _placed_solids.has(cell):
			_toggle_solid(cell)
		else:
			_remove_decoration(world)
		board.queue_redraw()
		board.accept_event()


func _world_cell(world: Vector2) -> Vector2i:
	return Vector2i(
		floori(world.x / maxi(_tile_size.x, 1)), floori(world.y / maxi(_tile_size.y, 1))
	)


func _in_map(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < _map_size.x and cell.y < _map_size.y


## Adds or removes a solid block. It uses the selected palette tile, so the
## added platform looks like the rest of the level.
func _toggle_solid(cell: Vector2i) -> void:
	if not _in_map(cell):
		return
	if _placed_solids.has(cell):
		_placed_solids.erase(cell)
		_solid.erase(cell)
	else:
		_placed_solids[cell] = maxi(_brush_tile, 0)
		_solid[cell] = true
		if _collides(_hero_rect()):
			# A block placed on the hero is undone instead of trapping it.
			_placed_solids.erase(cell)
			_solid.erase(cell)
			Global.notification_label("这里站着主角，先挪开再放")
			return
	if is_instance_valid(_board):
		_board.queue_redraw()
	_update_status()


func _set_spawn_cell(cell: Vector2i) -> void:
	if not _in_map(cell):
		return
	_spawn_cell = cell
	_reset_player()
	_update_status()


## Snaps a frame image to the tile grid, so placed art lines up with the map.
func _place_decoration(world: Vector2) -> void:
	if _frame_textures.is_empty():
		Global.notification_label("绘画区还没有可以放置的帧")
		return
	var cell := _world_cell(world)
	if not _in_map(cell):
		return
	var frame := clampi(_frame_index, 0, _frame_textures.size() - 1)
	_decorations.append(
		{"cell": cell, "size": _hero_tiles, "texture": _frame_textures[frame], "frame": frame}
	)
	if is_instance_valid(_board):
		_board.queue_redraw()
	_update_status()


func _remove_decoration(world: Vector2) -> void:
	var tile := Vector2(maxi(_tile_size.x, 1), maxi(_tile_size.y, 1))
	for index in range(_decorations.size() - 1, -1, -1):
		var decoration: Dictionary = _decorations[index]
		var rect := Rect2(
			Vector2(decoration["cell"]) * tile, tile * float(decoration["size"])
		)
		if rect.has_point(world):
			_decorations.remove_at(index)
			if is_instance_valid(_board):
				_board.queue_redraw()
			_update_status()
			return


#endregion


#region Status


func _update_status() -> void:
	if not is_instance_valid(_status):
		return
	var frame_text := "无帧"
	if not _frame_textures.is_empty():
		frame_text = "帧 %d/%d" % [_frame_index + 1, _frame_textures.size()]
	var map_text := "无地图"
	if _map_size.x > 0 and _map_size.y > 0:
		map_text = "地图 %d×%d · 图块 %d×%d" % [
			_map_size.x, _map_size.y, _tile_size.x, _tile_size.y
		]
	var state_text := "已暂停"
	if _playing:
		state_text = "在地面" if _on_ground else "空中"
	var pad_text := ""
	if not _pad_name.is_empty():
		pad_text = " · 手柄：%s" % _pad_name
	var mode_text := ""
	match _edit_mode:
		MODE_SPRITE:
			mode_text = " · 放置精灵"
		MODE_SOLID:
			mode_text = " · 放置实心块"
		MODE_SPAWN:
			mode_text = " · 设置出生点"
	var spawn_text := ""
	if _in_map(_spawn_cell):
		spawn_text = " · 出生点 %d,%d" % [_spawn_cell.x, _spawn_cell.y]
	_status.text = (
		"%s · %s · 缩放 %d%% · 位置 %d,%d · %s · 精灵 %d · 实心 %d%s%s%s"
		% [
			map_text,
			frame_text,
			int(round(_scale * 100.0)),
			int(_player_pos.x),
			int(_player_pos.y),
			state_text,
			_decorations.size(),
			_placed_solids.size(),
			mode_text,
			spawn_text,
			pad_text,
		]
	)


#endregion


## Preview surface: draws the world and forwards clicks while placing sprites.
class Board extends Control:
	var page

	## Latest position of every finger, so two of them can pinch the view.
	var _touches: Dictionary = {}
	var _pinch_distance := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		resized.connect(_on_resized)

	func _on_resized() -> void:
		if page != null:
			page.update_view()
		queue_redraw()

	func _draw() -> void:
		if page != null:
			page.draw_world(self)

	func _gui_input(event: InputEvent) -> void:
		if page != null:
			page.handle_world_input(self, event)

	## Two fingers pinch the view. Play controls stay on the side panel, so a
	## touch on the world never moves the hero by accident.
	func _input(event: InputEvent) -> void:
		if page == null or not is_visible_in_tree():
			return
		if event is InputEventScreenTouch:
			var touch := make_input_local(event) as InputEventScreenTouch
			if touch.pressed:
				# A thumb on the game controls must not count as a pinch finger,
				# otherwise steering while jumping would zoom the view.
				if bool(page.call("_over_touch_controls", touch.position)):
					return
				_touches[touch.index] = touch.position
			else:
				_touches.erase(touch.index)
			_pinch_distance = _touch_distance()
		elif event is InputEventScreenDrag:
			var drag := make_input_local(event) as InputEventScreenDrag
			_touches[drag.index] = drag.position
			if _touches.size() >= 2:
				var distance := _touch_distance()
				if _pinch_distance > 0.0 and distance > 0.0:
					page.call("zoom_view", distance / _pinch_distance)
				_pinch_distance = distance

	func _touch_distance() -> float:
		var keys := _touches.keys()
		if keys.size() < 2:
			return 0.0
		return (_touches[keys[0]] as Vector2).distance_to(_touches[keys[1]])


## On screen controls drawn over the world: a steering wheel on the left and a
## jump button on the right. Raw touches are used, so the thumb on the wheel and
## a second finger on jump work at the same time; a mouse also works on a
## desktop.
class TouchPad extends Control:
	## Radius follows the board, so the wheel and the jump button always fit side
	## by side even on a narrow phone board.
	const WHEEL_MIN := 30.0
	const WHEEL_MAX := 64.0
	## A press slightly outside the ring still grabs it, which is easier with a
	## thumb than hitting the circle exactly.
	const GRAB_SCALE := 1.15
	## Below this fraction of the radius the wheel reads as "no direction", so a
	## thumb resting in the middle does not make the hero drift.
	const DEADZONE := 0.18

	var page

	## Touch index that grabbed the wheel -> axis in -1..1.
	var _steer: Dictionary = {}
	## Touch index holding the jump button.
	var _jump_touches: Dictionary = {}
	var _mouse_steer := 0.0
	var _mouse_wheel := false
	var _mouse_jump := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		focus_mode = Control.FOCUS_NONE
		resized.connect(queue_redraw)

	func _input(event: InputEvent) -> void:
		if not is_visible_in_tree():
			return
		if event is InputEventScreenTouch:
			var touch := make_input_local(event) as InputEventScreenTouch
			if touch.pressed:
				match role_at(touch.position):
					"wheel":
						_steer[touch.index] = _axis_for(touch.position)
					"jump":
						_jump_touches[touch.index] = true
					_:
						return
			else:
				var had := _steer.erase(touch.index)
				if _jump_touches.erase(touch.index):
					had = true
				if not had:
					return
			_apply()
			get_viewport().set_input_as_handled()
		elif event is InputEventScreenDrag:
			var drag := event as InputEventScreenDrag
			if _steer.has(drag.index):
				# Sliding the thumb steers, so the hero can turn without lifting
				# the finger.
				_steer[drag.index] = _axis_for(drag.position)
				_apply()
				get_viewport().set_input_as_handled()

	## Mouse support is only for trying the layout on a desktop; a touch screen
	## already reports raw touches.
	func _gui_input(event: InputEvent) -> void:
		if DisplayServer.is_touchscreen_available():
			return
		if event is InputEventMouseButton:
			var mouse := event as InputEventMouseButton
			if mouse.button_index != MOUSE_BUTTON_LEFT:
				return
			var role := role_at(mouse.position)
			if role.is_empty():
				return
			if role == "wheel":
				_mouse_wheel = mouse.pressed
				_mouse_steer = _axis_for(mouse.position) if mouse.pressed else 0.0
			else:
				_mouse_jump = mouse.pressed
			_apply()
			accept_event()
		elif event is InputEventMouseMotion and _mouse_wheel:
			_mouse_steer = _axis_for((event as InputEventMouseMotion).position)
			_apply()

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		_draw_wheel()
		_draw_jump(font)

	## Outer ring, four tick marks, two chevrons and a knob that follows the
	## thumb. The knob also tells the player how fast the hero will go.
	func _draw_wheel() -> void:
		var center := wheel_center()
		var radius := _wheel_radius()
		var axis := _wheel_axis()
		draw_circle(center, radius, Color(0.0, 0.0, 0.0, 0.3))
		draw_arc(center, radius, 0.0, TAU, 64, Color(1.0, 1.0, 1.0, 0.42), 2.0)
		for index in 4:
			var direction := Vector2.RIGHT.rotated(PI * 0.5 * float(index))
			draw_line(
				center + direction * radius * 0.8,
				center + direction * radius * 0.93,
				Color(1.0, 1.0, 1.0, 0.26),
				2.0
			)
		var chevron := radius * 0.16
		for side: float in [-1.0, 1.0]:
			var tip := center + Vector2(side * radius * 0.74, 0.0)
			var lit := axis * side > 0.01
			var color := Color(1.0, 1.0, 1.0, 0.85) if lit else Color(1.0, 1.0, 1.0, 0.35)
			draw_line(tip, tip + Vector2(-side * chevron, -chevron), color, 2.5)
			draw_line(tip, tip + Vector2(-side * chevron, chevron), color, 2.5)
		var knob := center + Vector2(axis * radius * 0.55, 0.0)
		var knob_radius := radius * 0.42
		draw_circle(
			knob,
			knob_radius,
			Color(1.0, 1.0, 1.0, 0.4) if absf(axis) > 0.01 else Color(1.0, 1.0, 1.0, 0.2)
		)
		draw_arc(knob, knob_radius, 0.0, TAU, 40, Color(1.0, 1.0, 1.0, 0.7), 2.0)

	func _draw_jump(font: Font) -> void:
		var radius := jump_radius()
		var center := jump_center()
		draw_circle(
			center,
			radius,
			Color(1.0, 1.0, 1.0, 0.32) if _jump_active() else Color(0.0, 0.0, 0.0, 0.32)
		)
		draw_arc(center, radius, 0.0, TAU, 40, Color(1.0, 1.0, 1.0, 0.55), 2.0)
		var font_size := int(clampf(radius * 0.62, 12.0, 22.0))
		var measured := font.get_string_size("跳", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		draw_string(
			font,
			center - Vector2(measured.x * 0.5, -measured.y * 0.32),
			"跳",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_size,
			Color(1.0, 1.0, 1.0, 0.92)
		)

	func _wheel_radius() -> float:
		return clampf(minf(size.x * 0.19, size.y * 0.34), WHEEL_MIN, WHEEL_MAX)

	func jump_radius() -> float:
		return clampf(_wheel_radius() * 0.6, 22.0, 38.0)

	func _margin() -> float:
		return _wheel_radius() * 0.2

	func wheel_center() -> Vector2:
		var radius := _wheel_radius()
		return Vector2(_margin() + radius, size.y - _margin() - radius)

	func jump_center() -> Vector2:
		var radius := jump_radius()
		return Vector2(size.x - _margin() - radius, size.y - _margin() - radius)

	## -1..1 for the horizontal offset of [param position] inside the wheel.
	func _axis_for(position: Vector2) -> float:
		var radius := maxf(_wheel_radius(), 1.0)
		var raw := clampf((position.x - wheel_center().x) / radius, -1.0, 1.0)
		if absf(raw) < DEADZONE:
			return 0.0
		return raw

	## Name of the control under [param position], or an empty string.
	func role_at(position: Vector2) -> String:
		if position.distance_to(wheel_center()) <= _wheel_radius() * GRAB_SCALE:
			return "wheel"
		if position.distance_to(jump_center()) <= jump_radius() * GRAB_SCALE:
			return "jump"
		return ""

	func release_all() -> void:
		_steer.clear()
		_jump_touches.clear()
		_mouse_steer = 0.0
		_mouse_wheel = false
		_mouse_jump = false
		_apply()

	func _jump_active() -> bool:
		return not _jump_touches.is_empty() or _mouse_jump

	## Average of every finger on the wheel, so two thumbs pushing the same way
	## do not double the speed.
	func _wheel_axis() -> float:
		var axis := _mouse_steer
		if not _steer.is_empty():
			var total := 0.0
			for value in _steer.values():
				total += float(value)
			axis += total / float(_steer.size())
		return clampf(axis, -1.0, 1.0)

	func _apply() -> void:
		if page != null:
			page.call("set_touch_axis", _wheel_axis(), _jump_active())
		queue_redraw()
