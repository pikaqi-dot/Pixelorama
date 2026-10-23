extends Panel

const UI_TRANSPARENCY_SHADER := preload("uid://bwtsxcdoe2ps1")
## Maximum duration of a multi-finger tap, in milliseconds.
const MULTI_FINGER_TAP_MSEC := 600
## Movement that turns a multi-finger tap into a pan/zoom gesture.
const MULTI_FINGER_TAP_MOVE := 24.0
## Change of the distance between two fingers that counts as a pinch.
const MULTI_FINGER_PINCH_MOVE := 18.0
## How long a single finger has to rest on the canvas before the color picker
## takes over, in seconds.
const HOLD_PICK_DELAY := 0.35
## Movement that cancels the hold-to-pick gesture.
const HOLD_PICK_MOVE := 14.0
## Grace period before a released finger actually ends the picker, in seconds.
## Android can send spurious touch releases while the finger is still down.
const HOLD_PICK_RELEASE_GRACE := 0.2
## Size of the magnifier that follows the finger while picking, in pixels.
const MAGNIFIER_SIZE := 130
## Default number of canvas pixels shown on each axis, used before the canvas
## zoom is known.
const MAGNIFIER_DEFAULT_SOURCE_PIXELS := 13
## How much larger than the on-screen canvas the magnifier looks. The number of
## canvas pixels shown follows the canvas zoom, so zooming in also zooms the lens.
const MAGNIFIER_SCREEN_FACTOR := 5.0
## Bounds for the number of magnified canvas pixels, on each axis.
const MAGNIFIER_MIN_SOURCE_PIXELS := 3
const MAGNIFIER_MAX_SOURCE_PIXELS := 65
## Distance between the finger and the magnifier.
const MAGNIFIER_OFFSET := 52.0
## Minimum delay between two magnifier texture updates, in milliseconds.
const MAGNIFIER_MIN_INTERVAL_MSEC := 40

var shader_disabled := false
var transparency_material: ShaderMaterial

## Finger index -> position where that finger touched down.
var _finger_starts: Dictionary[int, Vector2] = {}
## Finger index -> latest position, used to detect pinching.
var _finger_positions: Dictionary[int, Vector2] = {}
## Highest number of fingers that touched the screen during the current gesture.
var _gesture_max_fingers := 0
var _gesture_moved := false
var _gesture_started_msec := 0
## True when the OS reported a pan or zoom gesture during these touches.
var _gesture_pan_zoom := false
## Distance between the first two fingers when the second one landed.
var _gesture_initial_span := 0.0
## True while a multi-finger gesture keeps the tools from receiving input.
var _gesture_suppressed := false
## Identifies the pending hold-to-pick wait, so it can be cancelled.
var _hold_pick_generation := 0
## True while waiting for the finger to rest long enough to start picking.
var _hold_pick_armed := false
## True when the stroke began on the canvas, so toolbars are ignored.
var _hold_pick_stroke_seen := false
var _hold_pick_press_position := Vector2.ZERO
var _hold_pick_position := Vector2.ZERO
var _hold_pick_active := false
## Mouse buttons currently held down (Android turns a long press into a right
## button press, so both buttons are tracked).
var _pressed_buttons: Dictionary[int, bool] = {}
var _hold_pick_pointer_down := false
## Color previewed by the magnifier, only committed when the finger is lifted.
var _hold_pick_color := Color(0, 0, 0, 0)
var _hold_pick_index := -1
var _hold_pick_has_color := false
## Invalidates a pending "finger released" check when the finger keeps moving.
var _hold_pick_release_generation := 0
var _hold_pick_last_sample := 0
## Last time a mouse event arrived, used to recover from lost release events.
var _hold_pick_last_event_msec := 0
## Magnifier shown while the hold-to-pick gesture is sampling colors.
var _magnifier: Control
var _magnifier_shadow: Panel
var _magnifier_clip: Panel
var _magnifier_ring: Panel
var _magnifier_preview: TextureRect
var _magnifier_cell: Panel
var _magnifier_cell_style: StyleBoxFlat
var _magnifier_swatch: Panel
var _magnifier_swatch_style: StyleBoxFlat
var _magnifier_last_update := 0

@onready var dockable_container: DockableContainer = $DockableContainer
@onready var main_canvas_container := find_child("Main Canvas") as Container
@onready var right_tool_options: ScrollContainer = $"DockableContainer/Right Tool Options"
@onready var tiles: TileSetPanel = $DockableContainer/Tiles
@onready var object_tree_3d: PanelContainer = $"DockableContainer/3D Object Tree"


func _process(_delta: float) -> void:
	if _hold_pick_armed and Tools.active_button != -1:
		_hold_pick_stroke_seen = true
	# Keeps the preview alive even if no motion events are delivered while the
	# finger rests still on the screen.
	if not _hold_pick_active:
		return
	var now := Time.get_ticks_msec()
	if now - _hold_pick_last_event_msec > 3000:
		# No events for a long time: a release event was probably lost, so end
		# the picker instead of leaving it stuck.
		_pressed_buttons.clear()
		_hold_pick_pointer_down = false
		_finish_hold_to_pick()
		return
	if now - _hold_pick_last_sample < 50:
		return
	_hold_pick_last_sample = now
	_sample_hold_to_pick()


func _ready() -> void:
	Global.cel_switched.connect(_on_cel_switched)
	Global.single_tool_mode_changed.connect(_on_single_tool_mode_changed)
	if Global.window_transparency:
		transparency_material = ShaderMaterial.new()
		transparency_material.shader = UI_TRANSPARENCY_SHADER
		material = transparency_material
		main_canvas_container.property_list_changed.connect(_re_configure_shader)
		update_transparent_shader()
	await Global.pixelorama_opened
	if Global.single_tool_mode:
		dockable_container.set_control_hidden.call_deferred(right_tool_options, true)
	dockable_container.set_control_hidden.call_deferred(tiles, true)
	dockable_container.set_control_hidden.call_deferred(object_tree_3d, true)


func _input(event: InputEvent) -> void:
	if not DisplayServer.is_touchscreen_available():
		return
	# A recognized pan/zoom means these touches are not a multi-finger tap.
	if event is InputEventMagnifyGesture or event is InputEventPanGesture:
		_gesture_pan_zoom = true
		return
	# The hold-to-pick gesture uses the (touch emulated) mouse events, because
	# those are the same ones the drawing tools rely on.
	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventScreenTouch:
		_on_screen_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_on_screen_drag(event as InputEventScreenDrag)


func _on_mouse_button(mouse_button: InputEventMouseButton) -> void:
	_hold_pick_last_event_msec = Time.get_ticks_msec()
	var button := mouse_button.button_index
	if button != MOUSE_BUTTON_LEFT and button != MOUSE_BUTTON_RIGHT:
		return
	if mouse_button.pressed:
		_pressed_buttons[button] = true
		_hold_pick_pointer_down = true
		if button == MOUSE_BUTTON_RIGHT:
			# Android's long press emulation. It must not draw or restart the pick.
			return
		if _hold_pick_active:
			return
		_start_hold_to_pick(mouse_button.global_position)
		return
	_pressed_buttons.erase(button)
	_hold_pick_pointer_down = not _pressed_buttons.is_empty()
	if _hold_pick_armed or _hold_pick_active:
		_schedule_finish_hold_to_pick()


func _on_mouse_motion(motion: InputEventMouseMotion) -> void:
	_hold_pick_last_event_msec = Time.get_ticks_msec()
	if _hold_pick_active:
		_hold_pick_position = motion.global_position
		if _hold_pick_pointer_down or motion.button_mask != 0:
			# The finger is still pressed, keep the picker alive.
			_hold_pick_release_generation += 1
		_sample_hold_to_pick()
	elif _hold_pick_armed:
		_hold_pick_position = motion.global_position
		if motion.global_position.distance_to(_hold_pick_press_position) > HOLD_PICK_MOVE:
			_clear_hold_to_pick()


## Two fingers tapped together undo, three fingers tapped together redo.
## A single finger resting on the canvas switches to the color picker until it is
## lifted, which then selects the color under it.
func _on_screen_touch(touch: InputEventScreenTouch) -> void:
	if touch.pressed:
		if _finger_starts.has(touch.index):
			_finger_positions[touch.index] = touch.position
			return
		_finger_starts[touch.index] = touch.position
		_finger_positions[touch.index] = touch.position
		if _finger_starts.size() > _gesture_max_fingers:
			_gesture_max_fingers = _finger_starts.size()
			_gesture_moved = false
			_gesture_started_msec = Time.get_ticks_msec()
		if _finger_starts.size() == 2:
			_gesture_initial_span = _gesture_span()
		if _finger_starts.size() > 1:
			# Multi-finger gestures must not draw: revert the stroke the first
			# finger started and ignore tool input until every finger is lifted.
			_cancel_hold_to_pick()
			_suppress_tool_input()
		return

	_finger_starts.erase(touch.index)
	_finger_positions.erase(touch.index)
	if not _finger_starts.is_empty():
		return

	var duration := Time.get_ticks_msec() - _gesture_started_msec
	var fingers := _gesture_max_fingers
	var moved := _gesture_moved or _gesture_pan_zoom
	_reset_touch_gesture()
	_release_tool_input()
	if moved or duration > MULTI_FINGER_TAP_MSEC:
		return
	if fingers == 2:
		Global.current_project.commit_undo()
	elif fingers == 3:
		Global.current_project.commit_redo()


func _on_screen_drag(drag: InputEventScreenDrag) -> void:
	_finger_positions[drag.index] = drag.position
	var origin: Vector2 = _finger_starts.get(drag.index, drag.position)
	if drag.position.distance_to(origin) > MULTI_FINGER_TAP_MOVE:
		_gesture_moved = true
	if _finger_starts.size() >= 2:
		# Even a small pinch changes the distance between the fingers.
		if absf(_gesture_span() - _gesture_initial_span) > MULTI_FINGER_PINCH_MOVE:
			_gesture_moved = true


## Distance between the first two fingers that are on screen.
func _gesture_span() -> float:
	var positions := _finger_positions.values()
	if positions.size() < 2:
		return 0.0
	return (positions[0] as Vector2).distance_to(positions[1] as Vector2)


func _suppress_tool_input() -> void:
	# A press that has not started drawing yet is simply forgotten, so gestures
	# never leave a dot or an erased pixel behind.
	Tools.cancel_pending_press()
	Tools.cancel_active_tool()
	Tools.hold_to_pick_active = true
	_gesture_suppressed = true


func _release_tool_input() -> void:
	if not _gesture_suppressed:
		return
	_gesture_suppressed = false
	Tools.hold_to_pick_active = false


func _start_hold_to_pick(position: Vector2) -> void:
	if not is_instance_valid(Global.canvas) or Global.current_project == null:
		return
	_hold_pick_armed = true
	_hold_pick_stroke_seen = false
	_hold_pick_last_event_msec = Time.get_ticks_msec()
	_hold_pick_press_position = position
	_hold_pick_position = position
	_hold_pick_active = false
	_hold_pick_generation += 1
	var generation := _hold_pick_generation
	await get_tree().create_timer(HOLD_PICK_DELAY).timeout
	if generation != _hold_pick_generation or _hold_pick_active or not _hold_pick_armed:
		return
	# A stroke that started on the canvas means the finger is resting on it,
	# which is the only place where a color can be picked.
	if not _hold_pick_stroke_seen and Tools.active_button == -1:
		_hold_pick_armed = false
		return
	Tools.cancel_active_tool()
	_hold_pick_armed = false
	_hold_pick_active = true
	Tools.hold_to_pick_active = true
	_sample_hold_to_pick()


## Pixel under the finger, mirroring it when the view is mirrored like the tools do.
func _current_pick_pixel() -> Vector2i:
	var pixel := Vector2i(Global.canvas.get_local_mouse_position().floor())
	if Global.mirror_view:
		pixel.x = Global.current_project.size.x - pixel.x - 1
	return pixel


func _is_pixel_inside_project(pixel: Vector2i) -> bool:
	var size := Global.current_project.size
	return pixel.x >= 0 and pixel.y >= 0 and pixel.x < size.x and pixel.y < size.y


## Builds the magnifier lazily. It is a round loupe: a soft shadow, the magnified
## pixels clipped to a circle, a thin ring, a marker on the picked pixel and a
## round color swatch.
func _ensure_magnifier() -> void:
	if is_instance_valid(_magnifier):
		return
	var radius := MAGNIFIER_SIZE / 2
	_magnifier = Control.new()
	_magnifier.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_magnifier.custom_minimum_size = Vector2(MAGNIFIER_SIZE, MAGNIFIER_SIZE)
	_magnifier.size = Vector2(MAGNIFIER_SIZE, MAGNIFIER_SIZE)

	_magnifier_shadow = Panel.new()
	_magnifier_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_magnifier_shadow.set_anchors_preset(Control.PRESET_FULL_RECT)
	var shadow_style := StyleBoxFlat.new()
	shadow_style.bg_color = Color(0, 0, 0, 0)
	shadow_style.set_corner_radius_all(radius)
	shadow_style.shadow_color = Color(0, 0, 0, 0.45)
	shadow_style.shadow_size = 6
	shadow_style.shadow_offset = Vector2(0, 3)
	_magnifier_shadow.add_theme_stylebox_override("panel", shadow_style)
	_magnifier.add_child(_magnifier_shadow)

	_magnifier_clip = Panel.new()
	_magnifier_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_magnifier_clip.set_anchors_preset(Control.PRESET_FULL_RECT)
	var clip_style := StyleBoxFlat.new()
	clip_style.bg_color = Color(0.08, 0.08, 0.09)
	clip_style.set_corner_radius_all(radius)
	_magnifier_clip.add_theme_stylebox_override("panel", clip_style)
	_magnifier_clip.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	_magnifier.add_child(_magnifier_clip)

	_magnifier_preview = TextureRect.new()
	_magnifier_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	_magnifier_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_magnifier_preview.stretch_mode = TextureRect.STRETCH_SCALE
	_magnifier_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_magnifier_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_magnifier_clip.add_child(_magnifier_preview)

	_magnifier_ring = Panel.new()
	_magnifier_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_magnifier_ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	var ring_style := StyleBoxFlat.new()
	ring_style.bg_color = Color(0, 0, 0, 0)
	ring_style.border_color = Color(1, 1, 1, 0.92)
	ring_style.set_border_width_all(3)
	ring_style.set_corner_radius_all(radius)
	_magnifier_ring.add_theme_stylebox_override("panel", ring_style)
	_magnifier.add_child(_magnifier_ring)

	# A small ring marks the exact pixel that will be picked.
	var cell := float(MAGNIFIER_SIZE) / float(MAGNIFIER_DEFAULT_SOURCE_PIXELS)
	_magnifier_cell = Panel.new()
	_magnifier_cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_magnifier_cell_style = StyleBoxFlat.new()
	_magnifier_cell_style.bg_color = Color(0, 0, 0, 0)
	_magnifier_cell_style.border_color = Color(1, 1, 1, 0.95)
	_magnifier_cell_style.set_border_width_all(2)
	_magnifier_cell_style.set_corner_radius_all(int(cell) / 2)
	_magnifier_cell.add_theme_stylebox_override("panel", _magnifier_cell_style)
	_magnifier_cell.anchor_left = 0.5
	_magnifier_cell.anchor_right = 0.5
	_magnifier_cell.anchor_top = 0.5
	_magnifier_cell.anchor_bottom = 0.5
	_magnifier_cell.offset_left = -cell * 0.5
	_magnifier_cell.offset_top = -cell * 0.5
	_magnifier_cell.offset_right = cell * 0.5
	_magnifier_cell.offset_bottom = cell * 0.5
	_magnifier.add_child(_magnifier_cell)

	# Round color swatch, so the picked color is visible at a glance.
	_magnifier_swatch = Panel.new()
	_magnifier_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_magnifier_swatch_style = StyleBoxFlat.new()
	_magnifier_swatch_style.bg_color = Color(1, 0, 1)
	_magnifier_swatch_style.border_color = Color(1, 1, 1, 0.95)
	_magnifier_swatch_style.set_border_width_all(2)
	_magnifier_swatch_style.set_corner_radius_all(13)
	_magnifier_swatch.add_theme_stylebox_override("panel", _magnifier_swatch_style)
	_magnifier_swatch.anchor_left = 1.0
	_magnifier_swatch.anchor_right = 1.0
	_magnifier_swatch.anchor_top = 1.0
	_magnifier_swatch.anchor_bottom = 1.0
	_magnifier_swatch.offset_left = -30
	_magnifier_swatch.offset_top = -30
	_magnifier_swatch.offset_right = -6
	_magnifier_swatch.offset_bottom = -6
	_magnifier.add_child(_magnifier_swatch)

	add_child(_magnifier)
	_magnifier.hide()


func _update_magnifier(pixel: Vector2i) -> void:
	_ensure_magnifier()
	_magnifier_swatch_style.bg_color = _hold_pick_color
	var source_pixels := _magnifier_source_pixels()
	_update_magnifier_cell(source_pixels)
	var ui_rect := get_global_rect()
	var target := (
		_hold_pick_position
		- Vector2(MAGNIFIER_SIZE * 0.5, MAGNIFIER_SIZE + MAGNIFIER_OFFSET)
	)
	target.x = clampf(target.x, ui_rect.position.x, maxf(ui_rect.position.x, ui_rect.end.x - MAGNIFIER_SIZE))
	target.y = clampf(target.y, ui_rect.position.y, maxf(ui_rect.position.y, ui_rect.end.y - MAGNIFIER_SIZE))
	_magnifier.size = Vector2(MAGNIFIER_SIZE, MAGNIFIER_SIZE)
	_magnifier.global_position = target
	_magnifier.show()

	var now := Time.get_ticks_msec()
	if now - _magnifier_last_update < MAGNIFIER_MIN_INTERVAL_MSEC:
		return
	_magnifier_last_update = now
	var texture := _make_magnifier_texture(pixel, source_pixels)
	if texture != null:
		_magnifier_preview.texture = texture


## How many canvas pixels fit on each axis of the magnifier. It follows the
## canvas zoom, so zooming into the canvas also enlarges the pixels in the lens.
func _magnifier_source_pixels() -> int:
	var canvas_scale := 1.0
	if is_instance_valid(Global.canvas):
		# Includes the canvas transform and the camera zoom.
		canvas_scale = absf(Global.canvas.get_global_transform_with_canvas().get_scale().x)
	if canvas_scale <= 0.0001:
		canvas_scale = 1.0
	var count := int(round(MAGNIFIER_SIZE / (canvas_scale * MAGNIFIER_SCREEN_FACTOR)))
	count = clampi(count, MAGNIFIER_MIN_SOURCE_PIXELS, MAGNIFIER_MAX_SOURCE_PIXELS)
	# An odd count keeps the picked pixel exactly in the middle of the lens.
	if count % 2 == 0:
		count += 1
	return count


## Resizes the outline that marks the picked pixel, so it always covers one
## canvas pixel no matter how many of them are visible.
func _update_magnifier_cell(source_pixels: int) -> void:
	if not is_instance_valid(_magnifier_cell) or not is_instance_valid(_magnifier_cell_style):
		return
	var cell := float(MAGNIFIER_SIZE) / float(maxi(source_pixels, 1))
	_magnifier_cell.offset_left = -cell * 0.5
	_magnifier_cell.offset_top = -cell * 0.5
	_magnifier_cell.offset_right = cell * 0.5
	_magnifier_cell.offset_bottom = cell * 0.5
	var border := 2 if cell >= 9.0 else 1
	_magnifier_cell_style.set_border_width_all(border)
	_magnifier_cell_style.set_corner_radius_all(maxi(int(cell) / 2, 1))


## Crops the canvas around [param pixel] with no filtering, so individual pixels
## stay readable. The texture is stretched to the lens size by the preview.
func _make_magnifier_texture(pixel: Vector2i, source_pixels: int) -> Texture2D:
	var count := maxi(source_pixels, 1)
	var half := count / 2
	var region := Rect2i(pixel - Vector2i(half, half), Vector2i(count, count))
	# The layers are composited on the CPU for this small region, so no viewport
	# readback (which is slow on mobile) happens every frame.
	var image := Tools.get_composited_region(region)
	if image == null or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)


## Waits a short moment before ending the picker, because Android sometimes sends
## a release while the finger is still on the screen.
func _schedule_finish_hold_to_pick() -> void:
	_hold_pick_release_generation += 1
	var generation := _hold_pick_release_generation
	await get_tree().create_timer(HOLD_PICK_RELEASE_GRACE).timeout
	if generation != _hold_pick_release_generation:
		return
	_finish_hold_to_pick()


func _finish_hold_to_pick() -> void:
	if _hold_pick_active:
		_sample_hold_to_pick()
		if _hold_pick_has_color:
			# Only now, when the finger is lifted, the color is actually selected.
			Tools.assign_color(_hold_pick_color, MOUSE_BUTTON_LEFT, false, _hold_pick_index)
	_clear_hold_to_pick()


func _cancel_hold_to_pick() -> void:
	_clear_hold_to_pick()


func _clear_hold_to_pick() -> void:
	_hold_pick_generation += 1
	_hold_pick_release_generation += 1
	_hold_pick_armed = false
	_hold_pick_stroke_seen = false
	_hold_pick_active = false
	_hold_pick_has_color = false
	# The multi-finger gesture keeps the flag until every finger is lifted.
	if not _gesture_suppressed:
		Tools.hold_to_pick_active = false
	if is_instance_valid(_magnifier):
		_magnifier.hide()


## Only previews the color under the finger; the color is assigned on release.
func _sample_hold_to_pick() -> void:
	var pixel := _current_pick_pixel()
	if not _is_pixel_inside_project(pixel):
		return
	var info := Tools.get_color_at(pixel)
	if info.is_empty():
		return
	_hold_pick_color = info["color"]
	_hold_pick_index = int(info["index"])
	_hold_pick_has_color = true
	_update_magnifier(pixel)


func _reset_touch_gesture() -> void:
	_finger_starts.clear()
	_finger_positions.clear()
	_gesture_max_fingers = 0
	_gesture_moved = false
	_gesture_started_msec = 0
	_gesture_pan_zoom = false
	_gesture_initial_span = 0.0


func _on_cel_switched() -> void:
	var cel := Global.current_project.get_current_cel()
	dockable_container.set_control_hidden(tiles, cel is not CelTileMap)
	dockable_container.set_control_hidden(object_tree_3d, cel is not Cel3D)


func _on_single_tool_mode_changed(mode: bool) -> void:
	dockable_container.set_control_hidden(right_tool_options, mode)


func _re_configure_shader() -> void:
	await get_tree().process_frame
	if get_window() != main_canvas_container.get_window():
		material = null
		shader_disabled = true
	else:
		if shader_disabled:
			material = transparency_material
			shader_disabled = false


func _on_main_canvas_item_rect_changed() -> void:
	update_transparent_shader()


func _on_main_canvas_visibility_changed() -> void:
	update_transparent_shader()


func update_transparent_shader() -> void:
	if not is_instance_valid(main_canvas_container) or not is_instance_valid(transparency_material):
		return
	# Works independently of the transparency feature
	var canvas_size: Vector2 = (main_canvas_container.size - Vector2.DOWN * 2) * Global.shrink
	transparency_material.set_shader_parameter("screen_resolution", get_viewport().size)
	transparency_material.set_shader_parameter(
		"position", main_canvas_container.global_position * Global.shrink
	)
	transparency_material.set_shader_parameter("size", canvas_size)
