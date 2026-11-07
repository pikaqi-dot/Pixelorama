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
const LAYER_TILEMAP := 3

## Above this many pixels the per-pixel opacity pass is skipped: a project that
## big is not what a sprite importer is for, and the import should not crawl.
const OPACITY_PIXEL_LIMIT := 262144
## What this reader puts into the resource. An imported resource from an older
## number is missing whatever was added since, so the panel can say "re-import"
## instead of quietly showing nothing.
const READER_VERSION := 3


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
	project.reader_version = READER_VERSION
	project.canvas_size = Vector2i(int(dict.get("size_x", 0)), int(dict.get("size_y", 0)))
	if project.canvas_size.x <= 0 or project.canvas_size.y <= 0:
		push_error("PXO: %s 没有有效的画布尺寸" % path)
		return null
	project.fps = max(0.001, float(dict.get("fps", 12.0)))

	var format := _image_format(dict)
	project.color_mode = format
	var layer_defs: Array = dict.get("layers", [])
	var names := PackedStringArray()
	var shader_names := PackedStringArray()
	for layer_def: Dictionary in layer_defs:
		names.append(str(layer_def.get("name", "")))
		if _is_shader_layer(layer_def):
			shader_names.append(str(layer_def.get("name", "")))
	project.layer_names = names
	project.shader_layer_names = shader_names

	# The tilesets: name, tile size, terrain colours and the autotile bits. Only
	# the metadata is kept here — the tile images stay in the `.pxo` and are read
	# by PxoTileset when somebody actually asks for a TileSet.
	var tileset_defs: Array = dict.get("tilesets", [])
	for tileset_def: Dictionary in tileset_defs:
		project.tilesets.append(_tileset_meta(tileset_def))

	# Which layers draw with tiles, and from which tileset.
	for layer_index in layer_defs.size():
		var layer_def: Dictionary = layer_defs[layer_index]
		if int(layer_def.get("type", LAYER_PIXEL)) != LAYER_TILEMAP:
			continue
		project.tile_layers.append(
			{
				"layer": layer_index,
				"tileset": int(layer_def.get("tileset_index", 0)),
				"tile_size": str(layer_def.get("tile_size", "")),
				"name": str(layer_def.get("name", "")),
			}
		)

	var wanted := _wanted_layers(options)
	# A shader layer's cel is a static bake of a graph that Pixelorama evaluates
	# live, so stacking it puts a frozen, often wrong picture over everything else.
	# It is left out of the composite unless the import options ask for it.
	var keep_shader := bool(options.get("import_shader_layers", false))
	if not shader_names.is_empty():
		push_warning(_shader_warning(shader_names, keep_shader))

	var frame_defs: Array = dict.get("frames", [])
	var frame_index := 1
	for frame_def: Dictionary in frame_defs:
		var frame := PxoFrame.new()
		frame.duration = float(frame_def.get("duration", 1.0))
		var cel_defs: Array = frame_def.get("cels", [])
		var images: Array[Image] = []
		# Where each cel sits on the canvas and how opaque it is on its own, in
		# the same order as `images`: Pixelorama keeps both on the cel, not the
		# layer, so a moved or half-faded cel would otherwise be pasted wrong.
		var offsets: Array[Vector2i] = []
		var cel_opacities: Array[float] = []
		var cel_index := 1
		for cel_def: Dictionary in cel_defs:
			var layer_index := cel_index - 1
			var layer_def: Dictionary = {}
			if layer_index < layer_defs.size():
				layer_def = layer_defs[layer_index]
			var image := _cel_image(zip, project.canvas_size, format, frame_index, cel_index, cel_def, layer_def, wanted)
			images.append(image)
			offsets.append(_cel_offset(cel_def))
			cel_opacities.append(clampf(float(cel_def.get("opacity", 1.0)), 0.0, 1.0))
			cel_index += 1

		for image: Image in images:
			if image == null:
				frame.layer_images.append(null)
			else:
				frame.layer_images.append(ImageTexture.create_from_image(image))
		# The tile placement of every layer, in the same order: a cell map for a
		# tilemap layer, an empty dictionary for everything else.
		for cell_cel in cel_defs.size():
			var tile_cel_def: Dictionary = cel_defs[cell_cel]
			var tile_layer_def: Dictionary = {}
			if cell_cel < layer_defs.size():
				tile_layer_def = layer_defs[cell_cel]
			frame.tile_cells.append(_cel_cells(tile_cel_def, tile_layer_def))
		frame.composite = _composite_texture(
			zip, project.canvas_size, format, frame_index, images, layer_defs,
			offsets, cel_opacities, not keep_shader
		)
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


## One tileset's metadata, as the panel and [PxoTileset] need it. The images are
## deliberately not read here: a project can carry a big tileset, and a re-import
## should not pay for tiles nobody asked to see.
static func _tileset_meta(tileset_def: Dictionary) -> Dictionary:
	var colors: Array = []
	var terrain_names: Array = []
	var terrain_data: Array = tileset_def.get("terrain_data", [])
	for terrain_def: Dictionary in terrain_data:
		colors.append(str(terrain_def.get("color", "Color(1, 1, 1, 1)")))
		terrain_names.append(str(terrain_def.get("name", "")))
	var bits := {}
	var tile_data: Variant = tileset_def.get("tile_data", {})
	if tile_data is Dictionary:
		var per_tile: Dictionary = tile_data
		for key: String in per_tile:
			var info: Variant = per_tile[key]
			if not info is Dictionary:
				continue
			var tile: Dictionary = info
			bits[key] = {
				"center": int(tile.get("terrain_center_bit", -1)),
				"peering": _int_array(tile.get("terrain_peering_bits", [])),
			}
	return {
		"name": str(tileset_def.get("name", "")),
		"tile_size": str(tileset_def.get("tile_size", "Vector2i(16, 16)")),
		"tile_shape": int(tileset_def.get("tile_shape", 0)),
		"tile_amount": int(tileset_def.get("tile_amount", 0)),
		"terrain_colors": colors,
		"terrain_names": terrain_names,
		"tile_bits": bits,
	}


## Where the tiles of one layer sit: a cell position to [code]{index, flip_h,
## flip_v, transpose}[/code]. Empty for anything that is not a tilemap layer.
static func _cel_cells(cel_def: Dictionary, layer_def: Dictionary) -> Dictionary:
	var out := {}
	if int(layer_def.get("type", LAYER_PIXEL)) != LAYER_TILEMAP:
		return out
	var data: Variant = cel_def.get("cell_data", {})
	if not data is Dictionary:
		return out
	var cells: Dictionary = data
	for key: String in cells:
		# Pixelorama writes the position as the string key "(x, y)".
		if not key.begins_with("("):
			continue
		var info: Variant = cells[key]
		if not info is Dictionary:
			continue
		var tile: Dictionary = info
		out[_cell_from(key)] = {
			"index": int(tile.get("index", -1)),
			"flip_h": bool(tile.get("flip_h", false)),
			"flip_v": bool(tile.get("flip_v", false)),
			"transpose": bool(tile.get("transpose", false)),
		}
	return out


## "(0, 3)" and "(-1, 2)" both come back as a cell position.
static func _cell_from(key: String) -> Vector2i:
	var parts := key.trim_prefix("(").trim_suffix(")").split(",")
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))


static func _int_array(value: Variant) -> Array:
	var out: Array = []
	if not value is Array:
		return out
	for item: Variant in value:
		out.append(int(item))
	return out


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
	# A tilemap layer has a rendered image too, and it is the only picture of that
	# layer a .pxo carries: skipping it left the tiles out of every composite.
	if layer_type != LAYER_PIXEL and layer_type != LAYER_TILEMAP:
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


## A layer drawn by a shader graph — the Shader Composer's layers. The graph lives
## in the layer's own metadata and cannot be run from here; its cel only holds a
## static bake of it.
static func _is_shader_layer(layer_def: Dictionary) -> bool:
	var meta: Variant = layer_def.get("metadata", {})
	return meta is Dictionary and (meta as Dictionary).has("shader_graph")


## What to tell the person importing, once, about the shader layers in this file.
static func _shader_warning(names: PackedStringArray, keep: bool) -> String:
	var list := ", ".join(names)
	if keep:
		return (
			"PXO: 按选项把 %d 个着色器图层（%s）也合成了；它们的像素是静态烘焙，"
			% [names.size(), list]
			+ "Pixelorama 里是实时算的，画面可能对不上"
		)
	return (
		"PXO: %d 个着色器图层（%s）没有参与合成：它们的像素只是静态烘焙，"
		% [names.size(), list]
		+ "Pixelorama 里是实时算出来的。想让帧和编辑器完全一致，"
		+ "在 Pixelorama 保存时勾上「包含合成图」再重新保存。"
	)


## Where a cel's picture sits on the canvas. Pixelorama stores it on the cel as
## "(12, -4)"; a layer that was resized or moved has a picture smaller than the
## canvas, and blitting it at (0, 0) would slide the whole layer into the corner.
static func _cel_offset(cel_def: Dictionary) -> Vector2i:
	var parsed: Variant = str_to_var(str(cel_def.get("offset", "(0, 0)")))
	if parsed is Vector2i:
		return parsed
	if parsed is Vector2:
		return Vector2i(parsed)
	var text := str(cel_def.get("offset", "")).strip_edges()
	var parts := text.trim_prefix("(").trim_suffix(")").split(",")
	if parts.size() == 2:
		return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))
	return Vector2i.ZERO


## Blends one cel into the canvas, cutting off whatever hangs outside it: a cel can
## be smaller than the canvas, moved partly off it, or both.
static func _blend_clipped(canvas: Image, image: Image, offset: Vector2i) -> void:
	var target := Rect2i(offset, image.get_size()).intersection(
		Rect2i(Vector2i.ZERO, canvas.get_size())
	)
	if target.size.x <= 0 or target.size.y <= 0:
		return
	canvas.blend_rect(image, Rect2i(target.position - offset, target.size), target.position)


## The frame as it should look, flattened.
##
## A `.pxo` may already carry the flattened frame, in which case that is used
## verbatim: it is what Pixelorama itself drew, blend modes and all. Otherwise
## the visible pixel layers are stacked here, at the position Pixelorama gives each
## cel, which covers normal layers but not the exotic blend modes — those need
## Pixelorama's own compositor.
static func _composite_texture(
	zip: ZIPReader,
	canvas_size: Vector2i,
	format: int,
	frame_index: int,
	images: Array[Image],
	layer_defs: Array,
	offsets: Array[Vector2i],
	cel_opacities: Array[float],
	skip_shader: bool
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
		if skip_shader and _is_shader_layer(layer_def):
			continue
		var offset := Vector2i.ZERO
		if layer_index < offsets.size():
			offset = offsets[layer_index]
		var opacity := float(layer_def.get("opacity", 1.0))
		if layer_index < cel_opacities.size():
			opacity *= cel_opacities[layer_index]
		_blend_clipped(composite, _fade(image, clampf(opacity, 0.0, 1.0)), offset)
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
