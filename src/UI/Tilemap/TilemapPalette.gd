extends Control
## Tile palette of the Tilemap page. It draws the atlas itself instead of
## building one button per tile, so a tileset with thousands of tiles still
## opens quickly and scrolls smoothly.

## Side of one palette cell, in pixels. Comfortable to hit with a finger.
const CELL := 38.0

var page

var _hover := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tooltip_text = "点一个图块，把它设为当前图块"
	resized.connect(_on_resized)
	_update_minimum_size()


func _process(_delta: float) -> void:
	var index := _index_at(get_local_mouse_position())
	if index != _hover:
		_hover = index
		queue_redraw()


func _on_resized() -> void:
	_update_minimum_size()
	queue_redraw()


## Height that shows every row at the current width, so the scroll container has
## something to scroll instead of squeezing the rows.
func _update_minimum_size() -> void:
	var count := _tile_count()
	var columns := _columns()
	var rows := int(ceil(float(count) / float(columns))) if count > 0 else 0
	custom_minimum_size.y = float(rows) * CELL


func _columns() -> int:
	return maxi(int(maxf(size.x, CELL) / CELL), 1)


func _tile_count() -> int:
	return page.tile_count() if page != null else 0


func _draw() -> void:
	var count := _tile_count()
	if count <= 0 or page.atlas_texture() == null:
		return
	var columns := _columns()
	var selected: int = page.selected_tile()
	for index in range(1, count + 1):
		var slot := index - 1
		var cell_pos := Vector2(slot % columns, floor(float(slot) / float(columns))) * CELL
		var box := Rect2(cell_pos, Vector2.ONE * CELL)
		# Checker per cell, so a transparent tile reads as empty.
		var light := slot % 2 == 0
		draw_rect(box, Color(0.18, 0.19, 0.22) if light else Color(0.14, 0.15, 0.18))
		var rect: Rect2i = page.tile_rect(index)
		if rect.size.x > 0 and rect.size.y > 0:
			draw_texture_rect_region(page.atlas_texture(), box.grow(-2.0), Rect2(rect))
		if index == selected:
			draw_rect(box, Color(1.0, 0.85, 0.4), false, 2.0)
		elif index == _hover:
			draw_rect(box, Color(1.0, 1.0, 1.0, 0.6), false, 1.0)


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if mouse.button_index != MOUSE_BUTTON_LEFT or not mouse.pressed:
		return
	var index := _index_at(mouse.position)
	if index > 0:
		page.set_selected_tile(index)
		queue_redraw()
	accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover = -1
		queue_redraw()


func _index_at(position: Vector2) -> int:
	if position.x < 0.0 or position.y < 0.0:
		return -1
	var columns := _columns()
	var column := int(floor(position.x / CELL))
	if column < 0 or column >= columns:
		return -1
	var index := int(floor(position.y / CELL)) * columns + column + 1
	if index > _tile_count():
		return -1
	return index


## Called by the page whenever the tiles or the selection change.
func refresh() -> void:
	_update_minimum_size()
	queue_redraw()
