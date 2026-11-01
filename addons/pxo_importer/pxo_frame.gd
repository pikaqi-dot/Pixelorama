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

## How long this frame lasts. Pixelorama allows a per-frame hold, so this is not
## always 1.
@export var duration: float = 1.0
## Every visible layer flattened, ready to be drawn.
@export var composite: Texture2D
## One image per layer, parallel to [member PxoProject.layer_names]. Entries are
## null for layers that are not pixel layers (groups, tilemaps, 3D, audio) and
## for layers that were filtered out on import.
@export var layer_images: Array[Texture2D] = []


## The image of one layer, by index. Null when that layer has no pixels here.
func get_layer_image(index: int) -> Texture2D:
	if index < 0 or index >= layer_images.size():
		return null
	return layer_images[index]
