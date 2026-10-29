class_name Canvas
extends Node2D

const CURSOR_SPEED_RATE := 6.0
const ToolDialScript := preload("res://src/UI/ToolDial.gd")
## Two taps on the drawing view open the tool dial when they land this close in
## time and space. A finger is less precise than a mouse, so the window is
## generous; a mouse also gets the engine's own double click flag, which follows
## the double click speed set in the system. Nothing is delayed: the first tap is
## drawn like any other and its mark is taken back when the gesture is
## recognised, so drawing stays as fast as it was.
const DIAL_TAP_MSEC := 500
const DIAL_TAP_DISTANCE := 28.0
## Two taps closer than this are not a double tap: two or three fingers of one
## gesture land within a few milliseconds of each other, while a person needs at
## least a tenth of a second between deliberate taps.
const DIAL_MIN_PAIR_MSEC := 80
## Most tools the dial may hold. Past eight the circles shrink below a fingertip
## and the ring stops reading as one dial.
const DIAL_MAX_SLOTS := 8
## Order the ring fills up in: the tools a drawing needs first, because that is
## what a finger on the canvas reaches for. Tools the side panel hides are left
## out, so hiding them there is also how the ring is trimmed.
const DIAL_TOOL_ORDER := [
	"Pencil",
	"Eraser",
	"Bucket",
	"Shading",
	"LineTool",
	"RectangleTool",
	"EllipseTool",
	"ColorPicker",
	"Gradient",
	"CurveTool",
	"RectSelect",
	"EllipseSelect",
	"Lasso",
	"MagicWand",
	"Move",
	"Zoom",
	"Pan",
]
## Presses this soon after the dial opens are ignored: the finger that opened it
## is still on its way up, and it must not pick whatever lies under it.
const DIAL_GUARD_MSEC := 180

var current_pixel := Vector2.ZERO
## Tool dial overlay. It lives in the main interface instead of this viewport, so
## the camera zoom and rotation never stretch or turn it.
var _tool_dial: Control
## Time and place of the last tap, so a second one right after it is read as the
## dial gesture.
var _tap_at := -10000
var _tap_point := Vector2.ZERO
## Undo steps that existed when that tap landed. A step added since then is the
## mark the tap left behind, and the gesture takes exactly that one back.
var _tap_history := 0
## Swallows the rest of the gesture that opened the dial, so the emulated mouse
## release cannot reach a tool either. A release that never arrives (a finger
## lifted outside the window) expires instead of blocking every later press.
var _swallow_release := false
var _swallow_at := 0
## Where the dial asked to appear, and whether it still has to. Opening is put off
## to the end of the frame because a second finger of a multi finger gesture can
## arrive after the emulated mouse press that started this one, and that finger
## must be able to cancel the dial before it is ever seen.
var _pending_dial := false
var _pending_dial_point := Vector2.ZERO
var _pending_dial_history := 0
var _pending_dial_snapshots: Array = []
## Pictures of the cels of the frame the last tap landed on. A double tap puts
## them back verbatim, so no tool can leave a mark behind, whatever its own undo
## handling does. Each entry is {cel, image}.
var _tap_snapshots: Array[Dictionary] = []
## Canvases larger than this are not snapshotted; the undo step is used instead of
## copying megabytes on every tap, which would be felt on a phone.
const TAP_SNAPSHOT_MAX_PIXELS := 2_000_000
## The two tools the dial's default selection takes turns on, newest first. A
## double tap plus one tap on the highlighted circle is therefore a full switch
## between the two tools the drawing is using, which is the whole point of the
## dial being two taps away.
var _dial_pair: Array[String] = []
## Which member of [member _dial_pair] the next opening highlights. It is moved on
## every opening, so closing the dial without picking hands the other tool over.
var _dial_pair_next := 0
var sprite_changed_this_frame := false  ## For optimization purposes
var update_all_layers := false
## For optimization purposes. A kind of override to force include a layer during canvas update.
## Used in Undo/Redo for FX and visibility changes
var mandatory_update_layers := PackedInt32Array()
var project_changed := false
var move_preview_location := Vector2i.ZERO
var layer_texture_array := Texture2DArray.new()
var layer_metadata_image := Image.new()
var layer_metadata_texture := ImageTexture.new()

@onready var currently_visible_frame := $CurrentlyVisibleFrame as SubViewport
@onready var current_frame_drawer := $CurrentlyVisibleFrame/CurrentFrameDrawer as Node2D
@onready var tile_mode := $TileMode as Node2D
@onready var color_index := $ColorIndex as Node2D
@onready var selection := $Selection as SelectionNode
@onready var onion_past := $OnionPast as Node2D
@onready var onion_future := $OnionFuture as Node2D
@onready var crop_rect := $CropRect as CropRect
@onready var indicators := $Indicators as Node2D
@onready var previews := $Previews as Node2D
@onready var previews_sprite := $PreviewsSprite as Sprite2D
@onready var mouse_guide_container := $MouseGuideContainer as Node2D
@onready var gizmos_3d := $Gizmos3D as Node2D
@onready var measurements := $Measurements as Node2D
@onready var reference_image_container := $ReferenceImages as Node2D
@onready var tilemap_property_drawing := $TilemapPropertyDrawing as Node2D


func _ready() -> void:
	material.set_shader_parameter("layers", layer_texture_array)
	material.set_shader_parameter("metadata", layer_metadata_texture)
	Global.project_created.connect(camera_zoom)
	Global.project_about_to_switch.connect(_on_project_about_to_switch)
	Global.project_switched.connect(_on_project_switched)
	Global.cel_switched.connect(queue_redraw_all_layers)
	if not Tools.tool_changed.is_connected(_on_dial_tool_changed):
		Tools.tool_changed.connect(_on_dial_tool_changed)
	onion_past.type = onion_past.PAST
	onion_past.blue_red_color = Global.onion_skinning_past_color
	onion_future.type = onion_future.FUTURE
	onion_future.blue_red_color = Global.onion_skinning_future_color
	await get_tree().process_frame
	camera_zoom()


func _draw() -> void:
	var project := Global.current_project
	var position_tmp := position
	var scale_tmp := scale
	if Global.mirror_view:
		position_tmp.x = position_tmp.x + project.size.x
		scale_tmp.x = -1
	draw_set_transform(position_tmp, rotation, scale_tmp)
	# Placeholder so we can have a material here
	var image_to_draw := project.empty_image_texture
	draw_texture(image_to_draw, Vector2.ZERO)
	draw_layers(project_changed)
	project_changed = false
	if Global.onion_skinning:
		refresh_onion()
	currently_visible_frame.size = project.size
	current_frame_drawer.queue_redraw()
	tile_mode.queue_redraw()
	draw_set_transform(position, rotation, scale)
	color_index.queue_redraw()


func _input(event: InputEvent) -> void:
	# Move the cursor with the keyboard (numpad keys by default)
	var mouse_movement := Input.get_vector(
		&"move_mouse_left", &"move_mouse_right", &"move_mouse_up", &"move_mouse_down"
	)
	# Don't process anything below if the input isn't a mouse event, a tool activation shortcut,
	# or the numpad keys that move the cursor.
	# This decreases CPU/GPU usage slightly.
	if event is not InputEventMouseMotion and event is not InputEventGesture:
		if (
			mouse_movement == Vector2.ZERO
			and not (
				event.is_action(&"activate_left_tool") or event.is_action(&"activate_right_tool")
			)
		):
			return
	if mouse_movement != Vector2.ZERO:
		var tmp_position := get_viewport().get_mouse_position()
		tmp_position += mouse_movement * CURSOR_SPEED_RATE
		get_viewport().warp_mouse(tmp_position)
	current_pixel = get_local_mouse_position()

	sprite_changed_this_frame = false
	# A double tap asks for the tool dial and never reaches the tools, so the
	# selected tool is not used for the gesture itself.
	if _opens_tool_dial(event):
		return
	Tools.handle_draw(Vector2i(current_pixel.floor()), event)

	if sprite_changed_this_frame:
		queue_redraw()
		update_selected_cels_textures()


## True when this press is the second half of a double tap on the drawing view.
## The dial opens and the press is kept away from the tools, so the selected tool
## never draws on the gesture itself. The mark the first tap made is taken back
## instead of delaying every tap, because a delayed input makes drawing feel slow.
func _opens_tool_dial(event: InputEvent) -> bool:
	if not (event is InputEventMouseButton):
		return false
	var mouse := event as InputEventMouseButton
	if mouse.button_index != MOUSE_BUTTON_LEFT:
		return false
	if _swallow_release:
		if not mouse.pressed or Time.get_ticks_msec() - _swallow_at > 600:
			_swallow_release = false
		else:
			get_viewport().set_input_as_handled()
			return true
	if not mouse.pressed:
		# A stroke that moved is not the first half of a double tap, so a click
		# that follows it cannot cancel a real stroke by mistake.
		if mouse.position.distance_to(_tap_point) > 4.0:
			_tap_at = -10000
		return false
	# A two or three finger gesture owns the input: two fingers landing close
	# together are not a double tap, and neither is a tap right after a gesture.
	if Tools.hold_to_pick_active:
		return false
	if Time.get_ticks_msec() - Global.last_multi_finger_msec <= DIAL_TAP_MSEC:
		return false
	if not is_instance_valid(Global.control):
		return false
	var now := Time.get_ticks_msec()
	var since_tap := now - _tap_at
	var pair := (
		since_tap >= DIAL_MIN_PAIR_MSEC
		and since_tap <= DIAL_TAP_MSEC
		and mouse.position.distance_to(_tap_point) <= DIAL_TAP_DISTANCE
	)
	if not (pair or mouse.double_click):
		_tap_at = now
		# The position is kept in this viewport's own coordinates. Reading the
		# mouse instead would fail on a device where the pointer is only updated
		# on motion, which is exactly how a finger behaves.
		_tap_point = mouse.position
		_tap_history = _history_count()
		_take_tap_snapshot()
		return false
	_tap_at = -10000
	# Taking the mark back waits a moment: a touch tool holds its press for about
	# 60ms before it starts drawing, and reverting before that lands would miss
	# exactly the mark this is meant to remove.
	_pending_dial = true
	_pending_dial_point = _screen_point(mouse.position)
	_pending_dial_history = _tap_history
	_pending_dial_snapshots = _tap_snapshots.duplicate()
	_tap_snapshots.clear()
	call_deferred("_open_pending_dial")
	_swallow_release = true
	_swallow_at = now
	get_viewport().set_input_as_handled()
	return true


## Opens the dial once the frame is over, unless a second finger turned the tap
## into a pinch or a multi finger tap in the meantime. The mark of the first tap
## is taken back here too, after its own deferred press had time to land.
func _open_pending_dial() -> void:
	if not _pending_dial:
		return
	_pending_dial = false
	var point := _pending_dial_point
	var history := _pending_dial_history
	var snapshots := _pending_dial_snapshots
	_pending_dial_snapshots = []
	# Let the tap's deferred press finish first, so its mark exists to be undone.
	await get_tree().create_timer(0.09).timeout
	if Tools.hold_to_pick_active:
		# A gesture owns the input: its fingers must not have drawn either.
		_restore_snapshots(snapshots)
		return
	# A press the tool has not started yet is dropped too, otherwise it would draw
	# right after the picture was put back.
	Tools.cancel_pending_press()
	Tools.cancel_active_tool()
	var project := Global.current_project
	if project != null and _history_count() > history:
		project.commit_undo()
	# Whatever the tool and its undo did, the cels go back to the picture they had
	# before the tap, so a fill or a stroke cannot be left behind.
	_restore_snapshots(snapshots)
	if Time.get_ticks_msec() - Global.last_multi_finger_msec <= DIAL_TAP_MSEC:
		return
	_open_tool_dial(point)


## Remembers the picture of every cel of the current frame before a tap does
## anything to it. The bucket can fill more than one layer at once, so a single
## cel is not enough. The budget is [constant TAP_SNAPSHOT_MAX_PIXELS] in total; a
## canvas beyond it is skipped instead of copying megabytes on every tap.
func _take_tap_snapshot() -> void:
	_tap_snapshots.clear()
	var project := Global.current_project
	if project == null or project.current_frame < 0:
		return
	if project.current_frame >= project.frames.size():
		return
	var budget := TAP_SNAPSHOT_MAX_PIXELS
	for cel in project.frames[project.current_frame].cels:
		if not (cel is PixelCel):
			continue
		var image := cel.get_image()
		if image == null:
			continue
		var pixels := image.get_width() * image.get_height()
		if pixels <= 0 or pixels > budget:
			continue
		budget -= pixels
		_tap_snapshots.append({"cel": cel, "image": image.duplicate()})


## Puts every cel of the frame back the way it was before the tap and redraws
## them, so whatever the tool changed the picture is exactly the old one again.
## The entries are handed in, because the gesture takes them when it is recognised
## and restores them a moment later.
func _restore_snapshots(entries: Array) -> void:
	var restored := false
	for entry: Dictionary in entries:
		var cel: BaseCel = entry["cel"]
		var snapshot: Image = entry["image"]
		if not is_instance_valid(cel):
			continue
		var image := cel.get_image()
		if image == null or image.get_size() != snapshot.get_size():
			continue
		image.copy_from(snapshot)
		cel.update_texture()
		restored = true
	if not restored:
		return
	sprite_changed_this_frame = true
	queue_redraw()


## Number of undo steps the project has, which is how the gesture knows whether
## the tap it just cancelled left a committed mark behind.
func _history_count() -> int:
	var project := Global.current_project
	if project == null:
		return 0
	return project.undo_redo.get_history_count()


## Window position of a point of this viewport, for placing the dial in the
## interface above the canvas.
func _screen_point(local_point: Vector2) -> Vector2:
	var container := get_viewport().get_parent() as SubViewportContainer
	if container == null:
		return local_point
	return container.global_position + local_point


## Builds the ring from the side toolbar's own buttons, so the icons are exactly
## the ones the panel shows. A tool the panel hides never reaches the ring, and
## [constant DIAL_TOOL_ORDER] decides which ones get a slot first.
func _dial_entries() -> Array:
	var entries: Array = []
	var buttons: Node = Tools._tool_buttons
	if not is_instance_valid(buttons):
		return entries
	var by_name := {}
	for child in buttons.get_children():
		if child is Button and child.visible:
			by_name[String(child.name)] = child
	for tool_name in DIAL_TOOL_ORDER:
		if entries.size() >= DIAL_MAX_SLOTS:
			break
		if not by_name.has(tool_name):
			continue
		entries.append(_dial_entry(tool_name, by_name[tool_name]))
		by_name.erase(tool_name)
	# Anything else the panel shows still gets a slot when there is room left.
	for tool_name in by_name:
		if entries.size() >= DIAL_MAX_SLOTS:
			break
		entries.append(_dial_entry(tool_name, by_name[tool_name]))
	return entries


func _dial_entry(tool_name: String, button: Button) -> Dictionary:
	var icon := button.get_node_or_null("ToolIcon") as TextureRect
	return {
		"tool": tool_name,
		"texture": icon.texture if icon != null else null,
		"label": str(button.tooltip_text).get_slice("\n", 0),
	}


## Name of the tool a stroke uses. The left slot is the one the canvas draws with
## and the one the side panel lights up, so it is the name that can be trusted.
func _left_tool_name() -> String:
	var slot := Tools.get_tool(MOUSE_BUTTON_LEFT)
	if slot != null and is_instance_valid(slot.tool_node):
		return str(slot.tool_node.name)
	return ""


## Remembers [param tool_name] as the newest of the two tools the dial alternates
## on, and points the next opening at the other one.
func _remember_dial_tool(tool_name: String) -> void:
	if tool_name.is_empty():
		return
	if not _dial_pair.is_empty() and _dial_pair[0] == tool_name:
		return
	var previous := ""
	if not _dial_pair.is_empty():
		previous = _dial_pair[0]
	_dial_pair.clear()
	_dial_pair.append(tool_name)
	if not previous.is_empty():
		_dial_pair.append(previous)
	_dial_pair_next = 1


## Every tool change is remembered, wherever it came from: the side panel, a
## shortcut or the dial itself. Only the left slot is the tool a stroke uses.
func _on_dial_tool_changed(tool_name: String, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	_remember_dial_tool(tool_name)


## Tool the ring highlights on this opening, which is the one sitting on the right
## so the thumb path to it never changes. It is one of the last two tools used and
## the two take turns, so two openings in a row offer each of them once. A tool the
## ring cannot show falls back to the one in use.
func _next_dial_default(entries: Array) -> String:
	var available := {}
	for entry in entries:
		available[str(entry.get("tool", ""))] = true
	var usable: Array[String] = []
	for tool_name in _dial_pair:
		if available.has(tool_name):
			usable.append(tool_name)
	if usable.is_empty():
		var in_use := _left_tool_name()
		if available.has(in_use):
			return in_use
		return str(entries[0].get("tool", ""))
	_dial_pair_next = posmod(_dial_pair_next, usable.size())
	var choice := usable[_dial_pair_next]
	_dial_pair_next = (_dial_pair_next + 1) % usable.size()
	return choice


## Puts the dial around the tool its next default is, which always sits on the
## right of the ring so the thumb path to it never changes.
func _open_tool_dial(screen_point: Vector2) -> void:
	var entries := _dial_entries()
	if entries.is_empty():
		return
	if not is_instance_valid(_tool_dial):
		_tool_dial = ToolDialScript.new()
		_tool_dial.picked.connect(_on_tool_dial_picked)
		_tool_dial.dismissed.connect(_close_tool_dial)
		Global.control.add_child(_tool_dial)
		_tool_dial.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var area: Vector2 = Global.control.size
	var active := _next_dial_default(entries)
	_tool_dial.setup(
		entries, screen_point - Global.control.global_position, area, active, DIAL_GUARD_MSEC
	)
	_tool_dial.grab_focus()


func _on_tool_dial_picked(tool_name: String) -> void:
	if not tool_name.is_empty():
		# The panel's own assignment path is used, so a pick is remembered exactly
		# like a sidebar press: the old tool is freed, the choice is written to the
		# config cache, and the slot that a stroke uses always ends up holding it.
		Tools.assign_tool(tool_name, MOUSE_BUTTON_LEFT)
		# Taken over right away, so a dial that is reopened before the tool change
		# signal arrives already offers the other tool.
		_remember_dial_tool(tool_name)
		if Global.single_tool_mode:
			Tools.assign_tool(tool_name, MOUSE_BUTTON_RIGHT)
	_close_tool_dial()


func _close_tool_dial() -> void:
	# A call that is still on its way must not reopen what is being closed now.
	_pending_dial = false
	if is_instance_valid(_tool_dial) and _tool_dial.visible:
		_tool_dial.visible = false


func queue_redraw_all_layers() -> void:
	project_changed = true
	var project := Global.current_project
	var current_cel := project.get_current_cel()
	if current_cel is Cel3D:
		var layer_3d := project.layers[project.current_layer] as Layer3D
		layer_3d.animation_player.speed_scale = project.fps
		layer_3d.animation.length = project.frames.size()
		layer_3d.animation_player.seek(project.current_frame, true)
		current_cel.update_texture()
	else:
		queue_redraw()


func camera_zoom(project := Global.current_project) -> void:
	await get_tree().process_frame
	for camera: CanvasCamera in get_tree().get_nodes_in_group("CanvasCameras"):
		camera.fit_to_frame(project.size)
	Global.transparent_checker.update_rect()


static func get_canvas_cel_image(cel: BaseCel, layer: BaseLayer, image: Image) -> void:
	var project := layer.project
	if layer.is_blender():
		var frame := project.frames[project.current_frame]
		var blended: Image = layer.blend_children(frame, false, Global.display_layer_effects)
		image.copy_from(blended)
	else:
		if Global.display_layer_effects:
			image.copy_from(layer.display_effects(cel, false))
			if layer.use_cel_image_for_effects:
				image.copy_from(project.crop_image_to_project_size(image, cel.offset))
		else:
			image.copy_from(project.crop_image_to_project_size(cel.get_image(), cel.offset))


func update_texture(
	layer_i: int, frame_i := -1, project := Global.current_project, undo := false
) -> void:
	if frame_i == -1:
		frame_i = project.current_frame

	if frame_i < project.frames.size() and layer_i < project.layers.size():
		var current_cel := project.frames[frame_i].cels[layer_i]
		current_cel.update_texture(undo)
		# Needed so that changes happening to the non-selected layer(s) are also visible
		# e.g. when undoing/redoing, when applying image effects to the entire frame, etc
		if frame_i != project.current_frame:
			# Don't update if the cel is on a different frame (can happen with undo/redo)
			return
		var layer := project.layers[layer_i].get_blender_ancestor()
		var cel_image := Image.new()
		get_canvas_cel_image(current_cel, layer, cel_image)
		if (
			cel_image.get_size()
			== Vector2i(layer_texture_array.get_width(), layer_texture_array.get_height())
		):
			layer_texture_array.update_layer(cel_image, project.ordered_layers.find(layer.index))


func update_selected_cels_textures(project := Global.current_project) -> void:
	for cel_index in project.selected_cels:
		var frame_index: int = cel_index[0]
		var layer_index: int = cel_index[1]
		if frame_index < project.frames.size() and layer_index < project.layers.size():
			var current_cel := project.frames[frame_index].cels[layer_index]
			current_cel.update_texture()


func draw_layers(force_recreate := false) -> void:
	var project := Global.current_project
	var recreate_texture_array := (
		layer_texture_array.get_layers() != project.layers.size()
		or layer_texture_array.get_width() != project.size.x
		or layer_texture_array.get_height() != project.size.y
		or force_recreate
	)
	if recreate_texture_array:
		var textures: Array[Image] = []
		textures.resize(project.layers.size())
		# Nx4 texture, where N is the number of layers and the first row are the blend modes,
		# the second are the opacities, the third are the clipping mask booleans.
		layer_metadata_image = Image.create(project.layers.size(), 4, false, Image.FORMAT_R8)
		# Draw current frame layers
		for i in project.layers.size():
			var layer := project.layers[i]
			var ordered_index := project.ordered_layers.find(layer.index)
			var cel_image := Image.new()
			_update_texture_array_layer(project, layer, cel_image, false)
			textures[ordered_index] = cel_image

		layer_texture_array.create_from_images(textures)
		layer_metadata_texture.set_image(layer_metadata_image)
	else:  # Update the TextureArray
		if layer_texture_array.get_layers() > 0:
			for i in project.layers.size():
				var layer := project.layers[i]
				if not update_all_layers:
					var test_array := [project.current_frame, i]
					if not test_array in project.selected_cels:
						var include := false
						# Some layers are required for mandatory update because they are part of
						# an undo/redo action that is being performed right now. The may not be
						# currently selected but still require an update
						if i in mandatory_update_layers:
							include = true
						else:
							var parents := layer.get_ancestors()
							# Even if the layer itself is not changed, if it is part of a group layer
							# with passthrough mode, it will still need an update if it's group cel is
							# selected.
							for parent in parents:
								if parent.blend_mode == BaseLayer.BlendModes.PASS_THROUGH:
									var test_array_parent := [project.current_frame, parent.index]
									if test_array_parent in project.selected_cels:
										include = true
						if not include:
							continue
				var cel_image := Image.new()
				_update_texture_array_layer(project, layer, cel_image, true)
				var parent_layer := layer.get_blender_ancestor()
				if layer != parent_layer:
					# True when the layer has parents. In that case, update its top-most parent.
					_update_texture_array_layer(project, parent_layer, Image.new(), true)
			layer_metadata_texture.update(layer_metadata_image)

	mandatory_update_layers = []
	update_all_layers = false


func _update_texture_array_layer(
	project: Project, layer: BaseLayer, cel_image: Image, update_layer: bool
) -> void:
	var ordered_index := project.ordered_layers.find(layer.index)
	var cel := project.frames[project.current_frame].cels[layer.index]
	var include := true
	get_canvas_cel_image(cel, layer, cel_image)
	if layer.is_blended_by_ancestor():
		include = false
	if update_layer:
		layer_texture_array.update_layer(cel_image, ordered_index)
	DrawingAlgos.set_layer_metadata_image(
		layer, cel, layer_metadata_image, ordered_index, include, false
	)


func refresh_onion() -> void:
	onion_past.queue_redraw()
	onion_future.queue_redraw()


func _on_project_about_to_switch() -> void:
	var project := Global.current_project
	if project.resized.is_connected(camera_zoom):
		project.resized.disconnect(camera_zoom)


func _on_project_switched() -> void:
	var project := Global.current_project
	if not project.resized.is_connected(camera_zoom):
		project.resized.connect(camera_zoom.bind(project))
