@tool
class_name PxoTileset
extends RefCounted
## One tileset of a Pixelorama project, read out of the `.pxo` it came from.
##
## Pixelorama keeps a tileset as a list of separate tile images
## ([code]tilesets/<tileset>/<tile>[/code] inside the ZIP) plus a per-tile terrain
## entry in `data.json`. Godot's [TileSet] wants a single atlas image instead, so
## the tiles are laid out into a grid and every tile index becomes one atlas
## coordinate: [method atlas_coords] is the whole mapping, and [method columns] is
## the grid width it needs.
##
## [codeblock]
## # Build a TileSet from the .pxo without going through the editor:
## var project: PxoProject = load("res://art/level.pxo")
## $TileMapLayer.tile_set = PxoTileset.build_tile_set(project)
##
## # Or the whole map, already filled in, in one call:
## add_child(PxoTileset.build_tile_map(project, 0))
## [/codeblock]

## Pixelorama's tile shapes, from [code]TileSetCustom.tile_shape[/code]. Only the
## square one maps onto atlas coordinates; the hexagonal and isometric ones store a
## different neighbour order and are reported instead of guessed at.
const SHAPE_SQUARE := 0
## A square tile has eight neighbours, which is how many of Pixelorama's sixteen
## peering bits are valid for it. The other eight are the isometric corners.
const SQUARE_NEIGHBOURS := 8
## A cell with no tile: Pixelorama leaves it out of `cell_data` entirely, so this
## is only used as the "nothing here" answer.
const NO_TILE := -1

## Index of this tileset in the project's `tilesets` array.
var index := 0
## The name Pixelorama shows for it.
var name := ""
## Size of one tile, in pixels.
var tile_size := Vector2i(16, 16)
## Pixelorama's tile shape enum; see [constant SHAPE_SQUARE].
var tile_shape := SHAPE_SQUARE
## One colour per terrain, in Pixelorama's terrain order.
var terrain_colors: Array[Color] = []
## One name per terrain, in the same order.
var terrain_names: PackedStringArray = PackedStringArray()
## Tile index -> [code]{probability, center, peering}[/code], where [code]center[/code]
## is the terrain in the middle of the tile (-1 for none) and [code]peering[/code] is
## the 16 neighbour bits.
var tile_bits: Dictionary = {}
## One image per tile, aligned with Pixelorama's tile index. Entries are null where
## the `.pxo` has no image for that index.
var tiles: Array[Image] = []


## Reads one tileset out of [param project]'s `.pxo`. Returns null when the index
## is out of range or the file cannot be opened.
static func load_from(project: PxoProject, tileset_index: int) -> PxoTileset:
	if project == null or tileset_index < 0 or tileset_index >= project.tilesets.size():
		return null
	var meta: Dictionary = project.tilesets[tileset_index]
	var zip := ZIPReader.new()
	if zip.open(project.source_path) != OK:
		push_error("PXO: 打不开 %s 来读图块" % project.source_path)
		return null
	var tileset := PxoTileset.new()
	tileset.index = tileset_index
	tileset.name = str(meta.get("name", ""))
	tileset.tile_size = _vector_from(meta.get("tile_size"), Vector2i(16, 16))
	tileset.tile_shape = int(meta.get("tile_shape", SHAPE_SQUARE))
	tileset.tile_bits = _bits_from(meta.get("tile_bits", {}))
	tileset.terrain_colors = _colors_from(meta.get("terrain_colors", []))
	tileset.terrain_names = _names_from(meta.get("terrain_names", []))
	var format := _format_of(project)
	var count := int(meta.get("tile_amount", 0))
	for tile_index in count:
		var entry := "tilesets/%d/%d" % [tileset_index, tile_index]
		tileset.tiles.append(_tile_image(zip, entry, tileset.tile_size, format))
	zip.close()
	return tileset


## Every tileset of the project as one Godot [TileSet], with the terrain bits
## carried over for square tilesets. This is what a [TileMapLayer] wants.
static func build_tile_set(project: PxoProject) -> TileSet:
	if project == null or project.tilesets.is_empty():
		return null
	var tile_set := TileSet.new()
	for tileset_index in project.tilesets.size():
		var tileset := load_from(project, tileset_index)
		if tileset == null:
			continue
		tileset.add_to(tile_set, tileset_index)
	if tile_set.get_source_count() == 0:
		return null
	return tile_set


## The tilemap layers of one frame as a [Node2D] with a [TileMapLayer] each, with
## every cell already placed — the pixel work Pixelorama did, expressed as Godot
## tiles. Returns null when the frame has no tilemap layer.
static func build_tile_map(project: PxoProject, frame_index := 0) -> Node2D:
	if project == null or project.tile_layers.is_empty():
		return null
	var frame := project.get_frame(frame_index)
	if frame == null:
		return null
	var tile_set := build_tile_set(project)
	if tile_set == null:
		return null
	var loaded: Dictionary = {}
	var root := Node2D.new()
	root.name = "TileMap"
	var placed := 0
	for entry: Dictionary in project.tile_layers:
		var layer_index := int(entry.get("layer", -1))
		var tileset_index := int(entry.get("tileset", 0))
		var cells := frame.get_tile_cells(layer_index)
		if cells.is_empty():
			continue
		var source := _tileset_for(project, tileset_index, loaded)
		if source == null:
			continue
		var layer := TileMapLayer.new()
		layer.name = _node_name(str(entry.get("name", "Tilemap %d" % layer_index)))
		layer.tile_set = tile_set
		layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		root.add_child(layer)
		# PackedScene.pack() only takes the nodes owned by the root, and a node
		# added with add_child() is owned by nobody.
		layer.owner = root
		for cell: Vector2i in cells:
			var info: Dictionary = cells[cell]
			var tile_index := int(info.get("index", NO_TILE))
			if tile_index == NO_TILE:
				continue
			layer.set_cell(
				cell, tileset_index, source.atlas_coords(tile_index), _alternative(info)
			)
			placed += 1
	if placed == 0:
		root.free()
		return null
	return root


## How many tiles wide the atlas grid is. Square-ish keeps a large tileset from
## becoming one very long strip, which is what the editor's tile picker dislikes.
func columns() -> int:
	var count := tiles.size()
	if count <= 0:
		return 1
	return maxi(1, int(ceil(sqrt(float(count)))))


## Where a Pixelorama tile index lands in the atlas.
func atlas_coords(tile_index: int) -> Vector2i:
	var width := columns()
	return Vector2i(tile_index % width, tile_index / width)


## Every tile blitted into one image, transparent where a tile is missing.
func build_atlas_image() -> Image:
	if tiles.is_empty() or tile_size.x <= 0 or tile_size.y <= 0:
		return null
	var width := columns()
	var rows := int(ceil(float(tiles.size()) / float(width)))
	var atlas := Image.create(
		width * tile_size.x, rows * tile_size.y, false, Image.FORMAT_RGBA8
	)
	atlas.fill(Color(0, 0, 0, 0))
	for tile_index in tiles.size():
		var tile: Image = tiles[tile_index]
		if tile == null or tile.is_empty():
			continue
		var target := atlas_coords(tile_index) * tile_size
		atlas.blit_rect(tile, Rect2i(Vector2i.ZERO, tile_size), target)
	return atlas


## Adds this tileset to [param tile_set] as an atlas source under
## [param source_id], and carries the terrain bits over when the shape allows it.
func add_to(tile_set: TileSet, source_id: int) -> void:
	var atlas := build_atlas_image()
	if atlas == null:
		return
	# The TileSet's own tile size is what positions every atlas source, so the
	# first tileset sets it and the rest are reported when they disagree.
	if tile_set.tile_size == Vector2i(16, 16) or tile_set.get_source_count() == 0:
		tile_set.tile_size = tile_size
	elif tile_set.tile_size != tile_size:
		push_warning(
			"PXO: 图块集 %s 的 %s 和第一个图块集的 %s 不同，用第一个"
			% [name, str(tile_size), str(tile_set.tile_size)]
		)
	var source := TileSetAtlasSource.new()
	source.texture = ImageTexture.create_from_image(atlas)
	source.texture_region_size = tile_size
	var width := columns()
	for tile_index in tiles.size():
		var tile: Image = tiles[tile_index]
		if tile == null or tile.is_empty():
			continue
		var coords := atlas_coords(tile_index)
		if source.has_tile(coords):
			continue
		source.create_tile(coords)
	# Terrain first on the TileSet, then the per-tile data through the source: a
	# terrain set has to exist before a tile can point at one.
	var terrain_set := _add_terrains(tile_set)
	tile_set.add_source(source, source_id)
	if terrain_set < 0:
		return
	_apply_bits(source, terrain_set, width)


## The terrain set this tileset was given in [method add_to], or -1. Kept out of
## [TileSet]'s own bookkeeping because a project can hold several tilesets, each
## with its own terrain list.
func _add_terrains(tile_set: TileSet) -> int:
	if terrain_colors.is_empty() or tile_shape != SHAPE_SQUARE:
		return -1
	var terrain_set := tile_set.get_terrain_sets_count()
	tile_set.add_terrain_set()
	# Pixelorama's autotiling is a 3×3 blob, i.e. sides plus corners.
	tile_set.set_terrain_set_mode(
		terrain_set, TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES
	)
	for terrain_index in terrain_colors.size():
		tile_set.add_terrain(terrain_set)
		tile_set.set_terrain_color(terrain_set, terrain_index, terrain_colors[terrain_index])
		if terrain_index < terrain_names.size() and not terrain_names[terrain_index].is_empty():
			tile_set.set_terrain_name(
				terrain_set, terrain_index, terrain_names[terrain_index]
			)
	return terrain_set


## Copies the centre and neighbour terrain bits of every tile.
func _apply_bits(source: TileSetAtlasSource, terrain_set: int, width: int) -> void:
	for tile_index in tile_bits:
		var bit_entry: Dictionary = tile_bits[tile_index]
		var coords := Vector2i(int(tile_index) % width, int(tile_index) / width)
		if not source.has_tile(coords):
			continue
		var data := source.get_tile_data(coords, 0)
		if data == null:
			continue
		data.terrain_set = terrain_set
		var center := int(bit_entry.get("center", -1))
		if center >= 0:
			data.terrain = center
		var peering: Array = bit_entry.get("peering", [])
		for neighbour in mini(peering.size(), SQUARE_NEIGHBOURS):
			var terrain := int(peering[neighbour])
			if terrain >= 0:
				data.set_terrain_peering_bit(neighbour, terrain)


## The transform bits [method TileMapLayer.set_cell] wants for one cell.
static func _alternative(info: Dictionary) -> int:
	var bits := 0
	if bool(info.get("flip_h", false)):
		bits |= TileSetAtlasSource.TRANSFORM_FLIP_H
	if bool(info.get("flip_v", false)):
		bits |= TileSetAtlasSource.TRANSFORM_FLIP_V
	if bool(info.get("transpose", false)):
		bits |= TileSetAtlasSource.TRANSFORM_TRANSPOSE
	return bits


static func _tileset_for(
	project: PxoProject, tileset_index: int, cache: Dictionary
) -> PxoTileset:
	if cache.has(tileset_index):
		return cache[tileset_index]
	var loaded := load_from(project, tileset_index)
	cache[tileset_index] = loaded
	return loaded


## One tile image out of the ZIP, as RGBA8. Null when the entry is missing or too
## short to hold a tile.
static func _tile_image(
	zip: ZIPReader, entry: String, size: Vector2i, format: int
) -> Image:
	if not zip.file_exists(entry):
		return null
	var data := zip.read_file(entry)
	if data.is_empty():
		return null
	var usable := _format_for(data.size(), size, format)
	if usable < 0:
		return null
	var image := Image.create_from_data(size.x, size.y, false, usable, data)
	if image == null or image.is_empty():
		return null
	image.convert(Image.FORMAT_RGBA8)
	return image


## The format the bytes are actually in: the project's own when the length fits,
## otherwise the one the byte count implies. A `.pxo` saved with a different colour
## mode than its `data.json` claims would otherwise produce noise instead of tiles.
static func _format_for(byte_count: int, size: Vector2i, format: int) -> int:
	var pixels := size.x * size.y
	if pixels <= 0:
		return -1
	if byte_count >= pixels * _bytes_per_pixel(format):
		return format
	var per_pixel := byte_count / pixels
	match per_pixel:
		1:
			return Image.FORMAT_L8
		2:
			return Image.FORMAT_LA8
		3:
			return Image.FORMAT_RGB8
		4:
			return Image.FORMAT_RGBA8
		_:
			return -1


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


## The project's pixel format, kept on [PxoProject] so the tile images are read the
## same way the cels were.
static func _format_of(project: PxoProject) -> int:
	var format := project.color_mode
	if format < 0 or format >= Image.FORMAT_MAX:
		return Image.FORMAT_RGBA8
	return format


## "Vector2i(16, 16)", "(16, 16)" and a real Vector2i all come back as one. The
## middle form is what Pixelorama's JSON actually holds: str() of a Vector2i.
static func _vector_from(value: Variant, fallback: Vector2i) -> Vector2i:
	if value is Vector2i:
		return value
	var text := str(value).strip_edges()
	var parsed: Variant = str_to_var(text)
	if parsed is Vector2i:
		return parsed
	if parsed is Vector2:
		return Vector2i(parsed)
	var parts := text.trim_prefix("(").trim_suffix(")").split(",")
	if parts.size() == 2:
		var width := int(parts[0].strip_edges())
		var height := int(parts[1].strip_edges())
		if width > 0 and height > 0:
			return Vector2i(width, height)
	return fallback


## The per-tile bits, keyed by int, with the terrain values as ints.
static func _bits_from(value: Variant) -> Dictionary:
	var out := {}
	if not value is Dictionary:
		return out
	var source: Dictionary = value
	for key: String in source:
		var entry: Variant = source[key]
		if not entry is Dictionary:
			continue
		var bits: Dictionary = entry
		var peering: Array = []
		var raw: Variant = bits.get("peering", [])
		if raw is Array:
			for item: Variant in raw:
				peering.append(int(item))
		out[int(key)] = {
			"center": int(bits.get("center", -1)),
			"peering": peering,
		}
	return out


## Pixelorama stores colours as var_to_str() text, e.g. "Color(0.5, 0.3, 0.2, 1)".
static func _colors_from(value: Variant) -> Array[Color]:
	var out: Array[Color] = []
	if not value is Array:
		return out
	for item: Variant in value:
		var parsed: Variant = item if item is Color else str_to_var(str(item))
		if parsed is Color:
			out.append(parsed)
		else:
			out.append(Color.WHITE)
	return out


static func _names_from(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if not value is Array:
		return out
	for item: Variant in value:
		out.append(str(item))
	return out


## A layer name that is a valid node name: Pixelorama allows spaces and slashes,
## Godot's node names do not.
static func _node_name(raw: String) -> String:
	var text := raw.strip_edges().replace("/", "-").replace(":", "-")
	return text if not text.is_empty() else "Tilemap"
