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
##
## Animations are named after Pixelorama's animation tags (see
## [method PxoProject.build_sprite_frames]); a project without tags gets one
## "default" animation, exactly as before.
static func export_sprite_frames(project: PxoProject, path: String) -> Error:
	if project == null:
		return ERR_INVALID_PARAMETER
	if project.frames.is_empty():
		return ERR_INVALID_DATA
	var frames := project.build_sprite_frames()
	if frames.get_animation_names().is_empty():
		return ERR_INVALID_DATA
	return ResourceSaver.save(frames, path)


## Writes every frame into one grid image.
##
## The layout mirrors Pixelorama's export dialog: [param columns] = frames per
## row, [param rows] = frames per column, neither = one long row (what
## `hframes = frame_count, vframes = 1` expects on a [Sprite2D]). [param crop]
## trims the empty border all frames share, so a 16×16 canvas holding a 12×13
## sprite packs into 12×13 cells; the box is the union over *every* frame, so the
## sprites do not shift against each other. [param scale] enlarges the finished
## sheet with nearest-neighbour, the same way Pixelorama's «缩放» does.
static func export_sheet(
	project: PxoProject,
	path: String,
	columns := 0,
	rows := 0,
	crop := false,
	scale := 1.0
) -> Error:
	var sheet := build_sheet(project, columns, rows, crop, scale)
	if sheet == null:
		return ERR_INVALID_DATA
	return sheet.save_png(ProjectSettings.globalize_path(path))


## Every frame as its own PNG, `<base>_0001.png`, `<base>_0002.png`, … — the
## "image" tab of Pixelorama's export dialog. Nothing else is written, so the
## directory can be used as-is by any importer.
static func export_frames(
	project: PxoProject,
	directory: String,
	base_name := "",
	separator := "_",
	digits := 4
) -> Error:
	if project == null or project.frames.is_empty():
		return ERR_INVALID_DATA
	if base_name.is_empty():
		base_name = local_path(project.source_path).get_file()
	var target := ProjectSettings.globalize_path(directory)
	if not DirAccess.dir_exists_absolute(target):
		var made := DirAccess.make_dir_recursive_absolute(target)
		if made != OK:
			return made
	for index in project.frames.size():
		var texture := project.get_composite(index)
		if texture == null:
			continue
		var image := texture.get_image()
		if image == null or image.is_empty():
			continue
		image.convert(Image.FORMAT_RGBA8)
		var file_name := "%s%s%s.png" % [
			base_name, separator, str(index + 1).pad_zeros(digits)
		]
		var err := image.save_png(target.path_join(file_name))
		if err != OK:
			return err
	return OK


## The description a game or a pipeline needs to rebuild the animation without
## the `.pxo`: frame size, fps, every frame with its hold and file name, and the
## tags. Pixelorama writes this next to its images when 「导出 JSON」 is ticked.
static func build_metadata(
	project: PxoProject, base_name := "", separator := "_", digits := 4
) -> Dictionary:
	var size := project.frame_size()
	var files: Array = []
	for index in project.frames.size():
		files.append(
			{
				"index": index,
				"file": "%s%s%s.png" % [
					base_name, separator, str(index + 1).pad_zeros(digits)
				],
				"duration": project.frames[index].duration,
			}
		)
	var tags: Array = []
	for tag: Dictionary in project.tags:
		tags.append(
			{
				"name": str(tag.get("name", "")),
				"from": int(tag.get("from", 0)),
				"to": int(tag.get("to", 0)),
			}
		)
	return {
		"generator": "pxo_importer",
		"source": project.source_path,
		"canvas": [project.canvas_size.x, project.canvas_size.y],
		"frame_rect": [
			project.frame_rect.position.x,
			project.frame_rect.position.y,
			project.frame_rect.size.x,
			project.frame_rect.size.y,
		],
		"frame_size": [size.x, size.y],
		"fps": project.fps,
		"frames": files,
		"tags": tags,
	}


## Writes [method build_metadata] as JSON next to the images.
static func export_json(
	project: PxoProject,
	path: String,
	base_name := "",
	separator := "_",
	digits := 4
) -> Error:
	if project == null:
		return ERR_INVALID_PARAMETER
	var text := JSON.stringify(build_metadata(project, base_name, separator, digits), "\t")
	var file := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(text)
	file.close()
	return OK


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
static func build_sheet(
	project: PxoProject, columns := 0, rows := 0, crop := false, scale := 1.0
) -> Image:
	if project == null or project.frames.is_empty():
		return null
	# The cell is the frame, not the canvas: a frame covers whatever the cels draw,
	# which can be taller or wider than the canvas. Using the canvas here would cut
	# the very part that was just kept.
	var cell := project.frame_size()
	if cell.x <= 0 or cell.y <= 0:
		return null
	var source := Rect2i(Vector2i.ZERO, cell)
	if crop:
		# One box for the whole project: trimming per frame would make the cells
		# different sizes and the sprite would jitter while the animation played.
		source = content_rect(project)
		cell = source.size
		if cell.x <= 0 or cell.y <= 0:
			return null
	var count := project.frames.size()
	if columns <= 0 and rows <= 0:
		columns = count
	var column_major := rows > 0 and columns <= 0
	var grid_columns := count
	var grid_rows := 1
	if column_major:
		grid_rows = rows
		grid_columns = ceili(float(count) / float(rows))
	elif columns > 0:
		grid_columns = columns
		grid_rows = ceili(float(count) / float(columns))
	var sheet := Image.create(
		cell.x * grid_columns, cell.y * grid_rows, false, Image.FORMAT_RGBA8
	)
	sheet.fill(Color(0, 0, 0, 0))
	for index in count:
		var texture := project.get_composite(index)
		if texture == null:
			continue
		var frame_image := texture.get_image()
		if frame_image == null or frame_image.is_empty():
			continue
		frame_image.convert(Image.FORMAT_RGBA8)
		var target: Vector2i
		if column_major:
			target = Vector2i(
				int(float(index) / float(grid_rows)) * cell.x,
				(index % grid_rows) * cell.y
			)
		else:
			target = Vector2i(
				(index % grid_columns) * cell.x,
				int(float(index) / float(grid_columns)) * cell.y
			)
		# A frame from an older import can still be canvas-sized; it sits in the
		# cell's top-left corner rather than overrunning it.
		var used := Vector2i(
			mini(frame_image.get_width() - source.position.x, cell.x),
			mini(frame_image.get_height() - source.position.y, cell.y)
		)
		if used.x <= 0 or used.y <= 0:
			continue
		sheet.blit_rect(frame_image, Rect2i(source.position, used), target)
	if scale > 0.0 and not is_equal_approx(scale, 1.0):
		sheet.resize(
			maxi(1, roundi(sheet.get_width() * scale)),
			maxi(1, roundi(sheet.get_height() * scale)),
			Image.INTERPOLATE_NEAREST
		)
	return sheet


## The box every frame's drawing fits in, in frame pixels: the union of the
## non-transparent pixels over the whole project. Falls back to the full frame
## when nothing is drawn, so a cropped export of an empty project is still a
## usable image rather than a zero-sized one.
static func content_rect(project: PxoProject) -> Rect2i:
	var union := Rect2i()
	var found := false
	for frame: PxoFrame in project.frames:
		if frame == null or frame.composite == null:
			continue
		var used := frame.composite.get_image().get_used_rect()
		if used.size.x <= 0 or used.size.y <= 0:
			continue
		union = used if not found else union.merge(used)
		found = true
	if not found:
		return Rect2i(Vector2i.ZERO, project.frame_size())
	return union
