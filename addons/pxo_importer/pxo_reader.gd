@tool
class_name PxoReader
extends RefCounted
## Reads a Pixelorama `.pxo` project without Pixelorama.
##
## A `.pxo` is a ZIP. The interesting parts are:
## [codeblock]
## data.json                          the whole project as JSON
## image_data/frames/<f>/layer_<c>    raw pixels of frame f, layer c (1-based)
## image_data/final_images/<f>        the frame already flattened (optional)
## preview.png                        256px thumbnail of the current frame
## mimetype                           "application/x-pixelorama"
## tilesets/<i>/<j>                   one image per tile (tilemap layers)
## [/codeblock]
## Frame and layer numbers in the file names are 1-based, while everything this
## class returns is 0-based, so the conversion happens in one place: here.

## Pixelorama's layer type values, from [code]Global.LayerTypes[/code].
const LAYER_PIXEL := 0
const LAYER_GROUP := 1

## Above this many pixels the per-pixel opacity pass is skipped: a project that
## big is not what a sprite importer is for, and the import should not crawl.
const OPACITY_PIXEL_LIMIT := 262144


## Reads [param path] into a [PxoProject]. Returns null when the file is not a
## readable Pixelorama project, and prints why.
##
## [param options] is the dictionary the import plugin was given; the keys it
## understands are [code]import_composite_only[/code] and [code]layer_filter[/code].
static func read(path: String, options: Dictionary = {}) -> PxoProject:
	var zip := ZIPReader.new()
	var err := zip.open(path)
	if err != OK:
		push_error("PXO: 无法打开 %s（错误 %d）——它可能不是 ZIP 格式的 .pxo" % [path, err])
		return null
	if not zip.file_exists("data.json"):
		push_error("PXO: %s 里没有 data.json，不是 Pixelorama 项目" % path)
		zip.close()
		return null
	var project := _build(zip, path, options)
	zip.close()
	return project


static func _build(zip: ZIPReader, path: String, options: Dictionary) -> PxoProject:
	var raw := zip.read_file("data.json")
	if raw.is_empty():
		push_error("PXO: %s 的 data.json 是空的" % path)
		return null
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not parsed is Dictionary:
		push_error("PXO: %s 的 data.json 不是有效的 JSON 对象" % path)
		return null
	var dict: Dictionary = parsed

	var project := PxoProject.new()
	project.source_path = path
	project.canvas_size = Vector2i(int(dict.get("size_x", 0)), int(dict.get("size_y", 0)))
	if project.canvas_size.x <= 0 or project.canvas_size.y <= 0:
		push_error("PXO: %s 没有有效的画布尺寸" % path)
		return null
	project.fps = max(0.001, float(dict.get("fps", 12.0)))

	var format := _image_format(dict)
	var layer_defs: Array = dict.get("layers", [])
	var names := PackedStringArray()
	for layer_def: Dictionary in layer_defs:
		names.append(str(layer_def.get("name", "")))
	project.layer_names = names

	var wanted := _wanted_layers(options)

	var frame_defs: Array = dict.get("frames", [])
	var frame_index := 1
	for frame_def: Dictionary in frame_defs:
		var frame := PxoFrame.new()
		frame.duration = float(frame_def.get("duration", 1.0))
		var cel_defs: Array = frame_def.get("cels", [])
		var images: Array[Image] = []
		var cel_index := 1
		for cel_def: Dictionary in cel_defs:
			var layer_index := cel_index - 1
			var layer_def: Dictionary = {}
			if layer_index < layer_defs.size():
				layer_def = layer_defs[layer_index]
			var image := _cel_image(zip, project.canvas_size, format, frame_index, cel_index, cel_def, layer_def, wanted)
			images.append(image)
			cel_index += 1

		for image: Image in images:
			if image == null:
				frame.layer_images.append(null)
			else:
				frame.layer_images.append(ImageTexture.create_from_image(image))
		frame.composite = _composite_texture(zip, project.canvas_size, format, frame_index, images, layer_defs)
		project.frames.append(frame)
		frame_index += 1

	var tag_defs: Array = dict.get("tags", [])
	for tag_def: Dictionary in tag_defs:
		project.tags.append(
			{
				"name": str(tag_def.get("name", "")),
				"from": int(tag_def.get("from", 0)),
				"to": int(tag_def.get("to", 0)),
				"color": str(tag_def.get("color", "#ffffff")),
			}
		)

	project.sprite_frames = project.build_sprite_frames()
	return project


## The Image format the pixels are stored in. Pixelorama records the Godot enum
## itself in [code]color_mode[/code]; negative values are the old indexed mode,
## whose pixels are written as RGBA8.
static func _image_format(dict: Dictionary) -> int:
	var format := int(dict.get("color_mode", Image.FORMAT_RGBA8))
	if format < 0 or format >= Image.FORMAT_MAX:
		return Image.FORMAT_RGBA8
	return format


## Layer names to keep, or an empty array for "all of them".
static func _wanted_layers(options: Dictionary) -> PackedStringArray:
	var filter := str(options.get("layer_filter", "")).strip_edges()
	if filter.is_empty():
		return PackedStringArray()
	var wanted := PackedStringArray()
	for part in filter.split(",", false):
		var trimmed := part.strip_edges()
		if not trimmed.is_empty():
			wanted.append(trimmed)
	return wanted


## One cel's pixels, or null when it has none (a group, a tilemap, an audio
## layer, or a layer the filter threw away).
static func _cel_image(
	zip: ZIPReader,
	canvas_size: Vector2i,
	format: int,
	frame_index: int,
	cel_index: int,
	cel_def: Dictionary,
	layer_def: Dictionary,
	wanted: PackedStringArray
) -> Image:
	var layer_type := int(layer_def.get("type", LAYER_PIXEL))
	if layer_type != LAYER_PIXEL:
		return null
	if not wanted.is_empty() and not wanted.has(str(layer_def.get("name", ""))):
		return null
	var size := canvas_size
	if cel_def.has("image_size"):
		# Pixelorama writes this as a var_to_str() string, e.g. "Vector2i(32, 32)".
		var parsed: Variant = str_to_var(str(cel_def["image_size"]))
		if parsed is Vector2i and parsed.x > 0 and parsed.y > 0:
			size = parsed
	var entry := "image_data/frames/%d/layer_%d" % [frame_index, cel_index]
	if not zip.file_exists(entry):
		return null
	var data := zip.read_file(entry)
	var expected := size.x * size.y * _bytes_per_pixel(format)
	if data.size() < expected:
		push_warning(
			"PXO: %s 只有 %d 字节，期望 %d，这一格被跳过" % [entry, data.size(), expected]
		)
		return null
	var image := Image.create_from_data(size.x, size.y, false, format, data)
	if image == null or image.is_empty():
		return null
	image.convert(Image.FORMAT_RGBA8)
	return image


## The frame as it should look, flattened.
##
## A `.pxo` may already carry the flattened frame, in which case that is used
## verbatim: it is what Pixelorama itself drew, blend modes and all. Otherwise
## the visible pixel layers are stacked here, which covers normal layers but not
## the exotic blend modes — those need Pixelorama's own compositor.
static func _composite_texture(
	zip: ZIPReader,
	canvas_size: Vector2i,
	format: int,
	frame_index: int,
	images: Array[Image],
	layer_defs: Array
) -> Texture2D:
	var baked := "image_data/final_images/%d" % frame_index
	if zip.file_exists(baked):
		var data := zip.read_file(baked)
		var expected := canvas_size.x * canvas_size.y * _bytes_per_pixel(format)
		if data.size() >= expected:
			var image := Image.create_from_data(
				canvas_size.x, canvas_size.y, false, format, data
			)
			if image != null and not image.is_empty():
				image.convert(Image.FORMAT_RGBA8)
				return ImageTexture.create_from_image(image)

	var composite := Image.create(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8)
	composite.fill(Color(0, 0, 0, 0))
	for layer_index in images.size():
		var image := images[layer_index]
		if image == null:
			continue
		var layer_def: Dictionary = {}
		if layer_index < layer_defs.size():
			layer_def = layer_defs[layer_index]
		if not bool(layer_def.get("visible", true)):
			continue
		var opacity := float(layer_def.get("opacity", 1.0))
		composite.blend_rect(
			_fade(image, opacity), Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO
		)
	return ImageTexture.create_from_image(composite)


## Applies a layer's opacity to a copy, or hands the image back untouched when
## there is nothing to apply.
static func _fade(image: Image, opacity: float) -> Image:
	if is_equal_approx(opacity, 1.0):
		return image
	if image.get_width() * image.get_height() > OPACITY_PIXEL_LIMIT:
		return image
	# duplicate() is typed as Resource, so the copy is spelled out: the pixel
	# calls below need an Image.
	var out: Image = image.duplicate()
	out.convert(Image.FORMAT_RGBA8)
	for y in out.get_height():
		for x in out.get_width():
			var color: Color = out.get_pixel(x, y)
			if color.a <= 0.0:
				continue
			color.a *= opacity
			out.set_pixel(x, y, color)
	return out


static func _bytes_per_pixel(format: int) -> int:
	match format:
		Image.FORMAT_R8, Image.FORMAT_L8:
			return 1
		Image.FORMAT_LA8, Image.FORMAT_RG8:
			return 2
		Image.FORMAT_RGB8:
			return 3
		_:
			return 4
