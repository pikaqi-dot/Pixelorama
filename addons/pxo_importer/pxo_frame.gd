@tool
class_name PxoFrame
extends Resource
## One frame of a Pixelorama project, as the drawing tab shows it.
##
## [member composite] is what the frame looks like with every visible layer
## stacked, which is what a game usually wants. [member layer_images] keeps the
## layers apart, in the same order as [member PxoProject.layer_names], so an
## effect that needs "just the character, not the background" can still find it.
## Use [method PxoProject.get_layer_image] to look one up by its Pixelorama name.
##
## A tilemap layer has both: the rendered picture in [member layer_images], and
## where each tile sits in [member tile_cells], which is what [PxoTileset] turns
## into a Godot [TileMapLayer].

## How long this frame lasts. Pixelorama allows a per-frame hold, so this is not
## always 1.
@export var duration: float = 1.0
## Every visible layer flattened, ready to be drawn.
@export var composite: Texture2D
## One image per layer, parallel to [member PxoProject.layer_names]. Entries are
## null for layers that are not pixel layers (groups, 3D, audio) and for layers
## that were filtered out on import.
@export var layer_images: Array[Texture2D] = []
## One cell map per layer, in the same order: a cell position ([Vector2i]) to
## [code]{index, flip_h, flip_v, transpose}[/code] for a tilemap layer, and an
## empty dictionary for every other kind of layer.
@export var tile_cells: Array[Dictionary] = []


## The image of one layer, by index. Null when that layer has no pixels here.
func get_layer_image(index: int) -> Texture2D:
	if index < 0 or index >= layer_images.size():
		return null
	return layer_images[index]


## Where the tiles of one layer sit. Empty for anything that is not a tilemap
## layer, which is also how to ask "is this layer a tilemap".
func get_tile_cells(index: int) -> Dictionary:
	if index < 0 or index >= tile_cells.size():
		return {}
	return tile_cells[index]
