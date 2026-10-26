extends RefCounted
## Frame animated tile set shared by the Tilemap page and the Game page.
##
## The drawing area is read once per animation frame and cut with the same
## rectangles, so a tile keeps its atlas position and a cell animates just by
## switching which picture is drawn. Rectangles always come from the first
## frame, so a later frame with a blank cell cannot shift the palette under the
## user's finger.

## Atlas rectangles; index 0 is the empty tile.
var rects: Array[Rect2i] = [Rect2i()]
## One packed atlas per animation frame, plus the texture built from it.
var atlases: Array[Image] = []
var textures: Array[ImageTexture] = []
var fps := 6.0
var playing := true

var _time := 0.0
var _frame := 0


func clear() -> void:
	rects.clear()
	rects.append(Rect2i())
	atlases.clear()
	textures.clear()
	_time = 0.0
	_frame = 0


func frame_count() -> int:
	return textures.size()


func frame() -> int:
	return clampi(_frame, 0, maxi(textures.size() - 1, 0))


## Texture to draw right now, or null when nothing is loaded.
func texture() -> Texture2D:
	if textures.is_empty():
		return null
	return textures[frame()] as Texture2D


## Advances the clock. True when the visible frame changed, so the caller knows
## whether a redraw is needed.
func advance(delta: float) -> bool:
	if not playing or textures.size() <= 1:
		return false
	_time += delta
	var step := 1.0 / maxf(fps, 0.1)
	var next := int(floor(_time / step)) % textures.size()
	if next == _frame:
		return false
	_frame = next
	return true


## Cuts [param sources] (one picture per animation frame) into [param tile]
## sized cells, keeping only the cells that paint something in the first frame.
func build_from_sources(sources: Array, tile: Vector2i) -> bool:
	clear()
	if sources.is_empty():
		return false
	var first: Image = sources[0]
	if first == null or first.is_empty():
		return false
	var columns := floori(float(first.get_width()) / float(maxi(tile.x, 1)))
	var rows := floori(float(first.get_height()) / float(maxi(tile.y, 1)))
	if columns <= 0 or rows <= 0:
		return false
	var kept: Array[Rect2i] = []
	var data := first.get_data()
	var stride := first.get_width()
	for y in rows:
		for x in columns:
			var region := Rect2i(Vector2i(x, y) * tile, tile)
			if _has_alpha(data, stride, region):
				kept.append(region)
	if kept.is_empty():
		return false
	rects.append_array(kept)
	for source in sources:
		var image: Image = source
		if image == null or image.is_empty() or image.get_size() != first.get_size():
			image = first
		var tiles: Array[Image] = [null]
		for region in kept:
			tiles.append(image.get_region(region))
		_pack(tiles)
	return not textures.is_empty()


## Packs one frame of already cut tile images. Used for project tilesets, which
## carry a single picture per tile.
func build_from_tiles(tiles: Array) -> bool:
	clear()
	if tiles.size() <= 1:
		return false
	_pack(tiles)
	return not textures.is_empty()


## Base64 PNG of every frame after the first, which travels as the map "atlas".
func encoded_frames() -> Array:
	var out := []
	for index in range(1, atlases.size()):
		out.append(Marshalls.raw_to_base64(atlases[index].save_png_to_buffer()))
	return out


## Rebuilds the frames saved next to a map. [param base] is the frame 0 atlas the
## map already carries, [param extra] the encoded frames behind it.
func restore(base: Image, extra: Array, rects_in: Array) -> void:
	clear()
	if rects_in.size() > 1:
		rects.assign(rects_in)
	if base != null and not base.is_empty():
		atlases.append(base)
		textures.append(ImageTexture.create_from_image(base))
	for entry in extra:
		var bytes := Marshalls.base64_to_raw(str(entry))
		if bytes.is_empty():
			continue
		var image := Image.new()
		if image.load_png_from_buffer(bytes) != OK:
			continue
		atlases.append(image)
		textures.append(ImageTexture.create_from_image(image))


## Draws every animated cell of [param layers]. Nothing happens while the set
## holds a single frame, so a static map costs nothing.
func draw_cells(
	board: CanvasItem,
	layers: Array,
	tile_size: Vector2i,
	origin: Vector2,
	scale: float
) -> void:
	if textures.size() <= 1 or rects.size() <= 1:
		return
	var texture_now := texture()
	if texture_now == null:
		return
	var cell := Vector2(maxi(tile_size.x, 1), maxi(tile_size.y, 1)) * scale
	for layer in layers:
		if not bool(layer["visible"]):
			continue
		var cells: Dictionary = layer["cells"]
		for cell_pos: Vector2i in cells:
			var index := int(cells[cell_pos])
			if index <= 0 or index >= rects.size():
				continue
			var region: Rect2i = rects[index]
			if region.size.x <= 0 or region.size.y <= 0:
				continue
			board.draw_texture_rect_region(
				texture_now, Rect2(origin + Vector2(cell_pos) * cell, cell), Rect2(region)
			)


## Packs one frame of tiles into a single atlas, keeping the layout identical
## between frames because the layout only depends on the tile count.
func _pack(tiles: Array) -> void:
	var cell := Vector2i(1, 1)
	for i in range(1, tiles.size()):
		var image: Image = tiles[i]
		if image != null:
			cell = Vector2i(maxi(cell.x, image.get_width()), maxi(cell.y, image.get_height()))
	var count := maxi(tiles.size() - 1, 1)
	var columns := maxi(int(ceil(sqrt(float(count)))), 1)
	var rows := maxi(int(ceil(float(count) / float(columns))), 1)
	var atlas := Image.create_empty(columns * cell.x, rows * cell.y, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0.0, 0.0, 0.0, 0.0))
	var layout: Array[Rect2i] = []
	for i in range(1, tiles.size()):
		var image: Image = tiles[i]
		if image == null:
			layout.append(Rect2i())
			continue
		var slot := i - 1
		var position := Vector2i(
			(slot % columns) * cell.x, floori(float(slot) / float(columns)) * cell.y
		)
		atlas.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), position)
		layout.append(Rect2i(position, image.get_size()))
	if rects.size() <= 1:
		rects.append_array(layout)
	atlases.append(atlas)
	textures.append(ImageTexture.create_from_image(atlas))


## True when any pixel of [param rect] has alpha. Bytes are read directly so a
## whole drawing area can be scanned without building a tile per cell.
func _has_alpha(data: PackedByteArray, image_width: int, rect: Rect2i) -> bool:
	for y in rect.size.y:
		var row := (rect.position.y + y) * image_width
		var start := (row + rect.position.x) * 4 + 3
		for x in rect.size.x:
			if data[start + x * 4] != 0:
				return true
	return false
