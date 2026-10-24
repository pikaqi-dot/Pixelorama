extends Panel
## Full screen node editor. Procedural nodes (noise, gradients, maths) are turned
## into a pixel image, which is added to the project as a new layer.
##
## The page is embedded in the interface instead of being a separate window, and
## it blocks drawing while it is open.

const ShaderGraphScript := preload("res://src/Classes/ShaderComposer/ShaderGraph.gd")
const ShaderPathEditorScript := preload("res://src/UI/ShaderComposer/ShaderPathEditor.gd")

const PORT_COLOR := Color(0.55, 0.8, 1.0)
const PREVIEW_LIMIT := 256
## Preview size for graphs that sample neighbours, which are much slower.
const PREVIEW_LIMIT_HEAVY := 128
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
## How often a graph that reads the project refreshes its preview.
const SOURCE_REFRESH_MSEC := 600
## How long a press on a node has to last to open the context menu.
const HOLD_MENU_MSEC := 500

var graph: RefCounted
var _graph_edit: GraphEdit
var _params_box: VBoxContainer
var _params_hint: Label
## Path editor shown in the parameters when Follow Path uses a custom shape.
var _path_editor
var _preview: TextureRect
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
## Long press on a node opens a context menu.
var _node_menu: PopupMenu
var _hold_id := ""
var _hold_start := 0
var _hold_position := Vector2.ZERO
var _hold_moved := false
## Saved graph presets, and the small dialog used to name them.
var _preset_menu: MenuButton
## Secondary actions, so the toolbar stays short on a phone.
var _more_menu: MenuButton
## Hides the graph to give the parameters the whole page.
var _zen_mode := false
var _preset_paths: Array[String] = []
var _preset_dialog: ConfirmationDialog
var _preset_name: LineEdit
var _can_draw_before := true
## Animation phase shown in the preview, and how many frames a dynamic graph
## generates.
var _phase: HSlider
var _frame_count: SpinBox
## Playback of the preview, and the layer being edited (when reopened from one).
var _play_timer: Timer
var _play_button: Button
var _playhead := 0.0
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
	_can_draw_before = Global.can_draw
	Global.can_draw = false
	_editing_layer = layer
	if layer != null and layer.has_meta("shader_graph"):
		graph.from_dict(layer.get_meta("shader_graph"))
		if is_instance_valid(_frame_count):
			_frame_count.value = int(layer.get_meta("shader_frames", _frame_count.value))
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


func is_open() -> bool:
	return visible


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
	_frame_count = SpinBox.new()
	_frame_count.min_value = 1
	_frame_count.max_value = 60
	_frame_count.step = 1
	_frame_count.value = 8
	_frame_count.tooltip_text = "生成多少帧"
	_frame_count.custom_minimum_size = Vector2(78, TOUCH_SIZE)
	_frame_count.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
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
	_body.add_child(_graph_edit)

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
	_node_menu.id_pressed.connect(_on_node_menu_pressed)
	add_child(_node_menu)

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

	var preview_label := Label.new()
	preview_label.text = "预览（点一下放大）"
	preview_label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_side.add_child(preview_label)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(200, 180)
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview.tooltip_text = "点一下放大预览"
	_preview.gui_input.connect(_on_preview_input)
	_side.add_child(_preview)

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
	var input_count := int(ShaderGraphScript.NODE_TYPES[node["type"]]["inputs"])
	graph_node.set_slot(0, input_count >= 1, 0, PORT_COLOR, true, 0, PORT_COLOR)
	var description := Label.new()
	description.text = ShaderGraphScript.describe(node)
	description.add_theme_font_size_override("font_size", 12)
	graph_node.add_child(description)
	if input_count >= 2:
		# Every slot needs its own child, otherwise the second input port does not
		# exist and connections to it are dropped.
		graph_node.set_slot(1, true, 0, PORT_COLOR, false, 0, PORT_COLOR)
		var spacing := Control.new()
		spacing.custom_minimum_size = Vector2(0, 10)
		graph_node.add_child(spacing)
	return graph_node


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
	if id == 2:
		_show_preset_dialog()
		return
	var index := id - 10
	if index >= 0 and index < _preset_paths.size():
		_load_preset(_preset_paths[index])


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
	_path_editor = null
	_params_target = _params_box
	_param_sections.clear()
	for child in _params_box.get_children():
		_params_box.remove_child(child)
		child.queue_free()
	var node: Dictionary = graph.get_node_by_id(id)
	if node.is_empty():
		_params_hint.text = "选择一个节点来编辑参数"
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
		"path":
			var path_hint := Label.new()
			path_hint.text = (
				"矢量描边：路径用三次贝塞尔曲线连接，线宽按画布短边比例。"
				+ "输出的是描边蒙版，接到输出节点或混合节点使用。"
			)
			path_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			path_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(path_hint)
			_add_path_editor(params, true)
			_add_check("闭合", bool(params.get("closed", false)), params, "closed", true)
			_add_check("填充（需闭合）", bool(params.get("fill", false)), params, "fill")
			_add_slider("线宽", 0.01, 0.3, 0.005, float(params["width"]), params, "width")
			_add_slider(
				"羽化", 0.0, 0.2, 0.005, float(params.get("soft", 0.0)), params, "soft"
			)
		"pixel_art":
			var source_hint := Label.new()
			source_hint.text = (
				"读取主窗口的图层内容，预览会跟着画布自动刷新。"
				+ "亮度通道会乘上透明度，透明处视为 0。帧号从 0 开始。"
			)
			source_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			source_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(source_hint)
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
				_add_path_editor(params)
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
			blur_hint.text = "3×3 模糊，半径越大越糊。配合 Output 的色阶可以做出柔边。"
			blur_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			blur_hint.add_theme_font_size_override("font_size", 13)
			_params_box.add_child(blur_hint)
			_add_slider("半径", 0.5, 8.0, 0.5, float(params["radius"]), params, "radius")
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
	_apply_param_filter()


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
	if _hold_id.is_empty() or graph.get_node_by_id(_hold_id).is_empty():
		return
	_selected_id = _hold_id
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


## Tracks press and release on a node, so a hold of half a second (without
## dragging) opens the context menu while a tap only selects.
func _on_graph_node_input(event: InputEvent, node_id: String) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			_hold_id = node_id
			_hold_start = Time.get_ticks_msec()
			_hold_position = button.global_position
			_hold_moved = false
			return
		var held := Time.get_ticks_msec() - _hold_start
		if _hold_id == node_id and not _hold_moved and held >= HOLD_MENU_MSEC:
			_hold_id = node_id
			_node_menu.popup(Rect2i(Vector2i(_hold_position), Vector2i.ZERO))
		_hold_id = ""
		return
	if event is InputEventMouseMotion and _hold_id == node_id:
		if (event as InputEventMouseMotion).global_position.distance_to(_hold_position) > 14.0:
			_hold_moved = true


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
			params[key] = index
			_schedule_preview()
			# Some options change which controls are shown, like the path shape.
			if rebuild and not _selected_id.is_empty():
				call_deferred("_show_params", _selected_id)
	)
	row.add_child(option)
	_params_target.add_child(row)


## Control point editor for a custom Follow Path.
func _add_path_editor(params: Dictionary, bezier := false) -> void:
	var stored: Array = params.get("points", [])
	if bezier:
		if stored.size() < 2:
			stored = ShaderPathEditorScript.default_bezier()
			params["points"] = stored
	else:
		if stored.size() < 2:
			# Graphs saved before the editor existed get the default loop.
			stored = ShaderPathEditorScript.default_points()
			params["points"] = stored
	var editor := ShaderPathEditorScript.new()
	if bezier:
		editor.set_bezier(stored, bool(params.get("closed", false)))
	else:
		editor.set_points(stored, float(params.get("phase", 0.0)))
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.custom_minimum_size = Vector2(0, 200)
	editor.points_changed.connect(
		func(new_points: Array) -> void:
			_push_undo("%s:points" % _selected_id)
			params["points"] = new_points
			_schedule_preview()
	)
	_params_box.add_child(editor)
	_path_editor = editor
	var remove_point := func() -> void:
		editor.remove_selected()
	var reset_path := func() -> void:
		editor.reset_to_square()
	var buttons := HBoxContainer.new()
	buttons.add_child(_make_button("删除选中点", remove_point))
	buttons.add_child(_make_button("重置路径", reset_path, "回到默认的方形路径"))
	_params_box.add_child(buttons)
	var hint := Label.new()
	hint.text = (
		"点空白处新增控制点，拖动移动，右键或上方按钮删除。"
		+ "贝塞尔路径上小圆点是手柄，拖它改变曲率。"
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	_params_box.add_child(hint)


func _add_slider(
	label_text: String,
	min_value: float,
	max_value: float,
	step: float,
	value: float,
	params: Dictionary,
	key: String
) -> void:
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
	row.add_child(slider)
	var display := Label.new()
	display.text = _format_number(value, step)
	display.custom_minimum_size = Vector2(48, 0)
	display.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(display)
	slider.value_changed.connect(
		func(new_value: float) -> void:
			_push_undo("%s:%s" % [_selected_id, key])
			params[key] = new_value
			display.text = _format_number(new_value, step)
			_schedule_preview()
	)
	_params_target.add_child(row)


func _add_number(
	label_text: String,
	min_value: int,
	max_value: int,
	step: int,
	value: int,
	params: Dictionary,
	key: String
) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(84, 0)
	label.add_theme_font_size_override("font_size", 14)
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	spin.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	spin.value_changed.connect(
		func(new_value: float) -> void:
			_push_undo("%s:%s" % [_selected_id, key])
			params[key] = int(new_value)
			_schedule_preview()
	)
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


func _refresh_preview() -> void:
	if not is_instance_valid(_preview):
		return
	var project := Global.current_project
	if project == null:
		return
	var limit := PREVIEW_LIMIT_HEAVY if graph.is_expensive() else PREVIEW_LIMIT
	var preview_size := Vector2i(
		mini(project.size.x, limit), mini(project.size.y, limit)
	)
	graph.time = _phase.value if is_instance_valid(_phase) else 0.0
	if is_instance_valid(_path_editor):
		_path_editor.set_phase(graph.time)
	var image: Image = graph.generate(preview_size)
	_preview.texture = ImageTexture.create_from_image(image)
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


## Launches the echo of earlier frames, which is the quickest way to judge an
## animated graph before committing it.
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


func _advance_playback() -> void:
	var frames := maxi(int(_frame_count.value) if is_instance_valid(_frame_count) else 1, 1)
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


## Generates the image(s) at the project size and adds them as a new layer.
func _on_add_layer_pressed() -> void:
	var project := Global.current_project
	if project == null:
		return
	var frames := maxi(int(_frame_count.value) if is_instance_valid(_frame_count) else 1, 1)
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


## Puts the parameters beside the graph when there is room, and below it on a
## narrow screen, so the page stays usable on a phone in portrait.
func _apply_layout() -> void:
	if not is_instance_valid(_body) or not is_instance_valid(_graph_edit):
		return
	var narrow := size.x < NARROW_WIDTH
	_body.vertical = narrow
	if _zen_mode:
		# The graph is hidden, so the parameters can use the whole height.
		_graph_edit.custom_minimum_size = Vector2.ZERO
		_side.custom_minimum_size = Vector2(0, 200)
		return
	if narrow:
		_graph_edit.custom_minimum_size = Vector2(0, 220)
		_side.custom_minimum_size = Vector2(0, 260)
	else:
		_graph_edit.custom_minimum_size = Vector2(320, 0)
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
