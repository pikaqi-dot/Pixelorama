extends RefCounted
## Builds a picture of one project frame. Every visible layer is blended in
## order with its cel offset, and transparency is kept, so the result is exactly
## what the drawing area shows without the checkerboard or the guides.
##
## Used by the Tilemap page (tiles out of the artwork) and by the Game page
## (frames as sprites), so both agree on what a frame looks like.


static func frame_image(project: Project, frame_index: int) -> Image:
	if project == null or project.frames.is_empty():
		return null
	var index := clampi(frame_index, 0, project.frames.size() - 1)
	var frame := project.frames[index]
	var size := Vector2i(maxi(project.size.x, 1), maxi(project.size.y, 1))
	var output := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	output.fill(Color(0.0, 0.0, 0.0, 0.0))
	for layer_index in project.layers.size():
		if layer_index >= frame.cels.size():
			break
		var layer := project.layers[layer_index]
		if not layer.is_visible_in_hierarchy():
			continue
		var cel = frame.cels[layer_index]
		if cel == null:
			continue
		var source: Image = cel.get_image()
		if source == null or source.is_empty():
			continue
		# The cel's own image is copied before it is converted, so the artwork is
		# never modified by a preview.
		var part := source.duplicate() as Image
		if part == null:
			continue
		if part.is_compressed():
			part.decompress()
		if part.get_format() != Image.FORMAT_RGBA8:
			part.convert(Image.FORMAT_RGBA8)
		output.blend_rect(part, Rect2i(Vector2i.ZERO, part.get_size()), cel.offset)
	return output
