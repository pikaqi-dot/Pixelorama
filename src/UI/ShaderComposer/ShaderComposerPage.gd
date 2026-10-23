extends Panel
## Full screen node editor. Procedural nodes (noise, gradients, maths) are turned
## into a pixel image, which is added to the project as a new layer.
##
## The page is embedded in the interface instead of being a separate window, and
## it blocks drawing while it is open.

const ShaderGraphScript := preload("res://src/Classes/ShaderComposer/ShaderGraph.gd")

const PORT_COLOR := Color(0.55, 0.8, 1.0)
const PREVIEW_LIMIT := 256
## Minimum height of every interactive row, which keeps it usable with a finger.
const TOUCH_SIZE := 40
const TOUCH_FONT_SIZE := 15
## Below this width the page stacks the graph above the parameters.
const NARROW_WIDTH := 760

var graph: RefCounted
var _graph_edit: GraphEdit
var _params_box: VBoxContainer
var _params_hint: Label
var _preview: TextureRect
var _status: Label
var _add_type: OptionButton
var _preview_timer: Timer
var _selected_id := ""
var _can_draw_before := true
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
func open_page() -> void:
	_can_draw_before = Global.can_draw
	Global.can_draw = false
	show()
	_apply_layout()
	_refresh_preview()


func close_page() -> void:
	Global.can_draw = _can_draw_before
	_preview_timer.stop()
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
	header_row.add_child(_make_button("作为新图层添加", _on_add_layer_pressed))
	header_row.add_child(_make_button("✕", close_page, "关闭", Vector2(48, TOUCH_SIZE)))

	var toolbar := HFlowContainer.new()
	root.add_child(toolbar)
	_add_type = OptionButton.new()
	for type: String in ShaderGraphScript.NODE_TYPES.keys():
		_add_type.add_item(ShaderGraphScript.NODE_TYPES[type]["label"])
	_add_type.select(0)
	_add_type.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	_add_type.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	toolbar.add_child(_add_type)
	toolbar.add_child(_make_button("添加节点", _on_add_pressed))
	toolbar.add_child(_make_button("删除选中", _on_delete_pressed))
	toolbar.add_child(_make_button("刷新预览", _refresh_preview))
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

	var preview_label := Label.new()
	preview_label.text = "预览"
	preview_label.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	_side.add_child(preview_label)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(200, 180)
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_side.add_child(_preview)

	_preview_timer = Timer.new()
	_preview_timer.one_shot = true
	_preview_timer.wait_time = 0.15
	_preview_timer.timeout.connect(_refresh_preview)
	add_child(_preview_timer)


## Rebuilds the graph view from the data, keeping where the user put each node.
func _refresh_graph() -> void:
	for child in _graph_edit.get_children():
		if child is GraphNode:
			var stored: Dictionary = graph.get_node_by_id(str(child.name))
			if not stored.is_empty():
				stored["position"] = (child as GraphNode).position_offset
	_graph_edit.clear_connections()
	for child in _graph_edit.get_children():
		if child is GraphNode:
			_graph_edit.remove_child(child)
			child.queue_free()
	for node: Dictionary in graph.nodes:
		_graph_edit.add_child(_make_graph_node(node))
	for node: Dictionary in graph.nodes:
		var inputs: Dictionary = node["inputs"]
		for slot: int in inputs.keys():
			_graph_edit.connect_node(inputs[slot], 0, node["id"], slot)
	_status.text = "节点 %d" % graph.nodes.size()


func _make_graph_node(node: Dictionary) -> GraphNode:
	var graph_node := GraphNode.new()
	graph_node.name = node["id"]
	graph_node.title = ShaderGraphScript.NODE_TYPES[node["type"]]["label"]
	graph_node.position_offset = node.get("position", Vector2.ZERO)
	var input_count := int(ShaderGraphScript.NODE_TYPES[node["type"]]["inputs"])
	graph_node.set_slot(0, input_count >= 1, 0, PORT_COLOR, true, 0, PORT_COLOR)
	if input_count >= 2:
		graph_node.set_slot(1, true, 0, PORT_COLOR, false, 0, PORT_COLOR)
	var description := Label.new()
	description.text = ShaderGraphScript.describe(node)
	description.add_theme_font_size_override("font_size", 12)
	graph_node.add_child(description)
	return graph_node


func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	graph.connect_nodes(str(from_node), str(to_node), to_port)
	_refresh_graph()
	_schedule_preview()


func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	graph.disconnect_input(str(to_node), to_port)
	_refresh_graph()
	_schedule_preview()


func _on_delete_nodes_request(nodes: Array[StringName]) -> void:
	for node_name in nodes:
		graph.remove_node(str(node_name))
	if _selected_id in nodes or graph.get_node_by_id(_selected_id).is_empty():
		_selected_id = ""
		_show_params("")
	_refresh_graph()
	_schedule_preview()


func _on_add_pressed() -> void:
	var type: String = ShaderGraphScript.NODE_TYPES.keys()[_add_type.selected]
	# New nodes land next to the visible area instead of on top of each other.
	var offset := Vector2(60 + graph.nodes.size() * 24, 40 + graph.nodes.size() * 18)
	var id: String = graph.add_node(type, offset)
	_refresh_graph()
	_selected_id = id
	_show_params(id)
	_schedule_preview()


func _on_delete_pressed() -> void:
	if _selected_id.is_empty():
		return
	graph.remove_node(_selected_id)
	_selected_id = ""
	_show_params("")
	_refresh_graph()
	_schedule_preview()


func _on_node_selected(node: Node) -> void:
	_selected_id = str(node.name)
	_show_params(_selected_id)


func _on_node_deselected(_node: Node) -> void:
	_selected_id = ""
	_show_params("")


## Builds the parameter controls of [param id] in the side panel.
func _show_params(id: String) -> void:
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
		"radial":
			_add_slider("中心 X", 0.0, 1.0, 0.01, float(params["center_x"]), params, "center_x")
			_add_slider("中心 Y", 0.0, 1.0, 0.01, float(params["center_y"]), params, "center_y")
			_add_slider("半径", 0.05, 1.5, 0.01, float(params["radius"]), params, "radius")
			_add_check("反向", bool(params["invert"]), params, "invert")
		"checker":
			_add_slider("格子 (px)", 1.0, 64.0, 1.0, float(params["cell"]), params, "cell")
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
			_add_color("颜色 B", params["color_b"], params, "color_b")


func _add_option(
	label_text: String, items: Array, selected: int, params: Dictionary, key: String
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
			params[key] = index
			_schedule_preview()
	)
	row.add_child(option)
	_params_box.add_child(row)


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
			params[key] = new_value
			display.text = _format_number(new_value, step)
			_schedule_preview()
	)
	_params_box.add_child(row)


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
			params[key] = int(new_value)
			_schedule_preview()
	)
	row.add_child(spin)
	_params_box.add_child(row)


func _add_check(
	label_text: String, value: bool, params: Dictionary, key: String
) -> void:
	var check := CheckBox.new()
	check.text = label_text
	check.button_pressed = value
	check.custom_minimum_size = Vector2(0, TOUCH_SIZE)
	check.add_theme_font_size_override("font_size", TOUCH_FONT_SIZE)
	check.toggled.connect(
		func(pressed: bool) -> void:
			params[key] = pressed
			_schedule_preview()
	)
	_params_box.add_child(check)


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
			params[key] = color
			_schedule_preview()
	)
	row.add_child(picker)
	_params_box.add_child(row)


static func _format_number(value: float, step: float) -> String:
	if step >= 1.0:
		return "%d" % int(value)
	return "%.2f" % value


func _schedule_preview() -> void:
	if is_instance_valid(_preview_timer):
		_preview_timer.start()


func _refresh_preview() -> void:
	if not is_instance_valid(_preview):
		return
	var project := Global.current_project
	if project == null:
		return
	var preview_size := Vector2i(
		mini(project.size.x, PREVIEW_LIMIT), mini(project.size.y, PREVIEW_LIMIT)
	)
	var image: Image = graph.generate(preview_size)
	_preview.texture = ImageTexture.create_from_image(image)
	_status.text = "预览 %d×%d · 输出 %d×%d · 节点 %d" % [
		preview_size.x, preview_size.y, project.size.x, project.size.y, graph.nodes.size()
	]


## Generates the image at the project size and adds it as a new layer.
func _on_add_layer_pressed() -> void:
	var project := Global.current_project
	if project == null:
		return
	var image: Image = graph.generate(project.size)
	_add_image_layer(project, image, "Shader Layer")
	close_page()


## Adds [param image] as a new pixel layer, undoable like the timeline does it.
static func _add_image_layer(project: Project, image: Image, layer_name: String) -> void:
	var cel_image := ImageExtended.create_from_image(image, project.is_indexed())
	var layer := PixelLayer.new(project, layer_name)
	var cels: Array = []
	for frame in project.frames:
		cels.append(layer.new_empty_cel())
	var first_cel: BaseCel = cels[0]
	if first_cel is PixelCel:
		(first_cel as PixelCel).image = cel_image
		first_cel.update_texture()

	var current_layer: BaseLayer = project.layers[project.current_layer]
	layer.parent = current_layer.parent
	var new_layer_idx := project.current_layer + 1
	project.undo_redo.create_action("Add Shader Layer")
	project.undo_redo.add_do_method(project.add_layers.bind([layer], [new_layer_idx], [cels]))
	project.undo_redo.add_undo_method(project.remove_layers.bind([new_layer_idx]))
	project.undo_redo.add_do_method(project.change_cel.bind(-1, new_layer_idx))
	project.undo_redo.add_undo_method(project.change_cel.bind(-1, project.current_layer))
	project.undo_redo.add_do_method(Global.undo_or_redo.bind(false))
	project.undo_redo.add_undo_method(Global.undo_or_redo.bind(true))
	project.undo_redo.commit_action()
	Global.notification_label("Shader layer added")


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
