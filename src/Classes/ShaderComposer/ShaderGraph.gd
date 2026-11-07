class_name ShaderGraph
extends RefCounted
## A tiny node graph that turns procedural nodes into a pixel image.
##
## Every node produces a single value between 0 and 1 for a pixel. A node can own
## a colour, and that colour travels down the wires to the [code]output[/code] node,
## which only closes the graph and says how the result meets the layer. A branch
## without a colour is drawn in grey, and a branch that drops the colour (a mask,
## a density, a canvas read as transparency) starts a grey picture again.

## Node types and how many inputs they take.
const NODE_TYPES := {
	"noise": {"label": "噪声", "inputs": 0},
	"gradient": {"label": "渐变", "inputs": 0},
	"radial": {"label": "径向", "inputs": 0},
	"checker": {"label": "棋盘", "inputs": 0},
	"constant": {"label": "常量", "inputs": 0},
	# A single primitive, sized and rotated. Useful as a mask for the filters.
	"shape": {"label": "图形", "inputs": 0},
	# A 3d mesh seen through a camera: its silhouette and the light falling on
	# it, so a render becomes a mask or a shaded plate for the rest of the graph.
	"model3d": {"label": "3D 模型", "inputs": 0},
	# A recursive tree, rasterised once per frame. Growth reveals it level by
	# level, which is what makes the growing animation possible.
	"tree": {"label": "树木", "inputs": 0},
	# A seeded pixel particle system. Positions are worked out from the phase
	# instead of being simulated, so any frame can be rendered on its own.
	"particles": {"label": "像素粒子", "inputs": 0},
	# Stamps the first input over the canvas at random angles and sizes. The
	# brush is usually a pixel_art layer, so a leaf turns into a bush. Only the
	# opacity of the brush is used, so the artwork recolours the stamps.
	"scatter": {"label": "散布", "inputs": 2},
	# Input nodes: one holds a vector path, the other turns a path or a layer
	# into pixels. The path carries no stroke of its own, so the canvas decides
	# how wide the line is and how it tapers.
	"path": {"label": "路径", "inputs": 0},
	"pixel_art": {"label": "画布", "inputs": 1},
	"time": {"label": "时间", "inputs": 0},
	"wave": {"label": "波纹", "inputs": 1},
	# Transform group. They all move the sampling position, so they can be
	# chained and applied to any branch of the graph.
	"transform": {"label": "变换", "inputs": 1},
	"scale": {"label": "缩放", "inputs": 1},
	"flip": {"label": "翻转", "inputs": 1},
	"skew": {"label": "倾斜", "inputs": 1},
	"tile": {"label": "平铺", "inputs": 1},
	"polar": {"label": "极坐标", "inputs": 1},
	"crop": {"label": "裁剪", "inputs": 1},
	"padding": {"label": "边距", "inputs": 1},
	"echo": {"label": "回声", "inputs": 1},
	"follow_path": {"label": "跟随路径", "inputs": 2},
	"mesh_warp": {"label": "网格变形", "inputs": 1},
	"area_warp": {"label": "区域扭曲", "inputs": 2},
	"nine_slice": {"label": "九宫格", "inputs": 1},
	"crop_content": {"label": "内容裁剪", "inputs": 1},
	"kaleidoscope": {"label": "万花筒", "inputs": 1},
	"bend": {"label": "弯曲", "inputs": 1},
	"stretch": {"label": "拉伸", "inputs": 1},
	"mirror": {"label": "镜像", "inputs": 1},
	"warp": {"label": "扭曲", "inputs": 2},
	# Filters read neighbouring pixels, they do not move the mapping.
	"blur": {"label": "模糊", "inputs": 1},
	"outline": {"label": "描边", "inputs": 2},
	"glow": {"label": "发光", "inputs": 2},
	"bloom": {"label": "泛光", "inputs": 2},
	"color_adjust": {"label": "颜色调整", "inputs": 1},
	"levels": {"label": "色阶", "inputs": 1},
	"threshold": {"label": "阈值", "inputs": 1},
	"normalize": {"label": "归一化", "inputs": 1},
	"curve": {"label": "曲线", "inputs": 1},
	"band": {"label": "色阶选择", "inputs": 1},
	"edge": {"label": "边缘检测", "inputs": 1},
	"dither": {"label": "抖动", "inputs": 1},
	"pixelate": {"label": "像素化", "inputs": 1},
	# Morphology: eats the silhouette inwards or grows it outwards, which a
	# transform cannot do because it only moves what is already there.
	"erode": {"label": "侵蚀", "inputs": 2},
	"math": {"label": "运算", "inputs": 1},
	"blend": {"label": "混合", "inputs": 2},
	"output": {"label": "输出", "inputs": 1},
}
## Text of the second input port. The same slot means different things per node,
## and showing it in the graph saves a trip to the parameter hint on a phone.
const SECOND_INPUT_LABELS := {
	"blend": "B",
	"warp": "扭曲场",
	"follow_path": "相位",
	"area_warp": "外部",
	"outline": "遮罩",
	"erode": "遮罩",
	"glow": "遮罩",
	"bloom": "遮罩",
	"scatter": "密度",
}

const NOISE_TYPES := ["Simplex", "Simplex Smooth", "Perlin", "Cellular", "Value"]
const NOISE_TYPE_VALUES := [
	FastNoiseLite.TYPE_SIMPLEX,
	FastNoiseLite.TYPE_SIMPLEX_SMOOTH,
	FastNoiseLite.TYPE_PERLIN,
	FastNoiseLite.TYPE_CELLULAR,
	FastNoiseLite.TYPE_VALUE,
]
const MATH_OPS := [
	"Add", "Subtract", "Multiply", "Min", "Max", "Step", "Posterize", "Invert", "Sine"
]
const BLEND_OPS := ["Mix", "Add", "Multiply", "Screen", "Difference"]
## How an animated parameter travels between its start and end value.
const ANIM_MODES := ["一次", "循环", "往返"]
const POLAR_MODES := ["矩形 → 极坐标", "极坐标 → 矩形"]
const ECHO_MODES := ["最大值（拖影）", "平均值（残影）"]
## Morphology of the erode node: shrink the bright shape or grow it.
const ERODE_MODES := ["侵蚀（向内收）", "扩张（向外长）"]
## Kernel used by the erode node.
const ERODE_SHAPES := ["方形", "圆形", "菱形"]
const PATH_SHAPES := ["圆形", "水平", "垂直", "正弦", "方形", "8 字", "自定义"]
## Primitives of the shape node.
const SHAPE_KINDS := ["圆形", "方形", "三角形", "菱形", "星形", "圆环"]
## Geometry of the 3d model node. Every one of them is a triangle soup, so the
## same projection and the same lighting work for all of them.
const MODEL_SHAPES := ["立方体", "球", "圆柱", "圆环", "棱柱", "平面"]
## Tessellation of the 3d meshes. A silhouette needs far fewer segments than a
## smooth render, and this is rasterised on the main thread of a phone.
const MODEL_SPHERE_SIDES := 28
const MODEL_SPHERE_RINGS := 16
const MODEL_TUBE_SIDES := 22
const MODEL_TORUS_RINGS := 28
const MODEL_TORUS_TUBES := 12
const MODEL_PRISM_SIDES := 3
## Above this many pixels the 3d node gives up its second sample per pixel. Every
## preview of the composer sits under it, so they stay smooth, while a canvas
## sized render stays one sample deep and finishes in a fraction of the time.
const MODEL_SAMPLES_LIMIT := 16384
## Area below which a projected triangle touches no pixel centre. Such a face
## would only cost the rasteriser its bounding box.
const MODEL_MIN_FACE := 0.000001
## Smallest distance kept in front of the camera, so a vertex sitting on it
## cannot blow the projection up.
const MODEL_MIN_DISTANCE := 0.05
## Where the pixel particles are born.
const PARTICLE_SPAWN := ["底部升起", "顶部下落", "中心爆发", "全画布"]
const PARTICLE_SHAPES := ["方形", "圆形", "菱形", "十字"]
## Shape index that uses the control points edited in the path editor.
const PATH_CUSTOM := 6
## How the stamps of a scatter are laid out.
const SCATTER_DISTRIBUTIONS := ["随机", "均匀间距", "网格"]
## Prefix of the ids of groups, so a group node can be told from a real node.
const GROUP_PREFIX := "group_"
const DITHER_SIZES_TEXT := ["2×2", "4×4", "8×8"]
const FLIP_AXIS := ["水平", "垂直", "两者"]
const SCALE_MODES := ["按比例", "缩放到尺寸"]
const SCALE_FITS := ["拉伸铺满", "保持比例放入", "保持比例填满"]
const BEND_TYPES := ["弧线", "波浪"]
const BEND_AXIS := ["沿 X（按 Y 弯曲）", "沿 Y（按 X 弯曲）"]
## Bits of the Bayer matrix behind each entry of [constant DITHER_SIZES_TEXT].
const DITHER_BITS := [1, 2, 3]

## Node types grouped for the add menu. Every type in [constant NODE_TYPES] has
## to appear exactly once, which the tests check.
const NODE_GROUPS := [
	{
		"label": "生成",
		"types":
		[
			"noise",
			"gradient",
			"radial",
			"checker",
			"constant",
			"shape",
			"model3d",
			"tree",
			"particles",
			"scatter",
		],
	},
	{"label": "输入", "types": ["path", "pixel_art"]},
	{"label": "动态", "types": ["time", "wave"]},
	{
		"label": "变换",
		"types":
		[
			"transform",
			"scale",
			"flip",
			"skew",
			"tile",
			"polar",
			"crop",
			"padding",
			"nine_slice",
			"crop_content",
		],
	},
	{
		"label": "变形",
		"types":
		[
			"warp",
			"area_warp",
			"mesh_warp",
			"bend",
			"stretch",
			"mirror",
			"kaleidoscope",
			"echo",
			"follow_path",
		],
	},
	{
		"label": "滤镜",
		"types":
		[
			"blur",
			"outline",
			"glow",
			"bloom",
			"color_adjust",
			"levels",
			"threshold",
			"normalize",
			"curve",
			"band",
			"edge",
			"dither",
			"pixelate",
			"erode",
		],
	},
	{"label": "合成", "types": ["math", "blend", "output"]},
]
## Accent of every group, reused for the node titles so a large graph can be read
## by colour instead of by reading every label.
const NODE_GROUP_COLORS := {
	"生成": Color(0.55, 0.82, 1.0),
	"输入": Color(0.55, 0.95, 0.75),
	"动态": Color(1.0, 0.84, 0.45),
	"变换": Color(0.76, 0.7, 1.0),
	"变形": Color(1.0, 0.66, 0.76),
	"滤镜": Color(0.66, 0.94, 0.6),
	"合成": Color(0.96, 0.76, 0.56),
}
## Coordinates closer than this to a pixel are treated as that pixel. Only used to
## cancel the floating point noise of rotations by right angles.
const SNAP_STEP := 0.000001
## Value below which a node counts as producing nothing. The previews leave those
## pixels transparent, so the backdrop of the frame shows through instead of a
## black block that hides what the node actually covers.
const PREVIEW_EMPTY := 0.004
## How many different raster sizes are kept at once. A thumbnail, the picture in
## the side panel and the main preview each use their own size, so keeping them
## apart saves rebuilding every stroke and particle field whenever the size
## changes. The preview keeps generating while the thumbnails are painted, so the
## four sizes of a drag in progress stay side by side instead of throwing the
## strokes of the running pass away. More distinct sizes than this drop
## everything, which bounds the memory.
const RASTER_SIZES_MAX := 4
## Most rasters kept at once. Keys carry the parameters and the time they were
## drawn from, so an untouched stroke survives the next generation instead of
## being redrawn for every step of an unrelated slider; this cap is what keeps
## that from growing without end while a graph plays. A node needs one entry per
## size in use, and the graph editor shows three of them at once (preview,
## thumbnail, side panel), so this leaves room for a good handful of rasters.
const RASTER_CACHE_MAX := 32
## Painting is split over the cores above this many rows and pixels. Below it the
## hand off costs more than the rows are worth.
const PARALLEL_MIN_ROWS := 4
const PARALLEL_MIN_PIXELS := 2048
## Most worker threads used for one picture. Measured on a 16 core machine, four
## threads nearly halve a heavy picture while six or more are slower again: the
## hand off and the memory traffic cost more than the extra rows are worth.
const PARALLEL_MAX_THREADS := 4

## Nodes of the graph, as dictionaries: id, type, position, params, inputs.
var nodes: Array[Dictionary] = []
## Collapsible groups of nodes. They are purely visual, the evaluation never
## looks at them.
var groups: Array[Dictionary] = []
## Animation phase between 0 and 1, read by the [code]time[/code] node.
var time := 0.0
var _next_id := 1
var _next_group_id := 1
var _noise_cache := {}
var _noise_signature := {}
## Parameters of every node with its animated value applied, rebuilt once per
## generated frame. Keeping it out of the per pixel loop is what makes animating
## a parameter affordable on a phone.
var _live_params: Dictionary = {}
## Node lookup used by the evaluator, rebuilt once per frame. Without it every
## sample would scan the whole node list.
var _eval_nodes: Dictionary = {}
## Whole canvas value fields of a branch, built once per generation and size so
## neighbour reading nodes do not walk the graph again for every sample.
var _field_cache: Dictionary = {}
## Noise nodes already prepared this frame, so their signature string is built
## once instead of once per pixel.
var _noise_checked: Dictionary = {}
## Cache key of the raster of every node of this frame, so the evaluator formats
## one string per node instead of one per pixel it visits.
var _raster_keys: Dictionary = {}
## Signature of the parameters, inputs and time a raster is drawn from. It is
## part of the key, which is what lets an unchanged stroke be found again in the
## next generation instead of being redrawn.
var _raster_sigs: Dictionary = {}
## Bumped once per generation while the graph reads the project. The artwork can
## change without a single parameter moving, so rasters of such a graph must not
## be reused across generations.
var _source_generation := 0
## Threads the paint loop may use. Zero follows the cores of the machine; a
## positive number pins it, which is how a single threaded picture is produced
## for comparisons and how the splitting can be switched off.
var paint_threads := 0
## False when the graph has a node that moves the shared clock while it samples,
## which is the one thing the threads cannot do side by side.
var _parallel_safe := true
## Bounds of the non empty part of a branch, rebuilt for every generated image.
var _bounds_cache := {}
var _bayer_cache := {}
## Decoded paintings of the canvas nodes, by node id, kept with the stored PNG they
## were decoded from so an edit invalidates it without extra bookkeeping.
var _painting_cache := {}
## Rasterised paths and the project layers read by the input nodes, per generate.
var _path_cache := {}
## Sizes currently held in [member _path_cache], so the cache can stay bounded.
var _raster_sizes := {}
var _source_cache := {}


func _init() -> void:
	reset_to_default()


## Starts over with a noise feeding an output, so the graph always has a result.
func reset_to_default() -> void:
	nodes.clear()
	groups.clear()
	_next_group_id = 1
	_noise_cache.clear()
	_noise_signature.clear()
	var noise_id := add_node("noise", Vector2(40, 60))
	var output_id := add_node("output", Vector2(420, 60))
	connect_nodes(noise_id, output_id, 0)


func add_node(type: String, position := Vector2.ZERO) -> String:
	if not NODE_TYPES.has(type):
		return ""
	var id := "%s_%d" % [type, _next_id]
	_next_id += 1
	nodes.append(
		{
			"id": id,
			"type": type,
			"position": position,
			"params": default_params(type),
			"inputs": {},
		}
	)
	return id


## Removes [param id]. When it fed other nodes, its own input is wired to them in
## its place, so deleting a step in the middle of a chain does not break it.
func remove_node(id: String) -> void:
	var node := get_node_by_id(id)
	if node.is_empty():
		return
	var upstream := _input_id(node, 0)
	var consumers: Array = []
	for other: Dictionary in nodes:
		if other["id"] == id:
			continue
		var other_inputs: Dictionary = other["inputs"]
		for slot: int in other_inputs.keys():
			if str(other_inputs[slot]) == id:
				consumers.append({"id": other["id"], "slot": slot})
	nodes.erase(node)
	_noise_cache.erase(id)
	_noise_signature.erase(id)
	for other: Dictionary in nodes:
		var inputs: Dictionary = other["inputs"]
		for slot: int in inputs.keys():
			if str(inputs[slot]) == id:
				inputs.erase(slot)
	for index in range(groups.size() - 1, -1, -1):
		var members: Array = groups[index]["nodes"]
		members.erase(id)
		if members.is_empty():
			groups.remove_at(index)
	if upstream.is_empty():
		return
	for entry: Dictionary in consumers:
		connect_nodes(upstream, str(entry["id"]), int(entry["slot"]))


func get_node_by_id(id: String) -> Dictionary:
	for node: Dictionary in nodes:
		if node["id"] == id:
			return node
	return {}


## Snapshot of the whole graph, stored on the layers this graph created so they
## can be edited again later.
func to_dict() -> Dictionary:
	return {
		"nodes": nodes.duplicate(true),
		"next_id": _next_id,
		"groups": groups.duplicate(true),
		"next_group_id": _next_group_id,
	}


## Restores a snapshot made by [method to_dict]. A project file stores the graph
## as JSON, which knows neither Color nor Vector2, so those come back as text and
## are turned into the values the nodes expect here. Without this, opening a saved
## project left every colour and position a string and the editor could not open.
func from_dict(data: Dictionary) -> void:
	var stored: Array = data.get("nodes", [])
	nodes.clear()
	_noise_cache.clear()
	_noise_signature.clear()
	for entry in stored:
		if entry is not Dictionary or not entry.has("id") or not entry.has("type"):
			continue
		var node: Dictionary = (entry as Dictionary).duplicate(true)
		node["position"] = _restore_value(node.get("position", Vector2.ZERO))
		var defaults: Dictionary = default_params(str(node["type"]))
		var params: Dictionary = node.get("params", {})
		var restored := {}
		for key in params:
			restored[key] = _restore_value(params[key], defaults.get(key, null))
		node["params"] = restored
		# Input slots are keyed by port number, and JSON turns those keys into text.
		# Without this the graph came back with every wire lost, which is what left a
		# reopened project with an empty looking composer.
		var inputs: Dictionary = node.get("inputs", {})
		var restored_inputs := {}
		for slot in inputs:
			restored_inputs[int(slot)] = str(inputs[slot])
		node["inputs"] = restored_inputs
		nodes.append(node)
	_next_id = maxi(int(data.get("next_id", 1)), 1)
	# Keep ids unique even if the snapshot came from an older graph.
	for node: Dictionary in nodes:
		var suffix := str(node["id"]).get_slice("_", -1)
		if suffix.is_valid_int():
			_next_id = maxi(_next_id, int(suffix) + 1)
	# Flip used to have two checkboxes, move old graphs to the single axis.
	for node: Dictionary in nodes:
		if str(node["type"]) != "flip":
			continue
		var flip_params: Dictionary = node["params"]
		if flip_params.has("axis"):
			continue
		var horizontal := bool(flip_params.get("horizontal", false))
		var vertical := bool(flip_params.get("vertical", false))
		flip_params["axis"] = 2 if (horizontal and vertical) else (1 if vertical else 0)
	# Blur renamed radius to size when it became directional.
	for node: Dictionary in nodes:
		if str(node["type"]) != "blur":
			continue
		var blur_params: Dictionary = node["params"]
		if not blur_params.has("size") and blur_params.has("radius"):
			blur_params["size"] = blur_params["radius"]
	# A canvas stroke used to be one width scaled down by the profile. It is now a
	# minimum and a maximum with the profile picking between them, and moving the
	# old number to the maximum keeps the stroke exactly as it was.
	for node: Dictionary in nodes:
		if str(node["type"]) != "pixel_art":
			continue
		var art_params: Dictionary = node["params"]
		if art_params.has("width_max"):
			continue
		var old_width := float(art_params.get("width", 0.06))
		art_params["width_min"] = 0.0
		art_params["width_max"] = old_width
		art_params.erase("width")
	groups.clear()
	for entry in data.get("groups", []):
		if entry is not Dictionary or not entry.has("id"):
			continue
		var group: Dictionary = (entry as Dictionary).duplicate(true)
		if group.has("position"):
			group["position"] = _restore_value(group["position"])
		var members: Array = []
		for member in group.get("nodes", []):
			if not get_node_by_id(str(member)).is_empty():
				members.append(str(member))
		if members.is_empty():
			continue
		group["nodes"] = members
		if not group.has("collapsed"):
			group["collapsed"] = false
		if not group.has("name"):
			group["name"] = str(group["id"])
		groups.append(group)
	_next_group_id = maxi(int(data.get("next_group_id", 1)), 1)
	for group: Dictionary in groups:
		var group_suffix := str(group["id"]).get_slice("_", -1)
		if group_suffix.is_valid_int():
			_next_group_id = maxi(_next_group_id, int(group_suffix) + 1)


## Turns a value that came back from a project file into what the graph expects.
## JSON has no Color and no Vector2, so both are written as text like
## [code]"(0.2, 0.5, 0.1, 1)"[/code] and read back here. [param default] is the
## value the node would use, which tells a Color and a Vector2 apart; without one
## the number of parts decides. Anything that is not such a text is returned as is.
static func _restore_value(value: Variant, default: Variant = null) -> Variant:
	if value is Dictionary:
		var restored := {}
		for key in (value as Dictionary):
			restored[key] = _restore_value((value as Dictionary)[key])
		return restored
	if value is Array:
		var items: Array = []
		for item in (value as Array):
			items.append(_restore_value(item))
		return items
	if not (value is String):
		return value
	var text := str(value).strip_edges()
	if not text.begins_with("(") or not text.ends_with(")"):
		return value
	if default is Color:
		return _tuple_value(text, "Color", value)
	if default is Vector3:
		return _tuple_value(text, "Vector3", value)
	if default is Vector2:
		return _tuple_value(text, "Vector2", value)
	if default is Vector2i:
		return _tuple_value(text, "Vector2i", value)
	# Nothing to judge by, so three or more parts can only have been a colour.
	if text.count(",") >= 2:
		return _tuple_value(text, "Color", value)
	return _tuple_value(text, "Vector2", value)


## Builds [code]Color(0.1, 0.2, 0.3, 1)[/code] out of the bare tuple a project file
## left behind, and keeps [param fallback] when the text does not parse.
static func _tuple_value(body: String, kind: String, fallback: Variant) -> Variant:
	var parsed: Variant = str_to_var(kind + body)
	return fallback if parsed == null else parsed


## Puts the given nodes into a new collapsible group. A node can only be in one
## group, and nodes that are already grouped are skipped.
func add_group(node_ids: Array, group_name := "") -> String:
	var members: Array[String] = []
	var top_left := Vector2.ZERO
	var first := true
	for id in node_ids:
		var node_id := str(id)
		if get_node_by_id(node_id).is_empty() or members.has(node_id):
			continue
		if not group_of_node(node_id).is_empty():
			continue
		members.append(node_id)
		var position: Vector2 = get_node_by_id(node_id).get("position", Vector2.ZERO)
		if first:
			top_left = position
			first = false
		else:
			top_left = Vector2(minf(top_left.x, position.x), minf(top_left.y, position.y))
	if members.is_empty():
		return ""
	var suffix := _next_group_id
	_next_group_id += 1
	var group_id := "%s%d" % [GROUP_PREFIX, suffix]
	groups.append(
		{
			"id": group_id,
			"name": group_name if not group_name.is_empty() else "组 %d" % suffix,
			"nodes": members,
			"collapsed": false,
			"position": top_left - Vector2(30.0, 40.0),
		}
	)
	return group_id


func get_group(group_id: String) -> Dictionary:
	for group: Dictionary in groups:
		if group["id"] == group_id:
			return group
	return {}


## Group that [param node_id] belongs to, or an empty dictionary.
func group_of_node(node_id: String) -> Dictionary:
	for group: Dictionary in groups:
		if (group["nodes"] as Array).has(node_id):
			return group
	return {}


func remove_group(group_id: String) -> void:
	for index in range(groups.size() - 1, -1, -1):
		if groups[index]["id"] == group_id:
			groups.remove_at(index)


func set_group_collapsed(group_id: String, collapsed: bool) -> void:
	var group := get_group(group_id)
	if group.is_empty():
		return
	group["collapsed"] = collapsed


## Edges that cross the border of [param group]. A collapsed group is drawn as one
## node, and these are the connections it has to show.
func group_edges(group: Dictionary) -> Dictionary:
	var members := {}
	for id: String in group["nodes"]:
		members[id] = true
	var incoming: Array = []
	var outgoing: Array = []
	for node: Dictionary in nodes:
		var inside := members.has(node["id"])
		var inputs: Dictionary = node["inputs"]
		for slot: int in inputs.keys():
			var source := str(inputs[slot])
			if source.is_empty():
				continue
			if inside and not members.has(source):
				incoming.append({"from": source, "to": node["id"], "slot": slot})
			elif not inside and members.has(source):
				outgoing.append({"node": node["id"], "slot": slot})
	return {"incoming": incoming, "outgoing": outgoing}


## Copies [param id] with its parameters, placed next to the original. Inputs are
## kept when they are not part of the copy itself, so a chain can be duplicated.
func duplicate_node(id: String) -> String:
	var source := get_node_by_id(id)
	if source.is_empty():
		return ""
	var copy_id := add_node(str(source["type"]))
	var copy := get_node_by_id(copy_id)
	copy["params"] = (source["params"] as Dictionary).duplicate(true)
	copy["position"] = (source.get("position", Vector2.ZERO) as Vector2) + Vector2(40, 40)
	var inputs: Dictionary = (source["inputs"] as Dictionary).duplicate()
	copy["inputs"] = inputs
	return copy_id


## Connects [param from_id]'s output to input [param slot] of [param to_id].
func connect_nodes(from_id: String, to_id: String, slot := 0) -> void:
	var target := get_node_by_id(to_id)
	if target.is_empty() or get_node_by_id(from_id).is_empty():
		return
	if from_id == to_id:
		return
	var inputs: Dictionary = target["inputs"]
	# Adding this edge would make a loop, and the evaluation would never end, if
	# the target already feeds the source.
	if _is_upstream_of(to_id, from_id):
		return
	inputs[slot] = from_id
	target["inputs"] = inputs


func disconnect_input(to_id: String, slot := 0) -> void:
	var target := get_node_by_id(to_id)
	if target.is_empty():
		return
	var inputs: Dictionary = target["inputs"]
	inputs.erase(slot)
	target["inputs"] = inputs


## True when [param candidate] is somewhere above [param id] in the graph.
func _is_upstream_of(candidate: String, id: String) -> bool:
	if candidate == id:
		return true
	var node := get_node_by_id(id)
	if node.is_empty():
		return false
	for upstream: String in node["inputs"].values():
		if _is_upstream_of(candidate, upstream):
			return true
	return false


## Nodes that read [param id], directly or through other nodes. Used to redraw
## only the thumbnails whose picture can have changed.
func downstream_ids(id: String) -> Array[String]:
	var result: Array[String] = []
	var pending: Array[String] = [id]
	var seen := {id: true}
	while not pending.is_empty():
		var current: String = pending.pop_back()
		for node: Dictionary in nodes:
			var node_id := str(node["id"])
			if seen.has(node_id):
				continue
			var inputs: Dictionary = node["inputs"]
			for slot: int in inputs.keys():
				if str(inputs[slot]) == current:
					seen[node_id] = true
					result.append(node_id)
					pending.append(node_id)
					break
	return result


## Ids of the nodes whose picture moves with the clock: the ones that read the
## time or carry an animation, plus everything downstream of them. Branches that
## do not read the clock keep the thumbnail they already have, which is what
## keeps playback cheap and the thumbnails in step with the preview.
func time_dependent_ids() -> Array[String]:
	var seeds: Array[String] = []
	for node: Dictionary in nodes:
		var node_id := str(node["id"])
		var params: Dictionary = node["params"]
		match str(node["type"]):
			"time", "particles":
				seeds.append(node_id)
			"tree":
				if bool(params.get("animate", false)):
					seeds.append(node_id)
			"scatter":
				if float(params.get("sway", 0.0)) > 0.0:
					seeds.append(node_id)
			"pixel_art":
				# A canvas that follows the animation shows another cel per frame.
				if int(params.get("frame_mode", 0)) == 2:
					seeds.append(node_id)
		var anim: Variant = params.get("anim", null)
		if anim is Dictionary and not (anim as Dictionary).is_empty():
			if not seeds.has(node_id):
				seeds.append(node_id)
	var result: Array[String] = []
	for seed in seeds:
		if not result.has(seed):
			result.append(seed)
		for other in downstream_ids(seed):
			if not result.has(other):
				result.append(other)
	return result


## Nodes that feed [param id], directly or not.
func upstream_ids(id: String) -> Array[String]:
	var result: Array[String] = []
	var stack: Array[String] = [id]
	while not stack.is_empty():
		var current: String = stack.pop_back()
		var node := get_node_by_id(current)
		if node.is_empty():
			continue
		for upstream: String in node["inputs"].values():
			if not result.has(upstream):
				result.append(upstream)
				stack.append(upstream)
	return result


func output_node_id() -> String:
	for node: Dictionary in nodes:
		if node["type"] == "output":
			return node["id"]
	return ""


## Ids of the nodes the output actually reads: the output plus everything
## upstream of it. A node parked beside the chain must not change how the picture
## is generated, however heavy or animated it is.
func output_chain_ids() -> Array[String]:
	var output := output_node_id()
	if output.is_empty():
		return []
	# The lookup table is built once so walking the chain stays linear, which
	# matters because the preview asks for it on every generated frame.
	var by_id := {}
	for node: Dictionary in nodes:
		by_id[str(node["id"])] = node
	var chain: Array[String] = [output]
	var stack: Array[String] = [output]
	while not stack.is_empty():
		var current: String = stack.pop_back()
		var node: Dictionary = by_id.get(current, {})
		if node.is_empty():
			continue
		for upstream: String in node["inputs"].values():
			if not chain.has(upstream):
				chain.append(upstream)
				stack.append(upstream)
	return chain


## Label of the second input port of [param type], shown inside the graph node.
static func second_input_label(type: String) -> String:
	return str(SECOND_INPUT_LABELS.get(type, "输入 2"))


## Group of the add menu a type belongs to, or an empty string. The page colours
## the node titles with the accent of their group.
static func group_of_type(type: String) -> String:
	for group: Dictionary in NODE_GROUPS:
		if (group["types"] as Array).has(type):
			return str(group["label"])
	return ""


static func default_params(type: String) -> Dictionary:
	match type:
		"noise":
			return {"noise_type": 0, "scale": 16.0, "octaves": 3, "seed": 1, "gain": 0.5}
		"gradient":
			return {"angle": 0.0, "offset": 0.0}
		"radial":
			return {
				"center_x": 0.5,
				"center_y": 0.5,
				"radius": 0.5,
				"invert": false,
				"falloff": 1.0,
			}
		"checker":
			return {"cell": 8.0}
		"shape":
			return {
				"kind": 0,
				"center_x": 0.5,
				"center_y": 0.5,
				"size": 0.35,
				"angle": 0.0,
				"soft": 0.02,
				"invert": false,
				"points": 5,
				"inner": 0.45,
				"thickness": 0.18,
			}
		"constant":
			return {"value": 0.5}
		"model3d":
			return {
				"shape": 0,
				"yaw": 35.0,
				"pitch": 22.0,
				"zoom": 0.8,
				"perspective": 0.35,
				"light": 135.0,
				"shade": 1.0,
				# Toon lighting, ported from the pixel grass demo: the light is cut
				# into bands, the terminator can be pushed by "wrap" and sharpened
				# by "steepness", and "soft" blends the bands back towards a plain
				# gradient, which is what the demo calls hybrid toon shading.
				"cuts": 3,
				"wrap": 0.0,
				"steepness": 1.2,
				# Zero keeps the hard steps the demo actually draws; raising it
				# pulls the bands back towards a plain gradient.
				"soft": 0.0,
				# Pixel border around the silhouette, in pixels. It is drawn at a
				# value below the darkest band, so the colour ramp of the output
				# paints it with its darkest stop.
				"outline": 1,
			}
		"tree":
			return {
				"seed": 3,
				"growth": 1.0,
				"animate": false,
				"ease": 0.4,
				"lean": 0.0,
				"sway": 0.0,
				"sway_speed": 0.5,
				"depth": 5,
				"branches": 2,
				"spread": 34.0,
				"taper": 0.72,
				"bend": 0.35,
				"width": 0.045,
				"randomness": 0.3,
				"leaves": true,
				"leaf_size": 1.0,
				"soft": 0.0,
			}
		"scatter":
			return {
				"amount": 24,
				# 0 scatters inside a radius, 1 places the brush along a path node
				# connected to the second input, 2 places it on the drawn part of
				# whatever the second input is, so a canvas that grows from a path
				# animates the whole pattern.
				"mode": 0,
				"spread": 0.6,
				"path_width": 0.08,
				"follow_tangent": true,
				"stamp": 0.3,
				# Value the opaque part of the brush is stamped with. The brush
				# only supplies its shape, so this is where the stamps get their
				# brightness.
				"level": 1.0,
				# The colour the stamps are painted in, and the flag that says
				# whether this node owns a colour at all. A colour travels down the
				# chain from here, which is why the output node needs none.
				"tint": false,
				"color": Color(1.0, 1.0, 1.0, 1.0),
				"angle": 0.0,
				"angle_random": 180.0,
				"scale_min": 0.7,
				"scale_max": 1.3,
				"seed": 1,
				"align": true,
				# 0 scatters at random, 1 keeps a minimum distance between the stamps
				# so nothing clumps, 2 lays them on a lattice. Only the lattice
				# replaces the amount, with one stamp per cell.
				"distribution": 0,
				"distance": 0.12,
				"grid_x": 4,
				"grid_y": 4,
				"jitter": 0.35,
				# Whole field shift in canvas units, so one node can be nudged
				# without moving the branch that feeds it.
				"offset_x": 0.0,
				"offset_y": 0.0,
				# How far the brightness of a single stamp may wander, which keeps a
				# patch of leaves from looking painted with one brush.
				"level_random": 0.0,
				# Wind, taken from the pixel grass demo: the stamps lean with a wave
				# that travels along "sway_angle", so neighbours move together the way
				# grass does instead of every stamp twitching on its own.
				"sway": 0.0,
				"sway_speed": 1.0,
				"sway_scale": 1.5,
				"sway_angle": 90.0,
				# Phase of its own per stamp, hashed from where it stands, so the
				# field ripples like the demo's grass instead of leaning in one piece.
				"sway_jitter": 0.0,
				# Something standing in the field. The bright part of the second
				# input shoves the stamps away and tips them over, which is what the
				# demo does with the positions of its characters. Above zero the
				# second input stops acting as a density mask.
				"push": 0.0,
				"push_radius": 0.25,
				# Stamp the lower stamps last, so they cover the higher ones.
				"sort_y": false,
				# Wrap the stamps around the edges, for a pattern that tiles.
				"tile": false,
				# Take the brightness of a stamp from the second input at its
				# position, so a gradient or a drawing lights the scatter.
				"level_from_map": false,
				# Radial shaping: point every stamp at the middle, turn it by its
				# distance, and grow or shrink it with that distance. Together they
				# turn the same field into a burst, a ring or a spiral.
				"point_at_center": false,
				"spin": 0.0,
				"scale_per_radius": 0.0,
			}
		"particles":
			return {
				"seed": 1,
				"count": 48,
				"size": 1.5,
				"spawn": 0,
				"angle": -90.0,
				"spread": 30.0,
				"speed": 0.5,
				"gravity": 0.0,
				"turbulence": 0.0,
				# Sideways drift, which bends rain and makes leaves travel on the wind.
				"wind": 0.0,
				# How much of its own life a particle drags behind it, so a dot
				# becomes a streak. Purely visual: nothing is simulated.
				"trail": 0.0,
				"lifetime": 0.8,
				"fade": true,
				"twinkle": 0.0,
				"shape": 0,
				"soft": 0.0,
				# How fast and how big a particle ends up compared to its birth, so a
				# spark can slow down and shrink while smoke speeds up and grows.
				"speed_end": 1.0,
				"size_end": 1.0,
				# Each particle keeps its own size and brightness, which is what
				# makes a field of sparks look lit instead of printed.
				"size_random": 0.0,
				"level_random": 0.0,
				# The colour this node paints its particles in, the same way a
				# scatter carries one.
				"tint": false,
				"color": Color(1.0, 1.0, 1.0, 1.0),
			}
		"path":
			return {
				"points":
				[
					{
						"point": Vector2(0.2, 0.75),
						"in": Vector2.ZERO,
						"out": Vector2(0.1, -0.15),
					},
					{
						"point": Vector2(0.5, 0.3),
						"in": Vector2(-0.12, 0.12),
						"out": Vector2(0.12, -0.12),
					},
					{
						"point": Vector2(0.8, 0.75),
						"in": Vector2(-0.1, -0.15),
						"out": Vector2.ZERO,
					},
				],
				"closed": false,
				# How much of the path is drawn. Animating this grows the stroke
				# along the curve, which is what a vine or a lightning needs.
				"reveal": 1.0,
				# Grows from the far end instead of the first control point.
				"reveal_reverse": false,
			}
		"pixel_art":
			return {
				# 0 reads a frame of a layer, 1 draws the path connected to input 1,
				# 2 uses the picture painted in the node's own window. That painting
				# is a PNG in the graph itself, so it belongs to the project and
				# never writes into a layer.
				"source": 0,
				"painting": "",
				"layer": 0,
				"frame_mode": 0,
				"frame": 0,
				"channel": 0,
				"invert": false,
				# Stroke used in path mode. The profile is a curve from the start
				# of the path to its end, and it picks the width between the
				# thinnest and the thickest part of the line.
				"width_min": 0.0,
				"width_max": 0.06,
				"soft": 0.0,
				"fill": false,
				"profile": [1.0, 1.0, 1.0, 1.0, 1.0],
				# Cropped rectangle in layer pixels. A width or height of 0 means
				# "up to the edge", so an untouched node reads the whole layer.
				"crop_x": 0,
				"crop_y": 0,
				"crop_w": 0,
				"crop_h": 0,
			}
		"time":
			# "steps" is the stepped framerate of the pixel grass demo: the phase
			# is held on one of that many positions instead of moving smoothly.
			return {"speed": 1.0, "offset": 0.0, "steps": 0}
		"wave":
			return {"frequency": 2.0, "angle": 0.0, "amplitude": 1.0}
		"transform":
			return {
				"angle": 0.0,
				"scale": 1.0,
				"offset_x": 0.0,
				"offset_y": 0.0,
				"tile": false,
				"position_x": 0.0,
				"position_y": 0.0,
				"round": false,
				"alpha": 1.0,
			}
		"scale":
			return {
				"scale_x": 1.0,
				"scale_y": 1.0,
				"tile": false,
				"mode": 0,
				"target_x": 32.0,
				"target_y": 32.0,
				"fit": 0,
			}
		"flip":
			return {"axis": 0}
		"skew":
			return {"angle_x": 0.0, "angle_y": 0.0}
		"tile":
			return {"count_x": 2.0, "count_y": 2.0, "offset_x": 0.0, "offset_y": 0.0}
		"polar":
			return {"mode": 0, "repeat": 2.0, "twist": 0.0}
		"crop":
			return {"left": 0.0, "top": 0.0, "right": 1.0, "bottom": 1.0, "aspect": 0.0}
		"padding":
			return {"amount": 0.15, "align_x": 0.5, "align_y": 0.5}
		"echo":
			return {
				"count": 4,
				"angle": 90.0,
				"distance": 0.2,
				"mode": 0,
				"animated": false,
				"frame_step": 0.05,
			}
		"follow_path":
			return {
				"shape": 0,
				"radius": 0.3,
				"loops": 1.0,
				"phase": 0.0,
				"points":
				[
					Vector2(0.3, 0.3),
					Vector2(0.7, 0.3),
					Vector2(0.7, 0.7),
					Vector2(0.3, 0.7),
				],
			}
		"mesh_warp":
			return {
				"tl_x": 0.0,
				"tl_y": 0.0,
				"tr_x": 0.0,
				"tr_y": 0.0,
				"bl_x": 0.0,
				"bl_y": 0.0,
				"br_x": 0.0,
				"br_y": 0.0,
				"randomness": 0.0,
			}
		"bend":
			return {
				"type": 1,
				"axis": 0,
				"amount": 0.1,
				"scale": 1.0,
				"shift": 0.0,
				"uv_scale": 1.0,
				"uv_shift": 0.0,
			}
		"stretch":
			return {"angle": 0.0, "amount": 0.3, "inverse": true}
		"mirror":
			return {"angle": 0.0, "position": 0.5, "flip_side": false}
		"area_warp":
			return {"center_x": 0.5, "center_y": 0.5, "radius": 0.35, "amount": 0.2}
		"nine_slice":
			return {"border": 0.2, "scale": 1.5}
		"crop_content":
			return {"threshold": 0.02, "margin": 0.0}
		"kaleidoscope":
			return {"segments": 6.0, "angle": 0.0, "mirror": true}
		"blur":
			return {"size": 1.5, "angle": 0.0, "aspect": 1.0, "mix": 1.0}
		"outline":
			return {"position": 0, "width": 1.0, "threshold": 0.5}
		"glow":
			return {"size": 3.0, "strength": 1.5, "tolerance": 0.35}
		"bloom":
			return {"size": 3.0, "strength": 1.0, "tolerance": 0.5}
		"levels":
			# The input range is stretched onto the output range, with gamma on the
			# middle, which is the classic level adjustment.
			return {
				"black": 0.0,
				"white": 1.0,
				"gamma": 1.0,
				"out_black": 0.0,
				"out_white": 1.0,
			}
		"threshold":
			# Above the cut is solid, below is empty. The soft edge keeps the border
			# readable instead of a staircase, which matters for masks.
			return {"cut": 0.5, "soft": 0.0, "invert": false}
		"normalize":
			# Stretch the range the branch really uses over the whole range, the way
			# an auto level does. Low and high pick how much of that range to keep.
			return {"low": 0.0, "high": 1.0}
		"curve":
			# Five output values for five evenly spaced inputs. A straight line is
			# the identity, so a fresh node changes nothing until a point is moved.
			return {"curve": [0.0, 0.25, 0.5, 0.75, 1.0]}
		"band":
			# Picks the values inside a range, which is how a mask is cut out of a
			# brightness field: mid tones, highlights, a slice of a gradient.
			return {"low": 0.3, "high": 0.7, "soft": 0.05, "invert": false}
		"color_adjust":
			return {
				"brightness": 0.0,
				"contrast": 0.0,
				"exposure": 0.0,
				"gamma": 1.0,
				"value": 1.0,
				"invert": false,
				"mix": 1.0,
			}
		"edge":
			return {"radius": 1.0, "gain": 3.0, "invert": false}
		"dither":
			return {"matrix": 1, "strength": 0.5}
		"pixelate":
			return {"size": 4.0}
		"erode":
			return {"mode": 0, "radius": 1.0, "shape": 0, "mix": 1.0}
		"warp":
			return {"amount": 0.15}
		"math":
			return {"op": 0, "amount": 0.5, "steps": 4}
		"blend":
			return {"op": 0, "factor": 0.5}
		# The output only closes the graph: it says how the artwork meets the layer,
		# a solid block or an overlay with transparency. Colour is not decided here,
		# the node that paints a pixel carries it down the chain.
		"output":
			return {"transparent": false, "alpha_cut": 0.0, "alpha_from_value": false}
	return {}


## Generates the image of the graph. [param size] is in pixels.
func generate(size: Vector2i) -> Image:
	var state := _begin_generation(size)
	if not bool(state.get("done", false)):
		_paint_rows(state, 0, int((state["size"] as Vector2i).y))
	return state["image"]


## Same picture as [method generate], painted a few rows at a time. The interface
## keeps answering while a heavy graph is previewed, which is what makes editing
## and panning usable during playback. [param slice_msec] bounds how long one
## slice may run before the frame is handed back to the engine.
func generate_sliced(size: Vector2i, slice_msec := 16.0) -> Image:
	var state := _begin_generation(size)
	if bool(state.get("done", false)):
		return state["image"]
	var height: int = int((state["size"] as Vector2i).y)
	var tree := Engine.get_main_loop() as SceneTree
	while int(state["row"]) < height:
		var start := Time.get_ticks_usec()
		var row: int = int(state["row"])
		var batch: int = maxi(int(state.get("batch", 1)), 1)
		var end_row: int = mini(row + batch, height)
		_paint_rows(state, row, end_row)
		state["row"] = end_row
		# The band is grown while it stays cheap and halved when a slice runs long,
		# so a light graph is not painted one row at a time and a heavy one still
		# hands the frame back. Wide bands are also what makes the rows worth
		# spreading over the cores.
		var spent := float(Time.get_ticks_usec() - start) / 1000.0
		if spent > slice_msec:
			batch = maxi(int(floorf(float(batch) * 0.5)), 1)
		elif spent < slice_msec * 0.4:
			batch = mini(batch * 2, maxi(int(floorf(float(height) * 0.5)), 1))
		state["batch"] = batch
		if int(state["row"]) < height and tree != null:
			await tree.process_frame
	return state["image"]


## Clears the per frame caches and captures the output node settings, so the
## synchronous and the sliced generation share the same preparation.
func _begin_generation(size: Vector2i) -> Dictionary:
	size = Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	_bounds_cache.clear()
	_source_cache.clear()
	# A graph that reads the project can see the artwork change underneath it
	# without any parameter moving, so its rasters belong to this generation only.
	if uses_source():
		_source_generation += 1
	# Resolved once per frame, so an animated parameter costs a lookup per pixel.
	_resolve_animations()
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	var output_id := output_node_id()
	if output_id.is_empty():
		image.fill(Color(0, 0, 0, 0))
		return {"image": image, "size": size, "done": true}
	var output := get_node_by_id(output_id)
	var output_params: Dictionary = params_for(output)
	var source := _input_id(output, 0)
	# Old graphs decided the colour at the output, so a ramp saved there is still
	# honoured. New ones carry the colour on the node that paints it, and the whole
	# picture is that colour where that node is the one feeding the output.
	var legacy := output_params.has("color_a") and output_params.has("color_b")
	var color_a: Color = output_params.get("color_a", Color.WHITE)
	# A node that draws its picture once per generation is walked byte by byte
	# instead of through the evaluator, which cuts the cost of a particle or
	# scatter field to the price of reading its bytes.
	var field := _raster_field(source, size)
	var field_data := PackedByteArray()
	if field != null:
		field_data = field.get_data()
	return {
		"image": image,
		"size": size,
		"done": false,
		"row": 0,
		"batch": 1,
		"source": source,
		"field_data": field_data,
		"tint": source_colour(source),
		"ramp": legacy,
		"steps": maxi(int(output_params.get("steps", 2)), 2),
		"color_a": color_a,
		"color_mid": output_params.get("color_mid", color_a),
		"color_b": output_params.get("color_b", color_a),
		"mid_position": clampf(float(output_params.get("mid_position", 0.5)), 0.05, 0.95),
		# A transparent background turns the layer into an overlay instead of a
		# full rectangle, which is what particles and glows need.
		"transparent": bool(output_params.get("transparent", false)),
		"alpha_cut": clampf(float(output_params.get("alpha_cut", 0.0)), 0.0, 1.0),
		"alpha_from_value": bool(output_params.get("alpha_from_value", false)),
	}


## Paints rows [param from_row] to [param to_row] of a generation, spreading a
## wide band over the cores. Every band draws into its own image, so no two
## threads ever write into the same buffer.
func _paint_rows(state: Dictionary, from_row: int, to_row: int) -> void:
	var size: Vector2i = state["size"]
	var threads := _paint_threads()
	var rows := to_row - from_row
	if threads > 1 and rows >= PARALLEL_MIN_ROWS and size.x * rows >= PARALLEL_MIN_PIXELS:
		_paint_rows_parallel(state, from_row, to_row, threads)
		return
	_paint_into(state, state["image"], 0, from_row, to_row)


## How many worker threads a picture may use on this machine.
func _paint_threads() -> int:
	if not _parallel_safe:
		return 1
	if paint_threads > 0:
		return mini(paint_threads, PARALLEL_MAX_THREADS)
	# One thread is left for the interface on a two core machine; a big desktop
	# stops at [constant PARALLEL_MAX_THREADS].
	return clampi(OS.get_processor_count() - 1, 1, PARALLEL_MAX_THREADS)


## Evaluates every node once, so anything the evaluator fills the first time it
## visits a node is filled before the worker threads start reading. Without this
## the threads would race on the raster and noise caches, and a cache the
## interface dropped between two slices would be rebuilt from several threads at
## once; with it the paint loop only reads.
func _warm_caches(size: Vector2i) -> void:
	var probe := Vector2(0.5, 0.5)
	# Only the chain the output reads is painted, so only those caches have to be
	# filled before the workers start. A node beside the chain is not visited.
	for node_id in output_chain_ids():
		var node := get_node_by_id(node_id)
		if node.is_empty():
			continue
		# A noise field is sampled for the whole picture at once, and this is the
		# main thread: building it here is what keeps the workers off that cache.
		if str(node["type"]) == "noise":
			_noise_field(node_id, params_for(node), size)
		_eval(node_id, probe, size, 0)


## Paints the band in [param band] into its own image and hands it back under the
## mutex, which is the only shared state the threads touch.
func _paint_band(
	state: Dictionary, band: int, bands: Array, results: Array, mutex: Mutex
) -> void:
	var pair: Array = bands[band]
	var from_row: int = int(pair[0])
	var to_row: int = int(pair[1])
	var size: Vector2i = state["size"]
	var band_image := Image.create_empty(size.x, to_row - from_row, false, Image.FORMAT_RGBA8)
	_paint_into(state, band_image, from_row, from_row, to_row)
	mutex.lock()
	results[band] = band_image
	mutex.unlock()


## Splits rows [param from_row] to [param to_row] over [param threads] workers and
## joins the bands into the picture once they are all done.
func _paint_rows_parallel(
	state: Dictionary, from_row: int, to_row: int, threads: int
) -> void:
	var size: Vector2i = state["size"]
	_warm_caches(size)
	var rows := to_row - from_row
	var count: int = mini(threads, rows)
	var step: int = int(ceilf(float(rows) / float(count)))
	var bands: Array = []
	var start := from_row
	while start < to_row:
		bands.append([start, mini(start + step, to_row)])
		start += step
	count = bands.size()
	var results: Array = []
	results.resize(count)
	var mutex := Mutex.new()
	var group := WorkerThreadPool.add_group_task(
		func(band: int) -> void: _paint_band(state, band, bands, results, mutex),
		count,
		count,
		false,
		"shader composer rows"
	)
	WorkerThreadPool.wait_for_group_task_completion(group)
	var target: Image = state["image"]
	for index in count:
		var band_image: Variant = results[index]
		if not (band_image is Image):
			continue
		var pair: Array = bands[index]
		var band_rows: int = int(pair[1]) - int(pair[0])
		target.blit_rect(
			band_image, Rect2i(0, 0, size.x, band_rows), Vector2i(0, int(pair[0]))
		)


## Paints rows [param from_row] to [param to_row] into [param image], whose first
## row corresponds to row [param offset] of the generation.
func _paint_into(
	state: Dictionary, image: Image, offset: int, from_row: int, to_row: int
) -> void:
	var size: Vector2i = state["size"]
	var source: String = state["source"]
	var tint: Variant = state["tint"]
	var use_ramp: bool = state["ramp"]
	var steps: int = state["steps"]
	var color_a: Color = state["color_a"]
	var color_mid: Color = state["color_mid"]
	var color_b: Color = state["color_b"]
	var mid_position: float = state["mid_position"]
	var transparent: bool = state["transparent"]
	var alpha_cut: float = state["alpha_cut"]
	var alpha_from_value: bool = state["alpha_from_value"]
	# When the branch is one picture that was already drawn at this size, its
	# bytes are the values: 255 steps, exactly what reading the pixel back gives.
	var field_data: PackedByteArray = state.get("field_data", PackedByteArray())
	var has_field := not field_data.is_empty()
	var row_bytes: int = size.x * 4
	for y in range(from_row, to_row):
		var row_start: int = y * row_bytes
		for x in size.x:
			var pixel := Color(0.0, 0.0, 0.0, 0.0)
			var value: float
			if has_field:
				pixel = _field_pixel(field_data, row_start + x * 4)
				# A picture is not one channel: reading red made a red leaf dark
				# and a grey one bright, so coverage is the brightest channel.
				value = maxf(maxf(pixel.r, pixel.g), pixel.b)
			else:
				value = clampf(_eval(source, Vector2(x, y), size, 0), 0.0, 1.0)
			if transparent and value <= alpha_cut:
				image.set_pixel(x, y - offset, Color(0.0, 0.0, 0.0, 0.0))
				continue
			var color: Color
			if tint == null:
				if has_field:
					# The node drew this picture itself, colours and transparency
					# included. Drawing it in grey was throwing them away.
					color = pixel
				elif use_ramp:
					# Graphs saved before the colour moved into the nodes keep
					# their three stop ramp, so old artwork still looks the same.
					var step := floori(value * steps)
					var ramp := clampf(float(step) / float(steps - 1), 0.0, 1.0)
					color = _ramp_color(color_a, color_mid, color_b, mid_position, ramp)
				else:
					color = Color(value, value, value, 1.0)
			else:
				# The colour of the branch, darkened by how much the pixel covers,
				# which is what keeps soft edges and glows readable.
				var base: Color = tint
				color = Color(base.r * value, base.g * value, base.b * value, 1.0)
				if has_field:
					color.a = pixel.a
			if transparent and alpha_from_value and tint != null:
				color.a = value
			image.set_pixel(x, y - offset, color)


## One RGBA pixel out of a raster field's byte block.
static func _field_pixel(data: PackedByteArray, at: int) -> Color:
	if at < 0 or at + 3 >= data.size():
		return Color(0.0, 0.0, 0.0, 0.0)
	return Color(
		float(data[at]) / 255.0,
		float(data[at + 1]) / 255.0,
		float(data[at + 2]) / 255.0,
		float(data[at + 3]) / 255.0
	)


## Colour a branch carries, or null when it carries none. A node that owns a
## colour hands it to everything downstream, so the output node needs no colour
## settings of its own. A blend mixes the colours of both of its branches.
func source_colour(node_id: String) -> Variant:
	return _colour_of(node_id, 0)


func _colour_of(node_id: String, depth: int) -> Variant:
	if node_id.is_empty() or depth > 32:
		return null
	var node := get_node_by_id(node_id)
	if node.is_empty():
		return null
	var params: Dictionary = params_for(node)
	# A blend never owns a colour. It only decides how the two colours it is given
	# combine, with the same factor it blends the values with, so a colour set on
	# the branch in front of it always comes through.
	if str(node["type"]) == "blend":
		var from_a: Variant = _colour_of(_input_id(node, 0), depth + 1)
		var from_b: Variant = _colour_of(_input_id(node, 1), depth + 1)
		if from_a == null:
			return from_b
		if from_b == null:
			return from_a
		return (from_a as Color).lerp(from_b as Color, clampf(float(params.get("factor", 0.5)), 0.0, 1.0))
	var own: Variant = own_colour(params)
	if own != null:
		return own
	if own_colour_stops(node, params):
		# Reading a canvas through its transparency gives coverage, not a picture,
		# so a colour does not travel through it.
		return null
	return _colour_of(_input_id(node, 0), depth + 1)


## Colour a node declares for itself, or null. Any node can carry one, which is
## what lets a scatter paint its stamps green without a colour on the output.
static func own_colour(params: Dictionary) -> Variant:
	if not params.has("color") or not bool(params.get("tint", false)):
		return null
	return params["color"]


## True when a node turns its input into coverage, which is not a picture, so no
## colour passes through it.
static func own_colour_stops(node: Dictionary, params: Dictionary) -> bool:
	if str(node["type"]) != "pixel_art":
		return false
	if int(params.get("source", 0)) == 1:
		return false
	return int(params.get("channel", 0)) != 0


static func _ramp_color(a: Color, mid: Color, b: Color, mid_position: float, t: float) -> Color:
	if t <= mid_position:
		return a.lerp(mid, t / mid_position)
	return mid.lerp(b, (t - mid_position) / (1.0 - mid_position))


## Rebuilds [member _live_params] for the current [member time]. Any numeric
## parameter of any node can be animated, which is what turns growth, masks and
## warps into an animation the user controls instead of a fixed behaviour that
## only some nodes support.
func _resolve_animations() -> void:
	_live_params.clear()
	_eval_nodes.clear()
	_field_cache.clear()
	_noise_checked.clear()
	# The keys and the signatures are rebuilt for every frame, the rasters they
	# point at are not: a stroke whose node, inputs and time did not change keeps
	# the image it already has, so dragging one slider no longer redraws every
	# other node of the graph.
	_raster_keys.clear()
	_raster_sigs.clear()
	_parallel_safe = true
	# An echo that walks the clock back moves [member time] while it samples, so a
	# graph whose picture holds one is painted on the main thread only. Only the
	# chain the output reads counts: an animated echo parked beside it does not
	# reach the picture, so it must not slow the picture down either.
	for chain_id in output_chain_ids():
		var chain_node := get_node_by_id(chain_id)
		if chain_node.is_empty():
			continue
		if (
			str(chain_node["type"]) == "echo"
			and bool(chain_node["params"].get("animated", false))
		):
			_parallel_safe = false
			break
	for node: Dictionary in nodes:
		var node_id := str(node["id"])
		var params: Dictionary = node["params"]
		var anim: Variant = params.get("anim", null)
		if anim is Dictionary:
			var setting: Dictionary = anim
			var key := str(setting.get("param", ""))
			if not key.is_empty() and params.has(key):
				var base: Variant = params[key]
				if typeof(base) == TYPE_FLOAT or typeof(base) == TYPE_INT:
					var live := params.duplicate()
					live[key] = animate_value(setting, float(base))
					params = live
					_live_params[node_id] = live
		# Node and parameters live in the same entry, so the pixel loop needs one
		# lookup instead of one for the node and another for the animation.
		_eval_nodes[node_id] = [node, params]


## Parameters of [param node] for the current frame, with the animated value
## applied when the node animates one of them. Nodes without animation hand
## their own dictionary back, so this stays a single lookup.
func params_for(node: Dictionary) -> Dictionary:
	return _live_params.get(str(node["id"]), node["params"])


## True when [param params] animate [param key]. Lets a node tell a user made
## animation apart from a clock it used to drive on its own.
static func _animates(params: Dictionary, key: String) -> bool:
	var anim: Variant = params.get("anim", null)
	return anim is Dictionary and str((anim as Dictionary).get("param", "")) == key


## Value of one animation block at the current time. The clock is mapped into
## the start..end window, eased, then used to blend between the two values, so
## every parameter shares the same timing controls.
func animate_value(anim: Dictionary, base: float) -> float:
	var from_value := float(anim.get("from", base))
	var to_value := float(anim.get("to", base))
	var start := clampf(float(anim.get("start", 0.0)), 0.0, 1.0)
	var finish := clampf(float(anim.get("end", 1.0)), 0.0, 1.0)
	var span := maxf(finish - start, 0.0001)
	var t := (time - start) / span
	match int(anim.get("mode", 0)):
		1:  # 循环
			t = fposmod(t, 1.0)
		2:  # 往返
			t = 1.0 - absf(fposmod(t * 2.0, 2.0) - 1.0)
		_:
			t = clampf(t, 0.0, 1.0)
	var eased := t * t * (3.0 - 2.0 * t)
	t = lerpf(t, eased, clampf(float(anim.get("ease", 0.4)), 0.0, 1.0))
	return lerpf(from_value, to_value, t)


func _input_id(node: Dictionary, slot: int) -> String:
	var inputs: Dictionary = node["inputs"]
	return str(inputs.get(slot, ""))


## Value of [param node_id] at the pixel (or the mapped canvas position) [param uv].
func _eval(node_id: String, uv: Vector2, size: Vector2i, depth: int) -> float:
	if node_id.is_empty() or depth > 32:
		return 0.0
	var entry: Variant = _eval_nodes.get(node_id, null)
	var node: Dictionary
	var params: Dictionary
	if entry == null:
		# A call from outside the regular generation path falls back to the
		# linear search, so scripting and tests still work.
		node = get_node_by_id(node_id)
		if node.is_empty():
			return 0.0
		params = params_for(node)
	else:
		node = entry[0]
		params = entry[1]
	if bool(node.get("bypass", false)):
		# A bypassed node hands its first input straight through, which is how a
		# step gets switched off without rewiring the graph.
		var passthrough := _input_id(node, 0)
		if passthrough.is_empty():
			return 0.0
		return _eval(passthrough, uv, size, depth + 1)
	var size_vec := Vector2(size)
	var normalized := uv / size_vec
	var node_type := str(node["type"])
	if node_type == "output":
		return clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
	elif node_type == "math":
		var source := clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
		return _math_value(int(params["op"]), source, params)
	elif node_type == "blend":
		var a := clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
		var b := clampf(_eval(_input_id(node, 1), uv, size, depth + 1), 0.0, 1.0)
		var factor := clampf(float(params["factor"]), 0.0, 1.0)
		var blend_op := int(params["op"])
		if blend_op == 0:  # Mix
			return lerpf(a, b, factor)
		# Index comparisons instead of a string match: this runs for every pixel.
		var blended := b
		if blend_op == 1:  # Add
			blended = a + b
		elif blend_op == 2:  # Multiply
			blended = a * b
		elif blend_op == 3:  # Screen
			blended = 1.0 - (1.0 - a) * (1.0 - b)
		elif blend_op == 4:  # Difference
			blended = absf(a - b)
		return clampf(lerpf(a, blended, factor), 0.0, 1.0)
	elif node_type == "noise":
		return _noise_at(node_id, params, size, uv)
	elif node_type == "gradient":
		var direction := Vector2.from_angle(deg_to_rad(float(params["angle"])))
		var shift := float(params.get("offset", 0.0))
		return clampf(
			0.5 + (normalized - Vector2(0.5, 0.5)).dot(direction) * 1.414 + shift, 0.0, 1.0
		)
	elif node_type == "path":
		# The stroke is rasterised once per generated image, so this is a lookup.
		if uv.x < 0.0 or uv.y < 0.0 or uv.x >= float(size.x) or uv.y >= float(size.y):
			return 0.0
		return _path_image(node, params, size).get_pixel(int(uv.x), int(uv.y)).r
	elif node_type == "tree":
		# Rasterised once per generated image, so this is a lookup like a path.
		if uv.x < 0.0 or uv.y < 0.0 or uv.x >= float(size.x) or uv.y >= float(size.y):
			return 0.0
		return _tree_image(node, params, size).get_pixel(int(uv.x), int(uv.y)).r
	elif node_type == "particles":
		if uv.x < 0.0 or uv.y < 0.0 or uv.x >= float(size.x) or uv.y >= float(size.y):
			return 0.0
		return _particles_image(node, params, size).get_pixel(int(uv.x), int(uv.y)).r
	elif node_type == "scatter":
		# Rasterised once per generated image, so this is a lookup like a path.
		if uv.x < 0.0 or uv.y < 0.0 or uv.x >= float(size.x) or uv.y >= float(size.y):
			return 0.0
		return _scatter_image(node, params, size, depth).get_pixel(int(uv.x), int(uv.y)).r
	elif node_type == "model3d":
		# Rasterised once per generated image, so this is a lookup like a path.
		if uv.x < 0.0 or uv.y < 0.0 or uv.x >= float(size.x) or uv.y >= float(size.y):
			return 0.0
		return _model_image(node, params, size).get_pixel(int(uv.x), int(uv.y)).r
	elif node_type == "constant":
		return clampf(float(params.get("value", 0.5)), 0.0, 1.0)
	elif node_type == "shape":
		# Every primitive is a distance to its border, so one softness setting
		# works for all of them and the edges stay anti aliased.
		var shape_center := Vector2(
			float(params.get("center_x", 0.5)), float(params.get("center_y", 0.5))
		)
		var shape_size := maxf(float(params.get("size", 0.35)), 0.01)
		var shape_offset := (normalized - shape_center) / shape_size
		shape_offset = shape_offset.rotated(-deg_to_rad(float(params.get("angle", 0.0))))
		var shape_distance := 0.0
		match int(params.get("kind", 0)):
			1:  # 方形
				shape_distance = maxf(absf(shape_offset.x), absf(shape_offset.y)) - 1.0
			2:  # 三角形（尖角朝上）
				shape_distance = _polygon_distance(shape_offset.rotated(PI * 0.5), 3)
			3:  # 菱形
				shape_distance = absf(shape_offset.x) + absf(shape_offset.y) - 1.0
			4:  # 星形
				shape_distance = shape_offset.length() - _star_radius(
					shape_offset,
					int(params.get("points", 5)),
					float(params.get("inner", 0.45))
				)
			5:  # 圆环
				shape_distance = (
					absf(shape_offset.length() - 1.0)
					- maxf(float(params.get("thickness", 0.18)), 0.01)
				)
			_:
				shape_distance = shape_offset.length() - 1.0
		var shape_soft := maxf(float(params.get("soft", 0.02)), 0.0005)
		var shape_value := clampf(0.5 - shape_distance / (shape_soft * 2.0), 0.0, 1.0)
		return 1.0 - shape_value if bool(params.get("invert", false)) else shape_value
	elif node_type == "wave":
		var phase := clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
		var travel := Vector2.from_angle(deg_to_rad(float(params["angle"])))
		var wave := 0.5 + 0.5 * sin(
			TAU * (normalized.dot(travel) * float(params["frequency"]) + phase)
		)
		return lerpf(0.5, wave, clampf(float(params["amplitude"]), 0.0, 1.0))
	elif node_type == "transform":
		# Maps the canvas position before the input is sampled, so any branch
		# can be scaled, rotated, moved or tiled.
		var pivot := size_vec * 0.5
		var mapped := (uv - pivot).rotated(deg_to_rad(float(params["angle"])))
		mapped /= maxf(float(params["scale"]), 0.01)
		mapped += pivot
		mapped += (
			Vector2(float(params["offset_x"]), float(params["offset_y"])) * size_vec
		)
		# Position moves the content, so the sampling point moves the other way.
		mapped -= (
			Vector2(
				float(params.get("position_x", 0.0)),
				float(params.get("position_y", 0.0))
			)
			* size_vec
		)
		# cos(90°) is not exactly zero, so a quarter turn leaves a ~1e-16 wobble
		# that flips pixels sitting on a color step. Snapping far below a pixel
		# removes the wobble without touching the visible result.
		mapped = mapped.snapped(Vector2(SNAP_STEP, SNAP_STEP))
		if bool(params.get("round", false)):
			mapped = mapped.round()
		if bool(params.get("tile", false)):
			mapped = Vector2(fposmod(mapped.x, size_vec.x), fposmod(mapped.y, size_vec.y))
		var transformed := clampf(
			_eval(_input_id(node, 0), mapped, size, depth + 1), 0.0, 1.0
		)
		# There is no alpha channel in a value graph, so this fades towards the
		# darkest colour of the ramp instead.
		return transformed * clampf(float(params.get("alpha", 1.0)), 0.0, 1.0)
	elif node_type == "pixel_art":
		# The canvas node either reads the drawing area or draws its path input.
		match int(params.get("source", 0)):
			1:
				return _canvas_path_value(node, params, uv, size, depth)
			2:
				return _painting_value(node, params, uv, size)
		return _source_value(node, params, uv, size)
	elif node_type == "time":
		# Loops of the animation and a per node offset, so several time driven
		# parts of a graph can run out of phase.
		var loops := maxf(float(params.get("speed", 1.0)), 0.0)
		var phase := fposmod(time * loops + float(params.get("offset", 0.0)), 1.0)
		# Stepped clock, the way the pixel grass demo quantises its time: a hand
		# drawn look comes from the picture holding still for a few frames instead
		# of sliding smoothly. Zero leaves the clock as it is.
		var steps := clampi(int(params.get("steps", 0)), 0, 60)
		if steps > 0:
			phase = floorf(phase * float(steps)) / float(steps)
		return phase
	elif node_type == "radial":
		var center := Vector2(float(params["center_x"]), float(params["center_y"]))
		var distance := (normalized - center).length()
		var value := clampf(1.0 - distance / maxf(float(params["radius"]), 0.001), 0.0, 1.0)
		value = pow(value, maxf(float(params.get("falloff", 1.0)), 0.05))
		return 1.0 - value if bool(params["invert"]) else value
	elif node_type == "checker":
		var cell := maxf(float(params["cell"]), 1.0)
		var odd := (floori(uv.x / cell) + floori(uv.y / cell)) % 2
		return 1.0 if odd == 1 else 0.0
	elif node_type == "scale":
		# Separate axes, and a negative factor mirrors that axis.
		var scale_x := float(params["scale_x"])
		var scale_y := float(params["scale_y"])
		if int(params.get("mode", 0)) == 1:
			# Scale to size: a target sized image is fitted into the canvas.
			var target := Vector2(
				maxf(float(params.get("target_x", 32.0)), 1.0),
				maxf(float(params.get("target_y", 32.0)), 1.0)
			)
			var fitted := size_vec / target
			match int(params.get("fit", 0)):
				1:
					fitted = Vector2.ONE * minf(fitted.x, fitted.y)
				2:
					fitted = Vector2.ONE * maxf(fitted.x, fitted.y)
			scale_x = fitted.x
			scale_y = fitted.y
		var scale_mapped := Vector2(
			_scale_axis(uv.x, size_vec.x, scale_x),
			_scale_axis(uv.y, size_vec.y, scale_y)
		)
		var scale_wrap := bool(params.get("tile", false))
		return _sample(node, 0, scale_mapped, size, depth, scale_wrap, scale_wrap)
	elif node_type == "flip":
		var flip_axis := int(params.get("axis", -1))
		var flip_horizontal := bool(params.get("horizontal", false))
		var flip_vertical := bool(params.get("vertical", false))
		if flip_axis >= 0:
			flip_horizontal = flip_axis == 0 or flip_axis == 2
			flip_vertical = flip_axis == 1 or flip_axis == 2
		var flip_mapped := uv
		if flip_horizontal:
			flip_mapped.x = size_vec.x - 1.0 - flip_mapped.x
		if flip_vertical:
			flip_mapped.y = size_vec.y - 1.0 - flip_mapped.y
		return clampf(_eval(_input_id(node, 0), flip_mapped, size, depth + 1), 0.0, 1.0)
	elif node_type == "skew":
		# Shearing around the centre, so the content stays roughly in place.
		var skew_pivot := size_vec * 0.5
		var shear := Vector2(
			tan(deg_to_rad(clampf(float(params["angle_x"]), -80.0, 80.0))),
			tan(deg_to_rad(clampf(float(params["angle_y"]), -80.0, 80.0)))
		)
		var skew_delta := uv - skew_pivot
		var skew_mapped := Vector2(
			uv.x + skew_delta.y * shear.x, uv.y + skew_delta.x * shear.y
		)
		return _sample(
			node, 0, skew_mapped.snapped(Vector2(SNAP_STEP, SNAP_STEP)), size, depth
		)
	elif node_type == "tile":
		var tile_count := Vector2(
			maxf(float(params["count_x"]), 1.0), maxf(float(params["count_y"]), 1.0)
		)
		var tile_shift := (
			Vector2(float(params["offset_x"]), float(params["offset_y"])) * size_vec
		)
		return _sample(node, 0, uv * tile_count + tile_shift, size, depth, true, true)
	elif node_type == "polar":
		var polar_repeat := maxf(float(params["repeat"]), 1.0)
		var polar_twist := float(params.get("twist", 0.0))
		var polar_half := minf(size_vec.x, size_vec.y) * 0.5
		if int(params["mode"]) == 0:
			# Rectangle to polar: the angle becomes the X axis, the radius the Y.
			var polar_delta := uv - size_vec * 0.5
			var polar_angle := atan2(polar_delta.y, polar_delta.x) / TAU + 0.5 + polar_twist
			var polar_radius := polar_delta.length() / maxf(polar_half, 0.001)
			var polar_mapped := Vector2(
				polar_angle * polar_repeat * size_vec.x, polar_radius * size_vec.y
			)
			return _sample(node, 0, polar_mapped, size, depth, true, false)
		# Polar to rectangle: X is the angle again and Y the distance to the centre.
		var unwrap_angle := (uv.x / size_vec.x) * TAU * polar_repeat + polar_twist * TAU
		var unwrap_radius := (uv.y / size_vec.y) * polar_half
		var unwrap_mapped := (
			size_vec * 0.5
			+ Vector2(cos(unwrap_angle), sin(unwrap_angle)) * unwrap_radius
		)
		return _sample(node, 0, unwrap_mapped, size, depth)
	elif node_type == "crop":
		# Everything outside the rectangle is empty, which frames the branch.
		var crop_left := float(params["left"]) * size_vec.x
		var crop_top := float(params["top"]) * size_vec.y
		var crop_right := float(params["right"]) * size_vec.x
		var crop_bottom := float(params["bottom"]) * size_vec.y
		var crop_aspect := float(params.get("aspect", 0.0))
		if crop_aspect > 0.001 and crop_right > crop_left and crop_bottom > crop_top:
			# Locking the aspect ratio adjusts the shorter side around the centre.
			var crop_center := Vector2(
				(crop_left + crop_right) * 0.5, (crop_top + crop_bottom) * 0.5
			)
			var crop_width := crop_right - crop_left
			var crop_height := crop_bottom - crop_top
			if crop_width / crop_height > crop_aspect:
				crop_width = crop_height * crop_aspect
			else:
				crop_height = crop_width / crop_aspect
			crop_left = crop_center.x - crop_width * 0.5
			crop_right = crop_center.x + crop_width * 0.5
			crop_top = crop_center.y - crop_height * 0.5
			crop_bottom = crop_center.y + crop_height * 0.5
		if (
			uv.x < crop_left
			or uv.x >= crop_right
			or uv.y < crop_top
			or uv.y >= crop_bottom
		):
			return 0.0
		return clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
	elif node_type == "padding":
		# Squeezes the branch inwards, leaving an empty margin around it. The
		# alignment decides where the shrunk content sits.
		var pad_amount := clampf(float(params["amount"]), 0.0, 0.49)
		var pad_scale := maxf(1.0 - pad_amount * 2.0, 0.02)
		var pad_align := Vector2(
			clampf(float(params.get("align_x", 0.5)), 0.0, 1.0),
			clampf(float(params.get("align_y", 0.5)), 0.0, 1.0)
		)
		var pad_origin := pad_align * (1.0 - pad_scale)
		var pad_mapped := ((normalized - pad_origin) / pad_scale) * size_vec
		return _sample(node, 0, pad_mapped, size, depth)
	elif node_type == "echo":
		# Samples the branch several times, either along a direction (a spatial
		# trail) or at earlier animation phases (a cross frame trail).
		var echo_count := clampi(int(params["count"]), 1, 12)
		var echo_best := 0.0
		var echo_total := 0.0
		if bool(params.get("animated", false)):
			var echo_original_time := time
			var echo_step_time := clampf(float(params.get("frame_step", 0.05)), 0.001, 0.5)
			for i in echo_count:
				time = fposmod(echo_original_time - echo_step_time * float(i), 1.0)
				var echo_frame := clampf(
					_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0
				)
				echo_best = maxf(echo_best, echo_frame)
				echo_total += echo_frame
			time = echo_original_time
		else:
			var echo_direction := Vector2.from_angle(deg_to_rad(float(params["angle"])))
			var echo_delta := echo_direction * float(params["distance"]) * size_vec.y
			for i in echo_count:
				var echo_weight := float(i) / float(maxi(echo_count - 1, 1))
				var echo_sample := _sample(node, 0, uv + echo_delta * echo_weight, size, depth)
				echo_best = maxf(echo_best, echo_sample)
				echo_total += echo_sample
		if int(params["mode"]) == 0:
			return echo_best
		return clampf(echo_total / float(echo_count), 0.0, 1.0)
	elif node_type == "follow_path":
		# Input 0 is the content, input 1 the phase. Without a phase input the
		# node simply sits at the phase slider, so it can be placed statically.
		var path_phase := float(params.get("phase", 0.0))
		var phase_source := _input_id(node, 1)
		if not phase_source.is_empty():
			path_phase = clampf(_eval(phase_source, uv, size, depth + 1), 0.0, 1.0)
		var path_offset := _path_offset(int(params["shape"]), path_phase, params, size_vec)
		return _sample(node, 0, uv - path_offset, size, depth)
	elif node_type == "mesh_warp":
		# Bilinear quad: the corners carry the source position of the dest
		# corners, so a 2×2 mesh can be pulled around with sliders.
		var mesh_s := uv.x / size_vec.x
		var mesh_t := uv.y / size_vec.y
		var mesh_top := Vector2(
			lerpf(float(params["tl_x"]), float(params["tr_x"]), mesh_s) + mesh_s,
			lerpf(float(params["tl_y"]), float(params["tr_y"]), mesh_s) + mesh_t
		)
		var mesh_bottom := Vector2(
			lerpf(float(params["bl_x"]), float(params["br_x"]), mesh_s) + mesh_s,
			lerpf(float(params["bl_y"]), float(params["br_y"]), mesh_s) + mesh_t
		)
		var mesh_mapped := Vector2(
			lerpf(mesh_top.x, mesh_bottom.x, mesh_t) * size_vec.x,
			lerpf(mesh_top.y, mesh_bottom.y, mesh_t) * size_vec.y
		)
		var mesh_random := clampf(float(params.get("randomness", 0.0)), 0.0, 0.4)
		if mesh_random > 0.0:
			# A smooth wobble, so the mesh looks hand jittered instead of noisy.
			var mesh_jitter := Vector2(
				sin(mesh_mapped.y * 0.19 + mesh_mapped.x * 0.11),
				cos(mesh_mapped.x * 0.17 - mesh_mapped.y * 0.23)
			)
			mesh_mapped += mesh_jitter * mesh_random * size_vec * 0.5
		return _sample(node, 0, mesh_mapped, size, depth)
	elif node_type == "area_warp":
		# Warp, but the displacement fades out towards the edge of a circle.
		var area_center := Vector2(float(params["center_x"]), float(params["center_y"]))
		var area_falloff := clampf(
			1.0 - (normalized - area_center).length() / maxf(float(params["radius"]), 0.001),
			0.0,
			1.0
		)
		if area_falloff <= 0.0:
			return clampf(_eval(_input_id(node, 1), uv, size, depth + 1), 0.0, 1.0)
		var area_amount := float(params["amount"]) * size_vec.y * area_falloff
		var area_field := _eval(_input_id(node, 0), uv, size, depth + 1) - 0.5
		var area_field_y := (
			_eval(_input_id(node, 0), uv + Vector2(37.0, 61.0), size, depth + 1) - 0.5
		)
		var area_shifted := uv + Vector2(area_field, area_field_y) * area_amount * 2.0
		return _sample(node, 1, area_shifted, size, depth)
	elif node_type == "nine_slice":
		# Corners keep their size, the middle stretches, each axis separately.
		var slice_border := clampf(float(params["border"]), 0.0, 0.49)
		var slice_scale := clampf(float(params["scale"]), 0.2, 4.0)
		var slice_mapped := Vector2(
			_slice_axis(uv.x, size_vec.x, slice_border, slice_scale),
			_slice_axis(uv.y, size_vec.y, slice_border, slice_scale)
		)
		return _sample(
			node, 0, slice_mapped.snapped(Vector2(SNAP_STEP, SNAP_STEP)), size, depth
		)
	elif node_type == "crop_content":
		# Stretches the non empty part of the branch over the whole canvas.
		var content_bounds := _content_bounds(node)
		if content_bounds.size.x <= 0.0 or content_bounds.size.y <= 0.0:
			return clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
		var content_uv := (
			content_bounds.position + (uv / size_vec) * content_bounds.size
		) * size_vec
		return _sample(node, 0, content_uv, size, depth)
	elif node_type == "kaleidoscope":
		# Folds the canvas into wedges around the centre.
		var kaleido_center := size_vec * 0.5
		var kaleido_delta := uv - kaleido_center
		var kaleido_slice := TAU / float(clampi(int(params["segments"]), 2, 16))
		var kaleido_angle := (
			atan2(kaleido_delta.y, kaleido_delta.x) - deg_to_rad(float(params["angle"]))
		)
		kaleido_angle = fposmod(kaleido_angle, kaleido_slice)
		if bool(params.get("mirror", true)) and kaleido_angle > kaleido_slice * 0.5:
			kaleido_angle = kaleido_slice - kaleido_angle
		var kaleido_radius := kaleido_delta.length()
		var kaleido_mapped := (
			kaleido_center
			+ Vector2(cos(kaleido_angle), sin(kaleido_angle)) * kaleido_radius
		)
		return clampf(
			_eval(_input_id(node, 0), kaleido_mapped, size, depth + 1), 0.0, 1.0
		)
	elif node_type == "bend":
		# Shifts one axis by a curve of the other, which arcs or ripples the
		# whole branch. UV Scale and UV Shift move the pattern beforehand.
		var bend_uv := normalized * maxf(float(params.get("uv_scale", 1.0)), 0.01)
		bend_uv += Vector2.ONE * float(params.get("uv_shift", 0.0))
		bend_uv = Vector2(fposmod(bend_uv.x, 1.0), fposmod(bend_uv.y, 1.0))
		var bend_amount := float(params["amount"]) * size_vec.y
		var bend_along := bend_uv.x
		if int(params["axis"]) == 0:
			bend_along = bend_uv.y
		var bend_delta := 0.0
		match int(params["type"]):
			0:
				# Arc: a parabola, so the middle bulges and the ends stay put.
				var bend_centered := (bend_along - 0.5) * 2.0
				bend_delta = (bend_centered * bend_centered - 0.5) * bend_amount
			_:
				var bend_frequency := maxf(float(params["scale"]), 0.05)
				bend_delta = (
					sin((bend_along * bend_frequency + float(params["shift"])) * TAU)
					* bend_amount
				)
		var bend_offset := (
			Vector2(bend_delta, 0.0) if int(params["axis"]) == 0 else Vector2(0.0, bend_delta)
		)
		return _sample(node, 0, bend_uv * size_vec + bend_offset, size, depth)
	elif node_type == "stretch":
		# Scales along one direction only, the classic speed smear. Inverse also
		# squeezes across, so the area roughly stays the same.
		var stretch_angle := deg_to_rad(float(params["angle"]))
		var stretch_amount := clampf(float(params["amount"]), 0.0, 0.95)
		var stretch_direction := Vector2.from_angle(stretch_angle)
		var stretch_normal := Vector2.from_angle(stretch_angle + PI * 0.5)
		var stretch_delta := uv - size_vec * 0.5
		var stretch_along := stretch_delta.dot(stretch_direction) / (1.0 + stretch_amount)
		var stretch_across := stretch_delta.dot(stretch_normal)
		if bool(params.get("inverse", false)):
			stretch_across /= maxf(1.0 - stretch_amount * 0.5, 0.05)
		var stretch_mapped := (
			size_vec * 0.5
			+ stretch_direction * stretch_along
			+ stretch_normal * stretch_across
		)
		return _sample(node, 0, stretch_mapped, size, depth)
	elif node_type == "mirror":
		# Folds one half of the canvas onto the other across a line. The centre
		# is the middle of the pixel grid, so mirrored pixels line up exactly and
		# no seam appears on an even sized canvas.
		var mirror_center := (size_vec - Vector2.ONE) * 0.5
		var mirror_normal := Vector2.from_angle(deg_to_rad(float(params["angle"])) + PI * 0.5)
		if bool(params.get("flip_side", false)):
			mirror_normal = -mirror_normal
		var mirror_delta := uv - mirror_center
		mirror_delta -= mirror_normal * float(params["position"]) * size_vec.y
		var mirror_distance := mirror_delta.dot(mirror_normal)
		if mirror_distance > 0.0:
			mirror_delta -= mirror_normal * mirror_distance * 2.0
		return _sample(node, 0, mirror_center + mirror_delta, size, depth)
	elif node_type == "blur":
		# A 3×3 kernel spread over the size. The aspect stretches it along the
		# angle, which is how a directional speed blur is made.
		var blur_source := clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
		var blur_size := maxf(float(params.get("size", params.get("radius", 1.5))), 0.0)
		if blur_size < 0.01:
			return blur_source
		var blur_angle := deg_to_rad(float(params.get("angle", 0.0)))
		var blur_aspect := clampf(float(params.get("aspect", 1.0)), 0.1, 8.0)
		var blur_along := Vector2.from_angle(blur_angle)
		var blur_across := Vector2.from_angle(blur_angle + PI * 0.5)
		var blur_total := 0.0
		for row in 3:
			for column in 3:
				var blur_offset := (
					blur_along * float(column - 1) * blur_size * blur_aspect
					+ blur_across * float(row - 1) * blur_size / blur_aspect
				)
				blur_total += clampf(
					_eval(_input_id(node, 0), uv + blur_offset, size, depth + 1), 0.0, 1.0
				)
		var blurred := clampf(blur_total / 9.0, 0.0, 1.0)
		return lerpf(blur_source, blurred, clampf(float(params.get("mix", 1.0)), 0.0, 1.0))
	elif node_type == "erode":
		# Morphology: the darkest sample in the kernel wins, so a bright shape
		# loses a ring of pixels and keeps the same art inside. This changes the
		# silhouette itself; a transform would only move it. Dilate takes the
		# brightest sample and grows the shape back. The branch is read into a
		# field once per generation, so the kernel costs array reads instead of
		# walking the whole graph again for every neighbour.
		var erode_radius := clampf(float(params.get("radius", 1.0)), 0.0, 8.0)
		var erode_mix := clampf(float(params.get("mix", 1.0)), 0.0, 1.0)
		var erode_field := _field_of(node, 0, size, depth)
		if erode_field.is_empty():
			return 0.0
		var erode_px := clampi(int(uv.x), 0, size.x - 1)
		var erode_py := clampi(int(uv.y), 0, size.y - 1)
		var erode_center := erode_field[erode_py * size.x + erode_px]
		if erode_radius < 0.01 or erode_mix < 0.001:
			return erode_center * _mask_at(node, uv, size, depth)
		var erode_dilate := int(params.get("mode", 0)) == 1
		var erode_shape := int(params.get("shape", 0))
		var erode_extent := int(ceil(erode_radius))
		var erode_result := erode_center
		var erode_done := false
		for offset_y in range(-erode_extent, erode_extent + 1):
			var sample_y := erode_py + offset_y
			for offset_x in range(-erode_extent, erode_extent + 1):
				if offset_x == 0 and offset_y == 0:
					continue
				if erode_shape == 1 and Vector2(offset_x, offset_y).length() > erode_radius:
					continue
				if erode_shape == 2 and float(absi(offset_x) + absi(offset_y)) > erode_radius:
					continue
				var sample_x := erode_px + offset_x
				# Outside the canvas counts as empty, which is what makes a shape
				# touching the border erode from that side too.
				var erode_sample := 0.0
				if (
					sample_x >= 0
					and sample_y >= 0
					and sample_x < size.x
					and sample_y < size.y
				):
					erode_sample = erode_field[sample_y * size.x + sample_x]
				if erode_dilate:
					erode_result = maxf(erode_result, erode_sample)
					# A single full sample already fills this pixel.
					if erode_result >= 1.0:
						erode_done = true
						break
				else:
					erode_result = minf(erode_result, erode_sample)
					# A single empty sample already clears this pixel.
					if erode_result <= 0.0:
						erode_done = true
						break
			if erode_done:
				break
		var erode_value := lerpf(erode_center, erode_result, erode_mix)
		return clampf(erode_value * _mask_at(node, uv, size, depth), 0.0, 1.0)
	elif node_type == "outline":
		# Builds a ring from the silhouette: anything above the threshold counts
		# as shape. The ring sits on the empty side of the border (outer), on the
		# shape side (inner), or on both (centred), so the three positions keep
		# the same visual weight. Every neighbour has to be looked at: stopping
		# at the first bright one would hide the inner ring of a filled block.
		var outline_threshold := clampf(float(params.get("threshold", 0.5)), 0.0, 1.0)
		var outline_width := maxf(float(params.get("width", 1.0)), 0.5)
		var outline_source := clampf(
			_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0
		)
		var outline_inside := 1.0 if outline_source > outline_threshold else 0.0
		var outline_any_bright := 0.0
		var outline_any_dark := 0.0
		for index in 8:
			var outline_offset := (
				Vector2.from_angle(TAU * float(index) / 8.0) * outline_width
			)
			var outline_sample := clampf(
				_eval(_input_id(node, 0), uv + outline_offset, size, depth + 1), 0.0, 1.0
			)
			if outline_sample > outline_threshold:
				outline_any_bright = 1.0
			else:
				outline_any_dark = 1.0
		var outline_ring := 0.0
		match int(params.get("position", 0)):
			1:
				outline_ring = outline_inside * outline_any_dark
			2:
				outline_ring = (
					outline_inside * outline_any_dark
					+ (1.0 - outline_inside) * outline_any_bright
				)
			_:
				outline_ring = (1.0 - outline_inside) * outline_any_bright
		return clampf(outline_ring * _mask_value(node, uv, size, depth), 0.0, 1.0)
	elif node_type == "glow":
		# Bright samples bleed outwards, and the result keeps the brighter of the
		# two, so the shape itself stays crisp.
		var glow_source := clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
		var glow_halo := _halo(
			node,
			uv,
			size,
			depth,
			clampf(float(params.get("size", 3.0)), 0.5, 16.0),
			clampf(float(params.get("tolerance", 0.35)), 0.0, 1.0)
		)
		glow_halo *= maxf(float(params.get("strength", 1.5)), 0.0)
		glow_halo *= _mask_value(node, uv, size, depth)
		return clampf(maxf(glow_source, glow_halo), 0.0, 1.0)
	elif node_type == "bloom":
		# Same halo, but added to the source, so highlights blow out.
		var bloom_source := clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
		var bloom_halo := _halo(
			node,
			uv,
			size,
			depth,
			clampf(float(params.get("size", 3.0)), 0.5, 16.0),
			clampf(float(params.get("tolerance", 0.5)), 0.0, 1.0)
		)
		bloom_halo *= maxf(float(params.get("strength", 1.0)), 0.0)
		bloom_halo *= _mask_value(node, uv, size, depth)
		return clampf(bloom_source + bloom_halo, 0.0, 1.0)
	elif node_type == "color_adjust":
		# Value space grading: exposure, contrast, brightness, gamma, then mix.
		# Hue and saturation belong to the colour the branch carries instead.
		var adjust_source := clampf(
			_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0
		)
		var graded := adjust_source * pow(2.0, float(params.get("exposure", 0.0)))
		graded = (graded - 0.5) * (1.0 + float(params.get("contrast", 0.0))) + 0.5
		graded += float(params.get("brightness", 0.0))
		graded *= float(params.get("value", 1.0))
		graded = clampf(graded, 0.0, 1.0)
		var adjust_gamma := maxf(float(params.get("gamma", 1.0)), 0.05)
		if absf(adjust_gamma - 1.0) > 0.001:
			graded = pow(graded, 1.0 / adjust_gamma)
		if bool(params.get("invert", false)):
			graded = 1.0 - graded
		return lerpf(
			adjust_source, graded, clampf(float(params.get("mix", 1.0)), 0.0, 1.0)
		)
	elif node_type == "levels":
		# Stretch the input range onto the output range, with gamma on the middle,
		# which is the classic level adjustment of a paint program.
		var level_source := clampf(
			_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0
		)
		var level_black := clampf(float(params.get("black", 0.0)), 0.0, 0.99)
		var level_white := maxf(float(params.get("white", 1.0)), level_black + 0.01)
		var levelled := clampf(
			(level_source - level_black) / (level_white - level_black), 0.0, 1.0
		)
		var level_gamma := maxf(float(params.get("gamma", 1.0)), 0.05)
		if absf(level_gamma - 1.0) > 0.001:
			levelled = pow(levelled, 1.0 / level_gamma)
		return clampf(
			lerpf(
				clampf(float(params.get("out_black", 0.0)), 0.0, 1.0),
				clampf(float(params.get("out_white", 1.0)), 0.0, 1.0),
				levelled
			),
			0.0,
			1.0
		)
	elif node_type == "threshold":
		# Everything above the cut is solid and everything below is empty. The soft
		# edge spreads the cut over a range, which keeps a mask readable.
		var threshold_source := clampf(
			_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0
		)
		var cut := clampf(float(params.get("cut", 0.5)), 0.0, 1.0)
		var edge_soft := maxf(float(params.get("soft", 0.0)), 0.0005)
		var cut_value := clampf((threshold_source - cut) / edge_soft + 0.5, 0.0, 1.0)
		return 1.0 - cut_value if bool(params.get("invert", false)) else cut_value
	elif node_type == "normalize":
		# Auto level: measure the range the branch really uses and stretch it over
		# the whole range, so a faint branch becomes a full one.
		var norm_source_id := _input_id(node, 0)
		var norm_source := clampf(_eval(norm_source_id, uv, size, depth + 1), 0.0, 1.0)
		var span := _value_range(norm_source_id, size, depth)
		var norm_low := lerpf(span.x, span.y, clampf(float(params.get("low", 0.0)), 0.0, 0.9))
		var norm_high := lerpf(span.x, span.y, clampf(float(params.get("high", 1.0)), 0.1, 1.0))
		if norm_high - norm_low < 0.0001:
			return norm_source
		return clampf((norm_source - norm_low) / (norm_high - norm_low), 0.0, 1.0)
	elif node_type == "curve":
		# A five point curve through the value, drawn by the same spline the stroke
		# width uses: the samples are output values for evenly spaced inputs, so a
		# point dragged up brightens that part of the range.
		var curve_source := clampf(
			_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0
		)
		var curve_values: Array = params.get("curve", [])
		if curve_values.size() < 2:
			return curve_source
		return profile_at(curve_values, curve_source)
	elif node_type == "band":
		# Picks the values inside a range, which is the level selector of a paint
		# program: a mask out of the mid tones, the highlights, a slice of a ramp.
		var band_source := clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
		var band_low := clampf(float(params.get("low", 0.3)), 0.0, 1.0)
		var band_high := maxf(float(params.get("high", 0.7)), band_low)
		var band_soft := maxf(float(params.get("soft", 0.05)), 0.0005)
		# The window rises over the softness at the low end and falls at the high
		# end, so the mask keeps a readable edge instead of a staircase.
		var band_value := minf(
			clampf((band_source - band_low) / band_soft + 0.5, 0.0, 1.0),
			clampf((band_high - band_source) / band_soft + 0.5, 0.0, 1.0)
		)
		return 1.0 - band_value if bool(params.get("invert", false)) else band_value
	elif node_type == "edge":
		# Difference between opposite neighbours, which outlines the branch.
		var edge_step := maxf(float(params["radius"]), 0.5)
		var edge_left := _eval(_input_id(node, 0), uv - Vector2(edge_step, 0.0), size, depth + 1)
		var edge_right := _eval(_input_id(node, 0), uv + Vector2(edge_step, 0.0), size, depth + 1)
		var edge_top := _eval(_input_id(node, 0), uv - Vector2(0.0, edge_step), size, depth + 1)
		var edge_bottom := _eval(_input_id(node, 0), uv + Vector2(0.0, edge_step), size, depth + 1)
		var edge_value := clampf(
			Vector2(edge_right - edge_left, edge_bottom - edge_top).length()
			* maxf(float(params["gain"]), 0.0),
			0.0,
			1.0
		)
		return 1.0 - edge_value if bool(params["invert"]) else edge_value
	elif node_type == "dither":
		# Ordered dithering, so the posterized output gains texture instead of
		# flat bands. The threshold is per pixel, so it stays put while playing.
		var dither_matrix := _bayer_matrix(DITHER_BITS[clampi(int(params["matrix"]), 0, 2)])
		var dither_span := dither_matrix.size()
		var dither_x := int(floorf(uv.x)) % dither_span
		var dither_y := int(floorf(uv.y)) % dither_span
		var dither_threshold := (
			(float(dither_matrix[dither_y][dither_x]) + 0.5) / float(dither_span * dither_span)
		)
		var dither_source := clampf(
			_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0
		)
		return clampf(
			dither_source + (dither_threshold - 0.5) * float(params["strength"]), 0.0, 1.0
		)
	elif node_type == "pixelate":
		var block := maxf(float(params["size"]), 1.0)
		var pixel_mapped := Vector2(
			clampf(floorf(uv.x / block) * block + block * 0.5, 0.0, size_vec.x - 1.0),
			clampf(floorf(uv.y / block) * block + block * 0.5, 0.0, size_vec.y - 1.0)
		)
		return clampf(
			_eval(_input_id(node, 0), pixel_mapped, size, depth + 1), 0.0, 1.0
		)
	elif node_type == "warp":
		# The first input is the field, the second one the image being distorted.
		var amount := float(params.get("amount", 0.15)) * size_vec.y
		var field_x := _eval(_input_id(node, 0), uv, size, depth + 1) - 0.5
		var field_y := (
			_eval(_input_id(node, 0), uv + Vector2(37.0, 61.0), size, depth + 1) - 0.5
		)
		var shifted := uv + Vector2(field_x, field_y) * amount * 2.0
		return clampf(_eval(_input_id(node, 1), shifted, size, depth + 1), 0.0, 1.0)
	return 0.0


## Evaluates input [param slot] of [param node] at [param uv]. Axes that are not
## wrapped are empty outside the canvas, which is what the compositing nodes need.
func _sample(
	node: Dictionary,
	slot: int,
	uv: Vector2,
	size: Vector2i,
	depth: int,
	wrap_x := false,
	wrap_y := false
) -> float:
	var sampled := uv
	if wrap_x:
		sampled.x = fposmod(sampled.x, float(size.x))
	elif sampled.x < 0.0 or sampled.x >= float(size.x):
		return 0.0
	if wrap_y:
		sampled.y = fposmod(sampled.y, float(size.y))
	elif sampled.y < 0.0 or sampled.y >= float(size.y):
		return 0.0
	return clampf(_eval(_input_id(node, slot), sampled, size, depth + 1), 0.0, 1.0)


## Distance to the border of a regular polygon with [param sides] sides and an
## inradius of one, negative inside. [param offset] is centred on the polygon.
static func _polygon_distance(offset: Vector2, sides: int) -> float:
	var count := maxi(sides, 3)
	var step := TAU / float(count)
	var corner := fposmod(atan2(offset.y, offset.x), step) - step * 0.5
	return offset.length() * cos(corner) - cos(step * 0.5)


## Radius of the star with [param points] spikes in the direction of
## [param offset]. The edge between a spike and a valley is a straight line, so
## the star has sharp points instead of the petals a linear blend would give.
static func _star_radius(offset: Vector2, points: int, inner: float) -> float:
	var step := TAU / float(maxi(points, 3))
	var half := step * 0.5
	var angle := absf(fposmod(atan2(offset.y, offset.x), step))
	if angle > half:
		angle = step - angle
	var ratio := clampf(inner, 0.05, 0.95)
	var sine := sin(half)
	var cosine := cos(half)
	var denominator := sine * ratio * cos(angle) + (1.0 - cosine * ratio) * sin(angle)
	if absf(denominator) < 0.0001:
		return 1.0
	return sine * ratio / denominator


## Maps a coordinate around the middle of its axis, so scaling keeps the content
## centred. A negative factor mirrors the axis, using the pixel grid rather than
## the axis length so the result never falls outside the canvas.
static func _scale_axis(value: float, extent: float, factor: float) -> float:
	var scale := factor
	var source := value
	if scale < 0.0:
		source = extent - 1.0 - source
		scale = -scale
	if scale < 0.01:
		scale = 0.01
	return (source - extent * 0.5) / scale + extent * 0.5


## Offset of a point travelling along a closed path, in pixels. [param phase] runs
## from 0 to 1 over the whole path.
static func _path_offset(
	shape: int, phase: float, params: Dictionary, size_vec: Vector2
) -> Vector2:
	var radius := clampf(float(params.get("radius", 0.3)), 0.0, 1.0)
	var loops := maxf(float(params.get("loops", 1.0)), 0.25)
	var angle := phase * TAU * loops
	var shortest := minf(size_vec.x, size_vec.y) * radius
	match shape:
		1:  # 水平来回
			return Vector2((phase * 2.0 - 1.0) * radius * size_vec.x, 0.0)
		2:  # 垂直来回
			return Vector2(0.0, (phase * 2.0 - 1.0) * radius * size_vec.y)
		3:  # 正弦
			return Vector2(
				(phase * 2.0 - 1.0) * radius * size_vec.x, sin(angle) * shortest
			)
		4:  # 方形
			var walk := fposmod(phase * loops, 1.0) * 4.0
			var side := int(floorf(walk))
			var along := walk - float(side)
			match side:
				0:
					return Vector2(lerpf(-shortest, shortest, along), -shortest)
				1:
					return Vector2(shortest, lerpf(-shortest, shortest, along))
				2:
					return Vector2(lerpf(shortest, -shortest, along), shortest)
			return Vector2(-shortest, lerpf(shortest, -shortest, along))
		5:  # 8 字
			return Vector2(sin(angle) * radius * size_vec.x, sin(angle * 2.0) * shortest)
		PATH_CUSTOM:  # 自定义控制点
			var custom: Array = params.get("points", [])
			return (
				(sample_custom_path(custom, phase * loops) - Vector2(0.5, 0.5)) * size_vec
			)
	# 圆形
	return Vector2(cos(angle), sin(angle)) * shortest


## Point at [param t] (0..1) on the closed Catmull-Rom curve through
## [param points]. Shared with the path editor, so the drawn curve and the
## generated motion always agree.
static func sample_custom_path(points: Array, t: float) -> Vector2:
	var count := points.size()
	if count < 2:
		return Vector2(0.5, 0.5)
	if count == 2:
		var along := fposmod(t, 1.0)
		return (points[0] as Vector2).lerp(points[1] as Vector2, along)
	var scaled := fposmod(t, 1.0) * float(count)
	var index := int(floorf(scaled))
	var local := scaled - float(index)
	var p0: Vector2 = points[(index - 1 + count) % count]
	var p1: Vector2 = points[index % count]
	var p2: Vector2 = points[(index + 1) % count]
	var p3: Vector2 = points[(index + 2) % count]
	return _catmull_rom(p0, p1, p2, p3, local)


static func _catmull_rom(
	p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float
) -> Vector2:
	var squared := t * t
	var cubed := squared * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * squared
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * cubed
	)


## Maps one axis of a nine slice: the borders stay rigid, the middle is stretched
## by [param scale], and anything pushed past the canvas is simply cropped.
static func _slice_axis(
	value: float, extent: float, border_ratio: float, scale: float
) -> float:
	var border := border_ratio * extent
	var middle := maxf(extent - border * 2.0, 0.001)
	var split := border + middle * scale
	if value < border:
		return value
	if split >= extent or value < split:
		return border + (value - border) / maxf(scale, 0.001)
	var along := (value - split) / maxf(extent - split, 0.001)
	return (extent - border) + along * border


## Bounding box of the non empty part of the branch, in 0..1 canvas units. Probed
## at a reduced resolution and cached per generated image, because it needs a pass
## over the whole branch before any pixel can be placed.
func _content_bounds(node: Dictionary) -> Rect2:
	var source := _input_id(node, 0)
	var key := "%s|%s" % [node["id"], source]
	if _bounds_cache.has(key):
		return _bounds_cache[key]
	var params: Dictionary = params_for(node)
	var threshold := clampf(float(params.get("threshold", 0.02)), 0.0, 1.0)
	var margin := clampf(float(params.get("margin", 0.0)), 0.0, 0.4)
	var probe := 48
	var probe_size := Vector2i(probe, probe)
	var found := false
	var low := Vector2(float(probe), float(probe))
	var high := Vector2(-1.0, -1.0)
	for y in probe:
		for x in probe:
			if _eval(source, Vector2(x, y), probe_size, 1) > threshold:
				found = true
				low.x = minf(low.x, x)
				low.y = minf(low.y, y)
				high.x = maxf(high.x, x)
				high.y = maxf(high.y, y)
	var rect := Rect2()
	if found:
		rect = Rect2(low / float(probe), (high - low + Vector2.ONE) / float(probe))
		var grow := Vector2(rect.size.x * margin, rect.size.y * margin)
		rect = rect.grow_individual(grow.x, grow.y, grow.x, grow.y)
		rect = rect.intersection(Rect2(0.0, 0.0, 1.0, 1.0))
	_bounds_cache[key] = rect
	return rect


## Brightness range the branch feeding [param node_id] really covers, measured
## fresh so a button can set an adjustment up from what is actually there instead
## of two numbers guessed from the preview.
func input_range(node_id: String) -> Vector2:
	var node := get_node_by_id(node_id)
	if node.is_empty():
		return Vector2(0.0, 1.0)
	var source := _input_id(node, 0)
	if source.is_empty():
		return Vector2(0.0, 1.0)
	_bounds_cache.erase("%s|range" % source)
	_resolve_animations()
	return _value_range(source, Vector2i(32, 32), 0)


## Smallest and largest value a branch really produces, probed at a reduced
## resolution and cached per generated image. Normalize needs it before a single
## pixel can be mapped, the same way the content bounds are needed by a crop.
func _value_range(node_id: String, size: Vector2i, depth: int) -> Vector2:
	var key := "%s|range" % node_id
	if _bounds_cache.has(key):
		return _bounds_cache[key]
	var probe := 32
	var grid := Vector2i(mini(size.x, probe), mini(size.y, probe))
	var low := 1.0
	var high := 0.0
	for y in grid.y:
		for x in grid.x:
			var value := clampf(_eval(node_id, Vector2(x, y), grid, depth + 1), 0.0, 1.0)
			low = minf(low, value)
			high = maxf(high, value)
	if high - low < 0.001:
		high = minf(low + 0.001, 1.0)
	var span := Vector2(low, high)
	_bounds_cache[key] = span
	return span


## Bayer threshold matrix of 2^[param bits] per side, built once and cached.
func _bayer_matrix(bits: int) -> Array:
	if _bayer_cache.has(bits):
		return _bayer_cache[bits]
	var matrix := [[0]]
	for _step in bits:
		var span := matrix.size()
		var grown := []
		for _row in span * 2:
			var row: Array = []
			row.resize(span * 2)
			grown.append(row)
		for y in span:
			for x in span:
				var base: int = int(matrix[y][x]) * 4
				grown[y][x] = base
				grown[y][x + span] = base + 2
				grown[y + span][x] = base + 3
				grown[y + span][x + span] = base + 1
		matrix = grown
	_bayer_cache[bits] = matrix
	return matrix


## Flattens the cubic bezier path into a polyline in 0..1 canvas units. Each entry
## of [param points] is a dictionary with "point" and the "in" / "out" handles.
static func flatten_path(points: Array, closed: bool, steps := 20) -> PackedVector2Array:
	var result := PackedVector2Array()
	var count := points.size()
	if count == 0:
		return result
	if count == 1:
		result.append(points[0]["point"])
		return result
	var segments := count if closed else count - 1
	for index in segments:
		var start_entry: Dictionary = points[index % count]
		var end_entry: Dictionary = points[(index + 1) % count]
		var start: Vector2 = start_entry["point"]
		var end: Vector2 = end_entry["point"]
		var control_a: Vector2 = start + (start_entry.get("out", Vector2.ZERO) as Vector2)
		var control_b: Vector2 = end + (end_entry.get("in", Vector2.ZERO) as Vector2)
		for step in steps:
			result.append(_bezier_point(start, control_a, control_b, end, float(step) / steps))
	result.append((points[0] if closed else points[count - 1])["point"])
	return result


## Point at [param t] (0..1) along the flattened path. Shared with the editor, so
## the marker sits on the drawn curve.
static func sample_path_point(points: Array, closed: bool, t: float) -> Vector2:
	var flat := flatten_path(points, closed)
	if flat.is_empty():
		return Vector2(0.5, 0.5)
	if flat.size() == 1:
		return flat[0]
	# No wrapping here: the editor marker wants 1.0 to land on the last point.
	var scaled := clampf(t, 0.0, 1.0) * float(flat.size() - 1)
	var index := clampi(int(floorf(scaled)), 0, flat.size() - 2)
	return flat[index].lerp(flat[index + 1], scaled - float(index))


static func _bezier_point(
	start: Vector2, control_a: Vector2, control_b: Vector2, end: Vector2, t: float
) -> Vector2:
	var inverse := 1.0 - t
	return (
		start * inverse * inverse * inverse
		+ control_a * 3.0 * inverse * inverse * t
		+ control_b * 3.0 * inverse * t * t
		+ end * t * t * t
	)


## Keeps the first [param amount] (0..1) of a polyline, measured by length. The
## new tip is interpolated, so a growing path ends on the curve rather than on a
## control point.
static func trim_polyline(flat: PackedVector2Array, amount: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	if flat.is_empty() or amount <= 0.0:
		return result
	var total := 0.0
	for index in range(flat.size() - 1):
		total += flat[index].distance_to(flat[index + 1])
	if total <= 0.0:
		result.append(flat[0])
		return result
	var wanted := total * clampf(amount, 0.0, 1.0)
	result.append(flat[0])
	var walked := 0.0
	for index in range(flat.size() - 1):
		var from_point := flat[index]
		var to_point := flat[index + 1]
		var segment := from_point.distance_to(to_point)
		if walked + segment >= wanted:
			var local := 0.0 if segment <= 0.0 else (wanted - walked) / segment
			result.append(from_point.lerp(to_point, local))
			return result
		walked += segment
		result.append(to_point)
	return result


## Point and direction at [param t] (0..1) along a polyline, measured by length.
## Used to lay a scatter brush out along a path.
static func _path_point_at(flat: PackedVector2Array, t: float) -> Dictionary:
	if flat.is_empty():
		return {"point": Vector2(0.5, 0.5), "direction": Vector2.RIGHT}
	if flat.size() < 2:
		return {"point": flat[0], "direction": Vector2.RIGHT}
	var total := 0.0
	for index in range(flat.size() - 1):
		total += flat[index].distance_to(flat[index + 1])
	if total <= 0.0:
		return {"point": flat[0], "direction": Vector2.RIGHT}
	var wanted := clampf(t, 0.0, 1.0) * total
	var walked := 0.0
	for index in range(flat.size() - 1):
		var segment := flat[index].distance_to(flat[index + 1])
		if walked + segment >= wanted:
			var local := 0.0 if segment <= 0.0 else (wanted - walked) / segment
			return {
				"point": flat[index].lerp(flat[index + 1], local),
				"direction": (flat[index + 1] - flat[index]).normalized(),
			}
		walked += segment
	return {"point": flat[flat.size() - 1], "direction": Vector2.RIGHT}


## Preview of what one node outputs, used by the frame under the nodes in the
## graph editor and by the picture in the side panel. It evaluates the node the
## same way the generator does, and paints it in the colour the branch carries.
func preview_node(node_id: String, size: Vector2i) -> Image:
	_resolve_animations()
	# The colour is the one the branch carries: a node that owns a colour paints
	# with it, and every node downstream inherits it, which is what makes a colour
	# of a scatter visible under the filters behind it. A branch without a colour
	# is a plain value field, so it is drawn white on a transparent background
	# rather than borrowing the palette of another node.
	var tint: Variant = source_colour(node_id)
	var fade := _preview_fades_alpha()
	var alpha_cut := _preview_alpha_cut()
	# A node that draws its own picture is read straight out of it, so the preview
	# of a particle or scatter field costs the copy instead of a sample per pixel.
	var field := _raster_field(node_id, size)
	var field_data := PackedByteArray()
	if field != null:
		field_data = field.get_data()
	# A preview is rebuilt on every edit and every playback tick, and a thumbnail
	# of a long branch was the slowest single thing the interface did, so the rows
	# go over the cores here as well. Written into bytes and handed to the image at
	# the end, because per pixel set_pixel calls are what made it crawl on a phone.
	var bytes := PackedByteArray()
	var threads := _paint_threads()
	if threads > 1 and size.y >= PARALLEL_MIN_ROWS and size.x * size.y >= PARALLEL_MIN_PIXELS:
		bytes = _preview_parallel(
			node_id, size, tint, fade, alpha_cut, field_data, threads
		)
	else:
		bytes = _preview_into(node_id, size, tint, fade, alpha_cut, field_data, 0, 0, size.y)
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, bytes)


## Paints rows [param from_row] to [param to_row] of the preview of [param node_id]
## and returns them as one byte block, whose first row is row [param offset]. A
## block of its own per band is what lets the workers stay out of each other's way,
## packed arrays being copied when they are handed to a function.
func _preview_into(
	node_id: String,
	size: Vector2i,
	tint: Variant,
	fade: bool,
	alpha_cut: float,
	field_data: PackedByteArray,
	offset: int,
	from_row: int,
	to_row: int
) -> PackedByteArray:
	var row_bytes: int = size.x * 4
	var target := PackedByteArray()
	target.resize(row_bytes * (to_row - from_row))
	var has_field := not field_data.is_empty()
	for y in range(from_row, to_row):
		var row_start: int = (y - offset) * row_bytes
		for x in size.x:
			var pixel := Color(0.0, 0.0, 0.0, 0.0)
			var value: float
			if has_field:
				pixel = _field_pixel(field_data, y * row_bytes + x * 4)
				value = maxf(maxf(pixel.r, pixel.g), pixel.b)
			else:
				value = clampf(_eval(node_id, Vector2(x, y), size, 0), 0.0, 1.0)
			if value <= alpha_cut:
				continue
			var color: Color
			if tint == null:
				# A node that draws its own picture keeps its colours in the
				# thumbnail; only a bare value field is grey.
				color = pixel if has_field else Color(value, value, value, 1.0)
			else:
				var base: Color = tint
				color = Color(base.r * value, base.g * value, base.b * value, 1.0)
			if fade:
				color.a = pixel.a if (has_field and tint == null) else value
			# to_rgba32 packs red in the highest byte, so it is written out in the
			# RGBA order the image expects.
			var packed := color.to_rgba32()
			var at: int = row_start + x * 4
			target[at] = (packed >> 24) & 0xFF
			target[at + 1] = (packed >> 16) & 0xFF
			target[at + 2] = (packed >> 8) & 0xFF
			target[at + 3] = packed & 0xFF
	return target


## Paints one band of a preview into its own block and hands it back under the
## mutex, so the block is the only thing the workers share.
func _preview_band(
	node_id: String,
	size: Vector2i,
	tint: Variant,
	fade: bool,
	alpha_cut: float,
	field_data: PackedByteArray,
	band: int,
	bands: Array,
	results: Array,
	mutex: Mutex
) -> void:
	var pair: Array = bands[band]
	var from_row: int = int(pair[0])
	var to_row: int = int(pair[1])
	var piece := _preview_into(
		node_id, size, tint, fade, alpha_cut, field_data, from_row, from_row, to_row
	)
	mutex.lock()
	results[band] = piece
	mutex.unlock()


## Splits a preview over [param threads] workers and joins the blocks in order.
func _preview_parallel(
	node_id: String,
	size: Vector2i,
	tint: Variant,
	fade: bool,
	alpha_cut: float,
	field_data: PackedByteArray,
	threads: int
) -> PackedByteArray:
	_warm_caches(size)
	var count: int = mini(threads, size.y)
	var step: int = int(ceilf(float(size.y) / float(count)))
	var bands: Array = []
	var start := 0
	while start < size.y:
		bands.append([start, mini(start + step, size.y)])
		start += step
	count = bands.size()
	var results: Array = []
	results.resize(count)
	var mutex := Mutex.new()
	var group := WorkerThreadPool.add_group_task(
		func(band: int) -> void: _preview_band(
			node_id, size, tint, fade, alpha_cut, field_data, band, bands, results, mutex
		),
		count,
		count,
		false,
		"shader composer preview"
	)
	WorkerThreadPool.wait_for_group_task_completion(group)
	var bytes := PackedByteArray()
	var expected: int = size.x * size.y * 4
	for index in count:
		var piece: Variant = results[index]
		if piece is PackedByteArray:
			bytes.append_array(piece)
	if bytes.size() != expected:
		# A band that came back broken would otherwise shift the whole picture.
		return _preview_into(node_id, size, tint, fade, alpha_cut, field_data, 0, 0, size.y)
	return bytes


## Value below which a preview leaves a pixel transparent. The output says where
## the artwork is cut, which is what makes a preview a shape instead of a
## rectangle, so that threshold is read here too.
func _preview_alpha_cut() -> float:
	var output_id := output_node_id()
	if output_id.is_empty():
		return PREVIEW_EMPTY
	var params: Dictionary = params_for(get_node_by_id(output_id))
	if not bool(params.get("transparent", false)):
		return PREVIEW_EMPTY
	return maxf(clampf(float(params.get("alpha_cut", 0.0)), 0.0, 1.0), PREVIEW_EMPTY)


## True when the previews should fade with the value instead of drawing every
## covered pixel solid.
func _preview_fades_alpha() -> bool:
	var output_id := output_node_id()
	if output_id.is_empty():
		return false
	var params: Dictionary = params_for(get_node_by_id(output_id))
	return bool(params.get("transparent", false)) and bool(params.get("alpha_from_value", false))


## Cache key of a rasterised node image. The size is part of the key, so the
## thumbnail, the side panel picture and the main preview do not throw each
## other's rasters away whenever the size changes, which used to rebuild every
## stroke, tree and particle field several times per frame. The signature of the
## node is in there as well: a stroke that did not change is found again in the
## next generation instead of being drawn from scratch, and the finished key is
## remembered per node because this runs for every pixel of the picture.
func _raster_key(node_id: String, size: Vector2i) -> String:
	var cached: Variant = _raster_keys.get(node_id, null)
	if cached != null and (cached as Array)[0] == size:
		return str((cached as Array)[1])
	if not _raster_sizes.has(size):
		if _raster_sizes.size() >= RASTER_SIZES_MAX:
			_path_cache.clear()
			_raster_sizes.clear()
			_raster_keys.clear()
		_raster_sizes[size] = true
	if _path_cache.size() >= RASTER_CACHE_MAX:
		_path_cache.clear()
	var key := "%s|%d@%dx%d" % [node_id, _raster_signature(node_id), size.x, size.y]
	_raster_keys[node_id] = [size, key]
	return key


## Everything the raster of [param node_id] is drawn from: its parameters, the
## node itself (a bypass change rewires it), the signatures of the branches it
## reads and the clock. Built once per node per frame, it is what tells the cache
## an untouched stroke from an edited one.
func _raster_signature(node_id: String) -> int:
	if _raster_sigs.has(node_id):
		return int(_raster_sigs[node_id])
	var signature := 0
	var entry: Variant = _eval_nodes.get(node_id, null)
	if entry == null:
		signature = hash([node_id, time])
	else:
		var stored: Array = entry
		var node: Dictionary = stored[0]
		var params: Dictionary = stored[1]
		var node_type := str(node["type"])
		# Only a tree and a particle field read the clock while they are drawn;
		# everything else is drawn from its parameters, so it keeps its raster from
		# one frame to the next even while the animation plays.
		# A tree, a particle field and a scatter that sways all read the clock while
		# they are drawn, so their raster belongs to this frame only.
		var moves := node_type == "tree" or node_type == "particles"
		if node_type == "scatter":
			moves = float(params.get("sway", 0.0)) > 0.0
		var clock := time if moves else 0.0
		signature = hash([params, clock, _source_generation, node.get("bypass", false)])
		for slot in 2:
			var upstream := _input_id(node, slot)
			if not upstream.is_empty():
				signature = signature ^ (int(_raster_signature(upstream)) * (slot + 3))
	_raster_sigs[node_id] = signature
	return signature


## Picture behind [param node_id] when the node is one that draws itself once per
## generation, or null. The paint loop and the node previews walk those bytes
## directly, so a particle or scatter field costs a read per pixel instead of a
## call into the evaluator.
func _raster_field(node_id: String, size: Vector2i) -> Image:
	var entry: Variant = _eval_nodes.get(node_id, null)
	if entry == null:
		return null
	var stored: Array = entry
	var node: Dictionary = stored[0]
	var params: Dictionary = stored[1]
	if bool(node.get("bypass", false)):
		# A bypassed node hands its input through, so it owns no picture.
		return null
	match str(node["type"]):
		"path":
			return _path_image(node, params, size)
		"tree":
			return _tree_image(node, params, size)
		"particles":
			return _particles_image(node, params, size)
		"scatter":
			return _scatter_image(node, params, size, 0)
		"model3d":
			return _model_image(node, params, size)
		"pixel_art":
			# The picture of the layer itself, colours kept. Without this the node
			# went through the value evaluator, which only knows brightness, and a
			# drawing that never touched a colour node came out grey.
			return _pixel_art_image(node, params, size)
	return null


## Rasterises the stroke of a path node at [param size] and caches it, so the
## per pixel evaluation is just a lookup.
func _path_image(node: Dictionary, params: Dictionary, size: Vector2i) -> Image:
	var key := _raster_key(str(node["id"]), size)
	if _path_cache.has(key):
		return _path_cache[key]
	var image := rasterise_path(params, size)
	_path_cache[key] = image
	return image


## Draws a bare vector path without touching the cache, so the thumbnail on the
## node can be refreshed as soon as the control points change. A path carries no
## stroke of its own, so this is a one pixel line; a canvas node draws it with
## the width and the profile it was given.
func rasterise_path(params: Dictionary, size: Vector2i) -> Image:
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var flat := flatten_path(params.get("points", []), bool(params.get("closed", false)))
	flat = revealed_points(flat, params)
	if flat.size() >= 2:
		var scale := Vector2(size)
		for index in range(flat.size() - 1):
			var from_point: Vector2 = flat[index] * scale
			var to_point: Vector2 = flat[index + 1] * scale
			var span := maxi(int(ceil(from_point.distance_to(to_point) * 2.0)), 1)
			for step in span + 1:
				_stamp_disc(image, from_point.lerp(to_point, float(step) / span), 0.5, 0.0)
	return image


## Cuts a flattened path down to the part that is drawn. A partial stroke is cut
## by length, so the tip stays on the curve instead of jumping to the next
## control point.
static func revealed_points(flat: PackedVector2Array, params: Dictionary) -> PackedVector2Array:
	var points := flat
	if bool(params.get("reveal_reverse", false)):
		points = points.duplicate()
		points.reverse()
	var reveal := clampf(float(params.get("reveal", 1.0)), 0.0, 1.0)
	if reveal < 0.9999:
		points = trim_polyline(points, reveal)
	return points


## Value of a canvas node that draws its path input at [param uv].
func _canvas_path_value(
	node: Dictionary, params: Dictionary, uv: Vector2, size: Vector2i, depth: int
) -> float:
	if uv.x < 0.0 or uv.y < 0.0 or uv.x >= float(size.x) or uv.y >= float(size.y):
		return 0.0
	var image := _canvas_path_image(node, params, size, depth)
	return image.get_pixel(int(uv.x), int(uv.y)).r


## Rasterises the path connected to a canvas node as pixel lines. The path node
## only supplies the curve, so the width, the softening, the fill and the width
## profile along the stroke all come from the canvas node.
func _canvas_path_image(
	node: Dictionary, params: Dictionary, size: Vector2i, depth: int
) -> Image:
	var key := _raster_key(str(node["id"]), size)
	if _path_cache.has(key):
		return _path_cache[key]
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	_path_cache[key] = image
	var path_id := _input_id(node, 0)
	if path_id.is_empty():
		return image
	var path_node := get_node_by_id(path_id)
	if path_node.is_empty() or str(path_node["type"]) != "path":
		return image
	var path_params: Dictionary = params_for(path_node)
	var closed := bool(path_params.get("closed", false))
	var flat := flatten_path(path_params.get("points", []), closed)
	flat = revealed_points(flat, path_params)
	if flat.size() < 2:
		return image
	var shortest := float(mini(size.x, size.y))
	# The profile runs from 0 to 1 along the stroke and picks a width between the
	# two numbers given on the node, so a taper is a curve between a thin tip and
	# a thick middle instead of a fraction of one fixed width.
	var low := float(params.get("width_min", params.get("width", 0.06)))
	var high := float(params.get("width_max", params.get("width", 0.06)))
	if low > high:
		var swap := low
		low = high
		high = swap
	var radius_low := maxf(clampf(low, 0.0, 0.6) * shortest * 0.5, 0.0)
	var radius_high := maxf(clampf(high, 0.0, 0.6) * shortest * 0.5, 0.5)
	var soft := clampf(float(params.get("soft", 0.0)) * shortest, 0.0, radius_high)
	# Filling a half drawn outline would close the loop early, so the fill only
	# appears once the whole path is there.
	if closed and bool(params.get("fill", false)) and flat.size() >= 3:
		var reveal := clampf(float(path_params.get("reveal", 1.0)), 0.0, 1.0)
		if reveal >= 0.9999:
			_fill_polygon(image, flat)
	var profile: Array = params.get("profile", [])
	var scale := Vector2(size)
	# The width follows the position along the stroke, which is what makes a
	# tapered tip or a bulge in the middle possible.
	var total := 0.0
	for index in range(flat.size() - 1):
		total += flat[index].distance_to(flat[index + 1])
	if total <= 0.0001:
		return image
	var walked := 0.0
	for index in range(flat.size() - 1):
		var from_point: Vector2 = flat[index] * scale
		var to_point: Vector2 = flat[index + 1] * scale
		var segment := flat[index].distance_to(flat[index + 1])
		var t_from := walked / total
		walked += segment
		var t_to := walked / total
		var radius_from := lerpf(radius_low, radius_high, profile_at(profile, t_from))
		var radius_to := lerpf(radius_low, radius_high, profile_at(profile, t_to))
		var span := maxi(int(ceil(from_point.distance_to(to_point) * 2.0)), 1)
		for step in span + 1:
			var ratio := float(step) / float(span)
			var radius := lerpf(radius_from, radius_to, ratio)
			# A tip thinner than the softening would smear the whole stroke, so the
			# softening follows the local width.
			_stamp_disc(
				image, from_point.lerp(to_point, ratio), radius, minf(soft, radius)
			)
	return image


## Samples the width profile of a stroke. The array holds evenly spaced values
## from the start of the curve to its end. A Catmull-Rom spline runs through
## them, so five numbers give a taper that curves instead of five straight ramps
## with a kink at every number. The ends repeat their neighbour, which keeps the
## first and last sample flat, and the result is clamped because a spline can
## overshoot a sharp change.
static func profile_at(profile: Array, t: float) -> float:
	var count := profile.size()
	if count <= 0:
		return 1.0
	if count == 1:
		return clampf(float(profile[0]), 0.0, 1.0)
	var position := clampf(t, 0.0, 1.0) * float(count - 1)
	var index := mini(int(floorf(position)), count - 2)
	var ratio := position - float(index)
	var p0 := clampf(float(profile[maxi(index - 1, 0)]), 0.0, 1.0)
	var p1 := clampf(float(profile[index]), 0.0, 1.0)
	var p2 := clampf(float(profile[index + 1]), 0.0, 1.0)
	var p3 := clampf(float(profile[mini(index + 2, count - 1)]), 0.0, 1.0)
	var square := ratio * ratio
	var value := 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * ratio
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * square
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * square * ratio
	)
	return clampf(value, 0.0, 1.0)


## Rasterises the recursive tree at [param size] and caches it per generated
## image, so the per pixel evaluation stays a lookup. Growth is measured in
## levels: a branch appears when the growth reaches its level, and its children
## only start once the branch itself is complete. That is what makes a tree grow
## outward, one generation of branches at a time.
func _tree_image(node: Dictionary, params: Dictionary, size: Vector2i) -> Image:
	var phase := clampf(time, 0.0, 1.0)
	var amount := clampf(float(params.get("growth", 1.0)), 0.0, 1.0)
	# A generic animation on "growth" carries its own clock, so the legacy
	# "随预览时间生长" switch is skipped instead of stacking two timelines.
	if bool(params.get("animate", false)) and not _animates(params, "growth"):
		# Blend between a linear and a smoothstep clock, so the tree slows down
		# as it reaches its final size instead of stopping abruptly.
		var eased := phase * phase * (3.0 - 2.0 * phase)
		amount *= lerpf(phase, eased, clampf(float(params.get("ease", 0.4)), 0.0, 1.0))
	# The shape parameters belong in the key: editing them has to rebuild the
	# image even when the growth did not move. The phase is in there for the
	# sway, which bends the tree without changing the growth.
	var key := _raster_key(str(node["id"]), size)
	if _path_cache.has(key):
		return _path_cache[key]
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	if amount > 0.001:
		var shortest := float(mini(size.x, size.y))
		var depth := clampi(int(params.get("depth", 5)), 1, 7)
		var state := {
			"depth": depth,
			"span": 1.0 / float(depth + 1),
			"branches": clampi(int(params.get("branches", 2)), 1, 4),
			"spread": float(params.get("spread", 34.0)),
			"taper": clampf(float(params.get("taper", 0.72)), 0.4, 0.95),
			"bend": clampf(float(params.get("bend", 0.35)), 0.0, 2.0),
			"randomness": clampf(float(params.get("randomness", 0.3)), 0.0, 1.0),
			"leaves": bool(params.get("leaves", true)),
			"leaf_size": clampf(float(params.get("leaf_size", 1.0)), 0.2, 3.0),
			"soft": clampf(float(params.get("soft", 0.0)) * shortest, 0.0, 2.5),
			"sway": clampf(float(params.get("sway", 0.0)), 0.0, 1.0),
			"sway_speed": clampf(float(params.get("sway_speed", 0.5)), 0.05, 4.0),
			"phase": phase,
		}
		var rng := RandomNumberGenerator.new()
		rng.seed = int(params.get("seed", 3))
		var base := Vector2(float(size.x) * 0.5, float(size.y) * 0.99)
		var thickness := maxf(float(params.get("width", 0.045)) * shortest * 0.5, 0.6)
		var lean := deg_to_rad(float(params.get("lean", 0.0)))
		_grow_branch(
			image, base, -PI * 0.5 + lean, shortest * 0.3, thickness, 0, state, rng, amount
		)
	_path_cache[key] = image
	return image


## Draws one branch and, once it is fully grown, its children. The random numbers
## are taken before the growth check, so the same seed gives the same tree in
## every frame and only the visible part changes.
func _grow_branch(
	image: Image,
	from_point: Vector2,
	direction: float,
	length: float,
	thickness: float,
	level: int,
	state: Dictionary,
	rng: RandomNumberGenerator,
	amount: float
) -> void:
	var depth: int = int(state["depth"])
	var branches: int = int(state["branches"])
	var variability: float = float(state["randomness"])
	var spread := deg_to_rad(float(state["spread"]))
	var curve := rng.randf_range(-1.0, 1.0) * float(state["bend"])
	var child_angles: Array[float] = []
	var child_scales: Array[float] = []
	for index in branches:
		var offset := 0.0
		if branches > 1:
			offset = float(index) / float(branches - 1) * 2.0 - 1.0
		child_angles.append(
			offset * spread + rng.randf_range(-1.0, 1.0) * variability * 0.3
		)
		child_scales.append(1.0 + rng.randf_range(-1.0, 1.0) * variability * 0.25)
	var span: float = float(state["span"])
	var local := clampf((amount - float(level) * span) / span, 0.0, 1.0)
	if local <= 0.0:
		return
	var steps := maxi(int(ceil(length / 2.0)), 2)
	var step_length := length / float(steps)
	var drawn := clampi(int(ceil(float(steps) * local)), 1, steps)
	var brightness := lerpf(0.42, 0.74, float(level) / float(maxi(depth, 1)))
	var soft: float = float(state["soft"])
	var turn := curve * 0.8 / float(steps)
	# Wind bends the branches without touching the growth, and it bends the tips
	# more than the trunk because every level adds its own offset.
	var sway: float = float(state["sway"])
	var angle := direction
	if sway > 0.0:
		var depth_factor := float(level + 1) / float(depth + 1)
		angle += (
			sin(
				float(state["phase"]) * TAU * float(state["sway_speed"])
				+ float(level) * 0.8
			)
			* sway
			* 0.18
			* depth_factor
		)
	var point := from_point
	for step in drawn:
		var along := float(step) / float(steps)
		angle += turn
		var next := point + Vector2.from_angle(angle) * step_length
		_stamp_segment(image, point, next, thickness * (1.0 - 0.45 * along), soft, brightness)
		point = next
	if local < 1.0:
		# Wait for this branch to finish before the next generation appears.
		return
	if level >= depth:
		if bool(state["leaves"]):
			var leaf_radius := maxf(thickness * 2.2 * float(state["leaf_size"]), 0.9)
			_stamp_disc(image, point, leaf_radius, soft, 1.0)
			for index in 2:
				var leaf_angle := TAU * (float(index + 1) / 3.0) + curve
				_stamp_disc(
					image,
					point + Vector2.from_angle(leaf_angle) * leaf_radius * 0.9,
					maxf(leaf_radius * 0.8, 0.7),
					soft,
					1.0
				)
		return
	for index in branches:
		_grow_branch(
			image,
			point,
			angle + child_angles[index],
			length * float(state["taper"]) * child_scales[index],
			thickness * float(state["taper"]),
			level + 1,
			state,
			rng,
			amount
		)


## True when the particle field depends on the phase. Shared by the renderer and
## [method uses_time], so the preview and the generated layer always agree.
static func particles_animate(params: Dictionary) -> bool:
	if absf(float(params.get("speed", 0.0))) > 0.0:
		return true
	if absf(float(params.get("gravity", 0.0))) > 0.0:
		return true
	if float(params.get("turbulence", 0.0)) > 0.0:
		return true
	return float(params.get("twinkle", 0.0)) > 0.0


## Rasterises the pixel particles at [param size] and caches the result per
## generated image. A particle is placed from its own phase offset instead of
## being simulated frame by frame, so any frame can be rendered on its own and
## the sequence loops exactly.
func _particles_image(node: Dictionary, params: Dictionary, size: Vector2i) -> Image:
	var phase := clampf(time, 0.0, 1.0)
	var key := _raster_key(str(node["id"]), size)
	if _path_cache.has(key):
		return _path_cache[key]
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var count := clampi(int(params.get("count", 48)), 1, 256)
	var shortest := float(mini(size.x, size.y))
	var size_vec := Vector2(size)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(params.get("seed", 1))
	var angle := deg_to_rad(float(params.get("angle", -90.0)))
	var spread := deg_to_rad(clampf(float(params.get("spread", 30.0)), 0.0, 180.0))
	var speed := float(params.get("speed", 0.5))
	var gravity := float(params.get("gravity", 0.0))
	var turbulence := clampf(float(params.get("turbulence", 0.0)), 0.0, 1.0)
	var lifetime := clampf(float(params.get("lifetime", 0.8)), 0.1, 1.0)
	var fade := bool(params.get("fade", true))
	var twinkle := clampf(float(params.get("twinkle", 0.0)), 0.0, 1.0)
	var shape := int(params.get("shape", 0))
	var radius := maxf(float(params.get("size", 1.5)), 0.5)
	var soft := clampf(float(params.get("soft", 0.0)) * shortest, 0.0, 2.0)
	var spawn_mode := int(params.get("spawn", 0))
	var wind := clampf(float(params.get("wind", 0.0)), -1.0, 1.0)
	var trail := clampf(float(params.get("trail", 0.0)), 0.0, 0.6)
	var size_random := clampf(float(params.get("size_random", 0.0)), 0.0, 1.0)
	var level_random := clampf(float(params.get("level_random", 0.0)), 0.0, 1.0)
	var speed_end := clampf(float(params.get("speed_end", 1.0)), 0.1, 3.0)
	var size_end := clampf(float(params.get("size_end", 1.0)), 0.1, 3.0)
	# A field that never moves is a plain scattered pattern: every particle shows
	# up for good instead of blinking in and out of the lifetime window.
	var animated := particles_animate(params)
	for index in count:
		# Every random value is taken before the visibility test, so a hidden
		# particle never shifts the randomness of the ones after it.
		var particle_angle := angle + rng.randf_range(-1.0, 1.0) * spread
		var particle_speed := speed * rng.randf_range(0.65, 1.35)
		var offset := rng.randf()
		var spawn := _particle_spawn(spawn_mode, rng.randf(), rng.randf(), size_vec)
		var base_radius := radius
		if size_random > 0.0:
			base_radius = maxf(
				radius * (1.0 + rng.randf_range(-size_random, size_random)), 0.5
			)
		var particle_level := 1.0
		if level_random > 0.0:
			particle_level = 1.0 - level_random * rng.randf()
		var age_phase := fposmod(phase + offset, 1.0) if animated else 0.0
		if animated and age_phase > lifetime:
			continue
		var age := age_phase / lifetime if animated else 0.0
		var position := _particle_at(
			spawn,
			particle_angle,
			particle_speed,
			gravity,
			wind,
			turbulence,
			shortest,
			age_phase,
			offset,
			speed_end
		)
		# A particle can end up bigger or smaller than it was born, which is what
		# turns a spark into a shrinking glint and smoke into a growing puff.
		var radius_now := base_radius
		if not is_equal_approx(size_end, 1.0):
			radius_now = maxf(base_radius * lerpf(1.0, size_end, age), 0.5)
		var brightness := particle_level
		if fade and animated:
			# Fade in at birth and out towards the end, so a recycled particle
			# never pops into view.
			brightness *= clampf(age / 0.12, 0.0, 1.0) * (1.0 - age)
		if twinkle > 0.0:
			brightness *= (
				1.0 - twinkle * 0.5 * (1.0 - sin(phase * TAU * 4.0 + offset * 40.0))
			)
		if brightness > 0.004:
			_particle_stamp(image, position, radius_now, soft, brightness, shape)
		if trail <= 0.0 or not animated:
			continue
		# The trail is the same particle a moment earlier, dimmed a step at a time.
		# Nothing is simulated, so a streak costs only a few more stamps.
		var steps := 3
		for step in steps:
			var past := age_phase - trail * float(step + 1) / float(steps + 1)
			if past <= 0.0:
				continue
			var behind := _particle_at(
				spawn,
				particle_angle,
				particle_speed,
				gravity,
				wind,
				turbulence,
				shortest,
				past,
				offset,
				speed_end
			)
			# The trail follows the same size ramp, so a shrinking particle leaves a
			# tapered streak instead of a bar of equal width.
			var behind_radius := base_radius
			if not is_equal_approx(size_end, 1.0):
				behind_radius = maxf(
					base_radius * lerpf(1.0, size_end, past / lifetime), 0.5
				)
			_particle_stamp(
				image,
				behind,
				behind_radius,
				soft,
				brightness * (1.0 - float(step + 1) / float(steps + 1)),
				shape
			)
	_path_cache[key] = image
	return image


## Where a particle is at [param age_phase] of its life. Everything is computed
## from the phase instead of being stepped, so any frame renders on its own, the
## sequence loops exactly, and a trail is just the same particle a little earlier.
static func _particle_at(
	spawn: Vector2,
	angle: float,
	speed: float,
	gravity: float,
	wind: float,
	turbulence: float,
	shortest: float,
	age_phase: float,
	offset: float,
	speed_end := 1.0
) -> Vector2:
	# A speed that changes over the life of a particle changes how far it has
	# travelled, which is the only thing the shape of the path needs.
	var travel := age_phase
	if not is_equal_approx(speed_end, 1.0):
		travel = age_phase * lerpf(1.0, speed_end, clampf(age_phase, 0.0, 1.0))
	var position := (
		spawn
		+ Vector2.from_angle(angle) * speed * shortest * travel
		+ Vector2(wind * shortest * age_phase, 0.5 * gravity * shortest * age_phase * age_phase)
	)
	if turbulence > 0.0:
		position += (
			Vector2(
				sin(age_phase * TAU * 2.0 + offset * 31.0),
				cos(age_phase * TAU * 3.0 + offset * 17.0)
			)
			* turbulence
			* shortest
			* 0.08
		)
	return position


## Draws one particle in the shape the node was given.
static func _particle_stamp(
	image: Image, center: Vector2, radius: float, soft: float, brightness: float, shape: int
) -> void:
	match shape:
		1:
			_stamp_disc(image, center, radius, soft, brightness)
		2:
			_stamp_diamond(image, center, radius, brightness)
		3:
			_stamp_cross(image, center, radius, brightness)
		_:
			_stamp_square(image, center, radius, brightness)


## Stamps the brush of the first input over the canvas at random angles and sizes
## and caches the result per generated image. The brush is the whole source node,
## so a pixel_art layer holding a single leaf turns into a bush.
func _scatter_image(
	node: Dictionary, params: Dictionary, size: Vector2i, depth: int
) -> Image:
	var key := _raster_key(str(node["id"]), size)
	if _path_cache.has(key):
		return _path_cache[key]
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var source_id := _input_id(node, 0)
	var density_id := _input_id(node, 1)
	if source_id.is_empty():
		_path_cache[key] = image
		return image
	var amount := clampi(int(params.get("amount", 24)), 1, 256)
	var shortest := float(mini(size.x, size.y))
	var spread := clampf(float(params.get("spread", 0.6)), 0.0, 1.5)
	var path_width := clampf(float(params.get("path_width", 0.08)), 0.0, 0.5)
	var follow_tangent := bool(params.get("follow_tangent", true))
	var stamp := maxf(float(params.get("stamp", 0.3)), 0.01)
	var angle := deg_to_rad(float(params.get("angle", 0.0)))
	var angle_random := deg_to_rad(clampf(float(params.get("angle_random", 180.0)), 0.0, 180.0))
	var scale_min := maxf(float(params.get("scale_min", 0.7)), 0.05)
	var scale_max := maxf(float(params.get("scale_max", 1.3)), scale_min)
	var align := bool(params.get("align", true))
	var level := clampf(float(params.get("level", 1.0)), 0.0, 1.0)
	var level_random := clampf(float(params.get("level_random", 0.0)), 0.0, 1.0)
	var distribution := clampi(int(params.get("distribution", 0)), 0, 2)
	var min_gap := shortest * clampf(float(params.get("distance", 0.12)), 0.01, 1.0)
	var columns := clampi(int(params.get("grid_x", 4)), 1, 32)
	var rows := clampi(int(params.get("grid_y", 4)), 1, 32)
	var jitter := clampf(float(params.get("jitter", 0.35)), 0.0, 1.0)
	var sort_y := bool(params.get("sort_y", false))
	var tile := bool(params.get("tile", false))
	var level_from_map := bool(params.get("level_from_map", false))
	var point_at_center := bool(params.get("point_at_center", false))
	var spin := clampf(float(params.get("spin", 0.0)), -2.0, 2.0)
	var scale_per_radius := clampf(float(params.get("scale_per_radius", 0.0)), -1.0, 1.0)
	var field_offset := (
		Vector2(float(params.get("offset_x", 0.0)), float(params.get("offset_y", 0.0)))
		* Vector2(size)
	)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(params.get("seed", 1))
	# Wind. A zero amount keeps the whole calculation out of the stamp loop, so a
	# still scatter costs exactly what it did before this existed.
	var sway_degrees := clampf(float(params.get("sway", 0.0)), 0.0, 90.0)
	var sway_radians := deg_to_rad(sway_degrees)
	var sway_scale := clampf(float(params.get("sway_scale", 1.5)), 0.0, 8.0)
	var wind := Vector2.from_angle(deg_to_rad(float(params.get("sway_angle", 90.0))))
	var sway_wave := clampf(float(params.get("sway_speed", 1.0)), -8.0, 8.0) * time
	var sway_jitter := clampf(float(params.get("sway_jitter", 0.0)), 0.0, 1.0)
	# Something standing in the field: a strength and how wide it reaches.
	var push := clampf(float(params.get("push", 0.0)), 0.0, 1.0)
	var push_radius := clampf(float(params.get("push_radius", 0.25)), 0.02, 1.0)
	# Keep the aspect of a layer brush, so a wide leaf stays wide.
	var footprint := Vector2(shortest * stamp, shortest * stamp)
	# A painted element keeps its own pixels: its size is asked for in pixels, and
	# 0 means the size of the painting itself. A leaf drawn on a 16 px canvas is
	# then 16 px here too, instead of a fraction of a much larger canvas.
	var brush_pixels := clampi(int(params.get("brush_px", 0)), 0, 256)
	var source_node := get_node_by_id(source_id)
	if not source_node.is_empty() and str(source_node["type"]) == "pixel_art":
		var brush_params := params_for(source_node)
		var brush_mode := int(brush_params.get("source", 0))
		# A layer or a painting has an aspect worth keeping; a path brush is square
		# and keeps the square footprint.
		var brush := (
			_canvas_image(source_node, brush_params, size, depth)
			if brush_mode == 0 or brush_mode == 2
			else null
		)
		if brush != null and not brush.is_empty():
			# The aspect of the cropped brush, not of the whole layer, so a
			# cropped leaf keeps its own shape.
			var region := source_crop(
				brush_params, Vector2i(brush.get_width(), brush.get_height())
			)
			if brush_mode == 2:
				# A painting is a sprite: the cropped part is the element, so the
				# stamp is that many output pixels unless a size is asked for. The
				# canvas behind the painting never stretches it.
				var edge := maxi(maxi(region.size.x, region.size.y), 1)
				if brush_pixels > 0:
					edge = brush_pixels
				footprint = Vector2(edge, edge)
			var aspect := float(region.size.x) / float(maxi(region.size.y, 1))
			if aspect >= 1.0:
				footprint.y = footprint.x / aspect
			else:
				footprint.x = footprint.y * aspect
	var center := Vector2(size) * 0.5
	var reach := Vector2(shortest * spread * 0.5, shortest * spread * 0.5)
	var mode := int(params.get("mode", 0))
	# A lattice needs cells, so it replaces the amount with one stamp per cell. It
	# only applies to the area mode, where a grid over the canvas means something.
	var lattice := distribution == 2 and mode == 0
	if lattice:
		amount = columns * rows
	# Over a drawing: the stamps sit on the opaque part of the second input, so a
	# canvas that grows from a path animates the scatter by itself — the shape it
	# shows is exactly what is being scattered over.
	var mask_points := PackedVector2Array()
	if mode == 2 and not density_id.is_empty():
		mask_points = _coverage_points(density_id, size, depth)
	# Along a path the brush follows the curve, and the path's own reveal limits
	# how far it may go, so animating that reveal grows the scatter.
	var along_path := false
	var path_points := PackedVector2Array()
	if mode == 1 and not density_id.is_empty():
		var path_node := get_node_by_id(density_id)
		if not path_node.is_empty() and str(path_node["type"]) == "path":
			var path_params: Dictionary = params_for(path_node)
			var flat := flatten_path(
				path_params.get("points", []), bool(path_params.get("closed", false))
			)
			var reveal := clampf(float(path_params.get("reveal", 1.0)), 0.0, 1.0)
			if bool(path_params.get("reveal_reverse", false)):
				flat.reverse()
			if reveal < 0.9999:
				flat = trim_polyline(flat, reveal)
			if flat.size() >= 2:
				path_points = flat
				along_path = true
	var size_vec := Vector2(size)
	# Every placement is decided before anything is stamped, so the stamps can be
	# sorted by Y and a minimum distance can be kept between them.
	var placements: Array = []
	# The distance rule turns some candidates down, so more of them are drawn than
	# the amount of stamps that is wanted.
	var attempts := amount if distribution != 1 else mini(amount * 4, 512)
	for index in attempts:
		# Every random value is taken before the density test, so hiding one
		# stamp does not reshuffle the rest of the field.
		var across := rng.randf_range(-1.0, 1.0)
		var down := rng.randf_range(-1.0, 1.0)
		var rotation := angle + deg_to_rad(rng.randf_range(-angle_random, angle_random))
		var stamp_scale := rng.randf_range(scale_min, scale_max)
		var chance := rng.randf()
		var brightness := level
		if level_random > 0.0:
			# Each stamp keeps a brightness of its own, which is what turns a patch
			# of leaves into something with depth instead of a flat cut out.
			brightness = clampf(
				level * (1.0 + rng.randf_range(-level_random, level_random)), 0.0, 1.0
			)
		var position: Vector2
		if lattice:
			# One stamp per cell, nudged inside it so the grid does not read as
			# machine made. The lattice covers the area the random mode uses.
			var column := index % columns
			var row := floori(float(index) / float(columns))
			var cell := Vector2(float(column) + 0.5, float(row) + 0.5)
			position = (
				size_vec * 0.5
				+ (cell / Vector2(float(columns), float(rows)) - Vector2(0.5, 0.5))
				* size_vec
				* spread
			)
			position += (
				Vector2(rng.randf_range(-0.5, 0.5), rng.randf_range(-0.5, 0.5))
				* size_vec
				/ Vector2(float(columns), float(rows))
				* jitter
			)
		elif mode == 2:
			if mask_points.is_empty():
				continue
			# Stratified slots over the scanned points, so the stamps arrive along
			# the shape the way it was drawn instead of clumping.
			var slot := (float(index) + rng.randf_range(0.0, 1.0)) / float(attempts)
			var pick := clampi(
				int(slot * float(mask_points.size())), 0, mask_points.size() - 1
			)
			position = mask_points[pick] * size_vec
			position += Vector2(across, down) * shortest * spread * 0.06
		elif along_path:
			# Stratified slots keep the stamps spread evenly instead of clumping.
			var slot := (float(index) + rng.randf_range(0.0, 1.0)) / float(attempts)
			var sample: Dictionary = _path_point_at(path_points, slot)
			var direction: Vector2 = sample["direction"]
			if follow_tangent and direction.length_squared() > 0.0:
				rotation += direction.angle()
			position = (sample["point"] as Vector2) * size_vec
			position += Vector2(-direction.y, direction.x) * across * shortest * path_width * 0.5
		else:
			position = center + Vector2(across * reach.x, down * reach.y)
		position += field_offset
		if align:
			position = position.round()
		var density := 1.0
		# With a pusher in the field the second input is read as that, so it no
		# longer thins the stamps out: pushing and thinning at the same time would
		# mean two very different meanings for one wire.
		if push <= 0.0 and not density_id.is_empty() and not along_path and mode != 2:
			density = clampf(_eval(density_id, position, size, depth + 1), 0.0, 1.0)
			if density < chance:
				continue
		if level_from_map and not density_id.is_empty():
			# The stamp takes the brightness the second input has at its position,
			# which is what lets a gradient or a drawing light the scatter.
			brightness = clampf(
				brightness * clampf(_eval(density_id, position, size, depth + 1), 0.0, 1.0),
				0.0,
				1.0
			)
		# Radial shaping: with these the same field becomes a burst, a ring or a
		# spiral, because each stamp turns and grows with its distance to the middle.
		var radius := position.distance_to(center)
		if point_at_center:
			rotation += (position - center).angle()
		if not is_zero_approx(spin):
			rotation += radius / maxf(shortest, 1.0) * spin * TAU
		if not is_zero_approx(scale_per_radius):
			stamp_scale *= maxf(
				1.0 + scale_per_radius * (radius / maxf(shortest * 0.5, 1.0)), 0.05
			)
		if push > 0.0 and not density_id.is_empty() and not along_path and mode != 2:
			# The gradient of the field points into the pusher, so the stamps step
			# the other way and tip over with the push. Sampling it over a radius
			# wide enough to see a whole shape keeps the direction from flipping on
			# the noise of a single pixel.
			var pressed := clampf(_eval(density_id, position, size, depth + 1), 0.0, 1.0)
			if pressed > 0.02:
				# Sampled well inside the pusher, not across the whole of it: a step
				# as wide as the shape reads the same value on both sides and comes
				# back with no direction at all, which is what made the push look
				# like it did nothing.
				var step := maxf(push_radius * shortest * 0.3, 1.5)
				var ahead := clampf(
					_eval(density_id, position + Vector2(step, 0.0), size, depth + 1), 0.0, 1.0
				)
				var behind := clampf(
					_eval(density_id, position - Vector2(step, 0.0), size, depth + 1), 0.0, 1.0
				)
				var under := clampf(
					_eval(density_id, position + Vector2(0.0, step), size, depth + 1), 0.0, 1.0
				)
				var over := clampf(
					_eval(density_id, position - Vector2(0.0, step), size, depth + 1), 0.0, 1.0
				)
				var into := Vector2(ahead - behind, under - over)
				if into.length_squared() > 0.0001:
					var away := -into.normalized()
					# The shove is measured against the canvas, not against the
					# sampling radius: at full strength a stamp standing right on the
					# pusher moves half the short edge, which is what actually parts
					# the field instead of nudging it.
					position += away * (push * pressed * shortest * 0.5)
					rotation += deg_to_rad(push * 30.0 * pressed) * signf(away.x)
					if align:
						position = position.round()
		if sway_degrees > 0.0:
			# One wave over the field, advancing with the clock. The position is in
			# pixels, so it is measured against the short edge to stay square. The
			# jitter gives each stamp a phase of its own, which is what turns a field
			# leaning in one piece into grass rippling.
			var crossing := position.dot(wind) / maxf(shortest, 1.0)
			var phase := crossing * sway_scale + sway_wave
			if sway_jitter > 0.0:
				phase += sway_jitter * _position_seed(position)
			rotation += sway_radians * sin(TAU * phase)
		if distribution == 1 and not _scatter_has_room(placements, position, min_gap):
			continue
		placements.append(
			{
				"position": position,
				"rotation": rotation,
				"scale": stamp_scale,
				"level": brightness,
			}
		)
		if distribution == 1 and placements.size() >= amount:
			break
	if sort_y:
		# Smaller Y first, so the stamps lower on the canvas are drawn last and end
		# up in front. That is what gives a bush of leaves its depth.
		placements.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool:
				return float((a["position"] as Vector2).y) < float((b["position"] as Vector2).y)
		)
	# A brush that is not a canvas is drawn once for the whole field. A canvas is
	# left alone: it resolves its own crop and channel per stamp, which is a
	# different job from reading a value field.
	var brush: Image = null
	var brush_node := get_node_by_id(source_id)
	if not brush_node.is_empty() and str(brush_node["type"]) != "pixel_art":
		brush = _brush_field(source_id, size, depth)
	for place: Dictionary in placements:
		_stamp_source(
			image,
			source_id,
			place["position"],
			float(place["rotation"]),
			float(place["scale"]),
			footprint,
			size,
			depth,
			float(place["level"]),
			tile,
			sort_y,
			brush
		)
	_path_cache[key] = image
	return image


## True when a stamp at [param position] keeps the minimum gap to the stamps that
## were already placed, which is what spreads a scatter evenly instead of letting
## it clump in one corner.
static func _scatter_has_room(placements: Array, position: Vector2, min_gap: float) -> bool:
	var limit := min_gap * min_gap
	for place: Dictionary in placements:
		if (place["position"] as Vector2).distance_squared_to(position) < limit:
			return false
	return true


## Deterministic value between 0 and 1 from a position, so a field can give every
## stamp a phase of its own without keeping a list of them. The constants are the
## ones the pixel grass demo uses for its location seeds.
static func _position_seed(point: Vector2) -> float:
	return fposmod(sin(point.x * 12.9898 + point.y * 78.233) * 43758.5453, 1.0)
	
	
## Picture a canvas node stands for: the layer of its drawing area, the painting
## made in its window, or the stroke it draws from its path. The scatter uses it
## for both the area it stamps over and the opacity of the brush, so a canvas
## painted in the drawing window scatters over its own picture instead of over a
## project layer that has nothing to do with it.
func _canvas_image(
	node: Dictionary, params: Dictionary, size: Vector2i, depth: int
) -> Image:
	match int(params.get("source", 0)):
		1:
			return _canvas_path_image(node, params, size, depth)
		2:
			return painting_image(node, params)
	return _source_image(node, params)


## The canvas node as a picture at [param size]: its layer (or painting) cropped and
## stretched the way the node samples it, colours kept. A canvas read through its
## transparency is coverage rather than a picture, so those stay on the value path
## and keep the mask meaning they were given.
func _pixel_art_image(node: Dictionary, params: Dictionary, size: Vector2i) -> Image:
	if int(params.get("source", 0)) == 1:
		# A stroke drawn from a path paints its own colour in the evaluator.
		return null
	if int(params.get("channel", 0)) != 0:
		return null
	var source := _canvas_image(node, params, size, 0)
	if source == null or source.is_empty():
		return null
	var crop := source_crop(params, Vector2i(source.get_width(), source.get_height()))
	var picture := source.get_region(crop)
	picture.convert(Image.FORMAT_RGBA8)
	if picture.get_width() != size.x or picture.get_height() != size.y:
		picture.resize(maxi(size.x, 1), maxi(size.y, 1), Image.INTERPOLATE_NEAREST)
	return picture


## Node behind the brush input of a scatter node, or an empty dictionary. The
## parameter panel uses it to ask for a pixel size when the brush is a painting.
func brush_node(node_id: String) -> Dictionary:
	var node := get_node_by_id(node_id)
	if node.is_empty():
		return {}
	var source_id := _input_id(node, 0)
	if source_id.is_empty():
		return {}
	return get_node_by_id(source_id)


## Image a branch can hand out directly, or null when it has to be sampled. A
## canvas node answers with its drawing area, its painting or its stroke, a path
## node with its line, which is what makes "scatter over this drawing" exact and
## cheap.
func _branch_image(node_id: String, size: Vector2i, depth: int) -> Image:
	var owner := get_node_by_id(node_id)
	if owner.is_empty():
		return null
	var params: Dictionary = params_for(owner)
	match str(owner["type"]):
		"pixel_art":
			return _canvas_image(owner, params, size, depth)
		"path":
			return _path_image(owner, params, size)
	return null


## Whole picture of a brush branch, drawn once and cached across frames. A brush
## that is a chain of transform nodes over a raster has no image of its own, so
## the scatter used to sample the whole branch again for every pixel of every
## stamp; with a hundred blades in the field that was most of a frame.
func _brush_field(source_id: String, size: Vector2i, depth: int) -> Image:
	if source_id.is_empty():
		return null
	if get_node_by_id(source_id).is_empty():
		return null
	# A branch that already owns a picture hands it over without a copy.
	var direct := _branch_image(source_id, size, depth)
	if direct != null:
		return direct
	var key := _raster_key(source_id, size)
	if _path_cache.has(key):
		return _path_cache[key]
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	for y in size.y:
		for x in size.x:
			var value := clampf(_eval(source_id, Vector2(x, y), size, depth + 1), 0.0, 1.0)
			if value > 0.0:
				image.set_pixel(x, y, Color(value, value, value, 1.0))
	_path_cache[key] = image
	return image
	
	
## Points of the drawn part of a branch, in 0..1 canvas coordinates, in the order
## they are scanned. A canvas or a path node is read from its image; anything else
## is sampled through the evaluator, so a mask field works as an area too. The
## scan stops at 128 cells on the long edge, which is plenty for placing stamps.
func _coverage_points(node_id: String, size: Vector2i, depth: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	var image := _branch_image(node_id, size, depth)
	var grid := size
	var use_image := image != null and not image.is_empty()
	if use_image:
		grid = Vector2i(image.get_width(), image.get_height())
	if grid.x <= 0 or grid.y <= 0:
		return points
	# The scan only needs red and alpha, so an RGBA image is read as bytes. A
	# painting of a full canvas is 16k samples otherwise, and this runs again for
	# every stroke that changes it.
	var bytes := PackedByteArray()
	if use_image and image.get_format() == Image.FORMAT_RGBA8:
		bytes = image.get_data()
	var step := maxi(int(ceil(float(maxi(grid.x, grid.y)) / 128.0)), 1)
	for y in range(0, grid.y, step):
		for x in range(0, grid.x, step):
			var coverage := 0.0
			if not bytes.is_empty():
				var at: int = (y * grid.x + x) * 4
				coverage = maxf(float(bytes[at]), float(bytes[at + 3])) / 255.0
			elif use_image:
				var color := image.get_pixel(x, y)
				# A stroke keeps its coverage in the brightness, a drawn area
				# keeps it in the alpha channel, so the larger of the two counts.
				coverage = maxf(color.r, color.a)
			else:
				coverage = clampf(_eval(node_id, Vector2(x, y), grid, depth + 1), 0.0, 1.0)
			if coverage <= 0.5:
				continue
			points.append(Vector2(float(x) / float(grid.x), float(y) / float(grid.y)))
	return points
	
	
	## Draws one brush stamp. Every destination pixel is mapped back into the brush,
## so rotation and scaling stay pixel exact instead of smearing the brush.
func _stamp_source(
	image: Image,
	source_id: String,
	position: Vector2,
	rotation: float,
	scale: float,
	footprint: Vector2,
	size: Vector2i,
	depth: int,
	level := 1.0,
	tile := false,
	overwrite := false,
	prebuilt: Image = null
) -> void:
	var scaled := footprint * maxf(scale, 0.01)
	var reach := int(ceil(scaled.length() * 0.5)) + 1
	var center := Vector2i(roundi(position.x), roundi(position.y))
	var size_vec := Vector2(size)
	# The brush shape is resolved once per stamp. A pixel_art layer supplies its
	# opacity only, so the colours of the artwork never leak into the pattern and
	# the colour of the scatter node stays in charge.
	var mask_image: Image = null
	var mask_crop := Rect2i()
	var source_node := get_node_by_id(source_id)
	if not source_node.is_empty() and str(source_node["type"]) == "pixel_art":
		var source_params := params_for(source_node)
		# A canvas that shows a layer or a painting stamps the opacity of that
		# picture, so a brush painted in the drawing window keeps its shape. In path
		# mode the node already is a mask, so its value is used as it is.
		var brush_mode := int(source_params.get("source", 0))
		if brush_mode == 0 or brush_mode == 2:
			mask_image = _canvas_image(source_node, source_params, size, depth)
			if mask_image == null or mask_image.is_empty():
				return
			mask_crop = source_crop(
				source_params, Vector2i(mask_image.get_width(), mask_image.get_height())
			)
	for offset_y in range(-reach, reach + 1):
		var y := center.y + offset_y
		if tile:
			# A tiled pattern continues on the other side instead of stopping at
			# the edge, which is what makes the artwork seamless.
			y = wrapi(y, 0, size.y)
		elif y < 0 or y >= size.y:
			continue
		for offset_x in range(-reach, reach + 1):
			var x := center.x + offset_x
			if tile:
				x = wrapi(x, 0, size.x)
			elif x < 0 or x >= size.x:
				continue
			# -0.5..0.5 across the brush, then rotated back into brush space.
			var local := Vector2(float(offset_x), float(offset_y)) / scaled
			var brush_local := local.rotated(-rotation)
			if absf(brush_local.x) > 0.5 or absf(brush_local.y) > 0.5:
				continue
			var uv := (brush_local + Vector2(0.5, 0.5)) * size_vec
			var mask := 0.0
			if mask_image != null:
				mask = sample_source(mask_image, 1, false, uv, size, mask_crop)
			elif prebuilt != null:
				# The brush was drawn once for the whole field, so a stamp is a read
				# instead of an evaluation of the branch for every one of its pixels.
				mask = prebuilt.get_pixel(
					clampi(int(uv.x), 0, prebuilt.get_width() - 1),
					clampi(int(uv.y), 0, prebuilt.get_height() - 1)
				).r
			else:
				mask = _eval(source_id, uv, size, depth + 1)
			var value := clampf(mask * level, 0.0, 1.0)
			if value <= 0.0:
				continue
			# A stamp ordered by Y paints over what is already there, which is what
			# lets a nearer leaf cover a farther one. Without ordering the brightest
			# stamp wins instead, so overlapping stamps never get darker.
			if overwrite or value > image.get_pixel(x, y).r:
				image.set_pixel(x, y, Color(value, value, value, 1.0))


## Birth point of a particle, in pixels. The two random values are shared by all
## the modes, so switching the mode does not reshuffle the whole field.
static func _particle_spawn(
	mode: int, across: float, down: float, size_vec: Vector2
) -> Vector2:
	match mode:
		1:  # 顶部下落
			return Vector2(across * size_vec.x, -1.0)
		2:  # 中心爆发
			return size_vec * 0.5 + (Vector2(across, down) - Vector2(0.5, 0.5)) * size_vec * 0.06
		3:  # 全画布
			return Vector2(across * size_vec.x, down * size_vec.y)
	# 底部升起
	return Vector2(across * size_vec.x, size_vec.y + 1.0)


## Even odd scanline fill of a closed path, in 0..1 canvas units.
static func _fill_polygon(image: Image, flat: PackedVector2Array) -> void:
	var scale := Vector2(image.get_width(), image.get_height())
	var points := PackedVector2Array()
	for point in flat:
		points.append(point * scale)
	var count := points.size()
	for y in image.get_height():
		var scan := float(y) + 0.5
		var crossings: Array[float] = []
		for index in count:
			var a: Vector2 = points[index]
			var b: Vector2 = points[(index + 1) % count]
			if (a.y <= scan and b.y > scan) or (b.y <= scan and a.y > scan):
				var ratio := (scan - a.y) / (b.y - a.y)
				crossings.append(a.x + ratio * (b.x - a.x))
		crossings.sort()
		var pair := 0
		while pair + 1 < crossings.size():
			var from_x := maxi(int(ceil(crossings[pair])), 0)
			var to_x := mini(int(floor(crossings[pair + 1])), image.get_width() - 1)
			for x in range(from_x, to_x + 1):
				image.set_pixel(x, y, Color(1.0, 1.0, 1.0, 1.0))
			pair += 2


## Values of the branch feeding input [param slot] of [param node], one float per
## pixel. Built once per generation and size, so a node that reads its neighbours
## pays for the branch once instead of once per sample. Outside the canvas the
## field is read as empty by the callers.
func _field_of(
	node: Dictionary, slot: int, size: Vector2i, depth: int
) -> PackedFloat32Array:
	var source_id := _input_id(node, slot)
	if source_id.is_empty() or size.x <= 0 or size.y <= 0:
		return PackedFloat32Array()
	var key := "%s|%d|%d" % [source_id, size.x, size.y]
	var cached: Variant = _field_cache.get(key, null)
	if cached != null:
		var field_value: PackedFloat32Array = cached
		return field_value
	var field := PackedFloat32Array()
	field.resize(size.x * size.y)
	var index := 0
	for y in size.y:
		for x in size.x:
			field[index] = clampf(
				_eval(source_id, Vector2(float(x), float(y)), size, depth + 1), 0.0, 1.0
			)
			index += 1
	_field_cache[key] = field
	return field


## Mask of [param node] at [param uv], read from the cached field of the second
## input. 1 when nothing is connected, so an unmasked node changes nothing.
func _mask_at(node: Dictionary, uv: Vector2, size: Vector2i, depth: int) -> float:
	if _input_id(node, 1).is_empty():
		return 1.0
	var mask := _field_of(node, 1, size, depth)
	if mask.is_empty():
		return 1.0
	var px := clampi(int(uv.x), 0, size.x - 1)
	var py := clampi(int(uv.y), 0, size.y - 1)
	return mask[py * size.x + px]


## Value of the optional mask on the second input, 1 when nothing is connected.
func _mask_value(node: Dictionary, uv: Vector2, size: Vector2i, depth: int) -> float:
	var mask_id := _input_id(node, 1)
	if mask_id.is_empty():
		return 1.0
	return clampf(_eval(mask_id, uv, size, depth + 1), 0.0, 1.0)


## Average of the bright samples around [param uv], used by glow and bloom. Only
## samples above [param tolerance] contribute, and the ring falloff softens them.
func _halo(
	node: Dictionary,
	uv: Vector2,
	size: Vector2i,
	depth: int,
	radius_px: float,
	tolerance: float
) -> float:
	var rings := maxi(int(ceil(radius_px)), 1)
	var total := 0.0
	var samples := 0
	for ring in range(1, rings + 1):
		var falloff := 1.0 - float(ring) / float(rings + 1)
		for index in 8:
			var offset := Vector2.from_angle(TAU * float(index) / 8.0) * float(ring)
			var value := clampf(
				_eval(_input_id(node, 0), uv + offset, size, depth + 1), 0.0, 1.0
			)
			samples += 1
			if value > tolerance:
				total += value * falloff
	return clampf(total / float(maxi(samples, 1)), 0.0, 1.0)


static func _stamp_disc(
	image: Image, center: Vector2, radius: float, soft: float, brightness := 1.0
) -> void:
	var extent := int(ceil(radius))
	var middle := Vector2i(roundi(center.x), roundi(center.y))
	for offset_y in range(-extent, extent + 1):
		for offset_x in range(-extent, extent + 1):
			var x := middle.x + offset_x
			var y := middle.y + offset_y
			if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
				continue
			var distance := Vector2(offset_x, offset_y).length()
			if distance > radius:
				continue
			var value := brightness
			if soft > 0.0 and distance > radius - soft:
				value = brightness * clampf((radius - distance) / soft, 0.0, 1.0)
			if value > image.get_pixel(x, y).r:
				image.set_pixel(x, y, Color(value, value, value, 1.0))


## Stamps a square of pixels, which is what a pixel particle is made of.
static func _stamp_square(
	image: Image, center: Vector2, radius: float, brightness: float
) -> void:
	var span := maxi(int(round(radius * 2.0)), 1)
	var start := Vector2i(roundi(center.x), roundi(center.y)) - Vector2i(span / 2, span / 2)
	for offset_y in span:
		for offset_x in span:
			var x := start.x + offset_x
			var y := start.y + offset_y
			if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
				continue
			if brightness > image.get_pixel(x, y).r:
				image.set_pixel(x, y, Color(brightness, brightness, brightness, 1.0))


## Stamps a diamond, which reads as a sparkle or a leaf at pixel sizes.
static func _stamp_diamond(
	image: Image, center: Vector2, radius: float, brightness: float
) -> void:
	var extent := maxi(int(ceil(radius)), 1)
	var middle := Vector2i(roundi(center.x), roundi(center.y))
	for offset_y in range(-extent, extent + 1):
		for offset_x in range(-extent, extent + 1):
			var x := middle.x + offset_x
			var y := middle.y + offset_y
			if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
				continue
			if absf(float(offset_x)) + absf(float(offset_y)) > radius:
				continue
			if brightness > image.get_pixel(x, y).r:
				image.set_pixel(x, y, Color(brightness, brightness, brightness, 1.0))


## Stamps a plus sign, the classic pixel glint.
static func _stamp_cross(
	image: Image, center: Vector2, radius: float, brightness: float
) -> void:
	var middle := Vector2i(roundi(center.x), roundi(center.y))
	var arm := maxi(int(round(radius)), 1)
	for step in range(-arm, arm + 1):
		for point: Vector2i in [middle + Vector2i(step, 0), middle + Vector2i(0, step)]:
			if point.x < 0 or point.y < 0:
				continue
			if point.x >= image.get_width() or point.y >= image.get_height():
				continue
			if brightness > image.get_pixel(point.x, point.y).r:
				image.set_pixel(point.x, point.y, Color(brightness, brightness, brightness, 1.0))


## Stamps a line of discs, the way a branch of the tree is drawn.
static func _stamp_segment(
	image: Image,
	from_point: Vector2,
	to_point: Vector2,
	radius: float,
	soft: float,
	brightness: float
) -> void:
	var span := maxi(int(ceil(from_point.distance_to(to_point) * 2.0)), 1)
	for step in span + 1:
		_stamp_disc(
			image,
			from_point.lerp(to_point, float(step) / float(span)),
			radius,
			soft,
			brightness
		)


## The project layer picked by a pixel_art node, cached for this generation.
## A pixel cel only stores the rectangle that was painted, together with an
## offset, so the cel is composed onto a canvas sized image here. Reading the cel
## image directly would treat a one pixel cel as the whole artwork.
func _source_image(node: Dictionary, params: Dictionary) -> Image:
	var key := str(node["id"])
	# One picture per node, tagged with the frame and layer it was read from. A
	# plain per-node cache meant changing 「帧号」 kept handing back the frame that
	# was read first, so the number moved and nothing on screen followed it.
	var signature := _source_signature(params)
	var cached: Variant = _source_cache.get(key)
	if cached is Dictionary and int((cached as Dictionary).get("signature", 0)) == signature:
		return (cached as Dictionary).get("image", null)
	var cel := source_cel(node)
	var image: Image = null
	var project = Global.current_project
	if cel != null and project != null:
		var source: Image = cel.get_image()
		if source != null and not source.is_empty():
			var canvas: Vector2i = project.size
			if source.get_width() == canvas.x and source.get_height() == canvas.y:
				image = source
			else:
				image = _compose_cel(source, cel.offset, canvas)
	_source_cache[key] = {"signature": signature, "image": image}
	return image


## What makes one read of a node's source different from the next: the source
## kind, and the frame and layer it looks at. Used as the cache tag instead of a
## per-value key, so a frame number that keeps changing replaces one picture
## rather than piling up one per value — a phone cannot hold hundreds of
## canvas-sized images.
static func _source_signature(params: Dictionary) -> int:
	return hash(
		[
			int(params.get("source", 0)),
			int(params.get("frame_mode", 0)),
			int(params.get("frame", 0)),
			int(params.get("layer", 0)),
		]
	)


## Draws a cel image onto a transparent canvas sized picture at [param offset],
## which is how the drawing area shows it.
##
## The cel is clipped to the canvas first, because a cel that was dragged past an
## edge has a negative offset — and Image.blend_rect walks the destination pixel
## buffer without bounds checks, so a negative destination is an out-of-bounds
## write in the engine itself. On Android that is a crash of the whole app, not a
## script error, which is why reading such a frame used to kill the process.
static func _compose_cel(source: Image, offset: Vector2i, canvas: Vector2i) -> Image:
	var composed := Image.create_empty(
		maxi(canvas.x, 1), maxi(canvas.y, 1), false, Image.FORMAT_RGBA8
	)
	composed.fill(Color(0.0, 0.0, 0.0, 0.0))
	var layer := source
	if source.get_format() != Image.FORMAT_RGBA8:
		layer = source.duplicate()
		layer.convert(Image.FORMAT_RGBA8)
	var target := Rect2i(offset, layer.get_size()).intersection(
		Rect2i(Vector2i.ZERO, composed.get_size())
	)
	if target.size.x <= 0 or target.size.y <= 0:
		return composed
	composed.blend_rect(
		layer, Rect2i(target.position - offset, target.size), target.position
	)
	return composed


## Cel a canvas node reads. The small drawing window paints into the same cel,
## so what is drawn there becomes the material of the node.
func source_cel(node: Dictionary) -> BaseCel:
	var project = Global.current_project
	if project == null or project.frames.is_empty() or project.layers.is_empty():
		return null
	var params: Dictionary = params_for(node)
	var frame_index := clampi(project.current_frame, 0, project.frames.size() - 1)
	match int(params.get("frame_mode", 0)):
		1:
			frame_index = clampi(int(params.get("frame", 0)), 0, project.frames.size() - 1)
		2:
			var frame_count: int = project.frames.size()
			frame_index = clampi(int(floorf(time * float(frame_count))), 0, frame_count - 1)
	var layer_index := clampi(int(params.get("layer", 0)), 0, project.layers.size() - 1)
	var frame: Frame = project.frames[frame_index]
	# A cel list shorter than the layer list would index past its end. Reading a
	# frame the node cannot describe is "no image", not a crash.
	if layer_index >= frame.cels.size():
		return null
	var cel = frame.cels[layer_index]
	if cel is BaseCel:
		return cel
	return null


## Drops the cached layer images, so the preview reads the artwork again after
## the drawing window painted into it. Rasters can have the artwork baked into
## them, so they cannot outlive it either.
func clear_source_cache() -> void:
	_source_cache.clear()
	_path_cache.clear()
	_raster_keys.clear()
	_raster_sigs.clear()
	_source_generation += 1


## The picture behind a pixel_art node, for the editor preview. It is either the
## layer the node reads or the painting stored in the node itself.
func source_image(node: Dictionary) -> Image:
	var params: Dictionary = params_for(node)
	if int(params.get("source", 0)) == 2:
		return painting_image(node, params)
	return _source_image(node, params)


## Painting of a canvas node, decoded from the PNG stored in its parameters. The
## stored string is part of the cache key, so redoing a stroke or undoing it finds
## the right picture without any extra invalidation.
func painting_image(node: Dictionary, params: Dictionary) -> Image:
	var stored := str(params.get("painting", ""))
	if stored.is_empty():
		return null
	var key := str(node["id"])
	var cached: Dictionary = _painting_cache.get(key, {})
	if str(cached.get("data", "")) == stored:
		return cached.get("image", null)
	var image: Image = null
	var bytes := Marshalls.base64_to_raw(stored)
	if not bytes.is_empty():
		var decoded := Image.new()
		if decoded.load_png_from_buffer(bytes) == OK:
			image = decoded
	_painting_cache[key] = {"data": stored, "image": image}
	return image


## Stores a painting on a canvas node as a PNG inside the graph. Nothing is written
## to a project layer, so other canvas nodes keep their own picture, and the PNG
## travels with the project file.
func set_painting(node_id: String, image: Image) -> void:
	var node := get_node_by_id(node_id)
	if node.is_empty() or image == null or image.is_empty():
		return
	var params: Dictionary = node["params"]
	params["painting"] = Marshalls.raw_to_base64(image.save_png_to_buffer())
	_painting_cache.erase(node_id)


## Value of a canvas node in window mode at [param uv]. The stored picture is
## stretched over the canvas the same way a layer is, so the crop numbers and the
## channel switch keep working.
func _painting_value(
	node: Dictionary, params: Dictionary, uv: Vector2, size: Vector2i
) -> float:
	var image := painting_image(node, params)
	if image == null or image.is_empty():
		return 0.0
	return sample_source(
		image,
		int(params.get("channel", 0)),
		bool(params.get("invert", false)),
		uv,
		size,
		source_crop(params, image.get_size())
	)


## Size of the layer behind a pixel_art node, or a zero vector when the layer
## cannot be read. Node labels show it as the canvas size.
func source_image_size(node: Dictionary) -> Vector2i:
	var image := source_image(node)
	if image == null or image.is_empty():
		return Vector2i.ZERO
	return Vector2i(image.get_width(), image.get_height())


## Cropped rectangle of the layer behind a pixel_art node, clamped to the image.
func source_region(node: Dictionary) -> Rect2i:
	var image_size := source_image_size(node)
	if image_size.x <= 0 or image_size.y <= 0:
		return Rect2i()
	return source_crop(params_for(node), image_size)


## Value of a pixel_art node at [param uv]. The cropped part of the source image
## is stretched over the generated image, so the preview at a lower resolution
## still lines up.
func _source_value(node: Dictionary, params: Dictionary, uv: Vector2, size: Vector2i) -> float:
	var image := _source_image(node, params)
	if image == null or image.is_empty():
		return 0.0
	return sample_source(
		image,
		int(params.get("channel", 0)),
		bool(params.get("invert", false)),
		uv,
		size,
		source_crop(params, Vector2i(image.get_width(), image.get_height()))
	)


## Crop rectangle of a pixel_art node in image pixels. A width or height of 0
## means the rest of the image, and the result is always inside the image, so a
## layer that shrank underneath a node never reads out of bounds.
static func source_crop(params: Dictionary, image_size: Vector2i) -> Rect2i:
	var width := maxi(image_size.x, 1)
	var height := maxi(image_size.y, 1)
	var x := clampi(int(params.get("crop_x", 0)), 0, width - 1)
	var y := clampi(int(params.get("crop_y", 0)), 0, height - 1)
	var crop_width := int(params.get("crop_w", 0))
	var crop_height := int(params.get("crop_h", 0))
	var right := width if crop_width <= 0 else mini(x + crop_width, width)
	var bottom := height if crop_height <= 0 else mini(y + crop_height, height)
	return Rect2i(x, y, maxi(right - x, 1), maxi(bottom - y, 1))


## Reads one pixel of [param image] as a value. Split out from the node so it can
## be tested without a project behind it. [param crop] limits the sampled area,
## which is how a pixel_art node reads only part of its layer.
static func sample_source(
	image: Image,
	channel: int,
	invert: bool,
	uv: Vector2,
	size: Vector2i,
	crop := Rect2i()
) -> float:
	if image == null or image.is_empty():
		return 0.0
	var width := float(image.get_width())
	var height := float(image.get_height())
	if width <= 0.0 or height <= 0.0:
		return 0.0
	var region := crop
	if region.size.x <= 0 or region.size.y <= 0:
		region = Rect2i(0, 0, int(width), int(height))
	else:
		region = region.intersection(Rect2i(0, 0, int(width), int(height)))
		if region.size.x <= 0 or region.size.y <= 0:
			region = Rect2i(0, 0, int(width), int(height))
	var span := Vector2(maxf(float(size.x), 1.0), maxf(float(size.y), 1.0))
	var source_x := (
		int(clampf(uv.x / span.x, 0.0, 0.999999) * float(region.size.x)) + region.position.x
	)
	var source_y := (
		int(clampf(uv.y / span.y, 0.0, 0.999999) * float(region.size.y)) + region.position.y
	)
	source_x = clampi(source_x, 0, int(width) - 1)
	source_y = clampi(source_y, 0, int(height) - 1)
	var color := image.get_pixel(source_x, source_y)
	var value := 0.0
	match channel:
		1:
			value = color.a
		2:
			value = 1.0 - color.a
		_:
			value = (color.r + color.g + color.b) / 3.0 * color.a
	if invert:
		value = 1.0 - value
	return clampf(value, 0.0, 1.0)


## True when the graph reads the project, so the preview has to be refreshed when
## the artwork changes underneath it. Only the output chain is asked: a canvas
## node parked beside it never reaches the picture, so it must not make the whole
## preview follow the artwork.
func uses_source() -> bool:
	for node_id in output_chain_ids():
		var chain_node := get_node_by_id(node_id)
		if chain_node.is_empty():
			continue
		if (
			str(chain_node["type"]) == "pixel_art"
			and int(chain_node["params"].get("source", 0)) == 0
		):
			return true
	return false


func _math_value(op: int, source: float, params: Dictionary) -> float:
	var amount := float(params["amount"])
	# Index comparisons instead of a string match: this runs for every pixel.
	if op == 0:  # Add
		return clampf(source + amount, 0.0, 1.0)
	elif op == 1:  # Subtract
		return clampf(source - amount, 0.0, 1.0)
	elif op == 2:  # Multiply
		return clampf(source * amount, 0.0, 1.0)
	elif op == 3:  # Min
		return minf(source, amount)
	elif op == 4:  # Max
		return maxf(source, amount)
	elif op == 5:  # Step
		return 1.0 if source >= amount else 0.0
	elif op == 6:  # Posterize
		var steps := maxi(int(params["steps"]), 2)
		return clampf(floorf(source * steps) / float(steps - 1), 0.0, 1.0)
	elif op == 7:  # Invert
		return 1.0 - source
	elif op == 8:  # Sine
		return 0.5 + 0.5 * sin(source * TAU * maxf(amount, 0.0))
	return source


## [FastNoiseLite] of a noise node, rebuilt only when its settings changed. The
## signature string is wanted once per frame per node; building it on every pixel
## was one of the most expensive parts of the preview.
func _noise_object(node_id: String, params: Dictionary) -> FastNoiseLite:
	var noise: FastNoiseLite = _noise_cache.get(node_id, null)
	if noise == null or not _noise_checked.has(node_id):
		_noise_checked[node_id] = true
		var signature := "%d|%.4f|%d|%d|%.4f" % [
			int(params["noise_type"]),
			float(params["scale"]),
			int(params["octaves"]),
			int(params["seed"]),
			float(params["gain"]),
		]
		if noise == null or _noise_signature.get(node_id, "") != signature:
			noise = FastNoiseLite.new()
			noise.noise_type = NOISE_TYPE_VALUES[int(params["noise_type"])]
			noise.seed = int(params["seed"])
			noise.frequency = 1.0 / maxf(float(params["scale"]), 0.001)
			noise.fractal_type = FastNoiseLite.FRACTAL_FBM
			noise.fractal_octaves = maxi(int(params["octaves"]), 1)
			noise.fractal_gain = clampf(float(params["gain"]), 0.05, 0.95)
			_noise_cache[node_id] = noise
			_noise_signature[node_id] = signature
	return noise


## Noise is sampled with [FastNoiseLite], which is cached per node.
func _noise_value(node_id: String, params: Dictionary, uv: Vector2) -> float:
	var noise := _noise_object(node_id, params)
	return clampf(noise.get_noise_2d(uv.x, uv.y) * 0.5 + 0.5, 0.0, 1.0)


## Value of a noise node at [param uv]. A whole pixel comes out of a field that was
## sampled once for the whole picture, so a noise source costs one native sample
## per pixel of its area instead of a full evaluator call per pixel; a mapped
## position (a transform above it) still samples on demand.
func _noise_at(node_id: String, params: Dictionary, size: Vector2i, uv: Vector2) -> float:
	if uv.x < 0.0 or uv.y < 0.0 or uv.x >= float(size.x) or uv.y >= float(size.y):
		return 0.0
	var x := int(uv.x)
	var y := int(uv.y)
	if float(x) != uv.x or float(y) != uv.y:
		return _noise_value(node_id, params, uv)
	var field := _noise_field(node_id, params, size)
	if field.is_empty():
		return _noise_value(node_id, params, uv)
	return field[y * size.x + x]


## Noise of [param node_id] sampled over [param size] and kept with the rasters, so
## it is dropped the same way and only when the node itself changed.
func _noise_field(
	node_id: String, params: Dictionary, size: Vector2i
) -> PackedFloat32Array:
	var key := "%s#noise" % _raster_key(node_id, size)
	var cached: Variant = _path_cache.get(key, null)
	if cached is PackedFloat32Array:
		return cached
	var field := PackedFloat32Array()
	field.resize(size.x * size.y)
	var noise := _noise_object(node_id, params)
	var index := 0
	for y in size.y:
		for x in size.x:
			field[index] = clampf(noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5, 0.0, 1.0)
			index += 1
	_path_cache[key] = field
	return field


## Triangles of the 3d node's mesh, rotated and ready to project. Three entries of
## the array are one triangle, so the rasteriser walks one flat list instead of
## building a face for every triangle.
func model_triangles(params: Dictionary) -> PackedVector3Array:
	var soup := _model_mesh(int(params.get("shape", 0)))
	if soup.is_empty():
		return soup
	var rotation := Basis.from_euler(
		Vector3(
			deg_to_rad(float(params.get("pitch", 22.0))),
			deg_to_rad(float(params.get("yaw", 35.0))),
			0.0
		)
	)
	var result := PackedVector3Array()
	result.resize(soup.size())
	for index in soup.size():
		result[index] = rotation * soup[index]
	return result


## Mesh of a shape index, in object space. Every primitive fits in a sphere of
## radius one half, so zoom means the same thing whichever one is picked.
static func _model_mesh(shape: int) -> PackedVector3Array:
	match shape:
		1:
			return _model_sphere()
		2:
			return _model_cylinder()
		3:
			return _model_torus()
		4:
			return _model_prism()
		5:
			return _model_plane()
	return _model_box()


## Axis aligned box. The faces are wound the same way round, which is what keeps
## the lighting of two neighbouring faces apart.
static func _model_box() -> PackedVector3Array:
	var half := 0.42
	var corners: Array[Vector3] = [
		Vector3(-half, -half, -half),
		Vector3(half, -half, -half),
		Vector3(half, half, -half),
		Vector3(-half, half, -half),
		Vector3(-half, -half, half),
		Vector3(half, -half, half),
		Vector3(half, half, half),
		Vector3(-half, half, half),
	]
	var faces: Array[PackedInt32Array] = [
		PackedInt32Array([0, 3, 2, 1]),
		PackedInt32Array([4, 5, 6, 7]),
		PackedInt32Array([0, 1, 5, 4]),
		PackedInt32Array([1, 2, 6, 5]),
		PackedInt32Array([2, 3, 7, 6]),
		PackedInt32Array([3, 0, 4, 7]),
	]
	var soup := PackedVector3Array()
	for face: PackedInt32Array in faces:
		var near_a := corners[face[0]]
		var near_b := corners[face[1]]
		var near_c := corners[face[2]]
		var near_d := corners[face[3]]
		soup.append_array(PackedVector3Array([near_a, near_b, near_c, near_a, near_c, near_d]))
	return soup


static func _model_sphere() -> PackedVector3Array:
	var soup := PackedVector3Array()
	var sides := MODEL_SPHERE_SIDES
	var rings := MODEL_SPHERE_RINGS
	for ring in rings:
		var top := PI * float(ring) / float(rings)
		var bottom := PI * float(ring + 1) / float(rings)
		for side in sides:
			var left := TAU * float(side) / float(sides)
			var right := TAU * float(side + 1) / float(sides)
			var top_left := _model_sphere_point(top, left)
			var top_right := _model_sphere_point(top, right)
			var bottom_left := _model_sphere_point(bottom, left)
			var bottom_right := _model_sphere_point(bottom, right)
			soup.append_array(
				PackedVector3Array(
					[top_left, bottom_left, bottom_right, top_left, bottom_right, top_right]
				)
			)
	return soup


static func _model_sphere_point(polar: float, azimuth: float) -> Vector3:
	var radius := 0.5
	return Vector3(sin(polar) * cos(azimuth), cos(polar), sin(polar) * sin(azimuth)) * radius


static func _model_cylinder() -> PackedVector3Array:
	var soup := PackedVector3Array()
	var sides := MODEL_TUBE_SIDES
	var radius := 0.32
	var cap_top := Vector3(0.0, 0.5, 0.0)
	var cap_bottom := Vector3(0.0, -0.5, 0.0)
	for side in sides:
		var left := TAU * float(side) / float(sides)
		var right := TAU * float(side + 1) / float(sides)
		var rim_left := Vector3(cos(left), 0.0, sin(left)) * radius
		var rim_right := Vector3(cos(right), 0.0, sin(right)) * radius
		var top_left := rim_left + cap_top
		var top_right := rim_right + cap_top
		var bottom_left := rim_left + cap_bottom
		var bottom_right := rim_right + cap_bottom
		soup.append_array(
			PackedVector3Array(
				[bottom_left, top_left, top_right, bottom_left, top_right, bottom_right]
			)
		)
		# Caps, so the ends read as solid instead of showing the inside.
		soup.append_array(PackedVector3Array([cap_top, top_right, top_left]))
		soup.append_array(PackedVector3Array([cap_bottom, bottom_left, bottom_right]))
	return soup


static func _model_torus() -> PackedVector3Array:
	var soup := PackedVector3Array()
	var rings := MODEL_TORUS_RINGS
	var tubes := MODEL_TORUS_TUBES
	for ring in rings:
		var left := TAU * float(ring) / float(rings)
		var right := TAU * float(ring + 1) / float(rings)
		for tube in tubes:
			var round_left := TAU * float(tube) / float(tubes)
			var round_right := TAU * float(tube + 1) / float(tubes)
			var near_a := _model_torus_point(left, round_left)
			var near_b := _model_torus_point(left, round_right)
			var far_a := _model_torus_point(right, round_left)
			var far_b := _model_torus_point(right, round_right)
			soup.append_array(PackedVector3Array([near_a, far_a, far_b, near_a, far_b, near_b]))
	return soup


## Lies in the XY plane, so the hole faces the camera and the tilt of the node
## turns the ring instead of hiding it behind itself.
static func _model_torus_point(around: float, through: float) -> Vector3:
	var major := 0.34
	var minor := 0.16
	var outward := Vector3(cos(around), sin(around), 0.0)
	return outward * (major + cos(through) * minor) + Vector3(0.0, 0.0, sin(through) * minor)


static func _model_prism() -> PackedVector3Array:
	var soup := PackedVector3Array()
	var sides := MODEL_PRISM_SIDES
	var radius := 0.45
	var cap_top := Vector3(0.0, 0.45, 0.0)
	var cap_bottom := Vector3(0.0, -0.45, 0.0)
	var top: Array[Vector3] = []
	var bottom: Array[Vector3] = []
	for side in sides:
		var around := TAU * float(side) / float(sides) - PI * 0.5
		top.append(Vector3(cos(around) * radius, cap_top.y, sin(around) * radius))
		bottom.append(Vector3(cos(around) * radius, cap_bottom.y, sin(around) * radius))
	for side in sides:
		var next := (side + 1) % sides
		soup.append_array(
			PackedVector3Array(
				[
					bottom[side],
					top[side],
					top[next],
					bottom[side],
					top[next],
					bottom[next],
				]
			)
		)
		soup.append_array(PackedVector3Array([top[next], top[side], cap_top]))
		soup.append_array(PackedVector3Array([bottom[side], bottom[next], cap_bottom]))
	return soup


static func _model_plane() -> PackedVector3Array:
	return PackedVector3Array(
		[
			Vector3(-0.5, -0.5, 0.0),
			Vector3(0.5, -0.5, 0.0),
			Vector3(0.5, 0.5, 0.0),
			Vector3(-0.5, -0.5, 0.0),
			Vector3(0.5, 0.5, 0.0),
			Vector3(-0.5, 0.5, 0.0),
		]
	)


## Screen position of a view space vertex plus its inverse distance, which is what
## the depth test interpolates. A zero z means the vertex is behind the camera.
static func _model_project(
	point: Vector3, camera_z: float, center: Vector2, reach: float
) -> Vector3:
	var distance := camera_z - point.z
	if distance <= MODEL_MIN_DISTANCE:
		return Vector3.ZERO
	var near_scale := camera_z / distance
	return Vector3(
		center.x + point.x * near_scale * reach,
		center.y - point.y * near_scale * reach,
		1.0 / distance
	)


## Rasterises the 3d node once per generated image and size, so the per pixel
## evaluation is a lookup like a path or a tree.
func _model_image(node: Dictionary, params: Dictionary, size: Vector2i) -> Image:
	var key := _raster_key(str(node["id"]), size)
	if _path_cache.has(key):
		return _path_cache[key]
	var image := rasterise_model(params, size)
	_path_cache[key] = image
	return image


## Renders the mesh of a 3d node without touching the cache, which is what the
## node thumbnail asks for. The value written is the light falling on the nearest
## triangle: with shade at zero the whole shape is one flat value, which is the
## silhouette a mask downstream wants.
func rasterise_model(params: Dictionary, size: Vector2i) -> Image:
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var model := model_triangles(params)
	if model.is_empty():
		return image
	# Two samples per pixel where the buffer stays small: the silhouette is what
	# usually feeds a mask, and a stepped edge shows up there.
	var samples := 2 if size.x * size.y <= MODEL_SAMPLES_LIMIT else 1
	var wide := Vector2i(size.x * samples, size.y * samples)
	var count := wide.x * wide.y
	var nearest := PackedFloat32Array()
	nearest.resize(count)
	nearest.fill(INF)
	var light_buffer := PackedFloat32Array()
	light_buffer.resize(count)
	var center := Vector2(float(wide.x) * 0.5, float(wide.y) * 0.5)
	var reach := float(mini(wide.x, wide.y)) * clampf(float(params.get("zoom", 0.8)), 0.05, 3.0)
	var perspective := clampf(float(params.get("perspective", 0.35)), 0.0, 1.0)
	# Perspective is the camera walking closer: an orthographic view is the same
	# camera standing very far away, so only this distance decides.
	var camera_z := lerpf(400.0, 1.5, perspective)
	var light_angle := deg_to_rad(float(params.get("light", 135.0)))
	var light := Vector3(cos(light_angle), sin(light_angle), 0.8).normalized()
	var shade_amount := clampf(float(params.get("shade", 1.0)), 0.0, 1.0)
	var cuts := clampi(int(params.get("cuts", 3)), 1, 8)
	var wrap_amount := clampf(float(params.get("wrap", 0.0)), -2.0, 2.0)
	var steepness := clampf(float(params.get("steepness", 1.2)), 0.1, 8.0)
	var soft_amount := clampf(float(params.get("soft", 0.0)), 0.0, 1.0)
	# The darkest band sits one step above empty, so a face turned away from the
	# light stays part of the silhouette instead of punching a hole in it.
	var darkest := 1.0 / float(cuts)
	for index in range(0, model.size(), 3):
		var corner_a := model[index]
		var corner_b := model[index + 1]
		var corner_c := model[index + 2]
		var face := (corner_b - corner_a).cross(corner_c - corner_a)
		if face.length_squared() < MODEL_MIN_FACE:
			continue
		# The absolute value lights an open surface from whichever side faces the
		# camera, so a plane is never stuck at the ambient floor of its own back.
		var lambert := absf(face.normalized().dot(light))
		# Banded light. ceil() puts every face into one of "cuts" steps, which is
		# what gives the flat pixel-art shading instead of a soft gradient.
		var amount := clampf((lambert + wrap_amount) * steepness, 0.0, 1.0)
		var banded := ceilf(amount * float(cuts)) / float(cuts)
		var lit := maxf(lerpf(banded, amount, soft_amount), darkest)
		var brightness := lerpf(1.0, lit, shade_amount)
		var point_a := _model_project(corner_a, camera_z, center, reach)
		var point_b := _model_project(corner_b, camera_z, center, reach)
		var point_c := _model_project(corner_c, camera_z, center, reach)
		if point_a.z <= 0.0 or point_b.z <= 0.0 or point_c.z <= 0.0:
			continue
		var left := clampi(
			int(floor(minf(point_a.x, minf(point_b.x, point_c.x)))), 0, wide.x - 1
		)
		var right := clampi(
			int(ceil(maxf(point_a.x, maxf(point_b.x, point_c.x)))), 0, wide.x - 1
		)
		var top := clampi(
			int(floor(minf(point_a.y, minf(point_b.y, point_c.y)))), 0, wide.y - 1
		)
		var bottom := clampi(
			int(ceil(maxf(point_a.y, maxf(point_b.y, point_c.y)))), 0, wide.y - 1
		)
		if left > right or top > bottom:
			continue
		var denom := (
			(point_b.y - point_c.y) * (point_a.x - point_c.x)
			+ (point_c.x - point_b.x) * (point_a.y - point_c.y)
		)
		if absf(denom) < MODEL_MIN_FACE:
			continue
		var inv_denom := 1.0 / denom
		# The barycentrics are affine in the sample position, so their counts are
		# folded into three constants per edge and squared away from the loop. This
		# runs for every sample of every triangle, which is the whole cost of the
		# node, and the multiplications were most of it.
		var edge_a_x := (point_b.y - point_c.y) * inv_denom
		var edge_a_y := (point_c.x - point_b.x) * inv_denom
		var edge_a_const := -edge_a_x * point_c.x - edge_a_y * point_c.y
		var edge_b_x := (point_c.y - point_a.y) * inv_denom
		var edge_b_y := (point_a.x - point_c.x) * inv_denom
		var edge_b_const := -edge_b_x * point_c.x - edge_b_y * point_c.y
		for row in range(top, bottom + 1):
			var across_y := float(row) + 0.5
			var row_start: int = row * wide.x
			var start_a := edge_a_y * across_y + edge_a_const
			var start_b := edge_b_y * across_y + edge_b_const
			for column in range(left, right + 1):
				var across_x := float(column) + 0.5
				var bary_a := edge_a_x * across_x + start_a
				var bary_b := edge_b_x * across_x + start_b
				var bary_c := 1.0 - bary_a - bary_b
				if bary_a < 0.0 or bary_b < 0.0 or bary_c < 0.0:
					continue
				var inv_depth := (
					point_a.z * bary_a + point_b.z * bary_b + point_c.z * bary_c
				)
				if inv_depth <= 0.0:
					continue
				var depth := 1.0 / inv_depth
				var at: int = row_start + column
				if depth >= nearest[at]:
					continue
				nearest[at] = depth
				light_buffer[at] = brightness
	if samples == 1:
		for y in size.y:
			for x in size.x:
				var lit: int = y * wide.x + x
				if nearest[lit] < INF:
					var shade := light_buffer[lit]
					image.set_pixel(x, y, Color(shade, shade, shade, 1.0))
	else:
		var block := float(samples * samples)
		for y in size.y:
			for x in size.x:
				var total := 0.0
				for down in samples:
					var row_start: int = (y * samples + down) * wide.x + x * samples
					for across in samples:
						var at: int = row_start + across
						if nearest[at] < INF:
							total += light_buffer[at]
				if total > 0.0:
					var average := total / block
					image.set_pixel(x, y, Color(average, average, average, 1.0))
	var outline := clampi(int(params.get("outline", 1)), 0, 2)
	if outline > 0:
		# Border below every lit band, so the darkest stop of a colour ramp lands
		# on it and the shape reads as drawn instead of as a cut out picture.
		_draw_model_outline(image, outline, darkest * 0.5)
	return image


## Draws the pixel-art border around a rendered shape, the way the grass demo
## detects a depth edge in screen space: the silhouette is grown by
## [param width] pixels and whatever the growing added is painted at
## [param level]. Working at the final size keeps the border one exact pixel
## wide, which is what a pixel artwork wants.
func _draw_model_outline(image: Image, width: int, level: float) -> void:
	var size := Vector2i(image.get_width(), image.get_height())
	if size.x <= 0 or size.y <= 0:
		return
	var bytes := image.get_data()
	var count := size.x * size.y
	var filled := PackedByteArray()
	filled.resize(count)
	for index in count:
		if bytes[index * 4 + 3] > 127:
			filled[index] = 1
	var grown := filled.duplicate()
	for _step in width:
		var previous := grown.duplicate()
		for y in size.y:
			for x in size.x:
				var at: int = y * size.x + x
				if previous[at] == 1:
					continue
				if x > 0 and previous[at - 1] == 1:
					grown[at] = 1
				elif x < size.x - 1 and previous[at + 1] == 1:
					grown[at] = 1
				elif y > 0 and previous[at - size.x] == 1:
					grown[at] = 1
				elif y < size.y - 1 and previous[at + size.x] == 1:
					grown[at] = 1
	for y in size.y:
		for x in size.x:
			var at: int = y * size.x + x
			if grown[at] == 1 and filled[at] == 0:
				image.set_pixel(x, y, Color(level, level, level, 1.0))


## Small description of a node, used by the interface.
static func describe(node: Dictionary) -> String:
	var params: Dictionary = node["params"]
	match str(node["type"]):
		"noise":
			return "%s · %d px · %d oct" % [
				NOISE_TYPES[int(params["noise_type"])],
				int(params["scale"]),
				int(params["octaves"]),
			]
		"gradient":
			return "%d°" % int(params["angle"])
		"radial":
			return "r %.2f" % float(params["radius"])
		"checker":
			return "cell %d px" % int(params["cell"])
		"shape":
			return str(
				SHAPE_KINDS[clampi(int(params.get("kind", 0)), 0, SHAPE_KINDS.size() - 1)]
			)
		"tree":
			return "深 %d · %d 叉" % [
				int(params.get("depth", 5)), int(params.get("branches", 2))
			]
		"scatter":
			var scatter_text := "%d 枚 · %.0f%%" % [
				int(params.get("amount", 24)), float(params.get("stamp", 0.3)) * 100.0
			]
			match clampi(int(params.get("mode", 0)), 0, 2):
				1:
					scatter_text += " · 沿路径"
				2:
					scatter_text += " · 沿画布"
			var level := float(params.get("level", 1.0))
			if not is_equal_approx(level, 1.0):
				scatter_text += " · 亮度 %.2f" % level
			match clampi(int(params.get("distribution", 0)), 0, 2):
				1:
					scatter_text += " · 均匀间距"
				2:
					if int(params.get("mode", 0)) == 0:
						scatter_text += " · %d×%d 网格" % [
							int(params.get("grid_x", 4)), int(params.get("grid_y", 4))
						]
			if bool(params.get("sort_y", false)):
				scatter_text += " · 前后排序"
			if bool(params.get("tile", false)):
				scatter_text += " · 平铺"
			if bool(params.get("tint", false)):
				scatter_text += " · 上色"
			if float(params.get("sway", 0.0)) > 0.0:
				scatter_text += " · 摆动 %.0f°" % float(params.get("sway", 0.0))
			if float(params.get("push", 0.0)) > 0.0:
				scatter_text += " · 推挤 %.0f%%" % (float(params.get("push", 0.0)) * 100.0)
			return scatter_text
		"particles":
			var particles_text := "%d 颗 · %.1fpx" % [
				int(params.get("count", 48)), float(params.get("size", 1.5))
			]
			if float(params.get("trail", 0.0)) > 0.0:
				particles_text += " · 拖尾"
			if not is_equal_approx(float(params.get("speed_end", 1.0)), 1.0):
				particles_text += " · 末端速度 %.2f" % float(params.get("speed_end", 1.0))
			if not is_equal_approx(float(params.get("size_end", 1.0)), 1.0):
				particles_text += " · 末端大小 %.2f" % float(params.get("size_end", 1.0))
			if bool(params.get("tint", false)):
				particles_text += " · 上色"
			return particles_text
		"constant":
			return "%.2f" % float(params.get("value", 0.5))
		"model3d":
			var model_text := "%s · %.0f° · %d 阶" % [
				MODEL_SHAPES[
					clampi(int(params.get("shape", 0)), 0, MODEL_SHAPES.size() - 1)
				],
				float(params.get("yaw", 35.0)),
				clampi(int(params.get("cuts", 3)), 1, 8),
			]
			if clampi(int(params.get("outline", 1)), 0, 2) > 0:
				model_text += " · 描边"
			if float(params.get("shade", 1.0)) < 0.999:
				model_text += " · 明暗 %.0f%%" % (float(params.get("shade", 1.0)) * 100.0)
			return model_text
		"path":
			var path_text := "%d 点" % (params.get("points", []) as Array).size()
			if bool(params.get("closed", false)):
				path_text += " · 闭合"
			return path_text
		"pixel_art":
			var channels := ["亮度", "透明度", "反向透明度"]
			if int(params.get("source", 0)) == 1:
				var line_text := "路径线条 · 宽 %.3f–%.3f" % [
					float(params.get("width_min", 0.0)),
					float(params.get("width_max", params.get("width", 0.06))),
				]
				if bool(params.get("fill", false)):
					line_text += " · 填充"
				return line_text
			if int(params.get("source", 0)) == 2:
				# The label is built from the stored string, because [method describe]
				# has to work without a decoded picture for exported code.
				var stored := str(params.get("painting", ""))
				return "绘画窗口 · %s" % ("已画" if not stored.is_empty() else "空白")
			var source_text := "%s · 图层 %d" % [
				channels[clampi(int(params.get("channel", 0)), 0, 2)],
				int(params.get("layer", 0)) + 1
			]
			var crop_w := int(params.get("crop_w", 0))
			var crop_h := int(params.get("crop_h", 0))
			if crop_w > 0 or crop_h > 0:
				source_text += " · 裁切 %s×%s" % [
					str(crop_w) if crop_w > 0 else "全宽",
					str(crop_h) if crop_h > 0 else "全高"
				]
			return source_text
		"time":
			var time_text := "速度 %.1f" % float(params.get("speed", 1.0))
			if clampi(int(params.get("steps", 0)), 0, 60) > 0:
				time_text += " · %d 帧" % clampi(int(params.get("steps", 0)), 0, 60)
			return time_text
		"wave":
			return "%.1f 周期 · %d°" % [float(params["frequency"]), int(params["angle"])]
		"transform":
			return "×%.2f · %d°" % [float(params["scale"]), int(params["angle"])]
		"scale":
			if int(params.get("mode", 0)) == 1:
				return "%d×%d" % [int(params["target_x"]), int(params["target_y"])]
			return "×%.2f · %.2f" % [float(params["scale_x"]), float(params["scale_y"])]
		"flip":
			return FLIP_AXIS[clampi(int(params.get("axis", 0)), 0, 2)]
		"skew":
			return "%d° / %d°" % [int(params["angle_x"]), int(params["angle_y"])]
		"tile":
			return "%d×%d" % [int(params["count_x"]), int(params["count_y"])]
		"polar":
			return POLAR_MODES[int(params["mode"])]
		"crop":
			return "%d%%…%d%%" % [
				int(float(params["left"]) * 100.0), int(float(params["right"]) * 100.0)
			]
		"padding":
			return "%d%%" % int(float(params["amount"]) * 200.0)
		"echo":
			return "%d · %s" % [
				int(params["count"]), "Max" if int(params["mode"]) == 0 else "Avg"
			]
		"follow_path":
			if int(params["shape"]) == PATH_CUSTOM:
				return "自定义 · %d 点" % (params.get("points", []) as Array).size()
			return "%s · %.2f" % [
				PATH_SHAPES[int(params["shape"])], float(params["radius"])
			]
		"mesh_warp":
			return "网格 2×2"
		"area_warp":
			return "r %.2f · %.2f" % [float(params["radius"]), float(params["amount"])]
		"nine_slice":
			return "边框 %.2f · ×%.2f" % [float(params["border"]), float(params["scale"])]
		"crop_content":
			return "阈值 %.2f" % float(params["threshold"])
		"kaleidoscope":
			return "%d 段" % int(params["segments"])
		"bend":
			return "%s · %.2f" % [BEND_TYPES[clampi(int(params["type"]), 0, 1)], float(params["amount"])]
		"stretch":
			return "%d° · %.2f" % [int(params["angle"]), float(params["amount"])]
		"mirror":
			return "%d° · %.2f" % [int(params["angle"]), float(params["position"])]
		"blur":
			return "r %.1f · %.1fx" % [
				float(params.get("size", params.get("radius", 1.5))),
				float(params.get("aspect", 1.0))
			]
		"outline":
			var outline_positions := ["外侧", "内侧", "居中"]
			return "%s · %d px" % [
				outline_positions[clampi(int(params.get("position", 0)), 0, 2)],
				int(params.get("width", 1.0))
			]
		"glow":
			return "r %d · ×%.1f" % [int(params.get("size", 3.0)), float(params.get("strength", 1.5))]
		"bloom":
			return "r %d · ×%.1f" % [int(params.get("size", 3.0)), float(params.get("strength", 1.0))]
		"levels":
			return "%.2f…%.2f · 伽马 %.2f" % [
				float(params.get("black", 0.0)),
				float(params.get("white", 1.0)),
				float(params.get("gamma", 1.0)),
			]
		"threshold":
			var threshold_text := "阈值 %.2f" % float(params.get("cut", 0.5))
			if float(params.get("soft", 0.0)) > 0.0:
				threshold_text += " · 过渡 %.2f" % float(params.get("soft", 0.0))
			if bool(params.get("invert", false)):
				threshold_text += " · 反相"
			return threshold_text
		"normalize":
			return "拉伸 %.0f–%.0f%%" % [
				float(params.get("low", 0.0)) * 100.0, float(params.get("high", 1.0)) * 100.0
			]
		"curve":
			var curve_values: Array = params.get("curve", [])
			if curve_values.size() < 3:
				return "未设曲线"
			return "中 %.2f" % float(curve_values[2])
		"band":
			var band_text := "%.2f–%.2f" % [
				float(params.get("low", 0.3)), float(params.get("high", 0.7))
			]
			if float(params.get("soft", 0.05)) > 0.0:
				band_text += " · 过渡 %.2f" % float(params.get("soft", 0.05))
			if bool(params.get("invert", false)):
				band_text += " · 反相"
			return band_text
		"color_adjust":
			return "亮度 %+.2f · 对比 %+.2f" % [
				float(params.get("brightness", 0.0)), float(params.get("contrast", 0.0))
			]
		"edge":
			return "%.1f · ×%.1f" % [float(params["radius"]), float(params["gain"])]
		"dither":
			return DITHER_SIZES_TEXT[clampi(int(params["matrix"]), 0, 2)]
		"pixelate":
			return "%d px" % int(params["size"])
		"erode":
			return "%s · %.1f px · %s" % [
				ERODE_MODES[clampi(int(params.get("mode", 0)), 0, ERODE_MODES.size() - 1)],
				float(params.get("radius", 1.0)),
				ERODE_SHAPES[clampi(int(params.get("shape", 0)), 0, ERODE_SHAPES.size() - 1)],
			]
		"warp":
			return "%.2f" % float(params.get("amount", 0.15))
		"math":
			return MATH_OPS[int(params["op"])]
		"blend":
			return BLEND_OPS[int(params["op"])]
		"output":
			return "透明输出" if bool(params.get("transparent", false)) else "实心底"
	return ""


## True when the graph samples neighbours or does a pass over the whole branch,
## so the preview should be generated at a lower resolution.
func is_expensive() -> bool:
	const HEAVY := [
		"echo",
		"tree",
		"model3d",
		"scatter",
		"blur",
		"erode",
		"outline",
		"glow",
		"bloom",
		"warp",
		"area_warp",
		"mesh_warp",
		"crop_content",
	]
	for node_id in output_chain_ids():
		var node := get_node_by_id(node_id)
		if not node.is_empty() and HEAVY.has(str(node["type"])):
			return true
	return false


## True when the graph changes over time, so generating a layer has to produce
## one image per frame.
func uses_time() -> bool:
	for node_id in output_chain_ids():
		var chain_node := get_node_by_id(node_id)
		if chain_node.is_empty():
			continue
		var chain_params: Dictionary = chain_node["params"]
		# Any animated parameter is a clock of its own, whatever the node does.
		var anim: Variant = chain_params.get("anim", null)
		if anim is Dictionary and not (anim as Dictionary).is_empty():
			return true
		if chain_node["type"] == "time":
			return true
		if chain_node["type"] == "echo" and bool(chain_params.get("animated", false)):
			return true
		if chain_node["type"] == "tree":
			var tree_params: Dictionary = chain_params
			# Sway alone already needs one image per frame, even without growth.
			if bool(tree_params.get("animate", false)):
				return true
			if float(tree_params.get("sway", 0.0)) > 0.0:
				return true
		if chain_node["type"] == "particles" and particles_animate(chain_params):
			return true
		if chain_node["type"] == "scatter" and float(chain_params.get("sway", 0.0)) > 0.0:
			return true
		if chain_node["type"] == "pixel_art" and int(chain_params.get("frame_mode", 0)) == 2:
			return true
	return false


## Replaces the graph with a ready made animated pixel sea: two travelling waves
## added to some noise, posterized and painted in a deep blue.
func build_ocean_preset() -> void:
	nodes.clear()
	groups.clear()
	_noise_cache.clear()
	_noise_signature.clear()
	var time_id := add_node("time", Vector2(20, 80))
	# Crests run across the screen, so both waves travel along the vertical axis.
	var wave_a := add_node("wave", Vector2(200, 20))
	var wave_b := add_node("wave", Vector2(200, 170))
	var depth := add_node("gradient", Vector2(200, 320))
	var waves := add_node("blend", Vector2(420, 90))
	var shaded := add_node("blend", Vector2(600, 150))
	var noise := add_node("noise", Vector2(600, 320))
	var foam := add_node("blend", Vector2(780, 200))
	var post := add_node("math", Vector2(960, 200))
	var out := add_node("output", Vector2(1120, 200))
	connect_nodes(time_id, wave_a, 0)
	connect_nodes(time_id, wave_b, 0)
	connect_nodes(wave_a, waves, 0)
	connect_nodes(wave_b, waves, 1)
	connect_nodes(waves, shaded, 0)
	connect_nodes(depth, shaded, 1)
	connect_nodes(shaded, foam, 0)
	connect_nodes(noise, foam, 1)
	connect_nodes(foam, post, 0)
	connect_nodes(post, out, 0)

	get_node_by_id(wave_a)["params"].merge(
		{"frequency": 1.6, "angle": 90.0, "amplitude": 1.0}, true
	)
	get_node_by_id(wave_b)["params"].merge(
		{"frequency": 4.0, "angle": 96.0, "amplitude": 0.35}, true
	)
	get_node_by_id(depth)["params"].merge({"angle": 90.0, "offset": 0.0}, true)
	get_node_by_id(waves)["params"].merge({"op": 0, "factor": 0.35}, true)
	get_node_by_id(shaded)["params"].merge({"op": 0, "factor": 0.3}, true)
	get_node_by_id(noise)["params"].merge({"scale": 4.0, "octaves": 2, "seed": 7}, true)
	get_node_by_id(foam)["params"].merge({"op": 0, "factor": 0.16}, true)
	get_node_by_id(post)["params"].merge({"op": 6, "steps": 5}, true)
	# The colour sits on the gradient that paints the water and travels down from
	# there. The blend in between mixes it with the waves and never owns a colour.
	get_node_by_id(depth)["params"].merge(
		{"tint": true, "color": Color(0.13, 0.38, 0.6, 1.0)}, true
	)


## Replaces the graph with a toon shaded 3d shape in the palette of the Dylearn
## pixel grass demo: the light is cut into three bands, the silhouette gets a one
## pixel border, and the picture is painted with the greens its shaders use. A
## sphere stands in for a bush, which is what the grass clumps read as there.
func build_model3d_preset() -> void:
	nodes.clear()
	groups.clear()
	_noise_cache.clear()
	_noise_signature.clear()
	var model := add_node("model3d", Vector2(40, 60))
	var out := add_node("output", Vector2(420, 60))
	connect_nodes(model, out, 0)
	get_node_by_id(model)["params"].merge(
		{
			"shape": 1,
			"yaw": 0.0,
			"pitch": 16.0,
			"zoom": 0.86,
			"perspective": 0.2,
			"light": 135.0,
			"shade": 1.0,
			"cuts": 3,
			"wrap": 0.12,
			"steepness": 1.5,
			"soft": 0.0,
			"outline": 1,
		},
		true
	)
	# A ramp on the output is how a grey value graph gets a palette: the border
	# lands in the darkest stop and the three lit bands fill the rest of it.
	get_node_by_id(out)["params"].merge(
		{
			"color_a": Color(0.16, 0.27, 0.05),
			"color_mid": Color(0.443, 0.635, 0.0),
			"color_b": Color(0.604, 0.718, 0.0),
			"mid_position": 0.5,
			"steps": 4,
			"transparent": true,
			"alpha_cut": 0.04,
		},
		true
	)


## Replaces the graph with a patch of pixel grass, the way the demo builds one: a
## single blade is the stamp, the scatter lays down a field of them, and a vertical
## gradient thins the field out towards the top. The gradient is the part that
## makes it read as ground cover instead of a sprinkle of blades over the whole
## picture, and the brightness of every stamp wandering is what gives it depth.
func build_grass_preset() -> void:
	nodes.clear()
	groups.clear()
	_noise_cache.clear()
	_noise_signature.clear()
	var blade := add_node("model3d", Vector2(20, 40))
	var squash := add_node("scale", Vector2(200, 40))
	var field := add_node("scatter", Vector2(380, 40))
	var cover := add_node("gradient", Vector2(200, 280))
	var out := add_node("output", Vector2(620, 40))
	connect_nodes(blade, squash, 0)
	connect_nodes(squash, field, 0)
	connect_nodes(cover, field, 1)
	connect_nodes(field, out, 0)
	# Dense at the bottom, thin at the top: a gradient this steep leaves the lower
	# half almost solid and lets the blades stand on their own higher up.
	get_node_by_id(cover)["params"].merge({"angle": 90.0, "offset": 0.35}, true)
	# The blade is a prism seen from the front and squeezed through a scale node:
	# the factors are what the sampler divides by, so below one narrows that axis
	# and above one stretches it. A tapered upright blade is what comes out.
	get_node_by_id(blade)["params"].merge(
		{
			"shape": 4,
			"yaw": 0.0,
			"pitch": 0.0,
			"zoom": 1.0,
			"perspective": 0.0,
			"shade": 0.0,
			"outline": 0,
		},
		true
	)
	get_node_by_id(squash)["params"].merge(
		{"mode": 0, "scale_x": 0.34, "scale_y": 2.6, "tile": false}, true
	)
	# The scatter only takes the shape of the blade, so the brightness of a stamp
	# is what gives the patch its depth: every blade lands in a different band.
	get_node_by_id(field)["params"].merge(
		{
			# Enough blades to fill the bottom of the picture: at this size the
			# lower third has to be nearly solid or the patch reads as specks.
			"amount": 130,
			"mode": 0,
			"spread": 1.0,
			"stamp": 0.13,
			"level": 0.9,
			"level_random": 0.45,
			"angle": 0.0,
			# Grass stands up, so the random angle only tips it a little.
			"angle_random": 9.0,
			"scale_min": 0.7,
			"scale_max": 1.5,
			"seed": 4,
			"distribution": 0,
			"distance": 0.12,
			"sort_y": true,
			"tint": false,
			# The patch moves like the demo's grass: a wave rolls across it and the
			# blades lean with it, so pressing play shows the field breathing.
			"sway": 6.0,
			"sway_speed": 1.0,
			"sway_scale": 1.2,
			"sway_angle": 90.0,
			"sway_jitter": 0.35,
		},
		true
	)
	get_node_by_id(out)["params"].merge(
		{
			"color_a": Color(0.20, 0.33, 0.07),
			"color_mid": Color(0.443, 0.635, 0.0),
			"color_b": Color(0.604, 0.718, 0.0),
			"mid_position": 0.5,
			"steps": 3,
			"transparent": true,
			"alpha_cut": 0.04,
		},
		true
	)


## Replaces the graph with a pixel tree that grows along the animation: the tree
## node reveals one generation of branches per frame, and it carries the bark
## colour for the whole picture.
func build_tree_preset() -> void:
	nodes.clear()
	groups.clear()
	_noise_cache.clear()
	_noise_signature.clear()
	var tree := add_node("tree", Vector2(40, 60))
	var out := add_node("output", Vector2(420, 60))
	connect_nodes(tree, out, 0)
	get_node_by_id(tree)["params"].merge(
		{
			"seed": 3,
			"growth": 1.0,
			"animate": true,
			"ease": 0.5,
			"sway": 0.22,
			"sway_speed": 0.6,
			"depth": 5,
			"branches": 2,
			"spread": 32.0,
			"taper": 0.74,
			"bend": 0.4,
			"width": 0.05,
			"randomness": 0.3,
			"leaves": true,
			"leaf_size": 1.0,
		},
		true
	)
	get_node_by_id(tree)["params"].merge(
		{"tint": true, "color": Color(0.34, 0.24, 0.1, 1.0)}, true
	)
	get_node_by_id(out)["params"].merge(
		{
			# A tree is usually dropped onto an existing drawing, so the empty
			# part stays transparent instead of becoming a rectangle.
			"transparent": true,
		},
		true
	)


## A vine that grows along a curve: the path node draws more of itself as the
## animation runs. Nothing here is special cased, the growth is simply the
## "reveal" parameter animated like any other slider.
func build_path_growth_preset() -> void:
	nodes.clear()
	groups.clear()
	_noise_cache.clear()
	_noise_signature.clear()
	var path := add_node("path", Vector2(120, 80))
	var canvas := add_node("pixel_art", Vector2(360, 80))
	var out := add_node("output", Vector2(600, 80))
	connect_nodes(path, canvas, 0)
	connect_nodes(canvas, out, 0)
	get_node_by_id(path)["params"].merge(
		{
			"points":
			[
				{"point": Vector2(0.12, 0.9), "in": Vector2.ZERO, "out": Vector2(0.03, -0.1)},
				{
					"point": Vector2(0.3, 0.64),
					"in": Vector2(-0.06, 0.08),
					"out": Vector2(0.06, -0.09),
				},
				{
					"point": Vector2(0.5, 0.72),
					"in": Vector2(-0.08, -0.02),
					"out": Vector2(0.07, 0.05),
				},
				{
					"point": Vector2(0.7, 0.42),
					"in": Vector2(-0.1, 0.06),
					"out": Vector2(0.06, -0.08),
				},
				{"point": Vector2(0.86, 0.2), "in": Vector2(-0.05, 0.04), "out": Vector2.ZERO},
			],
			"closed": false,
			"reveal": 1.0,
			"reveal_reverse": false,
			"anim":
			{
				"param": "reveal",
				"from": 0.0,
				"to": 1.0,
				"start": 0.0,
				"end": 1.0,
				"ease": 0.35,
				"mode": 0,
			},
		},
		true
	)
	# The canvas draws the curve with a taper at both ends.
	get_node_by_id(canvas)["params"].merge(
		{
			"source": 1,
			"width_min": 0.0,
			"width_max": 0.05,
			"soft": 0.02,
			"profile": [0.35, 1.0, 0.9, 1.0, 0.25],
		},
		true
	)
	get_node_by_id(canvas)["params"].merge(
		{"tint": true, "color": Color(0.35, 0.68, 0.24, 1.0)}, true
	)
	get_node_by_id(out)["params"].merge({"transparent": true}, true)


## Content that appears from the bottom up: a gradient turned into a moving
## threshold by a Step node, multiplied over the image. The mask is a normal
## chain, so it can be swapped for a shape, a path or a noise field.
func build_mask_growth_preset() -> void:
	nodes.clear()
	groups.clear()
	_noise_cache.clear()
	_noise_signature.clear()
	var noise := add_node("noise", Vector2(40, 40))
	var gradient := add_node("gradient", Vector2(40, 240))
	var step := add_node("math", Vector2(260, 240))
	var blend := add_node("blend", Vector2(460, 120))
	var out := add_node("output", Vector2(680, 120))
	connect_nodes(gradient, step, 0)
	connect_nodes(noise, blend, 0)
	connect_nodes(step, blend, 1)
	connect_nodes(blend, out, 0)
	get_node_by_id(noise)["params"].merge(
		{"scale": 12.0, "octaves": 3, "gain": 0.55, "seed": 7}, true
	)
	# Angle 90 makes the gradient bright at the bottom, and the negative offset
	# keeps the whole picture hidden at the first frame. A threshold that falls
	# from 1 to 0 then reveals it upwards.
	get_node_by_id(gradient)["params"].merge({"angle": 90.0, "offset": -0.25}, true)
	get_node_by_id(step)["params"].merge(
		{
			"op": 5,
			"amount": 0.0,
			"anim":
			{
				"param": "amount",
				"from": 1.0,
				"to": 0.0,
				"start": 0.0,
				"end": 1.0,
				"ease": 0.25,
				"mode": 0,
			},
		},
		true
	)
	get_node_by_id(blend)["params"].merge({"op": 2, "factor": 1.0}, true)
	# The colour belongs to the noise that fills the picture, and the blend only
	# mixes it with the growing mask.
	get_node_by_id(noise)["params"].merge(
		{"tint": true, "color": Color(0.28, 0.62, 0.78, 1.0)}, true
	)
	get_node_by_id(out)["params"].merge({"transparent": true}, true)


## A pixel bush built from the current layer: the layer is the brush, and a soft
## shape decides where the leaves may land, so they clump instead of carpeting
## the whole canvas.
func build_scatter_preset(layer_material := true) -> void:
	nodes.clear()
	groups.clear()
	_noise_cache.clear()
	_noise_signature.clear()
	var brush := add_node("pixel_art", Vector2(20, 40))
	var area := add_node("shape", Vector2(20, 300))
	var scatter := add_node("scatter", Vector2(240, 60))
	var out := add_node("output", Vector2(560, 60))
	connect_nodes(brush, scatter, 0)
	connect_nodes(area, scatter, 1)
	connect_nodes(scatter, out, 0)
	if not layer_material:
		# A vector leaf drawn by the canvas, so the preset shows a bush even
		# before anything is drawn on a layer.
		var leaf := add_node("path", Vector2(-240, 40))
		connect_nodes(leaf, brush, 0)
		get_node_by_id(leaf)["params"].merge(
			{
				"points":
				[
					{
						"point": Vector2(0.5, 0.04),
						"in": Vector2(0.22, 0.10),
						"out": Vector2(-0.22, 0.10),
					},
					{
						"point": Vector2(0.94, 0.5),
						"in": Vector2(-0.16, -0.22),
						"out": Vector2(-0.16, 0.22),
					},
					{
						"point": Vector2(0.5, 0.96),
						"in": Vector2(-0.22, -0.10),
						"out": Vector2(0.22, -0.10),
					},
					{
						"point": Vector2(0.06, 0.5),
						"in": Vector2(0.16, 0.22),
						"out": Vector2(0.16, -0.22),
					},
				],
				"closed": true,
			},
			true
		)
		get_node_by_id(brush)["params"].merge(
			{
				"source": 1,
				"width_min": 0.0,
				"width_max": 0.02,
				"soft": 0.01,
				"fill": true,
			},
			true
		)
	get_node_by_id(area)["params"].merge(
		{
			"kind": 0,
			"center_x": 0.5,
			"center_y": 0.55,
			"size": 0.62,
			"soft": 0.55,
		},
		true
	)
	get_node_by_id(scatter)["params"].merge(
		{
			"amount": 36,
			"spread": 1.0,
			"stamp": 0.22,
			"angle": 0.0,
			"angle_random": 180.0,
			"scale_min": 0.7,
			"scale_max": 1.4,
			"seed": 4,
			"align": true,
			# Leaves overlap, so the ones lower on the canvas are drawn last and end
			# up in front, and each of them keeps a brightness of its own.
			"sort_y": true,
			"level_random": 0.25,
		},
		true
	)
	get_node_by_id(scatter)["params"].merge(
		{"tint": true, "color": Color(0.22, 0.45, 0.27, 1.0)}, true
	)
	get_node_by_id(out)["params"].merge({"transparent": true}, true)


## Leaves growing along a vine: the path is both the stem and the placement for
## the scatter, and animating its reveal grows the whole thing.
func build_vine_preset() -> void:
	nodes.clear()
	groups.clear()
	_noise_cache.clear()
	_noise_signature.clear()
	var stem := add_node("path", Vector2(20, 40))
	var stem_draw := add_node("pixel_art", Vector2(300, 40))
	var brush_path := add_node("path", Vector2(20, 320))
	var brush := add_node("pixel_art", Vector2(300, 320))
	var scatter := add_node("scatter", Vector2(560, 60))
	var blend := add_node("blend", Vector2(820, 60))
	var out := add_node("output", Vector2(1060, 60))
	connect_nodes(stem, stem_draw, 0)
	connect_nodes(stem_draw, blend, 0)
	connect_nodes(brush_path, brush, 0)
	connect_nodes(brush, scatter, 0)
	# The leaves sit on the drawn stem, so they follow the stroke as it grows.
	connect_nodes(stem_draw, scatter, 1)
	connect_nodes(scatter, blend, 1)
	connect_nodes(blend, out, 0)
	# The stem gets thinner towards its tip, so the vine reads as a growing line.
	get_node_by_id(stem_draw)["params"].merge(
		{
			"source": 1,
			"width_min": 0.0,
			"width_max": 0.035,
			"soft": 0.01,
			"profile": [0.5, 1.0, 1.0, 0.75, 0.35],
		},
		true
	)
	get_node_by_id(stem)["params"].merge(
		{
			"points":
			[
				{"point": Vector2(0.12, 0.95), "in": Vector2.ZERO, "out": Vector2(0.05, -0.08)},
				{
					"point": Vector2(0.28, 0.76),
					"in": Vector2(-0.05, 0.06),
					"out": Vector2(0.06, -0.05),
				},
				{
					"point": Vector2(0.45, 0.82),
					"in": Vector2(-0.06, -0.02),
					"out": Vector2(0.06, -0.01),
				},
				{
					"point": Vector2(0.62, 0.56),
					"in": Vector2(-0.06, 0.05),
					"out": Vector2(0.06, -0.04),
				},
				{
					"point": Vector2(0.78, 0.62),
					"in": Vector2(-0.06, -0.03),
					"out": Vector2(0.05, -0.05),
				},
				{"point": Vector2(0.9, 0.26), "in": Vector2(-0.04, 0.06), "out": Vector2.ZERO},
			],
			"closed": false,
			"reveal": 1.0,
			"reveal_reverse": false,
			"anim":
			{
				"param": "reveal",
				"from": 0.0,
				"to": 1.0,
				"start": 0.0,
				"end": 1.0,
				"ease": 0.35,
				"mode": 0,
			},
		},
		true
	)
	get_node_by_id(brush_path)["params"].merge(
		{
			"points":
			[
				{"point": Vector2(0.5, 0.06), "in": Vector2(0.2, 0.1), "out": Vector2(-0.2, 0.1)},
				{
					"point": Vector2(0.94, 0.5),
					"in": Vector2(-0.16, -0.22),
					"out": Vector2(-0.16, 0.22),
				},
				{
					"point": Vector2(0.5, 0.94),
					"in": Vector2(-0.2, -0.1),
					"out": Vector2(0.2, -0.1),
				},
				{
					"point": Vector2(0.06, 0.5),
					"in": Vector2(0.16, 0.22),
					"out": Vector2(0.16, -0.22),
				},
			],
			"closed": true,
			"reveal": 1.0,
			"reveal_reverse": false,
		},
		true
	)
	get_node_by_id(brush)["params"].merge(
		{
			"source": 1,
			"width_min": 0.0,
			"width_max": 0.02,
			"soft": 0.01,
			"fill": true,
		},
		true
	)
	get_node_by_id(scatter)["params"].merge(
		{
			"amount": 30,
			"mode": 2,
			"spread": 1.0,
			"path_width": 0.08,
			"follow_tangent": false,
			"stamp": 0.13,
			"angle": 0.0,
			"angle_random": 40.0,
			"scale_min": 0.7,
			"scale_max": 1.2,
			"seed": 3,
			"align": true,
			"sort_y": true,
			"level_random": 0.15,
		},
		true
	)
	get_node_by_id(blend)["params"].merge({"op": 1, "factor": 1.0}, true)
	# The leaves are the colour of the picture; the stem stays uncoloured and the
	# blend mixes the two branches, so setting a colour on the scatter shows up.
	get_node_by_id(scatter)["params"].merge(
		{"tint": true, "color": Color(0.26, 0.55, 0.24, 1.0)}, true
	)
	get_node_by_id(out)["params"].merge({"transparent": true}, true)
