extends Panel
## Full screen node editor. Procedural nodes (noise, gradients, maths) are turned
## into a pixel image, which is added to the project as a new layer.
##
## The page is embedded in the interface instead of being a separate window, and
## it blocks drawing while it is open.

## Emitted when the close button hides the page, so the host can switch back to
## the drawing tab.
signal page_closed

const ShaderGraphScript := preload("res://src/Classes/ShaderComposer/ShaderGraph.gd")
const ShaderPathEditorScript := preload("res://src/UI/ShaderComposer/ShaderPathEditor.gd")
const ShaderValueChangerScript := preload("res://src/UI/ShaderComposer/ShaderValueChanger.gd")
const ShaderWidthCurveScript := preload("res://src/UI/ShaderComposer/ShaderWidthCurve.gd")
const ShaderCanvasEditorScript := preload("res://src/UI/ShaderComposer/ShaderCanvasEditor.gd")

const PORT_COLOR := Color(0.55, 0.8, 1.0)
const PREVIEW_LIMIT := 256
## Preview size for graphs that sample neighbours, which are much slower.
const PREVIEW_LIMIT_HEAVY := 128
## Longest edge while the animation plays. A smaller picture is far cheaper per
## frame, and the preview is on screen at a similar size anyway.
const PREVIEW_LIMIT_PLAYBACK := 160
## Time one preview refresh may take. The preview size adapts to the device, so
## a slow phone draws fewer pixels instead of freezing the interface.
const PREVIEW_BUDGET_MSEC := 180.0
## Tighter budget while playing, where a steady frame rate matters more.
const PLAYBACK_BUDGET_MSEC := 90.0
## Longest time one slice of the preview may take before the frame is handed
## back, so input and scrolling stay responsive while a graph is painted.
const PREVIEW_SLICE_MSEC := 12.0
## Time one frame may spend on node thumbnails. They are drawn a few at a time
## instead of all at once after every preview refresh.
const THUMB_BUDGET_MSEC := 4.0
## More room for thumbnails while playing, where every moving node is queued.
const THUMB_BUDGET_PLAYBACK_MSEC := 8.0
## Minimum height of every interactive row, which keeps it usable with a finger.
const TOUCH_SIZE := 40
const TOUCH_FONT_SIZE := 15
## Below this width the page stacks the graph above the parameters.
const NARROW_WIDTH := 760
## Frames per second of the looping preview.
const PREVIEW_FPS := 8.0
## How many graph snapshots the undo history keeps.
const UNDO_LIMIT := 40
## Repeated parameter edits within this window collapse into one undo step.
const UNDO_COALESCE_MSEC := 700
## Where user made graph presets live.
const PRESET_DIR := "user://shader_presets"
## Exported scenes go inside the project, so the folder can be copied to a game
## and the resource paths in the .tscn keep working.
const EXPORT_DIR := "res://shader_exports"
## The evaluator is copied into the exported script, this is where it lives.
const GRAPH_SOURCE := "res://src/Classes/ShaderComposer/ShaderGraph.gd"
## How often a graph that reads the project refreshes its preview.
const SOURCE_REFRESH_MSEC := 600
## How long a press on a node has to last to open the context menu.
const HOLD_MENU_MSEC := 500
## Finger travel that turns a hold into a drag, which cancels the menu. A
## touchscreen wobbles by a few pixels, so this is larger than a mouse would need.
const HOLD_MENU_MOVE := 20.0
## The path window takes most of the screen, the control points need the room.
const PATH_POPUP_RATIO := 0.9
## Smallest height of the control point canvas. When the screen is shorter than
## the window needs, the canvas stops shrinking here and the window scrolls.
const PATH_EDITOR_MIN_HEIGHT := 110
## Side of the preview drawn in the frame under every node, in pixels.
const NODE_PREVIEW_SIZE := 56
## Smaller thumbnails while the animation plays, so the moving nodes still fit
## in a frame and stay in step with the main preview.
const NODE_PREVIEW_SIZE_PLAYBACK := 36
## Side of the picture in the side panel, which shows the selected node.
const SELECTED_PREVIEW_SIZE := 64
## Height of the cropped source preview in the pixel_art panel, in pixels.
const SOURCE_PREVIEW_HEIGHT := 120

var graph: RefCounted
var _graph_edit: GraphEdit
var _params_box: VBoxContainer
var _params_hint: Label
## The large path window and the node it edits. The editor is only alive while
## the window is open.
var _path_popup: PopupPanel
var _path_popup_node := ""
var _path_editor
## Small drawing window of a canvas node, and the node it paints for.
var _canvas_popup: PopupPanel
var _canvas_editor
var _canvas_node_id := ""
## Preview frame, thumbnail and toggle button of every node, by node id.
var _node_previews: Dictionary = {}
## Nodes whose preview frame the user folded away. Open is the default.
var _preview_collapsed: Dictionary = {}
var _preview: TextureRect
## Picture of the node selected in the side panel.
var _node_preview: TextureRect
## Holds the graph view and the floating output window, so the window can sit on
## top of the graph without being a child of GraphEdit.
var _graph_host: Control
## Floating window with the output of the whole graph, on top of the graph view.
var _preview_panel: PanelContainer
## Area that holds the picture and the backdrop behind it.
var _preview_frame: Control
## Backdrop of the picture: solid black, solid white or a checker for transparency.
var _preview_back: TextureRect
var _preview_back_choice: OptionButton
var _preview_backdrop := 0
var _preview_solid_black: ImageTexture
var _preview_solid_white: ImageTexture
var _preview_checker: ImageTexture
## Title bar of that window, which is the handle used to move it.
var _preview_header: Label
var _preview_dragging := false
var _preview_placed := false
## Canvas size the preview boxes were last fitted to.
var _preview_canvas_size := Vector2i.ZERO
## Tapping the small preview opens it at a readable size.
var _preview_popup: PopupPanel
var _preview_big: TextureRect
var _status: Label
## Categorised add menu. Picking an item adds that node straight away.
var _add_menu: MenuButton
## Item id of every entry in the add menu, mapped to its node type.
var _menu_types: Dictionary = {}
var _menu_next_id := 1
var _preview_timer: Timer
## Keeps the preview in sync with the artwork when the graph reads a layer.
var _source_timer: Timer
var _selected_id := ""
## Nodes selected in the graph, so several of them can be grouped at once.
var _selected_ids: Array[String] = []
## Tapping a node adds it to the selection instead of replacing it.
var _multi_select := false
## Snapshots of the graph, so node edits can be undone like the rest of the app.
var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []
var _undo_key := ""
var _undo_time := 0
## Filters the parameter rows of the selected node.
var _param_filter := ""
var _param_filter_edit: LineEdit
## Where the parameter rows go: the panel itself or the current section.
var _params_target: VBoxContainer
## Sections of the current node, so the filter can fold them.
var _param_sections: Array[Dictionary] = []
## Numeric parameters of the node being shown, by key. The animation section is
## built from this, so every slider and number can be animated without a hand
## written list per node type.
var _animatable: Dictionary = {}
## Touch screens change numbers by dragging; a keyboard would cover the panel.
## A phone browser reports itself as web_mobile, not as a mobile platform.
var _drag_numbers := (
	OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")
)
## Long press on a node opens a context menu.
var _node_menu: PopupMenu
var _hold_id := ""
var _hold_position := Vector2.ZERO
var _hold_moved := false
## True once the press lasted long enough, waiting for the release to open.
var _hold_ready := false
## Node the open context menu belongs to. It outlives the release, which is why
## the menu items still know what they act on.
var _menu_node_id := ""
## Runs while a node is pressed, so the hold is measured without the release.
var _hold_timer: Timer
## Saved graph presets, and the small dialog used to name them.
var _preset_menu: MenuButton
## Secondary actions, so the toolbar stays short on a phone.
var _more_menu: MenuButton
## Hides the graph to give the parameters the whole page.
var _zen_mode := false
var _preset_paths: Array[String] = []
var _preset_dialog: ConfirmationDialog
var _preset_name: LineEdit
## Dialog used to name an exported scene.
var _export_dialog: ConfirmationDialog
var _export_name: LineEdit
var _can_draw_before := true
## Animation phase shown in the preview, and how many frames a dynamic graph
## generates.
var _phase: HSlider
var _frame_count: Control
## Playback of the preview, and the layer being edited (when reopened from one).
var _play_timer: Timer
var _play_button: Button
var _playhead := 0.0
## Node thumbnails waiting to be redrawn, and the one the playback rotates to.
var _thumb_queue: Array[String] = []
var _thumb_index := 0
## Nodes whose thumbnail picture can have changed. Everything downstream of an
## edited node is affected, nothing else is, so only those are repainted.
var _dirty_previews: Dictionary = {}
var _all_previews_dirty := true
## Measured size and duration of the last preview, used to keep every refresh
## inside a time budget on slower devices.
var _preview_side := 0
var _preview_msec := 0.0
## A sliced preview is in flight; new requests are merged into it.
var _preview_busy := false
var _preview_pending := false
## Pauses previews while a one shot generation runs, so its caches are not
## cleared halfway through.
var _suspend_preview := false
var _editing_layer: BaseLayer
## Header button, whose label changes when an existing layer is being edited.
var _add_layer_button: Button
var _body: SplitContainer
var _side: VBoxContainer
## Two finger pan and pinch inside the graph, because the system gestures that
## [GraphEdit] would normally rely on are disabled for the canvas.
var _graph_fingers: Dictionary[int, Vector2] = {}
var _graph_gesture := false
var _graph_span := 1.0
var _graph_midpoint := Vector2.ZERO
var _graph_zoom := 1.0
var _graph_scroll := Vector2.ZERO


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	graph = ShaderGraphScript.new()
	_build_ui()
	_apply_layout()
	resized.connect(_apply_layout)
	_refresh_graph()
	_refresh_preview()
	hide()


## Shows the page and stops the canvas from receiving input meanwhile.
## Opens the page. When [param layer] is a layer made by this editor, its graph is
## loaded back so the nodes can be adjusted again.
func open_page(layer: BaseLayer = null) -> void:
	# Only remember the state before the page took over, so reopening it from a
	# layer button cannot turn drawing off for good.
	if not visible:
		_can_draw_before = Global.can_draw
	Global.can_draw = false
	_editing_layer = layer
	if layer != null and layer.has_meta("shader_graph"):
		graph.from_dict(layer.get_meta("shader_graph"))
		_set_frame_count_value(int(layer.get_meta("shader_frames", _frame_count_value())))
		_selected_id = ""
		_show_params("")
		_refresh_graph()
	if is_instance_valid(_add_layer_button):
		_add_layer_button.text = (
			"更新图层" if _editing_layer != null else "作为新图层添加"
		)
	show()
	_apply_layout()
	_refresh_preview()


func close_page() -> void:
	Global.can_draw = _can_draw_before
	_preview_timer.stop()
	if is_instance_valid(_source_timer):
		_source_timer.stop()
	if is_instance_valid(_play_timer):
		_play_timer.stop()
	if is_instance_valid(_play_button):
		_play_button.text = "▶"
	_editing_layer = null
	_graph_fingers.clear()
	_graph_gesture = false
	hide()
	page_closed.emit()


func is_open() -> bool:
	return visible


## Hides the page while another view tab is shown. The graph, the selected node
## and the layer being edited all stay, so switching back is instant.
func pause_page() -> void:
	if not visible:
		return
	_preview_timer.stop()
	if is_instance_valid(_source_timer):
		_source_timer.stop()
	if is_instance_valid(_play_timer):
		_play_timer.stop()
	if is_instance_valid(_play_button):
		_play_button.text = "▶"
	hide()
	Global.can_draw = _can_draw_before


## Shows the page again after [method pause_page], without reloading anything.
func resume_page() -> void:
	Global.can_draw = false
	show()
	_apply_layout()
	_refresh_preview()


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
	margin.add_child(root)

	# Tab style header, so the page reads as a tab of the main area.
	var header := PanelContainer.new()
	var header_style := StyleBoxFlat.new()
	header_style.bg_color = Color(0.17, 0.17, 0.2)
	header_style.set_corner_radius_all(4)
	header_style.content_margin_left = 10
	header_style.content_margin_right = 6
	header_style.content_margin_top = 4
	header_style.content_margin_bottom = 4
	header.add_theme_stylebox_override("panel", header_style)
	root.add_child(header)
	# Buttons wrap instead of overflowing, and every row is finger sized.
	var header_row := HFlowContainer.new()
	header.add_child(header_row)
	var title := Label.new()
	title.text = "节点图层 · Shader Composer"
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_row.add_child(title)
	_add_layer_button = _make_button("作为新图层添加", _on_add_layer_pressed)
	header_row.add_child(_add_layer_button)
	header_row.add_child(_make_button("✕", close_page, "关闭", Vector2(48, TOUCH_SIZE)))

	var toolbar := HFlowContainer.new()
	root.add_child(toolbar)
	_add_menu = MenuButton.new()
	_add_menu.text = "＋节点"
	_add_menu.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	_add_menu.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_build_add_menu()
	toolbar.add_child(_add_menu)
	toolbar.add_child(_make_button("多选", _on_multi_select_pressed, "打开后连续点节点即可多选"))
	toolbar.add_child(_make_button("组合", _on_group_pressed, "把选中的节点放进一个可折叠的组"))
	toolbar.add_child(_make_button("撤销", _undo, "Ctrl+Z"))
	toolbar.add_child(_make_button("重做", _redo, "Ctrl+Y"))
	_more_menu = MenuButton.new()
	_more_menu.text = "更多"
	_more_menu.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	_more_menu.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_build_more_menu()
	toolbar.add_child(_more_menu)
	_preset_menu = MenuButton.new()
	_preset_menu.text = "预设"
	_preset_menu.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	_preset_menu.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_build_preset_menu()
	toolbar.add_child(_preset_menu)
	_play_button = _make_button("▶", _on_play_pressed, "循环播放预览")
	toolbar.add_child(_play_button)
	_frame_count = _make_frame_count_control()
	toolbar.add_child(_frame_count)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 13)
	toolbar.add_child(_status)

	# A single split switches between side by side and stacked, so the same page
	# works on a portrait phone and on a desktop window.
	_body = SplitContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_body)

	_graph_edit = GraphEdit.new()
	_graph_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph_edit.minimap_enabled = false
	# Bigger port hot zones, so connecting nodes works with a finger.
	_graph_edit.add_theme_constant_override("port_hotzone_inner_extent", 26)
	_graph_edit.add_theme_constant_override("port_hotzone_outer_extent", 18)
	_graph_edit.connection_request.connect(_on_connection_request)
	_graph_edit.disconnection_request.connect(_on_disconnection_request)
	_graph_edit.delete_nodes_request.connect(_on_delete_nodes_request)
	_graph_edit.node_selected.connect(_on_node_selected)
	_graph_edit.node_deselected.connect(_on_node_deselected)
	_graph_host = Control.new()
	_graph_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph_host.clip_contents = true
	_body.add_child(_graph_host)
	_graph_host.add_child(_graph_edit)
	_graph_edit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# The output picture floats over the graph instead of taking a column of its
	# own: it is the shape of the canvas and can be dragged where it is handy.
	_preview_panel = PanelContainer.new()
	_preview_panel.name = "OutputPreview"
	_preview_panel.z_index = 10
	_preview_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.13, 0.14, 0.17, 0.94)
	panel_style.set_corner_radius_all(4)
	panel_style.set_border_width_all(1)
	panel_style.border_color = Color(0.36, 0.4, 0.48)
	panel_style.content_margin_left = 6
	panel_style.content_margin_right = 6
	panel_style.content_margin_top = 4
	panel_style.content_margin_bottom = 6
	_preview_panel.add_theme_stylebox_override("panel", panel_style)
	_graph_host.add_child(_preview_panel)
	var panel_column := VBoxContainer.new()
	panel_column.add_theme_constant_override("separation", 4)
	_preview_panel.add_child(panel_column)
	var preview_header_row := HBoxContainer.new()
	preview_header_row.add_theme_constant_override("separation", 6)
	panel_column.add_child(preview_header_row)
	_preview_header = Label.new()
	_preview_header.text = "输出预览 ⠿"
	_preview_header.tooltip_text = "按住这一行拖动预览，点图片放大"
	_preview_header.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview_header.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_preview_header.custom_minimum_size = Vector2(0, 28)
	_preview_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_header.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_preview_header.add_theme_font_size_override("font_size", 13)
	_preview_header.gui_input.connect(_on_preview_header_input)
	preview_header_row.add_child(_preview_header)
	# The backdrop makes the transparent parts of the output readable, and white
	# is what the artwork will look like on paper.
	_preview_back_choice = OptionButton.new()
	_preview_back_choice.add_item("黑", 0)
	_preview_back_choice.add_item("白", 1)
	_preview_back_choice.add_item("透明", 2)
	_preview_back_choice.select(_preview_backdrop)
	_preview_back_choice.custom_minimum_size = Vector2(84, 28)
	_preview_back_choice.add_theme_font_size_override("font_size", 12)
	_preview_back_choice.tooltip_text = "预览底色"
	_preview_back_choice.item_selected.connect(_on_preview_backdrop_selected)
	preview_header_row.add_child(_preview_back_choice)
	_preview_frame = Control.new()
	_preview_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel_column.add_child(_preview_frame)
	_preview_back = TextureRect.new()
	_preview_back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_back.stretch_mode = TextureRect.STRETCH_TILE
	_preview_back.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_frame.add_child(_preview_back)
	_preview = TextureRect.new()
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview.tooltip_text = "输出节点的结果，点一下放大"
	_preview.gui_input.connect(_on_preview_input)
	_preview_frame.add_child(_preview)
	_apply_preview_backdrop()
	_graph_host.resized.connect(_fit_preview_panel)

	_side = VBoxContainer.new()
	_body.add_child(_side)

	var filter_row := HBoxContainer.new()
	var filter_label := Label.new()
	filter_label.text = "筛选"
	filter_label.custom_minimum_size = Vector2(48, 0)
	filter_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	filter_label.add_theme_font_size_override("font_size", 14)
	filter_row.add_child(filter_label)
	_param_filter_edit = LineEdit.new()
	_param_filter_edit.placeholder_text = "参数名过滤…"
	_param_filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_param_filter_edit.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	_param_filter_edit.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_param_filter_edit.text_changed.connect(
		func(text: String) -> void:
			_param_filter = text
			_show_params(_selected_id)
	)
	filter_row.add_child(_param_filter_edit)
	_side.add_child(filter_row)

	_params_hint = Label.new()
	_params_hint.text = "选择一个节点来编辑参数"
	_params_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_params_hint.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_side.add_child(_params_hint)

	var params_scroll := ScrollContainer.new()
	params_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	params_scroll.custom_minimum_size = Vector2(0, 180)
	_side.add_child(params_scroll)
	_params_box = VBoxContainer.new()
	_params_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	params_scroll.add_child(_params_box)
	_params_target = _params_box

	_node_menu = PopupMenu.new()
	_node_menu.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_node_menu.add_item("复制节点", 0)
	_node_menu.add_item("删除节点", 1)
	_node_menu.add_item("断开输入", 2)
	_node_menu.add_item("组合选中", 3)
	_node_menu.add_item("编辑路径…", 4)
	_node_menu.add_item("旁路此节点", 5)
	_node_menu.id_pressed.connect(_on_node_menu_pressed)
	_node_menu.popup_hide.connect(_on_node_menu_hidden)
	add_child(_node_menu)
	# Measures the press while the finger is down, so a dropped release event
	# cannot make the long press miss.
	_hold_timer = Timer.new()
	_hold_timer.one_shot = true
	_hold_timer.wait_time = float(HOLD_MENU_MSEC) / 1000.0
	_hold_timer.timeout.connect(_on_hold_timeout)
	add_child(_hold_timer)

	# Scrubbing the phase is how a dynamic graph is previewed frame by frame.
	var phase_row := HBoxContainer.new()
	var phase_label := Label.new()
	phase_label.text = "相位"
	phase_label.custom_minimum_size = Vector2(48, 0)
	phase_label.add_theme_font_size_override("font_size", 14)
	phase_row.add_child(phase_label)
	_phase = HSlider.new()
	_phase.min_value = 0.0
	_phase.max_value = 1.0
	_phase.step = 0.01
	_phase.value = 0.0
	_phase.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phase.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	_phase.value_changed.connect(
		func(_value: float) -> void:
			_schedule_preview()
	)
	phase_row.add_child(_phase)
	_side.add_child(phase_row)

	# What the selected node outputs, which is what the parameters on the left
	# of it are changing.
	var node_preview_label := Label.new()
	node_preview_label.text = "节点预览（当前选中）"
	node_preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node_preview_label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_side.add_child(node_preview_label)
	_node_preview = TextureRect.new()
	_node_preview.custom_minimum_size = Vector2(200, 120)
	_node_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_node_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_node_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_node_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_side.add_child(_node_preview)

	_preview_timer = Timer.new()
	_preview_timer.one_shot = true
	_preview_timer.wait_time = 0.15
	_preview_timer.timeout.connect(_refresh_preview)
	add_child(_preview_timer)

	_source_timer = Timer.new()
	_source_timer.wait_time = float(SOURCE_REFRESH_MSEC) / 1000.0
	_source_timer.timeout.connect(_refresh_preview)
	add_child(_source_timer)

	_play_timer = Timer.new()
	_play_timer.wait_time = 1.0 / PREVIEW_FPS
	_play_timer.timeout.connect(_advance_playback)
	add_child(_play_timer)


## Rebuilds the graph view from the data, keeping where the user put each node.
## Nodes inside a collapsed group are hidden, and the group stands in for them.
func _refresh_graph() -> void:
	for child in _graph_edit.get_children():
		if child is GraphNode:
			var stored: Dictionary = graph.get_node_by_id(str(child.name))
			if not stored.is_empty():
				stored["position"] = (child as GraphNode).position_offset
			else:
				var group: Dictionary = graph.get_group(str(child.name))
				if not group.is_empty():
					group["position"] = (child as GraphNode).position_offset
	_graph_edit.clear_connections()
	# The previews belong to the nodes being rebuilt, so the map starts over.
	_node_previews.clear()
	_all_previews_dirty = true
	_dirty_previews.clear()
	for child in _graph_edit.get_children():
		if child is GraphNode:
			_graph_edit.remove_child(child)
			child.queue_free()

	var visible := {}
	for node: Dictionary in graph.nodes:
		if _is_hidden_by_group(str(node["id"])):
			continue
		visible[node["id"]] = true
		_graph_edit.add_child(_make_graph_node(node))
	for group: Dictionary in graph.groups:
		_graph_edit.add_child(_make_group_node(group))

	# Inner connections, only when both ends are on screen.
	for node: Dictionary in graph.nodes:
		if not visible.has(node["id"]):
			continue
		var inputs: Dictionary = node["inputs"]
		for slot: int in inputs.keys():
			var source := str(inputs[slot])
			if source.is_empty() or not visible.has(source):
				continue
			_graph_edit.connect_node(source, 0, node["id"], slot)

	# A collapsed group talks to the outside through its own ports.
	for group: Dictionary in graph.groups:
		if not bool(group.get("collapsed", false)):
			continue
		var edges: Dictionary = graph.group_edges(group)
		var incoming: Array = edges["incoming"]
		for index in incoming.size():
			var source := str((incoming[index] as Dictionary)["from"])
			if visible.has(source):
				_graph_edit.connect_node(source, 0, str(group["id"]), index)
		for entry: Dictionary in edges["outgoing"]:
			var target := str(entry["node"])
			if visible.has(target):
				_graph_edit.connect_node(str(group["id"]), 0, target, int(entry["slot"]))

	# Keep the multi selection across the rebuild.
	var still_selected: Array[String] = []
	for node_id in _selected_ids:
		var child := _graph_edit.get_node_or_null(NodePath(node_id))
		if child is GraphNode and visible.has(node_id):
			(child as GraphNode).selected = true
			still_selected.append(node_id)
	_selected_ids = still_selected
	_status.text = "节点 %d · 组 %d" % [graph.nodes.size(), graph.groups.size()]


func _is_hidden_by_group(node_id: String) -> bool:
	var group: Dictionary = graph.group_of_node(node_id)
	return not group.is_empty() and bool(group.get("collapsed", false))


## Stand-in for a group. Collapsed it shows the ports that cross its border,
## expanded it is only a header with the fold button.
func _make_group_node(group: Dictionary) -> GraphNode:
	var collapsed := bool(group.get("collapsed", false))
	var members: Array = group["nodes"]
	var graph_node := GraphNode.new()
	graph_node.name = str(group["id"])
	graph_node.title = "%s · %d 节点" % [str(group["name"]), members.size()]
	graph_node.position_offset = group.get("position", Vector2.ZERO)
	if collapsed:
		var edges: Dictionary = graph.group_edges(group)
		var incoming: Array = edges["incoming"]
		for index in maxi(incoming.size(), 1):
			var port_label := Label.new()
			port_label.text = ("输入 %d" % (index + 1)) if index < incoming.size() else " "
			port_label.add_theme_font_size_override("font_size", 11)
			graph_node.add_child(port_label)
		var has_output := not (edges["outgoing"] as Array).is_empty()
		graph_node.set_slot(0, not incoming.is_empty(), 0, PORT_COLOR, has_output, 0, PORT_COLOR)
		for index in range(1, incoming.size()):
			graph_node.set_slot(index, true, index, PORT_COLOR, false, 0, PORT_COLOR)
	var row := HBoxContainer.new()
	# 32 px tall, so the buttons are still comfortable for a finger.
	row.add_child(
		_make_button(
			"展开" if collapsed else "折叠",
			func() -> void: _toggle_group(str(group["id"])),
			"",
			Vector2(0, 32)
		)
	)
	if collapsed:
		row.add_child(
			_make_button(
				"解散",
				func() -> void: _dissolve_group(str(group["id"])),
				"拆掉这个组，节点都保留",
				Vector2(0, 32)
			)
		)
	graph_node.add_child(row)
	return graph_node


func _toggle_group(group_id: String) -> void:
	var group: Dictionary = graph.get_group(group_id)
	if group.is_empty():
		return
	_push_undo()
	graph.set_group_collapsed(group_id, not bool(group.get("collapsed", false)))
	_refresh_graph()


func _dissolve_group(group_id: String) -> void:
	_push_undo()
	graph.remove_group(group_id)
	_refresh_graph()


## Puts the selected nodes into a new group that can then be collapsed.
func _on_group_pressed() -> void:
	if _selected_ids.size() < 2:
		# The status line is rewritten by the preview, so use the app notification.
		Global.notification_label("先选中两个以上节点再组合")
		return
	_push_undo()
	var group_id: String = graph.add_group(_selected_ids)
	if group_id.is_empty():
		Global.notification_label("选中的节点已经在别的组里")
		return
	_selected_ids.clear()
	_refresh_graph()


func _make_graph_node(node: Dictionary) -> GraphNode:
	var graph_node := GraphNode.new()
	graph_node.name = node["id"]
	graph_node.title = ShaderGraphScript.NODE_TYPES[node["type"]]["label"]
	graph_node.position_offset = node.get("position", Vector2.ZERO)
	graph_node.gui_input.connect(_on_graph_node_input.bind(str(node["id"])))
	# The title carries the accent of its group, so a big graph reads by colour.
	var group_color: Color = ShaderGraphScript.NODE_GROUP_COLORS.get(
		ShaderGraphScript.group_of_type(str(node["type"])), PORT_COLOR
	)
	graph_node.add_theme_color_override("title_color", group_color)
	var input_count := int(ShaderGraphScript.NODE_TYPES[node["type"]]["inputs"])
	graph_node.set_slot(0, input_count >= 1, 0, PORT_COLOR, true, 0, PORT_COLOR)
	var description := Label.new()
	description.text = ShaderGraphScript.describe(node)
	# Every node names the canvas it generates at, so the graph reads without
	# opening the preview.
	var canvas_text := _canvas_size_text()
	if not canvas_text.is_empty():
		description.text += " · " + canvas_text
	description.add_theme_font_size_override("font_size", 12)
	description.tooltip_text = "生成尺寸：%s" % canvas_text
	graph_node.add_child(description)
	if bool(node.get("bypass", false)):
		# A bypassed node is still visible, so it can be switched back on, but the
		# whole node is dimmed to make it obvious that it does nothing right now.
		description.text += "（已旁路）"
		graph_node.modulate = Color(1.0, 1.0, 1.0, 0.6)
	if input_count >= 2:
		# Every slot needs its own child, otherwise the second input port does not
		# exist and connections to it are dropped. The label says what the port
		# takes (mask, B, phase...), which matters when the graph is read on a
		# phone without hovering the tooltips.
		graph_node.set_slot(1, true, 0, PORT_COLOR, false, 0, PORT_COLOR)
		var second_input := Label.new()
		second_input.text = ShaderGraphScript.second_input_label(str(node["type"]))
		second_input.add_theme_font_size_override("font_size", 11)
		second_input.modulate = Color(1.0, 1.0, 1.0, 0.6)
		second_input.custom_minimum_size = Vector2(0, 14)
		graph_node.add_child(second_input)
	# Every node shows what it produces, in a frame that can be folded away.
	graph_node.add_child(_make_node_preview(node))
	return graph_node


## Canvas size the graph generates at, taken from the project. It is written on
## every node label.
func _canvas_size_text() -> String:
	var project := Global.current_project
	if project == null:
		return ""
	return "%d×%d" % [project.size.x, project.size.y]


## Preview frame of every node, under its ports. It shows the value that node
## outputs, and its header folds the frame away when the graph gets crowded.
func _make_node_preview(node: Dictionary) -> Control:
	var node_id := str(node["id"])
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	var toggle := Button.new()
	toggle.text = "▾ 预览"
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle.flat = true
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.custom_minimum_size = Vector2(0, 20)
	toggle.add_theme_font_size_override("font_size", 11)
	toggle.modulate = Color(1.0, 1.0, 1.0, 0.75)
	toggle.pressed.connect(func() -> void: _toggle_node_preview(node_id))
	column.add_child(toggle)

	var frame := PanelContainer.new()
	var body := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		body.add_theme_constant_override("margin_" + side, 3)
	frame.add_child(body)
	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(NODE_PREVIEW_SIZE, NODE_PREVIEW_SIZE)
	thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(thumb)
	column.add_child(frame)

	var collapsed := bool(_preview_collapsed.get(node_id, false))
	frame.visible = not collapsed
	toggle.text = "▸ 预览" if collapsed else "▾ 预览"
	_node_previews[node_id] = {"frame": frame, "thumb": thumb, "toggle": toggle}
	if not collapsed:
		thumb.texture = ImageTexture.create_from_image(
			graph.preview_node(node_id, Vector2i(NODE_PREVIEW_SIZE, NODE_PREVIEW_SIZE))
		)
	return column


## Paints queued thumbnails a few milliseconds at a time, so a graph with many
## nodes never blocks one frame after a change or a playback tick.
func _process(_delta: float) -> void:
	if _thumb_queue.is_empty() or not visible:
		return
	if _preview_busy:
		# A sliced generation is mid-frame; rasterising a thumbnail now would
		# make it rebuild its cached nodes at the thumbnail size.
		return
	var budget := THUMB_BUDGET_PLAYBACK_MSEC if _is_playing() else THUMB_BUDGET_MSEC
	var deadline := Time.get_ticks_usec() + int(budget * 1000.0)
	var index := 0
	while index < _thumb_queue.size() and Time.get_ticks_usec() < deadline:
		var node_id: String = _thumb_queue[index]
		var entry: Dictionary = _node_previews.get(node_id, {})
		if entry.is_empty():
			_thumb_queue.remove_at(index)
			continue
		var frame: Control = entry["frame"]
		if not is_instance_valid(frame):
			_node_previews.erase(node_id)
			_thumb_queue.remove_at(index)
			continue
		if not frame.visible or not _preview_on_screen(frame):
			# Keep it queued: it is drawn as soon as it scrolls back in.
			index += 1
			continue
		_thumb_queue.remove_at(index)
		_refresh_node_preview(node_id, entry)


## True when a node preview is inside the visible part of the graph, so panning
## a big graph does not pay for pictures nobody sees.
func _preview_on_screen(frame: Control) -> bool:
	if not is_instance_valid(_graph_edit):
		return false
	var view := _graph_edit.get_global_rect()
	if view.size.x <= 0.0 or view.size.y <= 0.0:
		# Before the first layout there is no visible area to test against.
		return true
	return view.intersects(frame.get_global_rect())


## Folds the preview of one node away, or brings it back with a fresh picture.
func _toggle_node_preview(node_id: String) -> void:
	var entry: Dictionary = _node_previews.get(node_id, {})
	if entry.is_empty():
		return
	var frame: Control = entry["frame"]
	if not is_instance_valid(frame):
		return
	var show := not frame.visible
	frame.visible = show
	_preview_collapsed[node_id] = not show
	var toggle: Button = entry["toggle"]
	if is_instance_valid(toggle):
		toggle.text = "▾ 预览" if show else "▸ 预览"
	if show:
		_refresh_node_preview(node_id, entry)


## Picture of the node selected in the side panel. It is bigger than the
## thumbnails so a parameter change can be judged without zooming the graph.
func _refresh_selected_preview() -> void:
	if not is_instance_valid(_node_preview):
		return
	if _selected_id.is_empty() or graph.get_node_by_id(_selected_id).is_empty():
		_node_preview.texture = null
		return
	_node_preview.texture = ImageTexture.create_from_image(
		graph.preview_node(_selected_id, Vector2i(SELECTED_PREVIEW_SIZE, SELECTED_PREVIEW_SIZE))
	)


## Redraws the preview of one node.
func _refresh_node_preview(node_id: String, entry: Dictionary) -> void:
	var thumb: TextureRect = entry["thumb"]
	if not is_instance_valid(thumb) or graph.get_node_by_id(node_id).is_empty():
		return
	# Playback draws smaller thumbnails, which is the difference between the
	# moving branch keeping up and falling a whole second behind.
	var side := NODE_PREVIEW_SIZE_PLAYBACK if _is_playing() else NODE_PREVIEW_SIZE
	thumb.texture = ImageTexture.create_from_image(
		graph.preview_node(node_id, Vector2i(side, side))
	)


## Marks a node and everything downstream of it for a thumbnail redraw. Editing
## one branch no longer repaints the whole graph.
func _mark_preview_dirty(node_id: String) -> void:
	if node_id.is_empty() or graph.get_node_by_id(node_id).is_empty():
		_all_previews_dirty = true
		return
	_dirty_previews[node_id] = true
	for other: String in graph.downstream_ids(node_id):
		_dirty_previews[other] = true


## Queues the previews whose picture can have changed. [method _process] paints
## them a few at a time, and only the ones inside the visible part of the graph.
func _refresh_node_previews() -> void:
	var candidates: Array = []
	if _all_previews_dirty:
		_all_previews_dirty = false
		candidates = _node_previews.keys()
	else:
		candidates = _dirty_previews.keys()
		_dirty_previews.clear()
	if candidates.is_empty():
		return
	for node_id: String in candidates:
		var entry: Dictionary = _node_previews.get(node_id, {})
		var frame: Control = entry.get("frame", null)
		if not is_instance_valid(frame):
			_node_previews.erase(node_id)
			continue
		if not frame.visible:
			continue
		if not _thumb_queue.has(node_id):
			_thumb_queue.append(node_id)


func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	_push_undo()
	graph.connect_nodes(str(from_node), str(to_node), to_port)
	_refresh_graph()
	_schedule_preview()


func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	_push_undo()
	graph.disconnect_input(str(to_node), to_port)
	_refresh_graph()
	_schedule_preview()


func _on_delete_nodes_request(nodes: Array[StringName]) -> void:
	_push_undo()
	var removed := {}
	for node_name in nodes:
		var target := str(node_name)
		removed[target] = true
		if target.begins_with(ShaderGraphScript.GROUP_PREFIX):
			graph.remove_group(target)
		else:
			graph.remove_node(target)
		_selected_ids.erase(target)
	if (
		removed.has(_selected_id)
		or (
			graph.get_node_by_id(_selected_id).is_empty()
			and graph.get_group(_selected_id).is_empty()
		)
	):
		_selected_id = ""
		_show_params("")
	_refresh_graph()
	_schedule_preview()


## Builds the add menu: every category is a submenu, and picking an entry adds
## that node right away, which is one tap less than before on a phone.
func _build_add_menu() -> void:
	var root := _add_menu.get_popup()
	root.clear()
	for child in root.get_children():
		if child is PopupMenu:
			root.remove_child(child)
			child.queue_free()
	_menu_types.clear()
	_menu_next_id = 1
	var index := 0
	for group: Dictionary in ShaderGraphScript.NODE_GROUPS:
		var submenu := PopupMenu.new()
		submenu.name = "group_%d" % index
		index += 1
		submenu.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
		for type: String in group["types"]:
			var item_id := _menu_next_id
			_menu_next_id += 1
			_menu_types[item_id] = type
			submenu.add_item(ShaderGraphScript.NODE_TYPES[type]["label"], item_id)
		submenu.id_pressed.connect(_on_add_menu_pressed)
		root.add_child(submenu)
		root.add_submenu_item(str(group["label"]), submenu.name)


func _on_add_menu_pressed(item_id: int) -> void:
	var type: String = str(_menu_types.get(item_id, ""))
	if type.is_empty():
		return
	_push_undo()
	# New nodes land next to the visible area instead of on top of each other.
	var offset := Vector2(60 + graph.nodes.size() * 24, 40 + graph.nodes.size() * 18)
	var node_id: String = graph.add_node(type, offset)
	_refresh_graph()
	_selected_id = node_id
	_show_params(node_id)
	_schedule_preview()


## Remembers the graph before a change. Repeating the same key shortly after
## (dragging a slider) collapses into a single undo step.
func _push_undo(key := "") -> void:
	var now := Time.get_ticks_msec()
	if not key.is_empty() and key == _undo_key and now - _undo_time < UNDO_COALESCE_MSEC:
		_undo_time = now
		return
	_undo_key = key
	_undo_time = now
	_undo_stack.append(graph.to_dict())
	if _undo_stack.size() > UNDO_LIMIT:
		_undo_stack.pop_front()
	_redo_stack.clear()


func _undo() -> void:
	if _undo_stack.is_empty():
		Global.notification_label("没有可撤销的节点操作")
		return
	_redo_stack.append(graph.to_dict())
	graph.from_dict(_undo_stack.pop_back())
	_undo_key = ""
	_after_history_change()


func _redo() -> void:
	if _redo_stack.is_empty():
		Global.notification_label("没有可重做的节点操作")
		return
	_undo_stack.append(graph.to_dict())
	graph.from_dict(_redo_stack.pop_back())
	_undo_key = ""
	_after_history_change()


func _after_history_change() -> void:
	_selected_ids.clear()
	if (
		graph.get_node_by_id(_selected_id).is_empty()
		and graph.get_group(_selected_id).is_empty()
	):
		_selected_id = ""
	_refresh_graph()
	_show_params(_selected_id)
	_refresh_preview()


## Turns tap-to-select into tap-to-add, so several nodes can be grouped by touch.
func _on_multi_select_pressed() -> void:
	_multi_select = not _multi_select
	Global.notification_label("多选：%s" % ("开" if _multi_select else "关"))
	if _multi_select:
		if not _selected_id.is_empty() and not _selected_ids.has(_selected_id):
			_selected_ids.append(_selected_id)
	elif _selected_ids.size() > 1:
		_selected_ids.clear()
		if not _selected_id.is_empty():
			_selected_ids.append(_selected_id)


## Switches a node off without deleting it: its first input goes straight
## through, so a step can be compared on and off with one tap.
func _toggle_bypass(node_id: String) -> void:
	var node: Dictionary = graph.get_node_by_id(node_id)
	if node.is_empty():
		return
	_push_undo("%s:bypass" % node_id)
	node["bypass"] = not bool(node.get("bypass", false))
	_refresh_graph()
	_show_params(node_id)
	_schedule_preview()


func _on_copy_pressed() -> void:
	if _selected_id.is_empty():
		return
	_push_undo()
	var copy: String = graph.duplicate_node(_selected_id)
	if copy.is_empty():
		return
	_refresh_graph()
	_selected_id = copy
	_show_params(copy)
	_schedule_preview()


## Secondary actions live here, so the main toolbar still fits a portrait phone.
func _build_more_menu() -> void:
	var popup := _more_menu.get_popup()
	popup.clear()
	popup.add_item("复制选中", 0)
	popup.add_item("删除选中", 1)
	popup.add_item("刷新预览", 2)
	popup.add_item("断开选中输入", 3)
	popup.add_item("导出 tscn…", 5)
	popup.add_separator()
	popup.add_check_item("放大参数面板", 4)
	popup.set_item_checked(popup.get_item_index(4), _zen_mode)
	if not popup.id_pressed.is_connected(_on_more_pressed):
		popup.id_pressed.connect(_on_more_pressed)


func _on_more_pressed(id: int) -> void:
	match id:
		0:
			_on_copy_pressed()
		1:
			_on_delete_pressed()
		2:
			_refresh_preview()
		3:
			_disconnect_selected()
		4:
			_toggle_zen()
			_build_more_menu()
		5:
			_show_export_dialog()


## Touch friendly way to drop a wire: dragging one off a port is fiddly with a
## finger, so the menu can clear the inputs of the selected node.
func _disconnect_selected() -> void:
	if _selected_id.is_empty() or graph.get_node_by_id(_selected_id).is_empty():
		return
	_push_undo()
	graph.disconnect_input(_selected_id, 0)
	graph.disconnect_input(_selected_id, 1)
	_refresh_graph()
	_schedule_preview()


## Hides the graph so the parameter list gets the whole height, which a phone
## needs for something like Mesh Warp with its ten sliders.
func _toggle_zen() -> void:
	_zen_mode = not _zen_mode
	if is_instance_valid(_graph_edit):
		_graph_edit.visible = not _zen_mode
	_apply_layout()


## Builds the preset menu: two built in presets, the save entry and the files the
## user saved before.
func _build_preset_menu() -> void:
	var root := _preset_menu.get_popup()
	root.clear()
	_preset_paths.clear()
	root.add_item("默认图", 0)
	root.add_item("像素海面", 1)
	root.add_item("生长树", 3)
	root.add_item("路径生长", 4)
	root.add_item("遮罩生长", 5)
	root.add_item("灌木丛", 6)
	root.add_item("灌木丛（程序化）", 7)
	root.add_item("藤蔓叶片（沿路径）", 8)
	root.add_separator()
	root.add_item("保存当前图…", 2)
	var saved := _list_presets()
	if not saved.is_empty():
		root.add_separator("已保存")
	var id := 10
	for path in saved:
		_preset_paths.append(path)
		root.add_item(path.get_file().get_basename(), id)
		id += 1
	if not root.id_pressed.is_connected(_on_preset_pressed):
		root.id_pressed.connect(_on_preset_pressed)


func _list_presets() -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(PRESET_DIR)
	if dir == null:
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.get_extension() == "txt":
			result.append(PRESET_DIR.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result


func _on_preset_pressed(id: int) -> void:
	if id == 0:
		_on_reset_pressed()
		return
	if id == 1:
		_on_ocean_preset_pressed()
		return
	if id == 3:
		_on_tree_preset_pressed()
		return
	if id == 4:
		_on_path_growth_preset_pressed()
		return
	if id == 5:
		_on_mask_growth_preset_pressed()
		return
	if id == 6:
		_on_scatter_preset_pressed(true)
		return
	if id == 7:
		_on_scatter_preset_pressed(false)
		return
	if id == 8:
		_on_vine_preset_pressed()
		return
	if id == 2:
		_show_preset_dialog()
		return
	var index := id - 10
	if index >= 0 and index < _preset_paths.size():
		_load_preset(_preset_paths[index])


## Asks for a name, then writes the scene into res://shader_exports/<name>/.
func _show_export_dialog() -> void:
	if not is_instance_valid(_export_dialog):
		_export_dialog = ConfirmationDialog.new()
		_export_dialog.title = "导出为 Godot 场景"
		_export_name = LineEdit.new()
		_export_name.custom_minimum_size = Vector2(240, TOUCH_SIZE)
		_export_name.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
		_export_dialog.add_child(_export_name)
		_export_dialog.confirmed.connect(_export_scene)
		add_child(_export_dialog)
	_export_dialog.popup_centered(Vector2i(340, 150))
	_export_name.grab_focus()
	_export_name.select_all()


## Writes three files: the scene, the evaluator with the graph baked in, and a
## preview PNG. The folder is self contained, so it can be copied into a game.
func _export_scene() -> void:
	# A sliced preview may still own the per frame caches, so let it finish
	# before the one shot generation clears them.
	_suspend_preview = true
	await _wait_for_preview()
	_export_scene_now()
	_suspend_preview = false


func _export_scene_now() -> void:
	var typed := _export_name.text.strip_edges()
	if typed.is_empty():
		Global.notification_label("请先给场景起个名字")
		return
	var folder := "%s/%s" % [EXPORT_DIR, typed.validate_filename()]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var script_path := folder.path_join("graph_sprite.gd")
	var scene_path := folder.path_join("shader_graph.tscn")
	var project := Global.current_project
	var image_size: Vector2i = project.size if project != null else Vector2i(64, 64)
	var frames := _frame_count_value()
	var script_file := FileAccess.open(script_path, FileAccess.WRITE)
	if script_file == null:
		Global.notification_label("无法写入 %s" % script_path)
		return
	script_file.store_string(_build_runtime_script())
	script_file.close()
	var scene_text := (
		"[gd_scene load_steps=2 format=3]\n\n"
		+ "[ext_resource type=\"Script\" path=\"%s\" id=\"1_graph\"]\n\n"
		+ "[node name=\"ShaderGraph\" type=\"Sprite2D\"]\n"
		+ "script = ExtResource(\"1_graph\")\n"
		+ "graph_data = %s\n"
		+ "size = %s\n"
		+ "frames = %d\n"
	) % [script_path, var_to_str(graph.to_dict()), var_to_str(image_size), frames]
	var scene_file := FileAccess.open(scene_path, FileAccess.WRITE)
	if scene_file == null:
		Global.notification_label("无法写入 %s" % scene_path)
		return
	scene_file.store_string(scene_text)
	scene_file.close()
	var preview: Image = graph.generate(image_size)
	preview.save_png(folder.path_join("preview.png"))
	Global.notification_label("已导出到 %s" % folder)


## Builds the exported script: a small Sprite2D driver plus the evaluator, taken
## from the composer so the behaviour matches exactly.
func _build_runtime_script() -> String:
	var source := FileAccess.get_file_as_string(GRAPH_SOURCE)
	var lines := source.split("\n")
	var body := ""
	# Skip the class_name and extends lines of the original file.
	for index in range(2, lines.size()):
		var line := lines[index]
		if line.strip_edges().is_empty():
			body += "\n"
		else:
			body += "\t" + line + "\n"
	# The exported scene must not depend on Pixelorama's autoloads.
	body = body.replace("Global.current_project", "null")
	var driver := """@tool
extends Sprite2D
## Auto generated by Pixelorama's Shader Composer.
##
## The node graph is baked into graph_data and the evaluator is included below,
## so this folder is self contained: copy it into a Godot project and the sprite
## renders there too, in the editor as well.
##
## Frames are prerendered on _ready(), so playing the animation costs nothing per
## frame. Nodes that read the project layer export as empty, they need Pixelorama.

@export var graph_data: Dictionary = {}:
	set(value):
		graph_data = value
		if is_inside_tree():
			_rebuild()
@export var size: Vector2i = Vector2i(64, 64):
	set(value):
		size = value
		if is_inside_tree():
			_rebuild()
@export var frames: int = 1:
	set(value):
		frames = maxi(value, 1)
		if is_inside_tree():
			_rebuild()
@export var fps: float = 8.0
@export var animate: bool = false:
	set(value):
		animate = value
		_start_playback()
@export var pixel_snap: bool = true:
	set(value):
		pixel_snap = value
		texture_filter = (
			CanvasItem.TEXTURE_FILTER_NEAREST if pixel_snap else CanvasItem.TEXTURE_FILTER_LINEAR
		)

var _graph: RefCounted
var _textures: Array[ImageTexture] = []
var _index := 0
var _elapsed := 0.0


func _ready() -> void:
	texture_filter = (
		CanvasItem.TEXTURE_FILTER_NEAREST if pixel_snap else CanvasItem.TEXTURE_FILTER_LINEAR
	)
	_rebuild()


## Regenerates every frame of the graph into textures.
func _rebuild() -> void:
	_graph = Graph.new()
	_graph.from_dict(graph_data)
	_textures.clear()
	var count: int = maxi(frames, 1) if _graph.uses_time() else 1
	for index in count:
		_graph.time = float(index) / float(count)
		_textures.append(ImageTexture.create_from_image(_graph.generate(size)))
	_index = 0
	texture = _textures[0] if not _textures.is_empty() else null
	_start_playback()


func _start_playback() -> void:
	if not is_inside_tree():
		return
	set_process(animate and _textures.size() > 1)


func _process(delta: float) -> void:
	_elapsed += delta
	var step := 1.0 / maxf(fps, 0.1)
	while _elapsed >= step:
		_elapsed -= step
		_index = (_index + 1) % _textures.size()
		texture = _textures[_index]


## The evaluator, copied from the composer so the scene stays portable.
class Graph extends RefCounted:
"""
	return driver + body


func _show_preset_dialog() -> void:
	if not is_instance_valid(_preset_dialog):
		_preset_dialog = ConfirmationDialog.new()
		_preset_dialog.title = "保存预设"
		_preset_name = LineEdit.new()
		_preset_name.custom_minimum_size = Vector2(240, TOUCH_SIZE)
		_preset_name.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
		_preset_dialog.add_child(_preset_name)
		_preset_dialog.confirmed.connect(_save_preset)
		add_child(_preset_dialog)
	_preset_dialog.popup_centered(Vector2i(320, 140))
	_preset_name.grab_focus()
	_preset_name.select_all()


func _save_preset() -> void:
	var typed := _preset_name.text.strip_edges()
	if typed.is_empty():
		Global.notification_label("预设名不能为空")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PRESET_DIR))
	var path := PRESET_DIR.path_join(typed.validate_filename() + ".txt")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		Global.notification_label("无法写入预设")
		return
	file.store_string(var_to_str(graph.to_dict()))
	file.close()
	_build_preset_menu()
	Global.notification_label("预设已保存：%s" % typed)


func _load_preset(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		Global.notification_label("无法读取预设")
		return
	var data = str_to_var(file.get_as_text())
	file.close()
	if not (data is Dictionary):
		Global.notification_label("预设文件损坏：%s" % path.get_file())
		return
	_push_undo()
	graph.from_dict(data as Dictionary)
	_selected_id = ""
	_selected_ids.clear()
	_refresh_graph()
	_show_params("")
	_refresh_preview()
	Global.notification_label("已载入预设：%s" % path.get_file().get_basename())


func _on_reset_pressed() -> void:
	_push_undo()
	graph.reset_to_default()
	_selected_id = ""
	_show_params("")
	_refresh_graph()
	_refresh_preview()


func _on_delete_pressed() -> void:
	if _selected_id.is_empty():
		return
	_push_undo()
	if _selected_id.begins_with(ShaderGraphScript.GROUP_PREFIX):
		graph.remove_group(_selected_id)
	else:
		graph.remove_node(_selected_id)
		_selected_ids.erase(_selected_id)
	_selected_id = ""
	_show_params("")
	_refresh_graph()
	_schedule_preview()


func _on_node_selected(node: Node) -> void:
	_selected_id = str(node.name)
	if _multi_select:
		if not _selected_ids.has(_selected_id):
			_selected_ids.append(_selected_id)
	else:
		_selected_ids.clear()
		_selected_ids.append(_selected_id)
	_show_params(_selected_id)


func _on_node_deselected(node: Node) -> void:
	if _multi_select:
		# In multi select mode the graph deselects on every new tap, keep the set.
		return
	var node_id := str(node.name)
	_selected_ids.erase(node_id)
	if _selected_id == node_id:
		_selected_id = ""
		_show_params("")


## Builds the parameter controls of [param id] in the side panel.
func _show_params(id: String) -> void:
	_params_target = _params_box
	_param_sections.clear()
	_animatable.clear()
	for child in _params_box.get_children():
		_params_box.remove_child(child)
		child.queue_free()
	var node: Dictionary = graph.get_node_by_id(id)
	if node.is_empty():
		_params_hint.text = "选择一个节点来编辑参数"
		_refresh_selected_preview()
		return
	_params_hint.text = "%s（%s）" % [
		ShaderGraphScript.NODE_TYPES[node["type"]]["label"], node["id"]
	]
	var params: Dictionary = node["params"]
	match str(node["type"]):
		"noise":
			_add_option("类型", ShaderGraphScript.NOISE_TYPES, int(params["noise_type"]), params, "noise_type")
			_add_slider("周期 (px)", 2.0, 128.0, 1.0, float(params["scale"]), params, "scale")
			_add_number("层数", 1, 8, 1, int(params["octaves"]), params, "octaves")
			_add_number("种子", 0, 99999, 1, int(params["seed"]), params, "seed")
			_add_slider("细节保持", 0.1, 0.9, 0.05, float(params["gain"]), params, "gain")
		"gradient":
			_add_slider("角度", 0.0, 360.0, 1.0, float(params["angle"]), params, "angle")
			_add_slider("偏移", -1.0, 1.0, 0.01, float(params.get("offset", 0.0)), params, "offset")
		"radial":
			_add_slider("中心 X", 0.0, 1.0, 0.01, float(params["center_x"]), params, "center_x")
			_add_slider("中心 Y", 0.0, 1.0, 0.01, float(params["center_y"]), params, "center_y")
			_add_slider("半径", 0.05, 1.5, 0.01, float(params["radius"]), params, "radius")
			_add_slider("过渡", 0.05, 4.0, 0.05, float(params.get("falloff", 1.0)), params, "falloff")
			_add_check("反向", bool(params["invert"]), params, "invert")
		"checker":
			_add_slider("格子 (px)", 1.0, 64.0, 1.0, float(params["cell"]), params, "cell")
		"shape":
			var shape_hint := Label.new()
			shape_hint.text = (
				"基础图形，用来做遮罩：接到描边、发光、混合或运算节点上使用。"
				+ "按距离场绘制，所以柔边在每种形状上表现一致。"
			)
			shape_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			shape_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(shape_hint)
			_add_option(
				"形状",
				ShaderGraphScript.SHAPE_KINDS,
				int(params.get("kind", 0)),
				params,
				"kind",
				true
			)
			_begin_section("位置与大小", true)
			_add_slider("中心 X", 0.0, 1.0, 0.01, float(params.get("center_x", 0.5)), params, "center_x")
			_add_slider("中心 Y", 0.0, 1.0, 0.01, float(params.get("center_y", 0.5)), params, "center_y")
			_add_slider("大小", 0.02, 1.5, 0.01, float(params.get("size", 0.35)), params, "size")
			_add_slider(
				"旋转", -180.0, 180.0, 1.0, float(params.get("angle", 0.0)), params, "angle"
			)
			_add_slider("柔边", 0.0, 0.2, 0.005, float(params.get("soft", 0.02)), params, "soft")
			_end_section()
			_add_check("反向", bool(params.get("invert", false)), params, "invert")
			if int(params.get("kind", 0)) == 4:
				_begin_section("星形", true)
				_add_number("角数", 3, 12, 1, int(params.get("points", 5)), params, "points")
				_add_slider(
					"内半径", 0.05, 0.95, 0.01, float(params.get("inner", 0.45)), params, "inner"
				)
				_end_section()
			elif int(params.get("kind", 0)) == 5:
				_begin_section("圆环", true)
				_add_slider(
					"环宽", 0.01, 0.5, 0.01, float(params.get("thickness", 0.18)), params, "thickness"
				)
				_end_section()
		"tree":
			var tree_hint := Label.new()
			tree_hint.text = (
				"递归生长的树：每个枝头再分叉一次，生长值按层展开。"
				+ "用下方「动画」驱动「生长」就是生长动画，也可以用「随预览时间生长」跑完整条时间线。"
				+ "颜色由输出节点的三段色阶决定。"
			)
			tree_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			tree_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(tree_hint)
			_add_number("种子", 0, 9999, 1, int(params.get("seed", 3)), params, "seed")
			_add_slider("生长", 0.0, 1.0, 0.01, float(params.get("growth", 1.0)), params, "growth")
			_add_check(
				"随预览时间生长",
				bool(params.get("animate", false)),
				params,
				"animate",
				true
			)
			_add_slider(
				"生长缓动", 0.0, 1.0, 0.05, float(params.get("ease", 0.4)), params, "ease"
			)
			_begin_section("形态", true)
			_add_number("深度", 1, 7, 1, int(params.get("depth", 5)), params, "depth")
			_add_number("每节分叉", 1, 4, 1, int(params.get("branches", 2)), params, "branches")
			_add_slider(
				"分叉角度", 5.0, 90.0, 1.0, float(params.get("spread", 34.0)), params, "spread"
			)
			_add_slider(
				"随机", 0.0, 1.0, 0.01, float(params.get("randomness", 0.3)), params, "randomness"
			)
			_end_section()
			_begin_section("枝干", false)
			_add_slider("粗细", 0.005, 0.15, 0.005, float(params.get("width", 0.045)), params, "width")
			_add_slider("收细", 0.4, 0.95, 0.01, float(params.get("taper", 0.72)), params, "taper")
			_add_slider("弯曲", 0.0, 2.0, 0.05, float(params.get("bend", 0.35)), params, "bend")
			_add_slider(
				"树干倾斜", -60.0, 60.0, 1.0, float(params.get("lean", 0.0)), params, "lean"
			)
			_add_slider("柔边", 0.0, 0.2, 0.005, float(params.get("soft", 0.0)), params, "soft")
			_end_section()
			_begin_section("树叶", true)
			_add_check("启用", bool(params.get("leaves", true)), params, "leaves", true)
			_add_slider(
				"叶大小", 0.3, 2.5, 0.05, float(params.get("leaf_size", 1.0)), params, "leaf_size"
			)
			_end_section()
			_begin_section("风", false)
			_add_slider("风力", 0.0, 1.0, 0.01, float(params.get("sway", 0.0)), params, "sway")
			_add_slider(
				"摆动速度",
				0.1,
				3.0,
				0.05,
				float(params.get("sway_speed", 0.5)),
				params,
				"sway_speed"
			)
			_end_section()
		"particles":
			var particles_hint := Label.new()
			particles_hint.text = (
				"像素粒子：位置按相位直接算出，不存状态，所以任意一帧都能单独生成、循环精确。"
				+ "底部升起做火花/尘埃，顶部下落做雪/雨，全画布做萤火。"
			)
			particles_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			particles_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(particles_hint)
			_add_number("种子", 0, 9999, 1, int(params.get("seed", 1)), params, "seed")
			_add_number("数量", 1, 256, 1, int(params.get("count", 48)), params, "count")
			_add_slider("大小", 0.5, 6.0, 0.5, float(params.get("size", 1.5)), params, "size")
			_begin_section("发射", true)
			_add_option(
				"起点", ShaderGraphScript.PARTICLE_SPAWN, int(params.get("spawn", 0)), params, "spawn"
			)
			_add_slider(
				"方向", -180.0, 180.0, 1.0, float(params.get("angle", -90.0)), params, "angle"
			)
			_add_slider(
				"扩散", 0.0, 180.0, 1.0, float(params.get("spread", 30.0)), params, "spread"
			)
			_add_slider(
				"速度", -2.0, 2.0, 0.05, float(params.get("speed", 0.5)), params, "speed"
			)
			_add_slider(
				"重力", -2.0, 2.0, 0.05, float(params.get("gravity", 0.0)), params, "gravity"
			)
			_end_section()
			_begin_section("运动", true)
			_add_slider(
				"湍流", 0.0, 1.0, 0.01, float(params.get("turbulence", 0.0)), params, "turbulence"
			)
			_add_slider(
				"寿命", 0.1, 1.0, 0.01, float(params.get("lifetime", 0.8)), params, "lifetime"
			)
			_add_check("淡入淡出", bool(params.get("fade", true)), params, "fade")
			_add_slider(
				"闪烁", 0.0, 1.0, 0.01, float(params.get("twinkle", 0.0)), params, "twinkle"
			)
			_end_section()
			_begin_section("外观", false)
			_add_option(
				"形状", ShaderGraphScript.PARTICLE_SHAPES, int(params.get("shape", 0)), params, "shape"
			)
			_add_slider("柔边", 0.0, 0.2, 0.005, float(params.get("soft", 0.0)), params, "soft")
			_end_section()
		"scatter":
			var scatter_hint := Label.new()
			scatter_hint.text = (
				"把输入 1 当作笔刷，按随机角度和大小盖章，"
				+ "适合把像素画图层里的叶片、石头、碎石铺成灌木和苔藓。"
				+ "输入 2 在「区域密度」时是遮罩（越亮越密）；"
				+ "切到「沿路径」并把路径接到输入 2，笔刷会顺着曲线排布，"
				+ "动画那个路径的「显示比例」就是边生长边撒。"
				+ "笔刷只取不透明的形状，像素画本身的颜色不参与，"
				+ "盖章的颜色由输出节点的渐变和下面的「亮度」决定。"
			)
			scatter_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			scatter_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(scatter_hint)
			_add_number("数量", 1, 256, 1, int(params.get("amount", 24)), params, "amount")
			_add_option(
				"分布",
				["区域密度", "沿路径"],
				int(params.get("mode", 0)),
				params,
				"mode",
				true
			)
			if int(params.get("mode", 0)) == 1:
				_add_slider(
					"路径宽度",
					0.0,
					0.5,
					0.01,
					float(params.get("path_width", 0.08)),
					params,
					"path_width"
				)
				_add_check(
					"沿切线朝向",
					bool(params.get("follow_tangent", false)),
					params,
					"follow_tangent"
				)
			else:
				_add_slider(
					"范围", 0.0, 1.5, 0.01, float(params.get("spread", 0.6)), params, "spread"
				)
			_add_slider(
				"笔刷大小", 0.02, 0.6, 0.01, float(params.get("stamp", 0.3)), params, "stamp"
			)
			_add_slider(
				"亮度", 0.0, 1.0, 0.01, float(params.get("level", 1.0)), params, "level"
			)
			_begin_section("随机", true)
			_add_slider(
				"角度", -180.0, 180.0, 1.0, float(params.get("angle", 0.0)), params, "angle"
			)
			_add_slider(
				"角度随机",
				0.0,
				180.0,
				1.0,
				float(params.get("angle_random", 180.0)),
				params,
				"angle_random"
			)
			_add_slider(
				"最小缩放",
				0.25,
				2.0,
				0.05,
				float(params.get("scale_min", 0.7)),
				params,
				"scale_min"
			)
			_add_slider(
				"最大缩放",
				0.25,
				2.0,
				0.05,
				float(params.get("scale_max", 1.3)),
				params,
				"scale_max"
			)
			_add_number("种子", 0, 9999, 1, int(params.get("seed", 1)), params, "seed")
			_end_section()
			_add_check("对齐像素", bool(params.get("align", true)), params, "align")
		"path":
			var path_hint := Label.new()
			path_hint.text = (
				"纯矢量：这里只保存控制点和开合状态，没有线宽。"
				+ "接到「画布」节点的输入，线宽和粗细曲线都由画布决定。"
				+ "「显示比例」控制画到哪一段，在下方「动画」里驱动它就是沿路径生长。"
			)
			path_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			path_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(path_hint)
			_add_path_button(id)
			_add_check("闭合", bool(params.get("closed", false)), params, "closed", true)
			_add_slider(
				"显示比例",
				0.0,
				1.0,
				0.01,
				float(params.get("reveal", 1.0)),
				params,
				"reveal"
			)
			_add_check(
				"从末端生长",
				bool(params.get("reveal_reverse", false)),
				params,
				"reveal_reverse"
			)
		"pixel_art":
			# The canvas node either reads the drawing area or draws a path as
			# pixel lines, so the panel switches with the source.
			_add_option(
				"来源",
				["画布图像", "路径线条"],
				int(params.get("source", 0)),
				params,
				"source",
				true
			)
			if int(params.get("source", 0)) == 1:
				_build_canvas_line_section(id, params)
			else:
				_build_canvas_image_section(id, params)
		"constant":
			_add_slider("数值", 0.0, 1.0, 0.01, float(params.get("value", 0.5)), params, "value")
		"time":
			var hint := Label.new()
			hint.text = (
				"输出当前帧的相位（0…1）。接到 Wave、Transform 等节点的输入口，"
				+ "生成时按帧数逐帧出图。速度是每帧前进的圈数。"
			)
			hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(hint)
			_add_slider("速度", 0.0, 4.0, 0.05, float(params.get("speed", 1.0)), params, "speed")
			_add_slider("偏移", 0.0, 1.0, 0.01, float(params.get("offset", 0.0)), params, "offset")
		"wave":
			_add_slider("频率", 0.5, 16.0, 0.1, float(params["frequency"]), params, "frequency")
			_add_slider("角度", 0.0, 360.0, 1.0, float(params["angle"]), params, "angle")
			_add_slider("振幅", 0.0, 1.0, 0.01, float(params["amplitude"]), params, "amplitude")
		"transform":
			var transform_hint := Label.new()
			transform_hint.text = "位置移动内容；位置取整可减少像素画的糊边；不透明度在数值图里表现为向最暗色淡出。"
			transform_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			transform_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(transform_hint)
			_add_slider(
				"位置 X", -1.0, 1.0, 0.01, float(params.get("position_x", 0.0)), params, "position_x"
			)
			_add_slider(
				"位置 Y", -1.0, 1.0, 0.01, float(params.get("position_y", 0.0)), params, "position_y"
			)
			_add_slider("旋转", 0.0, 360.0, 1.0, float(params["angle"]), params, "angle")
			_add_slider("缩放", 0.1, 4.0, 0.05, float(params["scale"]), params, "scale")
			_add_slider("偏移 X", -1.0, 1.0, 0.01, float(params["offset_x"]), params, "offset_x")
			_add_slider("偏移 Y", -1.0, 1.0, 0.01, float(params["offset_y"]), params, "offset_y")
			_begin_section("像素细节", false)
			_add_check("位置取整", bool(params.get("round", false)), params, "round")
			_add_check("平铺", bool(params.get("tile", false)), params, "tile")
			_add_slider(
				"不透明度", 0.0, 1.0, 0.01, float(params.get("alpha", 1.0)), params, "alpha"
			)
			_end_section()
		"scale":
			_add_option(
				"模式", ShaderGraphScript.SCALE_MODES, int(params.get("mode", 0)), params, "mode", true
			)
			if int(params.get("mode", 0)) == 1:
				_add_slider(
					"目标宽",
					1.0,
					256.0,
					1.0,
					float(params.get("target_x", 32.0)),
					params,
					"target_x"
				)
				_add_slider(
					"目标高",
					1.0,
					256.0,
					1.0,
					float(params.get("target_y", 32.0)),
					params,
					"target_y"
				)
				_add_option("适配", ShaderGraphScript.SCALE_FITS, int(params.get("fit", 0)), params, "fit")
			else:
				_add_slider("X 缩放", -4.0, 4.0, 0.05, float(params["scale_x"]), params, "scale_x")
				_add_slider("Y 缩放", -4.0, 4.0, 0.05, float(params["scale_y"]), params, "scale_y")
			_add_check("平铺", bool(params.get("tile", false)), params, "tile")
		"flip":
			_add_option("翻转轴", ShaderGraphScript.FLIP_AXIS, int(params.get("axis", 0)), params, "axis")
		"skew":
			_add_slider("X 倾斜", -80.0, 80.0, 1.0, float(params["angle_x"]), params, "angle_x")
			_add_slider("Y 倾斜", -80.0, 80.0, 1.0, float(params["angle_y"]), params, "angle_y")
		"tile":
			_add_slider("横向次数", 1.0, 8.0, 1.0, float(params["count_x"]), params, "count_x")
			_add_slider("纵向次数", 1.0, 8.0, 1.0, float(params["count_y"]), params, "count_y")
			_add_slider("偏移 X", -1.0, 1.0, 0.01, float(params["offset_x"]), params, "offset_x")
			_add_slider("偏移 Y", -1.0, 1.0, 0.01, float(params["offset_y"]), params, "offset_y")
		"polar":
			_add_option("方向", ShaderGraphScript.POLAR_MODES, int(params["mode"]), params, "mode")
			_add_slider("重复", 1.0, 8.0, 1.0, float(params["repeat"]), params, "repeat")
			_add_slider("旋转", -1.0, 1.0, 0.01, float(params.get("twist", 0.0)), params, "twist")
		"crop":
			var crop_hint := Label.new()
			crop_hint.text = "按画布比例裁剪，框外变空。左 < 右、上 < 下 才会出内容。"
			crop_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			crop_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(crop_hint)
			_add_slider("左", 0.0, 1.0, 0.01, float(params["left"]), params, "left")
			_add_slider("上", 0.0, 1.0, 0.01, float(params["top"]), params, "top")
			_add_slider("右", 0.0, 1.0, 0.01, float(params["right"]), params, "right")
			_add_slider("下", 0.0, 1.0, 0.01, float(params["bottom"]), params, "bottom")
			_add_slider("宽高比", 0.0, 4.0, 0.05, float(params.get("aspect", 0.0)), params, "aspect")
		"padding":
			_add_slider("边距", 0.0, 0.49, 0.01, float(params["amount"]), params, "amount")
			_add_slider(
				"对齐 X", 0.0, 1.0, 0.01, float(params.get("align_x", 0.5)), params, "align_x"
			)
			_add_slider(
				"对齐 Y", 0.0, 1.0, 0.01, float(params.get("align_y", 0.5)), params, "align_y"
			)
		"echo":
			var echo_hint := Label.new()
			echo_hint.text = (
				"空间回声沿一个方向重复采样；跨帧回声则取更早的相位，做出残影。"
				+ "最大值留下拖影，平均值得到残影。"
			)
			echo_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			echo_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(echo_hint)
			_add_slider("采样数", 1.0, 12.0, 1.0, float(params["count"]), params, "count")
			_add_option("合并", ShaderGraphScript.ECHO_MODES, int(params["mode"]), params, "mode")
			_add_check("跨帧回声", bool(params.get("animated", false)), params, "animated")
			_add_slider(
				"帧间隔",
				0.01,
				0.5,
				0.01,
				float(params.get("frame_step", 0.05)),
				params,
				"frame_step"
			)
			_add_slider("角度", 0.0, 360.0, 1.0, float(params["angle"]), params, "angle")
			_add_slider("距离", 0.0, 1.0, 0.01, float(params["distance"]), params, "distance")
		"follow_path":
			var path_hint := Label.new()
			path_hint.text = (
				"输入 1 是要移动的图案，输入 2 是相位（接 Time 才会动）。"
				+ "没有相位输入时停在下面的相位值上。"
			)
			path_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			path_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(path_hint)
			_add_option(
				"路径",
				ShaderGraphScript.PATH_SHAPES,
				int(params["shape"]),
				params,
				"shape",
				true
			)
			if int(params["shape"]) == ShaderGraphScript.PATH_CUSTOM:
				_add_path_button(id)
			else:
				_add_slider("半径", 0.05, 1.0, 0.01, float(params["radius"]), params, "radius")
			_add_slider("圈数", 0.25, 4.0, 0.25, float(params["loops"]), params, "loops")
			_add_slider("相位", 0.0, 1.0, 0.01, float(params["phase"]), params, "phase")
		"mesh_warp":
			var mesh_hint := Label.new()
			mesh_hint.text = (
				"2×2 网格：每个角都能拉，中间自动插值。数值是相对画布的位移比例。"
			)
			mesh_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			mesh_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(mesh_hint)
			# Four foldable corners, so a phone only shows one of them by default.
			_begin_section("左上角")
			_add_slider("X", -0.5, 0.5, 0.01, float(params["tl_x"]), params, "tl_x")
			_add_slider("Y", -0.5, 0.5, 0.01, float(params["tl_y"]), params, "tl_y")
			_end_section()
			_begin_section("右上角", false)
			_add_slider("X", -0.5, 0.5, 0.01, float(params["tr_x"]), params, "tr_x")
			_add_slider("Y", -0.5, 0.5, 0.01, float(params["tr_y"]), params, "tr_y")
			_end_section()
			_begin_section("左下角", false)
			_add_slider("X", -0.5, 0.5, 0.01, float(params["bl_x"]), params, "bl_x")
			_add_slider("Y", -0.5, 0.5, 0.01, float(params["bl_y"]), params, "bl_y")
			_end_section()
			_begin_section("右下角", false)
			_add_slider("X", -0.5, 0.5, 0.01, float(params["br_x"]), params, "br_x")
			_add_slider("Y", -0.5, 0.5, 0.01, float(params["br_y"]), params, "br_y")
			_end_section()
			_add_slider(
				"随机抖动", 0.0, 0.4, 0.01, float(params.get("randomness", 0.0)), params, "randomness"
			)
		"area_warp":
			var area_hint := Label.new()
			area_hint.text = "输入 1 是扰动场，输入 2 是被扭曲的图案。只在圆圈范围内生效。"
			area_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			area_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(area_hint)
			_add_slider("中心 X", 0.0, 1.0, 0.01, float(params["center_x"]), params, "center_x")
			_add_slider("中心 Y", 0.0, 1.0, 0.01, float(params["center_y"]), params, "center_y")
			_add_slider("半径", 0.05, 1.5, 0.01, float(params["radius"]), params, "radius")
			_add_slider("强度", 0.0, 0.5, 0.01, float(params["amount"]), params, "amount")
		"nine_slice":
			var slice_hint := Label.new()
			slice_hint.text = "四角保持原大小，中间按比例拉伸；超出画布的部分会被裁掉。"
			slice_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			slice_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(slice_hint)
			_add_slider("边框", 0.0, 0.49, 0.01, float(params["border"]), params, "border")
			_add_slider("拉伸", 0.2, 4.0, 0.05, float(params["scale"]), params, "scale")
		"crop_content":
			var content_hint := Label.new()
			content_hint.text = (
				"自动找到图案非空的范围并铺满画布。阈值控制多亮的像素算内容。"
			)
			content_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			content_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(content_hint)
			_add_slider("阈值", 0.0, 1.0, 0.01, float(params["threshold"]), params, "threshold")
			_add_slider("边距", 0.0, 0.4, 0.01, float(params["margin"]), params, "margin")
		"kaleidoscope":
			_add_slider("分段", 2.0, 16.0, 1.0, float(params["segments"]), params, "segments")
			_add_slider("旋转", 0.0, 360.0, 1.0, float(params["angle"]), params, "angle")
			_add_check("镜像", bool(params.get("mirror", true)), params, "mirror")
		"bend":
			var bend_hint := Label.new()
			bend_hint.text = "把整条分支按曲线推开：弧线做弯曲，波浪做热浪抖动。"
			bend_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			bend_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(bend_hint)
			_add_option("类型", ShaderGraphScript.BEND_TYPES, int(params["type"]), params, "type")
			_add_option("作用轴", ShaderGraphScript.BEND_AXIS, int(params["axis"]), params, "axis")
			_add_slider("幅度", -0.5, 0.5, 0.01, float(params["amount"]), params, "amount")
			_add_slider("频率", 0.1, 6.0, 0.1, float(params["scale"]), params, "scale")
			_add_slider("相位", 0.0, 1.0, 0.01, float(params["shift"]), params, "shift")
			_begin_section("UV 变换", false)
			_add_slider("UV 缩放", 0.25, 4.0, 0.05, float(params.get("uv_scale", 1.0)), params, "uv_scale")
			_add_slider("UV 偏移", -1.0, 1.0, 0.01, float(params.get("uv_shift", 0.0)), params, "uv_shift")
			_end_section()
		"stretch":
			var stretch_hint := Label.new()
			stretch_hint.text = "沿一个方向拉长，做冲刺、子弹、魔法弹的速度感。反向会同时压扁垂直方向。"
			stretch_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			stretch_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(stretch_hint)
			_add_slider("角度", 0.0, 360.0, 1.0, float(params["angle"]), params, "angle")
			_add_slider("强度", 0.0, 0.95, 0.01, float(params["amount"]), params, "amount")
			_add_check("反向压缩", bool(params.get("inverse", true)), params, "inverse")
		"mirror":
			var mirror_hint := Label.new()
			mirror_hint.text = "沿一条线把半边折到另一边，做左右对称或上下对称的图案。"
			mirror_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			mirror_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(mirror_hint)
			_add_slider("角度", 0.0, 360.0, 1.0, float(params["angle"]), params, "angle")
			_add_slider("位置", -1.0, 1.0, 0.01, float(params["position"]), params, "position")
			_add_check("反向半边", bool(params.get("flip_side", false)), params, "flip_side")
		"blur":
			var blur_hint := Label.new()
			blur_hint.text = (
				"3×3 模糊：尺寸越大越糊；拉宽宽高比就是方向性模糊，做速度线用。"
			)
			blur_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			blur_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(blur_hint)
			_add_slider("尺寸", 0.5, 8.0, 0.5, float(params.get("size", 1.5)), params, "size")
			_begin_section("方向性模糊", false)
			_add_slider("角度", 0.0, 360.0, 1.0, float(params.get("angle", 0.0)), params, "angle")
			_add_slider("宽高比", 0.1, 4.0, 0.1, float(params.get("aspect", 1.0)), params, "aspect")
			_end_section()
			_add_slider("混合", 0.0, 1.0, 0.01, float(params.get("mix", 1.0)), params, "mix")
		"outline":
			var outline_hint := Label.new()
			outline_hint.text = (
				"按阈值把画面切成形状，再沿边缘生成一圈。输入 2 可接遮罩限制范围。"
				+ "像素画建议宽度 1–2 px、阈值 0.5，接「混合（最大值）」叠到画面上做高亮描边。"
			)
			outline_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			outline_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(outline_hint)
			_add_option(
				"位置", ["外侧", "内侧", "居中"], int(params.get("position", 0)), params, "position"
			)
			_add_slider("宽度", 0.5, 8.0, 0.5, float(params.get("width", 1.0)), params, "width")
			_add_slider(
				"阈值", 0.0, 1.0, 0.01, float(params.get("threshold", 0.5)), params, "threshold"
			)
		"glow":
			var glow_hint := Label.new()
			glow_hint.text = (
				"高于阈值的亮部向外扩散光晕，原图保持清晰。输入 2 可接遮罩限制范围。"
			)
			glow_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			glow_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(glow_hint)
			_add_slider("范围", 1.0, 12.0, 0.5, float(params.get("size", 3.0)), params, "size")
			_add_slider(
				"强度", 0.0, 4.0, 0.05, float(params.get("strength", 1.5)), params, "strength"
			)
			_add_slider(
				"阈值", 0.0, 1.0, 0.01, float(params.get("tolerance", 0.35)), params, "tolerance"
			)
		"bloom":
			var bloom_hint := Label.new()
			bloom_hint.text = "和发光类似，但光晕是叠加到原图上的，亮部会过曝成一片白光。"
			bloom_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			bloom_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(bloom_hint)
			_add_slider("范围", 1.0, 12.0, 0.5, float(params.get("size", 3.0)), params, "size")
			_add_slider(
				"强度", 0.0, 4.0, 0.05, float(params.get("strength", 1.0)), params, "strength"
			)
			_add_slider(
				"阈值", 0.0, 1.0, 0.01, float(params.get("tolerance", 0.5)), params, "tolerance"
			)
		"color_adjust":
			var adjust_hint := Label.new()
			adjust_hint.text = (
				"数值域的调色：曝光、对比、亮度、明度、伽马。"
				+ "图本身是灰度的，色相与饱和度请改输出节点的三段色阶。"
			)
			adjust_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			adjust_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(adjust_hint)
			_add_slider(
				"亮度", -0.5, 0.5, 0.01, float(params.get("brightness", 0.0)), params, "brightness"
			)
			_add_slider(
				"对比", -0.9, 3.0, 0.05, float(params.get("contrast", 0.0)), params, "contrast"
			)
			_begin_section("曝光与伽马", false)
			_add_slider(
				"曝光", -2.0, 2.0, 0.05, float(params.get("exposure", 0.0)), params, "exposure"
			)
			_add_slider("伽马", 0.2, 3.0, 0.05, float(params.get("gamma", 1.0)), params, "gamma")
			_add_slider("明度", 0.0, 2.0, 0.01, float(params.get("value", 1.0)), params, "value")
			_end_section()
			_add_check("反相", bool(params.get("invert", false)), params, "invert")
			_add_slider("混合", 0.0, 1.0, 0.01, float(params.get("mix", 1.0)), params, "mix")
		"edge":
			var edge_hint := Label.new()
			edge_hint.text = "比较上下左右邻居，得到描边。反向可得到内部填充。"
			edge_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			edge_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(edge_hint)
			_add_slider("采样距离", 0.5, 8.0, 0.5, float(params["radius"]), params, "radius")
			_add_slider("强度", 0.5, 8.0, 0.1, float(params["gain"]), params, "gain")
			_add_check("反向", bool(params["invert"]), params, "invert")
		"dither":
			var dither_hint := Label.new()
			dither_hint.text = "有序抖动，让 Output 的色阶产生网点而不是平涂。"
			dither_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			dither_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(dither_hint)
			_add_option(
				"矩阵",
				ShaderGraphScript.DITHER_SIZES_TEXT,
				int(params["matrix"]),
				params,
				"matrix"
			)
			_add_slider("强度", 0.0, 1.0, 0.01, float(params["strength"]), params, "strength")
		"pixelate":
			_add_slider("块大小", 1.0, 32.0, 1.0, float(params["size"]), params, "size")
		"warp":
			var warp_hint := Label.new()
			warp_hint.text = "输入 1 是扰动场，输入 2 是被扭曲的图案。"
			warp_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			warp_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(warp_hint)
			_add_slider("强度", 0.0, 0.5, 0.01, float(params.get("amount", 0.15)), params, "amount")
		"math":
			_add_option("运算", ShaderGraphScript.MATH_OPS, int(params["op"]), params, "op")
			_add_slider("强度", 0.0, 1.0, 0.01, float(params["amount"]), params, "amount")
			_add_number("色阶", 2, 32, 1, int(params["steps"]), params, "steps")
		"blend":
			_add_option("混合", ShaderGraphScript.BLEND_OPS, int(params["op"]), params, "op")
			_add_slider("比例", 0.0, 1.0, 0.01, float(params["factor"]), params, "factor")
		"output":
			_add_number("色阶", 2, 32, 1, int(params["steps"]), params, "steps")
			_add_color("颜色 A", params["color_a"], params, "color_a")
			_add_color(
				"颜色 中", params.get("color_mid", params["color_a"]), params, "color_mid"
			)
			_add_color("颜色 B", params["color_b"], params, "color_b")
			_add_slider(
				"中间位置",
				0.05,
				0.95,
				0.01,
				float(params.get("mid_position", 0.5)),
				params,
				"mid_position"
			)
			var output_hint := Label.new()
			output_hint.text = (
				"透明背景让图层变成叠加层：数值低于阈值的像素完全透明，适合光效、粒子、烟。"
			)
			output_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			output_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(output_hint)
			_add_check("透明背景", bool(params.get("transparent", false)), params, "transparent")
			_add_slider(
				"透明阈值",
				0.0,
				1.0,
				0.01,
				float(params.get("alpha_cut", 0.0)),
				params,
				"alpha_cut"
			)
			_add_check(
				"按数值取透明度",
				bool(params.get("alpha_from_value", false)),
				params,
				"alpha_from_value"
			)
	_build_animation_section(params)
	_apply_param_filter()
	_refresh_selected_preview()


## Starts a foldable group of parameters. Rows added after this call go into it,
## until [method _end_section]. Collapsed groups stay one tap away, which keeps a
## long parameter list manageable on a phone.
func _begin_section(title: String, expanded := true) -> void:
	var heading := Button.new()
	heading.text = ("▼ " if expanded else "▶ ") + title
	heading.alignment = HORIZONTAL_ALIGNMENT_LEFT
	heading.custom_minimum_size = Vector2(0, 36)
	heading.add_theme_font_size_override("font_size", 14)
	var body := VBoxContainer.new()
	body.visible = expanded
	heading.pressed.connect(
		func() -> void:
			body.visible = not body.visible
			heading.text = ("▼ " if body.visible else "▶ ") + title
	)
	_params_box.add_child(heading)
	_params_box.add_child(body)
	_param_sections.append({"title": title, "heading": heading, "box": body})
	_params_target = body


func _end_section() -> void:
	_params_target = _params_box


## Remembers a numeric parameter of the node being shown, so the animation
## section can offer it. Slider and spin box rows both end up here, which is why
## no node needs its own animation list.
func _register_animatable(
	label_text: String,
	key: String,
	min_value: float,
	max_value: float,
	step: float,
	integer: bool,
	enabled: bool
) -> void:
	if not enabled or _selected_id.is_empty():
		return
	if _animatable.has(key):
		return
	_animatable[key] = {
		"label": label_text,
		"min": min_value,
		"max": max_value,
		"step": step,
		"integer": integer,
	}


## Animation controls for one numeric parameter of the selected node. Any slider
## of any node can be picked, so growth, masks, warps and colours all animate the
## same way instead of each node having a fixed, built in animation.
func _build_animation_section(params: Dictionary) -> void:
	if _animatable.is_empty():
		return
	var anim: Dictionary = {}
	var stored: Variant = params.get("anim", null)
	if stored is Dictionary and _animatable.has(str((stored as Dictionary).get("param", ""))):
		anim = stored
	_begin_section("动画（随预览时间）", true)
	var keys: Array = _animatable.keys()
	var labels: Array = ["（不启用）"]
	for key in keys:
		labels.append(str(_animatable[key]["label"]))
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "参数"
	label.custom_minimum_size = Vector2(84, 0)
	label.add_theme_font_size_override("font_size", 14)
	row.add_child(label)
	var option := OptionButton.new()
	for text in labels:
		option.add_item(str(text))
	option.select(0 if anim.is_empty() else keys.find(str(anim["param"])) + 1)
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	option.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	option.item_selected.connect(
		func(index: int) -> void:
			if _selected_id.is_empty():
				return
			_push_undo("%s:anim" % _selected_id)
			_mark_preview_dirty(_selected_id)
			if index <= 0 or index > keys.size():
				params.erase("anim")
			else:
				var key := str(keys[index - 1])
				var start_spec: Dictionary = _animatable[key]
				params["anim"] = {
					"param": key,
					"from": float(start_spec["min"]),
					"to": float(start_spec["max"]),
					"start": 0.0,
					"end": 1.0,
					"ease": 0.4,
					"mode": 0,
				}
			_schedule_preview()
			call_deferred("_show_params", _selected_id)
	)
	row.add_child(option)
	_params_target.add_child(row)
	if anim.is_empty():
		var hint := Label.new()
		hint.text = (
			"选一个数值参数，再用预览滑杆或 ▶ 播放推进时间；"
			+ "任何滑杆都能动画，生长只是其中一种用法。"
		)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", 13)
		_params_target.add_child(hint)
		_end_section()
		return
	var spec: Dictionary = _animatable[str(anim["param"])]
	var step := maxf(float(spec["step"]), 0.001)
	var low := float(spec["min"])
	var high := float(spec["max"])
	_add_slider("起始值", low, high, step, float(anim.get("from", low)), anim, "from", false)
	_add_slider("结束值", low, high, step, float(anim.get("to", high)), anim, "to", false)
	_add_slider("开始于", 0.0, 1.0, 0.01, float(anim.get("start", 0.0)), anim, "start", false)
	_add_slider("结束于", 0.0, 1.0, 0.01, float(anim.get("end", 1.0)), anim, "end", false)
	_add_slider("缓动", 0.0, 1.0, 0.05, float(anim.get("ease", 0.4)), anim, "ease", false)
	_add_option("方式", ShaderGraphScript.ANIM_MODES, int(anim.get("mode", 0)), anim, "mode")
	_end_section()


## Hides the parameter rows whose label does not contain the filter text. A
## section whose title matches keeps all of its rows and its heading.
func _apply_param_filter() -> void:
	if _param_filter.is_empty():
		return
	var needle := _param_filter.to_lower()
	var section_boxes := {}
	var section_headings := {}
	for section: Dictionary in _param_sections:
		section_boxes[section["box"]] = section
		section_headings[section["heading"]] = section
	for section: Dictionary in _param_sections:
		var body: VBoxContainer = section["box"]
		var heading: Button = section["heading"]
		var title_hit := str(section["title"]).to_lower().contains(needle)
		var any := title_hit
		for row in body.get_children():
			var matches := title_hit or _row_label(row).to_lower().contains(needle)
			(row as CanvasItem).visible = matches
			any = any or matches
		body.visible = any
		heading.visible = any
		heading.text = ("▼ " if any else "▶ ") + str(section["title"])
	for child in _params_box.get_children():
		if section_boxes.has(child) or section_headings.has(child):
			continue
		(child as CanvasItem).visible = _row_label(child).to_lower().contains(needle)


func _section_of(box: Node) -> Variant:
	for section: Dictionary in _param_sections:
		if section["box"] == box:
			return section
	return null


## Long press on a node opens this menu. It is the touch friendly version of
## right click, which a phone does not have.
func _on_node_menu_pressed(id: int) -> void:
	var target := _menu_node_id if not _menu_node_id.is_empty() else _hold_id
	if target.is_empty() or graph.get_node_by_id(target).is_empty():
		return
	_hold_id = target
	_selected_id = target
	match id:
		0:
			_on_copy_pressed()
		1:
			_on_delete_pressed()
		2:
			_disconnect_selected()
		3:
			if not _selected_ids.has(_hold_id):
				_selected_ids.append(_hold_id)
			_on_group_pressed()
		4:
			_open_path_editor(_hold_id)
		5:
			_toggle_bypass(_hold_id)


## Tracks press and release on a node. The hold is measured by a timer that runs
## while the finger is down, so the decision no longer depends on when the release
## happens to arrive. A right click opens the menu at once, which is also what
## Android sends when a finger rests on the screen.
func _on_graph_node_input(event: InputEvent, node_id: String) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_RIGHT:
			if button.pressed:
				_prepare_node_menu(node_id)
				_open_node_menu(node_id, button.global_position)
			return
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			_prepare_node_menu(node_id)
			_hold_id = node_id
			_hold_position = button.global_position
			_hold_moved = false
			_hold_ready = false
			if is_instance_valid(_hold_timer):
				_hold_timer.start()
			return
		if is_instance_valid(_hold_timer):
			_hold_timer.stop()
		if _hold_id == node_id and _hold_ready and not _hold_moved:
			# Opening on release keeps the finger that triggered the menu from
			# also picking the first entry under it.
			_open_node_menu(node_id, _hold_position)
		elif not _node_menu.visible:
			_hold_id = ""
		_hold_ready = false
		return
	if event is InputEventMouseMotion and _hold_id == node_id:
		var motion := event as InputEventMouseMotion
		if motion.global_position.distance_to(_hold_position) > HOLD_MENU_MOVE:
			_hold_moved = true
			_hold_ready = false
			if is_instance_valid(_hold_timer):
				_hold_timer.stop()


## Enables the menu entries that only make sense for this node, before it opens.
func _prepare_node_menu(node_id: String) -> void:
	var node: Dictionary = graph.get_node_by_id(node_id)
	if node.is_empty():
		return
	# The path entry only makes sense for a node that owns control points.
	var editable := str(node.get("type", "")) == "path"
	if str(node.get("type", "")) == "follow_path":
		editable = (
			int((node["params"] as Dictionary).get("shape", 0))
			== ShaderGraphScript.PATH_CUSTOM
		)
	_node_menu.set_item_disabled(4, not editable)
	# A node without inputs has nothing to pass through, so it cannot be bypassed;
	# for the others the entry says what tapping it would do.
	var has_input := false
	var node_type := str(node.get("type", ""))
	if ShaderGraphScript.NODE_TYPES.has(node_type):
		has_input = int(ShaderGraphScript.NODE_TYPES[node_type]["inputs"]) >= 1
	_node_menu.set_item_disabled(5, not has_input)
	_node_menu.set_item_text(5, "启用此节点" if bool(node.get("bypass", false)) else "旁路此节点")


## Shows the context menu of [param node_id] at [param position]. The node is
## remembered separately from the press, so the entries still know their target
## after the finger is lifted and while the menu is open.
func _open_node_menu(node_id: String, position: Vector2) -> void:
	if graph.get_node_by_id(node_id).is_empty():
		return
	_hold_id = node_id
	_menu_node_id = node_id
	_node_menu.popup(Rect2i(Vector2i(position), Vector2i.ZERO))


## Fires while the finger is still on the node, so a long press is recognised
## even if the release event never arrives (Android occasionally drops it).
func _on_hold_timeout() -> void:
	if _hold_id.is_empty() or _hold_moved:
		return
	_hold_ready = true


func _on_node_menu_hidden() -> void:
	_hold_id = ""
	_menu_node_id = ""
	_hold_ready = false


static func _row_label(row: Node) -> String:
	if row is CheckBox:
		return (row as CheckBox).text
	if row is Label:
		return (row as Label).text
	for child in row.get_children():
		if child is Label:
			return (child as Label).text
	return ""


func _add_option(
	label_text: String,
	items: Array,
	selected: int,
	params: Dictionary,
	key: String,
	rebuild := false
) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(84, 0)
	label.add_theme_font_size_override("font_size", 14)
	row.add_child(label)
	var option := OptionButton.new()
	for item in items:
		option.add_item(str(item))
	option.select(clampi(selected, 0, items.size() - 1))
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	option.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	option.item_selected.connect(
		func(index: int) -> void:
			_push_undo("%s:%s" % [_selected_id, key])
			_mark_preview_dirty(_selected_id)
			params[key] = index
			_schedule_preview()
			# Some options change which controls are shown, like the path shape.
			if rebuild and not _selected_id.is_empty():
				call_deferred("_show_params", _selected_id)
	)
	row.add_child(option)
	_params_target.add_child(row)


## Layer reading controls of a canvas node.
func _build_canvas_image_section(id: String, params: Dictionary) -> void:
	var source_hint := Label.new()
	source_hint.text = (
		"读取主窗口的图层内容，预览会跟着画布自动刷新。"
		+ "亮度通道会乘上透明度，透明处视为 0。帧号从 0 开始。"
	)
	source_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	source_hint.add_theme_font_size_override("font_size", 13)
	_params_target.add_child(source_hint)
	var project := Global.current_project
	var layer_names: Array = []
	var layer_index := 0
	if project != null:
		for i in project.layers.size():
			layer_names.append("%d %s" % [i + 1, project.layers[i].name])
		layer_index = clampi(int(params.get("layer", 0)), 0, layer_names.size() - 1)
	if layer_names.is_empty():
		layer_names.append("无图层")
	_add_option("图层", layer_names, layer_index, params, "layer")
	_add_option(
		"帧",
		["当前帧", "指定帧", "跟随动画"],
		int(params.get("frame_mode", 0)),
		params,
		"frame_mode",
		true
	)
	if int(params.get("frame_mode", 0)) == 1:
		_add_number("帧号", 0, 999, 1, int(params.get("frame", 0)), params, "frame")
	_add_option(
		"通道",
		["亮度×透明度", "透明度", "反向透明度"],
		int(params.get("channel", 0)),
		params,
		"channel"
	)
	_add_check("反相", bool(params.get("invert", false)), params, "invert")
	_build_source_crop_section(id, params)
	_params_target.add_child(
		_make_button(
			"绘画窗口…", func() -> void: _open_canvas_editor(id), "在画布大小的窗口里直接画材质"
		)
	)
	var draw_hint := Label.new()
	draw_hint.text = "窗口按画布大小打开，只有铅笔、橡皮、填充、方形、圆形，只用白色；完成后写回这个节点读取的图层。"
	draw_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	draw_hint.add_theme_font_size_override("font_size", 13)
	_params_target.add_child(draw_hint)


## Stroke controls of a canvas node in path mode.
func _build_canvas_line_section(id: String, params: Dictionary) -> void:
	var line_hint := Label.new()
	line_hint.text = (
		"把「路径」节点接到输入 1，这里把曲线画成像素线条。"
		+ "线宽按画布短边比例；下面的曲线是线宽沿路径的变化。"
	)
	line_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line_hint.add_theme_font_size_override("font_size", 13)
	_params_target.add_child(line_hint)
	_add_slider("线宽", 0.005, 0.3, 0.005, float(params.get("width", 0.06)), params, "width")
	_add_slider("羽化", 0.0, 0.2, 0.005, float(params.get("soft", 0.0)), params, "soft")
	_add_check("闭合填充（路径需闭合）", bool(params.get("fill", false)), params, "fill")
	var curve_hint := Label.new()
	curve_hint.text = "线宽曲线：横轴是从起点到终点的位置，纵轴是线宽倍率，拖动圆点调整。"
	curve_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	curve_hint.add_theme_font_size_override("font_size", 13)
	_params_target.add_child(curve_hint)
	_add_width_profile(id, params)


## Curve strip for the width along the stroke. The values live in the node
## parameters, so the graph stays a plain dictionary.
func _add_width_profile(id: String, params: Dictionary) -> void:
	var curve := ShaderWidthCurveScript.new()
	curve.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	curve.set_profile(params.get("profile", []))
	curve.changed.connect(
		func(values: Array) -> void:
			_push_undo("%s:profile" % id)
			_mark_preview_dirty(id)
			params["profile"] = values
			_schedule_preview()
	)
	_params_target.add_child(curve)


## Crop rectangle of the imported art, with a preview of what the node really
## reads. Cropping a leaf out of a sheet is how a scatter brush is made, so the
## numbers and the result belong in the same place.
func _build_source_crop_section(node_id: String, params: Dictionary) -> void:
	var node: Dictionary = graph.get_node_by_id(node_id)
	var image_size := Vector2i.ZERO
	if not node.is_empty():
		image_size = graph.source_image_size(node)
	_begin_section("裁切", true)
	if image_size.x <= 0 or image_size.y <= 0:
		var empty_hint := Label.new()
		empty_hint.text = "当前图层读不到内容，先画出材质再来裁切。"
		empty_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty_hint.add_theme_font_size_override("font_size", 13)
		_params_target.add_child(empty_hint)
		_end_section()
		return
	var hint := Label.new()
	hint.text = "按图层像素裁切一块当材质，宽或高填 0 表示一直到边缘；下面是裁切后的实际取样。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	_params_target.add_child(hint)
	_add_number(
		"X",
		0,
		maxi(image_size.x - 1, 0),
		1,
		int(params.get("crop_x", 0)),
		params,
		"crop_x",
		false,
		true
	)
	_add_number(
		"Y",
		0,
		maxi(image_size.y - 1, 0),
		1,
		int(params.get("crop_y", 0)),
		params,
		"crop_y",
		false,
		true
	)
	_add_number(
		"宽", 0, image_size.x, 1, int(params.get("crop_w", 0)), params, "crop_w", false, true
	)
	_add_number(
		"高", 0, image_size.y, 1, int(params.get("crop_h", 0)), params, "crop_h", false, true
	)
	var region: Rect2i = ShaderGraphScript.source_crop(params, image_size)
	var info := Label.new()
	info.text = "取样 %d×%d / 图层 %d×%d" % [
		region.size.x, region.size.y, image_size.x, image_size.y
	]
	info.add_theme_font_size_override("font_size", 12)
	_params_target.add_child(info)
	_add_source_preview(node, region)
	_params_target.add_child(
		_make_button("重置裁切", func() -> void: _reset_source_crop(node_id, params))
	)
	_end_section()


## Draws the cropped part of the layer, so the material can be checked while the
## numbers change. Nearest filtering keeps the pixels readable.
func _add_source_preview(node: Dictionary, region: Rect2i) -> void:
	var image: Image = graph.source_image(node)
	if image == null or image.is_empty() or region.size.x <= 0 or region.size.y <= 0:
		return
	var cropped := image.get_region(region)
	var preview := TextureRect.new()
	preview.texture = ImageTexture.create_from_image(cropped)
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = Vector2(0, SOURCE_PREVIEW_HEIGHT)
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_params_target.add_child(preview)


## Puts the crop back to the whole layer, which is the default of a new node.
func _reset_source_crop(node_id: String, params: Dictionary) -> void:
	_push_undo("%s:crop" % node_id)
	params["crop_x"] = 0
	params["crop_y"] = 0
	params["crop_w"] = 0
	params["crop_h"] = 0
	_mark_preview_dirty(node_id)
	_schedule_preview()
	call_deferred("_show_params", node_id)


## Opens the small drawing window of a canvas node. It paints into the same layer
## the node reads, so the material can be made without leaving the composer.
func _open_canvas_editor(node_id: String) -> void:
	var node: Dictionary = graph.get_node_by_id(node_id)
	if node.is_empty():
		return
	var cel: BaseCel = graph.source_cel(node)
	if cel == null or cel.get_image() == null:
		Global.notification_label("这个节点读不到图层内容")
		return
	if not is_instance_valid(_canvas_editor):
		_canvas_popup = PopupPanel.new()
		_canvas_popup.transparent_bg = false
		add_child(_canvas_popup)
		var frame := MarginContainer.new()
		for side in ["left", "right", "top", "bottom"]:
			frame.add_theme_constant_override("margin_" + side, 12)
		_canvas_popup.add_child(frame)
		_canvas_editor = ShaderCanvasEditorScript.new()
		_canvas_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_canvas_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
		frame.add_child(_canvas_editor)
		_canvas_editor.finished.connect(_finish_canvas_editor)
		_canvas_popup.popup_hide.connect(_finish_canvas_editor)
	_canvas_node_id = node_id
	_canvas_editor.setup(cel.get_image().duplicate())
	_popup_canvas_editor()


## Sizes the drawing window to the canvas, inside the visible part of the screen.
## The board keeps the aspect of the artwork, so the pixels are drawn square.
func _popup_canvas_editor() -> void:
	if not is_instance_valid(_canvas_popup) or not is_instance_valid(_canvas_editor):
		return
	var visible := _visible_popup_rect()
	var room := Vector2i(mini(visible.size.x, int(size.x)), mini(visible.size.y, int(size.y)))
	var image_size: Vector2i = _canvas_editor.image_size()
	if image_size.x <= 0 or image_size.y <= 0:
		image_size = Vector2i(64, 64)
	var room_for_board := Vector2(room) * Vector2(0.86, 0.72)
	var factor := minf(
		room_for_board.x / float(image_size.x), room_for_board.y / float(image_size.y)
	)
	factor = maxf(factor, 1.0)
	var target := Vector2i(
		mini(int(float(image_size.x) * factor) + 26, room.x),
		mini(int(float(image_size.y) * factor) + 160, room.y)
	)
	_canvas_popup.popup_centered_clamped(target, 0.95)


## Closes the drawing window and writes what was drawn into the layer, as one
## undo step, so the drawing can be undone like any other edit.
func _finish_canvas_editor() -> void:
	if not is_instance_valid(_canvas_editor):
		return
	var editor = _canvas_editor
	var node_id := _canvas_node_id
	_canvas_editor = null
	_canvas_node_id = ""
	if is_instance_valid(_canvas_popup):
		_canvas_popup.hide()
		_canvas_popup.queue_free()
		_canvas_popup = null
	if node_id.is_empty() or not editor.is_modified():
		return
	var image: Image = editor.take_result()
	if image != null:
		_write_canvas_image(node_id, image)


## Puts the painted buffer back into the cel the node reads.
func _write_canvas_image(node_id: String, image: Image) -> void:
	var node: Dictionary = graph.get_node_by_id(node_id)
	var project := Global.current_project
	if node.is_empty() or project == null:
		return
	var cel: BaseCel = graph.source_cel(node)
	if cel == null or not cel is PixelCel:
		return
	var replaced = cel.get_image()
	var incoming := _make_cel_image(image, project)
	project.undo_redo.create_action("绘制画布材质")
	project.undo_redo.add_do_method(_set_cel_image.bind(cel, incoming))
	project.undo_redo.add_undo_method(_set_cel_image.bind(cel, replaced))
	project.undo_redo.add_do_method(Global.undo_or_redo.bind(false))
	project.undo_redo.add_undo_method(Global.undo_or_redo.bind(true))
	project.undo_redo.commit_action()
	graph.clear_source_cache()
	_mark_preview_dirty(node_id)
	_schedule_preview()
	# The crop preview and the reported source size both follow the layer.
	if _selected_id == node_id:
		call_deferred("_show_params", node_id)


## Opens the path window from the side panel. The control points live in a large
## separate window, so the panel stays short and the node only shows a thumbnail.
func _add_path_button(id: String) -> void:
	var row := HBoxContainer.new()
	row.add_child(_make_button("编辑路径…", func() -> void: _open_path_editor(id)))
	_params_box.add_child(row)
	var hint := Label.new()
	hint.text = "节点上显示缩略图；点上面的按钮打开大窗口编辑控制点。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	_params_box.add_child(hint)


## Builds the separate path window. It is recreated on every opening, so it
## always starts from the current points of one node.
func _open_path_editor(node_id: String) -> void:
	var node: Dictionary = graph.get_node_by_id(node_id)
	if node.is_empty():
		return
	if _path_popup_node == node_id and is_instance_valid(_path_popup):
		# The same node keeps the window it already has, points and all.
		_popup_path_editor()
		return
	if is_instance_valid(_path_popup):
		_path_popup.queue_free()
		_path_popup = null
	_path_popup_node = node_id
	var type_name := str(node["type"])
	var bezier := type_name == "path"
	var params: Dictionary = node["params"]
	var stored: Array = params.get("points", [])
	if stored.size() < 2:
		# Graphs saved before the editor existed get the default shape.
		if bezier:
			stored = ShaderPathEditorScript.default_bezier()
		else:
			stored = ShaderPathEditorScript.default_points()
		params["points"] = stored

	_path_popup = PopupPanel.new()
	_path_popup.transparent_bg = false
	add_child(_path_popup)
	var frame := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		frame.add_theme_constant_override("margin_" + side, 12)
	_path_popup.add_child(frame)
	# The window is kept inside the visible part of the screen, so the content
	# scrolls instead of pushing the panel past the top and bottom edges of a
	# phone. The canvas itself still gets all the height that is left over.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_child(scroll)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)

	var title := Label.new()
	title.text = "编辑路径 · %s" % ShaderGraphScript.NODE_TYPES[type_name]["label"]
	title.add_theme_font_size_override("font_size", 17)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(title)

	var hint := Label.new()
	if bezier:
		# Short enough to stay on one line in landscape, which is the tightest
		# case for the window height.
		hint.text = "点空白处或线条上添加顶点；拖动顶点移动，拖小圆点改曲率，长按删除。"
	else:
		hint.text = "点空白处新增控制点，拖动移动，长按删除；曲线由节点统一平滑。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	column.add_child(hint)

	var editor := ShaderPathEditorScript.new()
	if bezier:
		editor.set_bezier(stored, bool(params.get("closed", false)))
		if bool(params.get("closed", false)):
			# The editor gives a closed path a tangent across the seam, so the
			# node takes the repaired handles instead of generating a corner.
			params["points"] = editor.payload()
	else:
		editor.set_points(stored, float(params.get("phase", 0.0)))
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(editor)
	# The canvas takes whatever height the rest of the window leaves, so the
	# window can stay inside the screen instead of asking for a fixed 300 px.
	editor.custom_minimum_size = Vector2(0, PATH_EDITOR_MIN_HEIGHT)
	_path_editor = editor
	editor.points_changed.connect(
		func(new_points: Array) -> void:
			_push_undo("%s:points" % node_id)
			_mark_preview_dirty(node_id)
			params["points"] = new_points
			_schedule_preview()
	)

	var buttons := HFlowContainer.new()
	# A flow container wraps the buttons instead of squeezing them on a phone.
	buttons.add_theme_constant_override("h_separation", 8)
	buttons.add_theme_constant_override("v_separation", 6)
	buttons.add_child(_make_button("删除选中点", func() -> void: editor.remove_selected()))
	buttons.add_child(_make_button("平滑全部", func() -> void: editor.smooth_all()))
	buttons.add_child(_make_button("反转路径", func() -> void: editor.reverse_points()))
	buttons.add_child(_make_button("重置路径", func() -> void: editor.reset_to_square()))
	buttons.add_child(_make_button("完成", func() -> void: _close_path_editor()))
	column.add_child(buttons)

	if bezier:
		# A real bezier vertex has collinear handles, so dragging one mirrors the
		# other unless the user asks for a corner.
		var mirror := CheckBox.new()
		# A short label, so the window can be narrow on a phone; the long version
		# lives in the tooltip.
		mirror.text = "对称手柄"
		mirror.tooltip_text = "拖一侧手柄时镜像另一侧"
		mirror.button_pressed = editor.smooth_handles
		mirror.custom_minimum_size = Vector2(0, TOUCH_SIZE)
		mirror.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
		mirror.toggled.connect(func(pressed: bool) -> void: editor.smooth_handles = pressed)
		column.add_child(mirror)

	# The window keeps the size it is popped up with; the canvas is resized to
	# the leftover height and everything else scrolls when that is not enough.
	# The hint only knows how tall it wrapped after it got its width, so it is
	# fitted again whenever it changes height.
	scroll.resized.connect(
		func() -> void: _fit_path_canvas(scroll, column, editor)
	)
	hint.resized.connect(func() -> void: _fit_path_canvas(scroll, column, editor))
	_popup_path_editor()
	_fit_path_canvas.call_deferred(scroll, column, editor)


func _close_path_editor() -> void:
	if is_instance_valid(_path_popup):
		_path_popup.hide()
	_path_popup_node = ""
	_path_editor = null


## Shows the path window with a size that stays inside the visible part of the
## screen. The ratio is only a target: a phone in landscape has far less height
## than the window would like, so the size is clamped and the content scrolls.
func _popup_path_editor() -> void:
	if not is_instance_valid(_path_popup):
		return
	var visible := _visible_popup_rect()
	var room := Vector2i(
		int(minf(float(visible.size.x), size.x)), int(minf(float(visible.size.y), size.y))
	)
	# Never ask for more than the room there is, even on a very small screen.
	var floor_size := Vector2i(mini(200, room.x), mini(200, room.y))
	var target := Vector2i(
		maxi(int(room.x * PATH_POPUP_RATIO), floor_size.x),
		maxi(int(room.y * PATH_POPUP_RATIO), floor_size.y)
	)
	_path_popup.popup_centered_clamped(target, PATH_POPUP_RATIO)


## The area of the screen a subwindow may cover. Mobile devices draw under the
## status and navigation bars, so the safe area is respected as well.
func _visible_popup_rect() -> Rect2i:
	var host := get_window()
	if host == null:
		return Rect2i(Vector2i.ZERO, Vector2i(size))
	var screen := DisplayServer.window_get_current_screen(host.get_window_id())
	var visible := DisplayServer.screen_get_usable_rect(screen)
	if visible.size.x <= 0 or visible.size.y <= 0:
		visible = Rect2i(host.position, host.size)
	if OS.has_feature("mobile"):
		var safe := DisplayServer.get_display_safe_area()
		if safe.size.x > 0 and safe.size.y > 0:
			var clipped := visible.intersection(safe)
			if clipped.size.x > 0 and clipped.size.y > 0:
				visible = clipped
	return visible


## Gives the control point canvas the height the rest of the window leaves. The
## window never grows past the screen, so on a short screen the canvas stops at
## [constant PATH_EDITOR_MIN_HEIGHT] and the rest of the column scrolls.
func _fit_path_canvas(scroll: ScrollContainer, column: VBoxContainer, editor: Control) -> void:
	if not is_instance_valid(scroll) or not is_instance_valid(column):
		return
	if not is_instance_valid(editor) or scroll.size.y <= 1.0:
		return
	var fixed := column.get_combined_minimum_size().y - editor.custom_minimum_size.y
	var target := maxf(scroll.size.y - fixed - 2.0, PATH_EDITOR_MIN_HEIGHT)
	if absf(editor.custom_minimum_size.y - target) > 1.0:
		editor.custom_minimum_size = Vector2(0, target)


func _add_slider(
	label_text: String,
	min_value: float,
	max_value: float,
	step: float,
	value: float,
	params: Dictionary,
	key: String,
	animatable := true
) -> void:
	_register_animatable(label_text, key, min_value, max_value, step, false, animatable)
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(84, 0)
	label.add_theme_font_size_override("font_size", 14)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	# Arrows on both sides step by exactly one step, which is far easier than
	# trying to hit a precise spot on the track with a finger.
	row.add_child(
		_make_button(
			"−", func() -> void: _step_slider(slider, -1.0), "减一档", Vector2(34, TOUCH_SIZE)
		)
	)
	row.add_child(slider)
	row.add_child(
		_make_button(
			"+", func() -> void: _step_slider(slider, 1.0), "加一档", Vector2(34, TOUCH_SIZE)
		)
	)
	var display := Label.new()
	display.text = _format_number(value, step)
	display.custom_minimum_size = Vector2(48, 0)
	display.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(display)
	slider.value_changed.connect(
		func(new_value: float) -> void:
			_push_undo("%s:%s" % [_selected_id, key])
			_mark_preview_dirty(_selected_id)
			params[key] = new_value
			display.text = _format_number(new_value, step)
			_schedule_preview()
	)
	_params_target.add_child(row)


## One arrow press moves a slider by exactly one step, so a value can be tuned
## without hitting the track at the right pixel.
func _step_slider(slider: HSlider, direction: float) -> void:
	var step := maxf(slider.step, 0.0001)
	var next := snappedf(slider.value + step * direction, step)
	slider.value = clampf(next, slider.min_value, slider.max_value)


## Same for the drag number field, whose value does not emit a change when it is
## set from code, so the caller's apply callback is run here.
func _step_changer(changer: Control, direction: float, apply: Callable) -> void:
	var step := maxf(float(changer.get("step")), 0.0001)
	var next := clampf(
		float(changer.get("value")) + step * direction,
		float(changer.get("min_value")),
		float(changer.get("max_value"))
	)
	changer.set("value", next)
	apply.call(float(changer.get("value")))


func _add_number(
	label_text: String,
	min_value: int,
	max_value: int,
	step: int,
	value: int,
	params: Dictionary,
	key: String,
	animatable := true,
	rebuild := false
) -> void:
	_register_animatable(label_text, key, min_value, max_value, step, true, animatable)
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(84, 0)
	label.add_theme_font_size_override("font_size", 14)
	row.add_child(label)
	var apply := func(new_value: float) -> void:
		_push_undo("%s:%s" % [_selected_id, key])
		_mark_preview_dirty(_selected_id)
		params[key] = int(new_value)
		_schedule_preview()
		# The crop numbers change the source preview drawn under them.
		if rebuild and not _selected_id.is_empty():
			call_deferred("_show_params", _selected_id)
	if _drag_numbers:
		# A drag strip instead of a text field, so the keyboard never covers the
		# parameter panel on a phone. The arrows beside it step by exactly one.
		var changer := ShaderValueChangerScript.new()
		changer.set_range(min_value, max_value, step, true, value)
		changer.custom_minimum_size = Vector2(0, TOUCH_SIZE)
		changer.value_changed.connect(apply)
		row.add_child(
			_make_button(
				"−",
				func() -> void: _step_changer(changer, -1.0, apply),
				"减一档",
				Vector2(34, TOUCH_SIZE)
			)
		)
		row.add_child(changer)
		row.add_child(
			_make_button(
				"+",
				func() -> void: _step_changer(changer, 1.0, apply),
				"加一档",
				Vector2(34, TOUCH_SIZE)
			)
		)
	else:
		var spin := SpinBox.new()
		spin.min_value = min_value
		spin.max_value = max_value
		spin.step = step
		spin.value = value
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.custom_minimum_size = Vector2(0, TOUCH_SIZE)
		spin.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
		spin.value_changed.connect(apply)
		row.add_child(spin)
	_params_target.add_child(row)


func _add_check(
	label_text: String, value: bool, params: Dictionary, key: String, rebuild := false
) -> void:
	var check := CheckBox.new()
	check.text = label_text
	check.button_pressed = value
	check.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	check.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	check.toggled.connect(
		func(pressed: bool) -> void:
			_push_undo("%s:%s" % [_selected_id, key])
			_mark_preview_dirty(_selected_id)
			params[key] = pressed
			_schedule_preview()
			# Some checkboxes change which controls are shown, like the closed path.
			if rebuild and not _selected_id.is_empty():
				call_deferred("_show_params", _selected_id)
	)
	_params_target.add_child(check)


func _add_color(label_text: String, value: Color, params: Dictionary, key: String) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(84, 0)
	row.add_child(label)
	var picker := ColorPickerButton.new()
	picker.color = value
	picker.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.color_changed.connect(
		func(color: Color) -> void:
			_push_undo("%s:%s" % [_selected_id, key])
			_mark_preview_dirty(_selected_id)
			params[key] = color
			_schedule_preview()
	)
	row.add_child(picker)
	_params_target.add_child(row)


static func _format_number(value: float, step: float) -> String:
	if step >= 1.0:
		return "%d" % int(value)
	return "%.2f" % value


## Opens the preview at a size that can actually be judged on a phone.
func _on_preview_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return
	_show_big_preview()
	get_viewport().set_input_as_handled()


func _show_big_preview() -> void:
	if not is_instance_valid(_preview_popup):
		_preview_popup = PopupPanel.new()
		_preview_big = TextureRect.new()
		_preview_big.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_preview_big.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_preview_big.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_preview_big.custom_minimum_size = Vector2(280, 280)
		_preview_popup.add_child(_preview_big)
		add_child(_preview_popup)
	if is_instance_valid(_preview):
		_preview_big.texture = _preview.texture
	var side := int(minf(size.x, size.y) * 0.82)
	_preview_popup.popup_centered(Vector2i(maxi(side, 220), maxi(side, 220)))


func _schedule_preview() -> void:
	if is_instance_valid(_preview_timer):
		_preview_timer.start()


## Waits for a sliced preview that is still being painted, so a one shot
## generation cannot clear its caches halfway through.
func _wait_for_preview() -> void:
	while _preview_busy and is_inside_tree():
		await get_tree().process_frame


func _refresh_preview() -> void:
	if not is_instance_valid(_preview) or not visible:
		return
	if _suspend_preview:
		_preview_pending = false
		return
	var project := Global.current_project
	if project == null:
		return
	if project.size != _preview_canvas_size:
		# A resized canvas changes the shape of both preview boxes.
		_preview_canvas_size = project.size
		_apply_layout()
	if _preview_busy:
		# The running pass picks up the newest state when it ends, so stacking
		# another full generation here would only add work.
		_preview_pending = true
		return
	_preview_busy = true
	var playing := _is_playing()
	# The size follows the measured cost, so a slow device renders a smaller
	# preview instead of freezing on a big one. Fast ones keep the full size.
	var cap := PREVIEW_LIMIT_HEAVY if graph.is_expensive() else PREVIEW_LIMIT
	if playing:
		# Playback is judged by how smooth it looks, not by the last pixel.
		cap = mini(cap, PREVIEW_LIMIT_PLAYBACK)
	var budget := PLAYBACK_BUDGET_MSEC if playing else PREVIEW_BUDGET_MSEC
	var side := cap
	if _preview_side > 0 and _preview_msec > 0.5:
		side = clampi(int(float(_preview_side) * sqrt(budget / _preview_msec)), 48, cap)
		# Skip tiny changes, so the picture does not flicker between sizes.
		if absi(side - _preview_side) < 8:
			side = _preview_side
	_preview_side = side
	var preview_size := Vector2i(mini(project.size.x, side), mini(project.size.y, side))
	graph.time = _phase.value if is_instance_valid(_phase) else 0.0
	if is_instance_valid(_path_editor):
		_path_editor.set_phase(graph.time)
	var started := Time.get_ticks_usec()
	# Painted in slices, so dragging a node or panning keeps working while the
	# animation runs instead of freezing for the whole generation.
	var image: Image = await graph.generate_sliced(preview_size, PREVIEW_SLICE_MSEC)
	_preview_msec = float(Time.get_ticks_usec() - started) / 1000.0
	if not is_instance_valid(_preview):
		_preview_busy = false
		return
	_preview.texture = ImageTexture.create_from_image(image)
	# A clock or a live source changes every thumbnail; without them only the
	# branches touched by the edit need a new picture.
	if graph.uses_time() or graph.uses_source():
		_all_previews_dirty = true
	# There is one thumbnail per node, so they are spread over several frames
	# while playing instead of competing with the main preview.
	if playing:
		_queue_animated_previews()
		# The side panel follows the clock too, but only for a node that moves.
		if graph.time_dependent_ids().has(_selected_id):
			_refresh_selected_preview()
	else:
		_refresh_node_previews()
		_refresh_selected_preview()
	if is_instance_valid(_preview_big) and _preview_popup.visible:
		_preview_big.texture = _preview.texture
	# A graph that reads the artwork keeps following it while the user draws.
	if is_instance_valid(_source_timer):
		if graph.uses_source() and _source_timer.is_stopped():
			_source_timer.start()
		elif not graph.uses_source() and not _source_timer.is_stopped():
			_source_timer.stop()
	_status.text = "预览 %d×%d · 输出 %d×%d · 节点 %d · %s" % [
		preview_size.x,
		preview_size.y,
		project.size.x,
		project.size.y,
		graph.nodes.size(),
		"动态" if graph.uses_time() else "静态",
	]
	_preview_busy = false
	if _preview_pending:
		_preview_pending = false
		_refresh_preview()


## Launches the echo of earlier frames, which is the quickest way to judge an
## animated graph before committing it.
func _is_playing() -> bool:
	return is_instance_valid(_play_timer) and not _play_timer.is_stopped()


## Queues every moving node at once while the clock runs. Only the nodes that
## read the time need a new picture, and queuing them together keeps them in
## step with the preview instead of refreshing one node per frame.
func _queue_animated_previews() -> void:
	if _node_previews.is_empty():
		return
	var moving: Array[String] = graph.time_dependent_ids()
	if moving.is_empty():
		return
	# A queue longer than everything it has to show means the drain cannot keep
	# up; starting over is better than painting stale frames first.
	var limit := maxi(moving.size() * 2 + 8, 16)
	if _thumb_queue.size() > limit:
		_thumb_queue.clear()
	for node_id in moving:
		var entry: Dictionary = _node_previews.get(node_id, {})
		var frame: Control = entry.get("frame", null)
		if not is_instance_valid(frame) or not frame.visible:
			continue
		if not _thumb_queue.has(node_id):
			_thumb_queue.append(node_id)


func _on_play_pressed() -> void:
	if not is_instance_valid(_play_timer):
		return
	if _play_timer.is_stopped():
		_play_timer.wait_time = 1.0 / maxf(PREVIEW_FPS, 1.0)
		_play_timer.start()
		_play_button.text = "⏸"
	else:
		_play_timer.stop()
		_play_button.text = "▶"
		# The thumbnails skipped during playback catch up in one go.
		_refresh_node_previews()
		_refresh_preview()


func _advance_playback() -> void:
	var frames := _frame_count_value()
	_playhead = fmod(_playhead + 1.0 / float(frames), 1.0)
	if is_instance_valid(_phase):
		_phase.set_value_no_signal(_playhead)
	_refresh_preview()


## Builds the ready made pixel sea, so a dynamic result is one click away.
func _on_ocean_preset_pressed() -> void:
	_push_undo()
	graph.build_ocean_preset()
	_selected_id = ""
	_show_params("")
	_refresh_graph()
	_refresh_preview()


## Builds the growing pixel tree. The phase is put at the end first, so the page
## shows the full tree and pressing play reveals how it grows.
func _on_tree_preset_pressed() -> void:
	_push_undo()
	graph.build_tree_preset()
	if is_instance_valid(_phase):
		_phase.set_value_no_signal(1.0)
	_selected_id = ""
	_show_params("")
	_refresh_graph()
	_refresh_preview()


## Builds a vine that grows along its path, driven by the animated reveal value
## of the path node.
func _on_path_growth_preset_pressed() -> void:
	_push_undo()
	graph.build_path_growth_preset()
	if is_instance_valid(_phase):
		_phase.set_value_no_signal(1.0)
	_selected_id = ""
	_show_params("")
	_refresh_graph()
	_refresh_preview()


## Builds content revealed by an animated mask, the classic bottom up growth.
func _on_mask_growth_preset_pressed() -> void:
	_push_undo()
	graph.build_mask_growth_preset()
	if is_instance_valid(_phase):
		_phase.set_value_no_signal(1.0)
	_selected_id = ""
	_show_params("")
	_refresh_graph()
	_refresh_preview()


## Builds leaves along a vine: the path is the stem and the placement, and its
## animated reveal grows the whole plant.
func _on_vine_preset_pressed() -> void:
	_push_undo()
	graph.build_vine_preset()
	if is_instance_valid(_phase):
		_phase.set_value_no_signal(1.0)
	_selected_id = ""
	_show_params("")
	_refresh_graph()
	_refresh_preview()


## Builds a pixel bush. With [param layer_material] the current layer is the
## brush; otherwise a leaf path is drawn for it, so the preset also works on an
## empty canvas.
func _on_scatter_preset_pressed(layer_material := true) -> void:
	_push_undo()
	graph.build_scatter_preset(layer_material)
	if is_instance_valid(_phase):
		_phase.set_value_no_signal(0.0)
	_selected_id = ""
	_show_params("")
	_refresh_graph()
	_refresh_preview()


## Generates the image(s) at the project size and adds them as a new layer.
func _on_add_layer_pressed() -> void:
	# A sliced preview may still own the per frame caches, so let it finish
	# before the frames are generated.
	_suspend_preview = true
	await _wait_for_preview()
	await _on_add_layer_now()
	_suspend_preview = false


func _on_add_layer_now() -> void:
	var project := Global.current_project
	if project == null:
		return
	var frames := _frame_count_value()
	# A big animated graph takes a moment, so show what is going on first.
	if is_instance_valid(_status):
		_status.text = "正在生成 %d 帧…" % frames
		await get_tree().process_frame
	var images: Array[Image] = []
	if graph.uses_time():
		# One image per frame, so the layer animates along the timeline.
		for i in frames:
			graph.time = float(i) / float(frames)
			images.append(graph.generate(project.size))
	else:
		graph.time = 0.0
		images.append(graph.generate(project.size))
	if is_instance_valid(_editing_layer) and project.layers.has(_editing_layer):
		_update_shader_layer(project, project.layers.find(_editing_layer), images)
		_editing_layer.set_meta("shader_graph", graph.to_dict())
		_editing_layer.set_meta("shader_frames", frames)
		Global.notification_label("Shader layer updated")
	else:
		# The graph is attached before the layer is committed, because the timeline
		# builds the layer row (and its edit button) while the action runs.
		_add_animated_layer(
			project,
			images,
			"Shader Layer",
			{"shader_graph": graph.to_dict(), "shader_frames": frames}
		)
		Global.notification_label("Shader layer added")
	close_page()


## Rewrites the cels of an existing shader layer, undoable.
static func _update_shader_layer(project: Project, layer_index: int, images: Array[Image]) -> void:
	if images.is_empty() or layer_index < 0 or layer_index >= project.layers.size():
		return
	project.undo_redo.create_action("Update Shader Layer")
	var count := mini(project.frames.size(), images.size())
	for f in count:
		var cel: BaseCel = project.frames[f].cels[layer_index]
		if not (cel is PixelCel):
			continue
		var replaced: ImageExtended = (cel as PixelCel).image
		var incoming := _make_cel_image(images[f], project)
		project.undo_redo.add_do_method(_set_cel_image.bind(cel, incoming))
		project.undo_redo.add_undo_method(_set_cel_image.bind(cel, replaced))
	project.undo_redo.add_do_method(Global.undo_or_redo.bind(false))
	project.undo_redo.add_undo_method(Global.undo_or_redo.bind(true))
	project.undo_redo.commit_action()


## The frame count is a spin box on desktop and a drag strip on a touch screen,
## where the keyboard would cover the preview.
func _make_frame_count_control() -> Control:
	var current := 8
	if _drag_numbers:
		var changer := ShaderValueChangerScript.new()
		changer.suffix = " 帧"
		changer.set_range(1, 60, 1, true, current)
		changer.custom_minimum_size = Vector2(96, TOUCH_SIZE)
		changer.tooltip_text = "生成多少帧，左右滑动调整"
		return changer
	var spin := SpinBox.new()
	spin.min_value = 1
	spin.max_value = 60
	spin.step = 1
	spin.value = current
	spin.tooltip_text = "生成多少帧"
	spin.custom_minimum_size = Vector2(78, TOUCH_SIZE)
	spin.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	return spin


## Reads the frame count from whichever control the toolbar has.
func _frame_count_value() -> int:
	if not is_instance_valid(_frame_count):
		return 1
	return maxi(int(_frame_count.get("value")), 1)


func _set_frame_count_value(frames: int) -> void:
	if is_instance_valid(_frame_count):
		_frame_count.set("value", frames)


## Builds the cel image of the project. Indexed projects map colours to the
## palette, so the indices are converted too and transparency is restored
## afterwards, otherwise the map would be index 0 everywhere and alpha would be
## replaced by the nearest palette colour.
static func _make_cel_image(image: Image, project: Project) -> ImageExtended:
	var result := ImageExtended.create_from_image(image, project.is_indexed())
	if result.is_indexed:
		result.convert_rgb_to_indexed()
		for y in result.get_height():
			for x in result.get_width():
				if image.get_pixel(x, y).a < 0.5:
					result.set_pixel(x, y, Color(0, 0, 0, 0))
	return result


static func _set_cel_image(cel: PixelCel, image: ImageExtended) -> void:
	cel.image = image
	cel.update_texture()


## Adds one cel per frame out of [param images], creating the missing frames when
## the graph is animated, all in a single undo step.
static func _add_animated_layer(
	project: Project, images: Array[Image], layer_name: String, meta := {}
) -> PixelLayer:
	if images.is_empty():
		return null
	var current_frames := project.frames.size()
	var missing := maxi(images.size() - current_frames, 0)
	var new_frames: Array = []
	var frame_indices := PackedInt32Array()
	for i in missing:
		frame_indices.append(current_frames + i)
		new_frames.append(project.new_empty_frame())
	var total_frames := current_frames + missing

	var layer := PixelLayer.new(project, layer_name)
	for key in meta:
		layer.set_meta(str(key), meta[key])
	var cels: Array = []
	for f in total_frames:
		cels.append(layer.new_empty_cel())
	for f in total_frames:
		var cel: BaseCel = cels[f]
		if not (cel is PixelCel):
			continue
		var image: Image = images[mini(f, images.size() - 1)]
		(cel as PixelCel).image = _make_cel_image(image, project)
		cel.update_texture()

	var current_layer: BaseLayer = project.layers[project.current_layer]
	layer.parent = current_layer.parent
	var new_layer_idx := project.current_layer + 1
	project.undo_redo.create_action("Add Shader Layer")
	if missing > 0:
		project.undo_redo.add_do_method(project.add_frames.bind(new_frames, frame_indices))
		project.undo_redo.add_undo_method(project.remove_frames.bind(frame_indices))
	project.undo_redo.add_do_method(project.add_layers.bind([layer], [new_layer_idx], [cels]))
	project.undo_redo.add_undo_method(project.remove_layers.bind([new_layer_idx]))
	project.undo_redo.add_do_method(project.change_cel.bind(-1, new_layer_idx))
	project.undo_redo.add_undo_method(project.change_cel.bind(-1, project.current_layer))
	project.undo_redo.add_do_method(Global.undo_or_redo.bind(false))
	project.undo_redo.add_undo_method(Global.undo_or_redo.bind(true))
	project.undo_redo.commit_action()
	return layer


## Finger sized button, so every action is easy to hit on a touchscreen.
func _make_button(
	text: String, callback: Callable, tooltip := "", min_size := Vector2(0, TOUCH_SIZE)
) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.custom_minimum_size = min_size
	button.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	button.pressed.connect(callback)
	return button


## Box of a preview that keeps the aspect of the project canvas, so the picture
## fits exactly instead of being padded inside a square.
func _preview_box(width: float, max_height: float) -> Vector2:
	var canvas := Vector2i(64, 64)
	var project := Global.current_project
	if project != null:
		canvas = project.size
	if canvas.x <= 0 or canvas.y <= 0:
		canvas = Vector2i(64, 64)
	var ratio := float(canvas.x) / float(canvas.y)
	var height := width / ratio
	if height > max_height:
		height = max_height
		width = height * ratio
	return Vector2(roundf(width), roundf(height))


## Backdrop of the floating picture: solid black, solid white, or a checker that
## shows where the output is transparent.
func _apply_preview_backdrop() -> void:
	if not is_instance_valid(_preview_back):
		return
	match _preview_backdrop:
		1:
			_preview_back.texture = _preview_backdrop_texture(Color(0.93, 0.93, 0.95))
		2:
			if _preview_checker == null:
				_preview_checker = _make_checker_texture()
			_preview_back.texture = _preview_checker
		_:
			_preview_back.texture = _preview_backdrop_texture(Color(0.05, 0.05, 0.06))


func _on_preview_backdrop_selected(index: int) -> void:
	_preview_backdrop = clampi(index, 0, 2)
	_apply_preview_backdrop()


## A one pixel texture repeated over the frame, which is the cheapest way to paint
## a solid backdrop behind the picture.
func _preview_backdrop_texture(color: Color) -> ImageTexture:
	var light := color.r > 0.5
	var cached := _preview_solid_white if light else _preview_solid_black
	if cached != null:
		return cached
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, color)
	var texture := ImageTexture.create_from_image(image)
	if light:
		_preview_solid_white = texture
	else:
		_preview_solid_black = texture
	return texture


## Checkerboard that stands for "transparent", like the one under the canvas.
func _make_checker_texture() -> ImageTexture:
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 16:
			var light := ((x / 8) + (y / 8)) % 2 == 0
			image.set_pixel(x, y, Color(0.32, 0.32, 0.34) if light else Color(0.2, 0.2, 0.22))
	return ImageTexture.create_from_image(image)


## Sizes the floating output window to the canvas shape and a corner of the graph
## area. It runs again when the graph area changes size, so the window keeps a
## sensible size on a phone and on a desktop.
func _fit_preview_panel() -> void:
	if not is_instance_valid(_preview_panel) or not is_instance_valid(_graph_host):
		return
	var host := _graph_host.size
	var box_width := clampf(host.x * 0.34, 96.0, 220.0)
	var box := _preview_box(box_width, maxf(host.y * 0.45, 80.0))
	# The frame is the canvas shape, plus room for the title row, so nothing is
	# squashed and nothing takes room it does not use.
	if is_instance_valid(_preview_frame):
		_preview_frame.custom_minimum_size = box
	_preview_panel.custom_minimum_size = box + Vector2(14.0, 46.0)
	_preview_panel.size = _preview_panel.custom_minimum_size
	if not _preview_placed and host.x >= box.x and host.y >= box.y:
		_preview_panel.position = Vector2(12, 12)
		_preview_placed = true
	_clamp_preview_panel()


## Keeps the floating output window inside the graph area, so it cannot be
## dragged off screen where it could never be grabbed again.
func _clamp_preview_panel() -> void:
	if not is_instance_valid(_preview_panel) or not is_instance_valid(_graph_host):
		return
	var limit := _graph_host.size - _preview_panel.size
	_preview_panel.position = _preview_panel.position.clamp(
		Vector2.ZERO, Vector2(maxf(limit.x, 0.0), maxf(limit.y, 0.0))
	)


## Dragging the small title bar moves the floating output window.
func _on_preview_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		_preview_dragging = button.pressed
		return
	if event is InputEventMouseMotion and _preview_dragging:
		var motion := event as InputEventMouseMotion
		_preview_panel.position += motion.relative
		_clamp_preview_panel()


## Puts the parameters beside the graph when there is room, and below it on a
## narrow screen, so the page stays usable on a phone in portrait.
func _apply_layout() -> void:
	if not is_instance_valid(_body) or not is_instance_valid(_graph_edit):
		return
	var narrow := size.x < NARROW_WIDTH
	_body.vertical = narrow
	# Zen mode hides the graph, so the floating window would only cover the
	# parameters that the mode is meant to give the whole page.
	if is_instance_valid(_preview_panel):
		_preview_panel.visible = not _zen_mode
	_fit_preview_panel()
	if is_instance_valid(_node_preview):
		_node_preview.custom_minimum_size = _preview_box(150.0, maxf(size.y * 0.3, 90.0))
	if _zen_mode:
		# The graph is hidden, so the parameters can use the whole height.
		_graph_host.custom_minimum_size = Vector2.ZERO
		_side.custom_minimum_size = Vector2(0, 200)
		return
	if narrow:
		_graph_host.custom_minimum_size = Vector2(0, 220)
		_side.custom_minimum_size = Vector2(0, 260)
	else:
		_graph_host.custom_minimum_size = Vector2(320, 0)
		_side.custom_minimum_size = Vector2(300, 0)


## Two finger pan and pinch for the graph itself. Only events over the graph are
## used, and they are consumed so the node under the fingers is not also dragged.
func _input(event: InputEvent) -> void:
	if not visible or not is_instance_valid(_graph_edit):
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# Never steal Ctrl+Z from the filter or the preset name field.
		var focused := get_viewport().gui_get_focus_owner()
		if focused is LineEdit or focused is TextEdit:
			return
		var key := event as InputEventKey
		if key.ctrl_pressed and key.keycode == KEY_Z:
			if key.shift_pressed:
				_redo()
			else:
				_undo()
			get_viewport().set_input_as_handled()
			return
		if key.ctrl_pressed and key.keycode == KEY_Y:
			_redo()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_graph_fingers[touch.index] = touch.position
			if _graph_fingers.size() == 2 and _inside_graph(touch.position):
				_begin_graph_gesture()
		else:
			_graph_fingers.erase(touch.index)
			_graph_gesture = false
		return
	if not (event is InputEventScreenDrag):
		return
	var drag := event as InputEventScreenDrag
	if not _graph_fingers.has(drag.index):
		return
	_graph_fingers[drag.index] = drag.position
	if _graph_fingers.size() != 2:
		return
	if not _graph_gesture:
		if not _inside_graph(drag.position):
			return
		_begin_graph_gesture()
	_apply_graph_gesture()
	get_viewport().set_input_as_handled()


func _inside_graph(point: Vector2) -> bool:
	return _graph_edit.get_global_rect().has_point(point)


func _begin_graph_gesture() -> void:
	_graph_gesture = true
	_graph_span = maxf(_graph_finger_span(), 1.0)
	_graph_midpoint = _graph_finger_midpoint()
	_graph_zoom = _graph_edit.zoom
	_graph_scroll = _graph_edit.scroll_offset


func _apply_graph_gesture() -> void:
	var span := maxf(_graph_finger_span(), 1.0)
	_graph_edit.zoom = clampf(_graph_zoom * span / _graph_span, 0.25, 2.5)
	# The graph content stays under the fingers while they also move.
	var midpoint := _graph_finger_midpoint()
	_graph_edit.scroll_offset = _graph_scroll - (midpoint - _graph_midpoint) / _graph_edit.zoom


func _graph_finger_span() -> float:
	var positions := _graph_fingers.values()
	if positions.size() < 2:
		return 0.0
	return (positions[0] as Vector2).distance_to(positions[1] as Vector2)


func _graph_finger_midpoint() -> Vector2:
	var positions := _graph_fingers.values()
	if positions.size() < 2:
		return Vector2.ZERO
	return ((positions[0] as Vector2) + (positions[1] as Vector2)) * 0.5
