@tool
extends RefCounted
## Writes an imported project out as the plain files Godot's own tools expect.
##
## A [PxoProject] is convenient to read but it is an imported resource: Godot
## treats it as read-only, so the animation editor and the tile tools have
## nothing to open. These helpers produce normal, editable files next to the
## `.pxo`:
##
## - a `SpriteFrames` `.tres`, which the SpriteFrames panel opens and an
##   [AnimatedSprite2D] uses directly;
## - a sprite sheet `.png` of every frame in a grid, which [Sprite2D] slices with
##   `hframes`/`vframes`, a [TileSet] uses as an atlas, or any other tool reads
##   as one image;
## - a `TileSet` `.tres` built from the project's own tilesets, tile picker and
##   autotiling included;
## - a `.tscn` holding one [TileMapLayer] per tilemap layer of a frame, cells
##   already placed, so the map Pixelorama drew is a Godot scene.
##
## None of them depends on the `.pxo` afterwards, so editing them does not get
## overwritten by a re-import. Re-exporting does overwrite them, which is the
## point: they are the derived artefacts.

const SUFFIX_FRAMES := "_spriteframes.tres"
const SUFFIX_SHEET := "_sheet.png"
const SUFFIX_TILESET := "_tileset.tres"
const SUFFIX_TILEMAP := "_tilemap.tscn"


## `res://art/player.pxo` for any spelling of the source path.
static func local_path(source: String) -> String:
	return ProjectSettings.localize_path(source).get_basename()


static func default_sprite_frames_path(source: String) -> String:
	return local_path(source) + SUFFIX_FRAMES


static func default_sheet_path(source: String) -> String:
	return local_path(source) + SUFFIX_SHEET


static func default_tile_set_path(source: String) -> String:
	return local_path(source) + SUFFIX_TILESET


static func default_tile_map_path(source: String) -> String:
	return local_path(source) + SUFFIX_TILEMAP


## Saves a [SpriteFrames] holding every frame's flattened image, at the speed the
## project was authored at. The images are embedded, so the file stands alone.
static func export_sprite_frames(project: PxoProject, path: String) -> Error:
	if project == null:
		return ERR_INVALID_PARAMETER
	if project.frames.is_empty():
		return ERR_INVALID_DATA
	var frames := project.build_sprite_frames()
	if frames.get_frame_count("default") == 0:
		return ERR_INVALID_DATA
	return ResourceSaver.save(frames, path)


## Writes every frame into one grid image. Without [param columns] the frames are
## laid out in a single row, which is what `hframes = frame_count, vframes = 1`
## expects on a [Sprite2D].
static func export_sheet(project: PxoProject, path: String, columns := 0) -> Error:
	var sheet := build_sheet(project, columns)
	if sheet == null:
		return ERR_INVALID_DATA
	return sheet.save_png(ProjectSettings.globalize_path(path))


## Saves the project's tilesets as a [TileSet] the TileSet editor can open, with
## the tiles already cut out and the autotile terrains filled in.
static func export_tile_set(project: PxoProject, path: String) -> Error:
	if project == null or project.tilesets.is_empty():
		return ERR_INVALID_DATA
	var tile_set := PxoTileset.build_tile_set(project)
	if tile_set == null or tile_set.get_source_count() == 0:
		return ERR_INVALID_DATA
	return ResourceSaver.save(tile_set, path)


## Saves one frame's tilemap layers as a `.tscn`: a [Node2D] with a
## [TileMapLayer] per tilemap layer, every cell placed, and the [TileSet] embedded
## so the scene is one file to drop into a game.
static func export_tile_map(project: PxoProject, frame_index: int, path: String) -> Error:
	var root := PxoTileset.build_tile_map(project, frame_index)
	if root == null:
		return ERR_INVALID_DATA
	# pack() files every child under [param root], so nothing has to be owned by
	# hand — the root does it on the way out.
	var scene := PackedScene.new()
	var err := scene.pack(root)
	root.free()
	if err != OK:
		return err
	return ResourceSaver.save(scene, path)


## The grid image itself, for callers that want to keep it in memory.
static func build_sheet(project: PxoProject, columns := 0) -> Image:
	if project == null or project.frames.is_empty():
		return null
	var cell := project.canvas_size
	if cell.x <= 0 or cell.y <= 0:
		return null
	var count := project.frames.size()
	if columns <= 0:
		columns = count
	var rows := int(ceil(float(count) / float(columns)))
	var sheet := Image.create(cell.x * columns, cell.y * rows, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	for index in count:
		var texture := project.get_composite(index)
		if texture == null:
			continue
		var frame_image := texture.get_image()
		if frame_image == null or frame_image.is_empty():
			continue
		frame_image.convert(Image.FORMAT_RGBA8)
		var target := Vector2i((index % columns) * cell.x, (index / columns) * cell.y)
		# A frame smaller than the canvas sits in its top-left corner, the same
		# way the importer composites it.
		var used := Vector2i(
			mini(frame_image.get_width(), cell.x), mini(frame_image.get_height(), cell.y)
		)
		sheet.blit_rect(
			frame_image, Rect2i(Vector2i.ZERO, used), target
		)
	return sheet
