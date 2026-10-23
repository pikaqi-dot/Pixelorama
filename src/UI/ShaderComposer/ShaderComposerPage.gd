extends Panel
## Full screen node editor. Procedural nodes (noise, gradients, maths) are turned
## into a pixel image, which is added to the project as a new layer.
##
## The page is embedded in the interface instead of being a separate window, and
## it blocks drawing while it is open.

const ShaderGraphScript := preload("res://src/Classes/ShaderComposer/ShaderGraph.gd")

const PORT_COLOR := Color(0.55, 0.8, 1.0)
const PREVIEW_LIMIT := 256

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


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	graph = ShaderGraphScript.new()
	_build_ui()
	_refresh_graph()
	_refresh_preview()
	hide()


## Shows the page and stops the canvas from receiving input meanwhile.
func open_page() -> void:
	_can_draw_before = Global.can_draw
	Global.can_draw = false
	show()
	_refresh_preview()


func close_page() -> void:
	Global.can_draw = _can_draw_before
	_preview_timer.stop()
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
	var header_row := HBoxContainer.new()
	header.add_child(header_row)
	var title := Label.new()
	title.text = "节点图层 · Shader Composer"
	title.add_theme_font_size_override("font_size", 15)
	header_row.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(spacer)
	var layer_button := Button.new()
	layer_button.text = "作为新图层添加"
	layer_button.pressed.connect(_on_add_layer_pressed)
	header_row.add_child(layer_button)
	var close_button := Button.new()
	close_button.text = "✕"
	close_button.tooltip_text = "关闭"
	close_button.pressed.connect(close_page)
	header_row.add_child(close_button)

	var toolbar := HBoxContainer.new()
	root.add_child(toolbar)
	var add_label := Label.new()
	add_label.text = "节点"
	toolbar.add_child(add_label)
	_add_type = OptionButton.new()
	for type: String in ShaderGraphScript.NODE_TYPES.keys():
		_add_type.add_item(ShaderGraphScript.NODE_TYPES[type]["label"])
	_add_type.select(0)
	toolbar.add_child(_add_type)
	var add_button := Button.new()
	add_button.text = "添加"
	add_button.pressed.connect(_on_add_pressed)
	toolbar.add_child(add_button)
	var delete_button := Button.new()
	delete_button.text = "删除选中"
	delete_button.pressed.connect(_on_delete_pressed)
	toolbar.add_child(delete_button)
	var generate_button := Button.new()
	generate_button.text = "刷新预览"
	generate_button.pressed.connect(_refresh_preview)
	toolbar.add_child(generate_button)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	toolbar.add_child(_status)

	var body := HSplitContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	_graph_edit = GraphEdit.new()
	_graph_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph_edit.minimap_enabled = false
	_graph_edit.connection_request.connect(_on_connection_request)
	_graph_edit.disconnection_request.connect(_on_disconnection_request)
	_graph_edit.delete_nodes_request.connect(_on_delete_nodes_request)
	_graph_edit.node_selected.connect(_on_node_selected)
	_graph_edit.node_deselected.connect(_on_node_deselected)
	body.add_child(_graph_edit)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(300, 0)
	body.add_child(side)

	_params_hint = Label.new()
	_params_hint.text = "选择一个节点来编辑参数"
	_params_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_params_hint)

	var params_scroll := ScrollContainer.new()
	params_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	params_scroll.custom_minimum_size = Vector2(0, 220)
	side.add_child(params_scroll)
	_params_box = VBoxContainer.new()
	_params_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	params_scroll.add_child(_params_box)

	var preview_label := Label.new()
	preview_label.text = "预览"
	side.add_child(preview_label)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(260, 260)
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	side.add_child(_preview)

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
	row.add_child(label)
	var option := OptionButton.new()
	for item in items:
		option.add_item(str(item))
	option.select(clampi(selected, 0, items.size() - 1))
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	picker.custom_minimum_size = Vector2(0, 26)
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
