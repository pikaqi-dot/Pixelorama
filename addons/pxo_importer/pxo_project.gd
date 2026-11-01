@tool
class_name PxoProject
extends Resource
## A Pixelorama project, unpacked into Godot nodes and resources.
##
## The point is that nothing here needs Pixelorama at run time: the `.pxo` is
## read once when the resource is imported, and what ships with the game is
## ordinary [Texture2D]s plus a [SpriteFrames] built from the frames.
##
## [codeblock]
## # AnimatedSprite2D, straight from the .pxo:
## var project: PxoProject = load("res://art/player.pxo")
## $AnimatedSprite2D.sprite_frames = project.sprite_frames
## $AnimatedSprite2D.play()
##
## # One layer of one frame, e.g. the character without the background:
## $Shadow.texture = project.get_layer_image(0, "character")
##
## # A tilemap project, as a Godot TileSet and a filled-in TileMapLayer:
## $TileMapLayer.tile_set = project.build_tile_set()
## add_child(project.build_tile_map(0))
## [/codeblock]

## Canvas size of the project, in pixels.
@export var canvas_size: Vector2i = Vector2i.ZERO
## Frames per second the project was authored at.
@export var fps: float = 12.0
## The Image format the pixels are stored in, kept so the tile images can be read
## the same way the cels were.
@export var color_mode: int = 4
## Layer names, in Pixelorama's own order (bottom to top).
@export var layer_names: PackedStringArray = PackedStringArray()
## Every frame of the drawing tab, in order.
@export var frames: Array[PxoFrame] = []
## Animation tags: a name, the frame range it covers, and its colour.
@export var tags: Array[Dictionary] = []
## Built on import from [member frames], so an AnimatedSprite2D can use the
## project with no glue code at all.
@export var sprite_frames: SpriteFrames
## Where this was imported from, for messages and debugging.
@export var source_path: String = ""
## The version of the reader that produced this resource. Zero means it was
## imported before the field existed, so it is missing whatever came after.
@export var reader_version: int = 0
## The project's tilesets, metadata only: [code]{name, tile_size, tile_shape,
## tile_amount, terrain_colors, terrain_names, tile_bits}[/code]. The tile images
## stay inside the `.pxo` and are read on demand by [PxoTileset].
@export var tilesets: Array[Dictionary] = []
## One entry per tilemap layer: [code]{layer, tileset, tile_size, name}[/code],
## where [code]layer[/code] is that layer's index in [member layer_names].
@export var tile_layers: Array[Dictionary] = []


func frame_count() -> int:
	return frames.size()


func get_frame(index: int) -> PxoFrame:
	if index < 0 or index >= frames.size():
		return null
	return frames[index]


## The flattened image of one frame.
func get_composite(index: int) -> Texture2D:
	var frame := get_frame(index)
	if frame == null:
		return null
	return frame.composite


## The image of one layer in one frame, by the layer's Pixelorama name. Returns
## null when the name is unknown or that layer carries no pixels.
func get_layer_image(frame_index: int, layer_name: String) -> Texture2D:
	var index := layer_names.find(layer_name)
	if index < 0:
		return null
	var frame := get_frame(frame_index)
	if frame == null:
		return null
	return frame.get_layer_image(index)


## The frame range of a tag, as [code]{from, to, name, color}[/code], or an empty
## dictionary when no tag has that name.
func get_tag(tag_name: String) -> Dictionary:
	for tag: Dictionary in tags:
		if str(tag.get("name", "")) == tag_name:
			return tag
	return {}


## Whether this project draws with tiles at all, so a panel can hide the tile
## buttons for a plain sprite.
func has_tilesets() -> bool:
	return not tilesets.is_empty()


## The names of the tilemap layers, for a menu or a log line.
func tile_layer_names() -> PackedStringArray:
	var out := PackedStringArray()
	for entry: Dictionary in tile_layers:
		out.append(str(entry.get("name", "")))
	return out


## A Godot [TileSet] built from the project's tilesets, tile images included. The
## `.pxo` is read again here, so this works at run time as long as the file is
## still in the project.
func build_tile_set() -> TileSet:
	return PxoTileset.build_tile_set(self)


## The tilemap layers of one frame as a [Node2D] with a [TileMapLayer] each, cells
## already placed. Null when that frame has no tilemap layer.
func build_tile_map(frame_index := 0) -> Node2D:
	return PxoTileset.build_tile_map(self, frame_index)


## Builds a fresh [SpriteFrames] from [member frames]. [member sprite_frames]
## already holds one made the same way, so this is only needed when the project
## was assembled by hand rather than imported.
func build_sprite_frames(animation_name := "default") -> SpriteFrames:
	var out := SpriteFrames.new()
	if animation_name != "default":
		out.remove_animation("default")
		out.add_animation(animation_name)
	out.set_animation_speed(animation_name, max(0.001, fps))
	for frame: PxoFrame in frames:
		if frame == null or frame.composite == null:
			continue
		# A per-frame hold is what Pixelorama stores, so it is what a game should
		# see: the duration rides along with the frame. At the default 1.0 the
		# animation speed alone decides, which is the usual case.
		out.add_frame(animation_name, frame.composite, frame.duration)
	return out
