class_name ShaderGraph
extends RefCounted
## A tiny node graph that turns procedural nodes into a pixel image.
##
## Every node produces a single grayscale value between 0 and 1 for a pixel. The
## [code]output[/code] node turns that value into a color with a three stop ramp
## and a limited number of steps, which keeps the result pixel art friendly.

## Node types and how many inputs they take.
const NODE_TYPES := {
	"noise": {"label": "噪声", "inputs": 0},
	"gradient": {"label": "渐变", "inputs": 0},
	"radial": {"label": "径向", "inputs": 0},
	"checker": {"label": "棋盘", "inputs": 0},
	"constant": {"label": "常量", "inputs": 0},
	# A single primitive, sized and rotated. Useful as a mask for the filters.
	"shape": {"label": "图形", "inputs": 0},
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
	"edge": {"label": "边缘检测", "inputs": 1},
	"dither": {"label": "抖动", "inputs": 1},
	"pixelate": {"label": "像素化", "inputs": 1},
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
const PATH_SHAPES := ["圆形", "水平", "垂直", "正弦", "方形", "8 字", "自定义"]
## Primitives of the shape node.
const SHAPE_KINDS := ["圆形", "方形", "三角形", "菱形", "星形", "圆环"]
## Where the pixel particles are born.
const PARTICLE_SPAWN := ["底部升起", "顶部下落", "中心爆发", "全画布"]
const PARTICLE_SHAPES := ["方形", "圆形"]
## Shape index that uses the control points edited in the path editor.
const PATH_CUSTOM := 6
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
			"edge",
			"dither",
			"pixelate",
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
## Noise nodes already prepared this frame, so their signature string is built
## once instead of once per pixel.
var _noise_checked: Dictionary = {}
## Time the images in [member _path_cache] were built at. A new frame throws
## them away, which is why they can be keyed by node id alone.
var _raster_time := -1.0
## Bounds of the non empty part of a branch, rebuilt for every generated image.
## Resolution the images in [member _path_cache] were built at. A thumbnail is
## generated at another size than the preview, so the rasters have to be rebuilt
## instead of being read at the wrong scale.
var _raster_size := Vector2i.ZERO
var _bounds_cache := {}
var _bayer_cache := {}
## Rasterised paths and the project layers read by the input nodes, per generate.
var _path_cache := {}
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


## Restores a snapshot made by [method to_dict].
func from_dict(data: Dictionary) -> void:
	var stored: Array = data.get("nodes", [])
	nodes.clear()
	_noise_cache.clear()
	_noise_signature.clear()
	for entry in stored:
		if entry is not Dictionary or not entry.has("id") or not entry.has("type"):
			continue
		nodes.append((entry as Dictionary).duplicate(true))
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
	groups.clear()
	for entry in data.get("groups", []):
		if entry is not Dictionary or not entry.has("id"):
			continue
		var group: Dictionary = (entry as Dictionary).duplicate(true)
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
				# connected to the second input, which makes growth animation easy.
				"mode": 0,
				"spread": 0.6,
				"path_width": 0.08,
				"follow_tangent": true,
				"stamp": 0.3,
				# Value the opaque part of the brush is stamped with. The brush
				# only supplies its shape, so this is where the stamps get their
				# step on the output ramp.
				"level": 1.0,
				"angle": 0.0,
				"angle_random": 180.0,
				"scale_min": 0.7,
				"scale_max": 1.3,
				"seed": 1,
				"align": true,
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
				"lifetime": 0.8,
				"fade": true,
				"twinkle": 0.0,
				"shape": 0,
				"soft": 0.0,
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
				# 0 reads the drawing area, 1 draws the path connected to input 1.
				"source": 0,
				"layer": 0,
				"frame_mode": 0,
				"frame": 0,
				"channel": 0,
				"invert": false,
				# Stroke used in path mode. The profile holds the line width along
				# the curve, from its start to its end, so a tip can taper out.
				"width": 0.06,
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
			return {"speed": 1.0, "offset": 0.0}
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
		"warp":
			return {"amount": 0.15}
		"math":
			return {"op": 0, "amount": 0.5, "steps": 4}
		"blend":
			return {"op": 0, "factor": 0.5}
		"output":
			return {
				"steps": 2,
				"color_a": Color(0.09, 0.09, 0.12, 1.0),
				"color_mid": Color(0.45, 0.45, 0.5, 1.0),
				"color_b": Color(0.95, 0.95, 0.98, 1.0),
				"mid_position": 0.5,
				"transparent": false,
				"alpha_cut": 0.0,
				"alpha_from_value": false,
			}
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
		var deadline := Time.get_ticks_usec() + int(slice_msec * 1000.0)
		var row: int = int(state["row"])
		# Always paint one row, then stop as soon as the slice is used up.
		while row < height:
			_paint_rows(state, row, row + 1)
			row += 1
			if Time.get_ticks_usec() >= deadline:
				break
		state["row"] = row
		if row < height and tree != null:
			await tree.process_frame
	return state["image"]


## Clears the per frame caches and captures the output node settings, so the
## synchronous and the sliced generation share the same preparation.
func _begin_generation(size: Vector2i) -> Dictionary:
	size = Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	_bounds_cache.clear()
	_path_cache.clear()
	_source_cache.clear()
	# Resolved once per frame, so an animated parameter costs a lookup per pixel.
	_resolve_animations()
	_raster_size = size
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	var output_id := output_node_id()
	if output_id.is_empty():
		image.fill(Color(0, 0, 0, 0))
		return {"image": image, "size": size, "done": true}
	var output := get_node_by_id(output_id)
	var output_params: Dictionary = params_for(output)
	var color_a: Color = output_params["color_a"]
	return {
		"image": image,
		"size": size,
		"done": false,
		"row": 0,
		"source": _input_id(output, 0),
		"steps": maxi(int(output_params["steps"]), 2),
		"color_a": color_a,
		"color_mid": output_params.get("color_mid", color_a),
		"color_b": output_params["color_b"],
		"mid_position": clampf(float(output_params.get("mid_position", 0.5)), 0.05, 0.95),
		# A transparent background turns the layer into an overlay instead of a
		# full rectangle, which is what particles and glows need.
		"transparent": bool(output_params.get("transparent", false)),
		"alpha_cut": clampf(float(output_params.get("alpha_cut", 0.0)), 0.0, 1.0),
		"alpha_from_value": bool(output_params.get("alpha_from_value", false)),
	}


## Paints rows [param from_row] to [param to_row] of a generation.
func _paint_rows(state: Dictionary, from_row: int, to_row: int) -> void:
	var image: Image = state["image"]
	var size: Vector2i = state["size"]
	var source: String = state["source"]
	var steps: int = state["steps"]
	var color_a: Color = state["color_a"]
	var color_mid: Color = state["color_mid"]
	var color_b: Color = state["color_b"]
	var mid_position: float = state["mid_position"]
	var transparent: bool = state["transparent"]
	var alpha_cut: float = state["alpha_cut"]
	var alpha_from_value: bool = state["alpha_from_value"]
	for y in range(from_row, to_row):
		for x in size.x:
			var value := clampf(_eval(source, Vector2(x, y), size, 0), 0.0, 1.0)
			if transparent and value <= alpha_cut:
				image.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
				continue
			var step := floori(value * steps)
			var ramp := clampf(float(step) / float(steps - 1), 0.0, 1.0)
			var color := _ramp_color(color_a, color_mid, color_b, mid_position, ramp)
			if transparent and alpha_from_value:
				color.a = value
			image.set_pixel(x, y, color)


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
	_noise_checked.clear()
	# Cached strokes, trees and particle fields only last for one frame, so a
	# node id is enough to find them again inside the pixel loop.
	if not is_equal_approx(time, _raster_time):
		_raster_time = time
		_raster_size = Vector2i.ZERO
		_path_cache.clear()
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
		return _noise_value(node_id, params, uv)
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
		if int(params.get("source", 0)) == 1:
			return _canvas_path_value(node, params, uv, size, depth)
		return _source_value(node, params, uv, size)
	elif node_type == "time":
		# Loops of the animation and a per node offset, so several time driven
		# parts of a graph can run out of phase.
		var loops := maxf(float(params.get("speed", 1.0)), 0.0)
		return fposmod(time * loops + float(params.get("offset", 0.0)), 1.0)
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
		# Hue and saturation belong to the ramp of the output node instead.
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


## Grayscale preview of what one node outputs, used by the frame under the nodes
## in the graph editor. It evaluates the node the same way the generator does, so
## the picture always matches that branch of the graph.
func preview_node(node_id: String, size: Vector2i) -> Image:
	_resolve_animations()
	# Thumbnails use another resolution than the preview, so the rasterised nodes
	# are rebuilt at this size instead of being read at the wrong scale.
	_ensure_raster_size(size)
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in size.y:
		for x in size.x:
			var value := clampf(_eval(node_id, Vector2(x, y), size, 0), 0.0, 1.0)
			image.set_pixel(x, y, Color(value, value, value, 1.0))
	return image


## Rasterised node images belong to one resolution. Reading them from another
## size would show a cropped corner of the bigger picture, so they are thrown
## away when the size changes.
func _ensure_raster_size(size: Vector2i) -> void:
	if size == _raster_size:
		return
	_raster_size = size
	_path_cache.clear()


## Rasterises the stroke of a path node at [param size] and caches it, so the
## per pixel evaluation is just a lookup.
func _path_image(node: Dictionary, params: Dictionary, size: Vector2i) -> Image:
	var key := str(node["id"])
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
	var key := str(node["id"])
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
	var base := maxf(float(params.get("width", 0.06)) * shortest * 0.5, 0.5)
	var soft := clampf(float(params.get("soft", 0.0)) * shortest, 0.0, base)
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
		var radius_from := base * profile_at(profile, t_from)
		var radius_to := base * profile_at(profile, t_to)
		var span := maxi(int(ceil(from_point.distance_to(to_point) * 2.0)), 1)
		for step in span + 1:
			var ratio := float(step) / float(span)
			_stamp_disc(
				image, from_point.lerp(to_point, ratio), lerpf(radius_from, radius_to, ratio), soft
			)
	return image


## Samples the width profile of a stroke. The array holds evenly spaced values
## from the start of the curve to its end, so five numbers give four straight
## ramps.
static func profile_at(profile: Array, t: float) -> float:
	if profile.is_empty():
		return 1.0
	if profile.size() == 1:
		return clampf(float(profile[0]), 0.0, 1.0)
	var position := clampf(t, 0.0, 1.0) * float(profile.size() - 1)
	var index := mini(int(floorf(position)), profile.size() - 2)
	var ratio := position - float(index)
	return lerpf(
		clampf(float(profile[index]), 0.0, 1.0),
		clampf(float(profile[index + 1]), 0.0, 1.0),
		ratio
	)


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
	var key := str(node["id"])
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
	var key := str(node["id"])
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
		var age_phase := fposmod(phase + offset, 1.0) if animated else 0.0
		if animated and age_phase > lifetime:
			continue
		var age := age_phase / lifetime if animated else 0.0
		var position := (
			spawn
			+ Vector2.from_angle(particle_angle) * particle_speed * shortest * age_phase
			+ Vector2(0.0, 0.5 * gravity * shortest * age_phase * age_phase)
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
		var brightness := 1.0
		if fade and animated:
			# Fade in at birth and out towards the end, so a recycled particle
			# never pops into view.
			brightness = clampf(age / 0.12, 0.0, 1.0) * (1.0 - age)
		if twinkle > 0.0:
			brightness *= (
				1.0 - twinkle * 0.5 * (1.0 - sin(phase * TAU * 4.0 + offset * 40.0))
			)
		if brightness <= 0.004:
			continue
		if shape == 1:
			_stamp_disc(image, position, radius, soft, brightness)
		else:
			_stamp_square(image, position, radius, brightness)
	_path_cache[key] = image
	return image


## Stamps the brush of the first input over the canvas at random angles and sizes
## and caches the result per generated image. The brush is the whole source node,
## so a pixel_art layer holding a single leaf turns into a bush.
func _scatter_image(
	node: Dictionary, params: Dictionary, size: Vector2i, depth: int
) -> Image:
	var key := str(node["id"])
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
	var rng := RandomNumberGenerator.new()
	rng.seed = int(params.get("seed", 1))
	# Keep the aspect of a layer brush, so a wide leaf stays wide.
	var footprint := Vector2(shortest * stamp, shortest * stamp)
	var source_node := get_node_by_id(source_id)
	if not source_node.is_empty() and str(source_node["type"]) == "pixel_art":
		var brush_params := params_for(source_node)
		# Only the layer mode of a canvas node has an image with an aspect; a
		# path brush is square and keeps the square footprint.
		var brush := (
			_source_image(source_node, brush_params)
			if int(brush_params.get("source", 0)) == 0
			else null
		)
		if brush != null and not brush.is_empty():
			# The aspect of the cropped brush, not of the whole layer, so a
			# cropped leaf keeps its own shape.
			var region := source_crop(
				brush_params, Vector2i(brush.get_width(), brush.get_height())
			)
			var aspect := float(region.size.x) / float(maxi(region.size.y, 1))
			if aspect >= 1.0:
				footprint.y = footprint.x / aspect
			else:
				footprint.x = footprint.y * aspect
	var center := Vector2(size) * 0.5
	var reach := Vector2(shortest * spread * 0.5, shortest * spread * 0.5)
	# Along a path the brush follows the curve, and the path's own reveal limits
	# how far it may go, so animating that reveal grows the scatter.
	var along_path := false
	var path_points := PackedVector2Array()
	if int(params.get("mode", 0)) == 1 and not density_id.is_empty():
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
	for index in amount:
		# Every random value is taken before the density test, so hiding one
		# stamp does not reshuffle the rest of the field.
		var across := rng.randf_range(-1.0, 1.0)
		var down := rng.randf_range(-1.0, 1.0)
		var rotation := angle + deg_to_rad(rng.randf_range(-angle_random, angle_random))
		var scale := rng.randf_range(scale_min, scale_max)
		var chance := rng.randf()
		var position: Vector2
		if along_path:
			# Stratified slots keep the stamps spread evenly instead of clumping.
			var slot := (float(index) + rng.randf_range(0.0, 1.0)) / float(amount)
			var sample: Dictionary = _path_point_at(path_points, slot)
			var direction: Vector2 = sample["direction"]
			if follow_tangent and direction.length_squared() > 0.0:
				rotation += direction.angle()
			position = (sample["point"] as Vector2) * size_vec
			position += Vector2(-direction.y, direction.x) * across * shortest * path_width * 0.5
		else:
			position = center + Vector2(across * reach.x, down * reach.y)
		if align:
			position = position.round()
		if not along_path and not density_id.is_empty():
			if _eval(density_id, position, size, depth + 1) < chance:
				continue
		_stamp_source(image, source_id, position, rotation, scale, footprint, size, depth, level)
	_path_cache[key] = image
	return image


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
	level := 1.0
) -> void:
	var scaled := footprint * maxf(scale, 0.01)
	var reach := int(ceil(scaled.length() * 0.5)) + 1
	var center := Vector2i(roundi(position.x), roundi(position.y))
	var size_vec := Vector2(size)
	# The brush shape is resolved once per stamp. A pixel_art layer supplies its
	# opacity only, so the colours of the artwork never leak into the pattern and
	# the output ramp stays in charge of the colour.
	var mask_image: Image = null
	var mask_crop := Rect2i()
	var source_node := get_node_by_id(source_id)
	if not source_node.is_empty() and str(source_node["type"]) == "pixel_art":
		var source_params := params_for(source_node)
		# A canvas node in layer mode stamps the opacity of the artwork. In path
		# mode it already is a mask, so the node value is used as it is.
		if int(source_params.get("source", 0)) == 0:
			mask_image = _source_image(source_node, source_params)
			if mask_image == null or mask_image.is_empty():
				return
			mask_crop = source_crop(
				source_params, Vector2i(mask_image.get_width(), mask_image.get_height())
			)
	for offset_y in range(-reach, reach + 1):
		var y := center.y + offset_y
		if y < 0 or y >= size.y:
			continue
		for offset_x in range(-reach, reach + 1):
			var x := center.x + offset_x
			if x < 0 or x >= size.x:
				continue
			# -0.5..0.5 across the brush, then rotated back into brush space.
			var local := Vector2(float(offset_x), float(offset_y)) / scaled
			var brush_local := local.rotated(-rotation)
			if absf(brush_local.x) > 0.5 or absf(brush_local.y) > 0.5:
				continue
			var uv := (brush_local + Vector2(0.5, 0.5)) * size_vec
			var mask := (
				sample_source(mask_image, 1, false, uv, size, mask_crop)
				if mask_image != null
				else _eval(source_id, uv, size, depth + 1)
			)
			var value := clampf(mask * level, 0.0, 1.0)
			if value <= 0.0:
				continue
			if value > image.get_pixel(x, y).r:
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
	if _source_cache.has(key):
		return _source_cache[key]
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
	_source_cache[key] = image
	return image


## Draws a cel image onto a transparent canvas sized picture at [param offset],
## which is how the drawing area shows it.
static func _compose_cel(source: Image, offset: Vector2i, canvas: Vector2i) -> Image:
	var composed := Image.create_empty(
		maxi(canvas.x, 1), maxi(canvas.y, 1), false, Image.FORMAT_RGBA8
	)
	composed.fill(Color(0.0, 0.0, 0.0, 0.0))
	var layer := source
	if source.get_format() != Image.FORMAT_RGBA8:
		layer = source.duplicate()
		layer.convert(Image.FORMAT_RGBA8)
	composed.blend_rect(layer, Rect2i(Vector2i.ZERO, layer.get_size()), offset)
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
	var cel = project.frames[frame_index].cels[layer_index]
	if cel is BaseCel:
		return cel
	return null


## Drops the cached layer images, so the preview reads the artwork again after
## the drawing window painted into it.
func clear_source_cache() -> void:
	_source_cache.clear()


## The layer behind a pixel_art node, for the editor preview.
func source_image(node: Dictionary) -> Image:
	return _source_image(node, params_for(node))


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
## the artwork changes underneath it.
func uses_source() -> bool:
	for node: Dictionary in nodes:
		if node["type"] == "pixel_art" and int(node["params"].get("source", 0)) == 0:
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


## Noise is sampled with [FastNoiseLite], which is cached per node.
func _noise_value(node_id: String, params: Dictionary, uv: Vector2) -> float:
	var noise: FastNoiseLite = _noise_cache.get(node_id, null)
	# The signature string is only needed once per frame per node. Building it on
	# every pixel was one of the most expensive parts of the preview.
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
	return clampf(noise.get_noise_2d(uv.x, uv.y) * 0.5 + 0.5, 0.0, 1.0)


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
			var level := float(params.get("level", 1.0))
			if not is_equal_approx(level, 1.0):
				scatter_text += " · 亮度 %.2f" % level
			return scatter_text
		"particles":
			return "%d 颗 · %.1fpx" % [
				int(params.get("count", 48)), float(params.get("size", 1.5))
			]
		"constant":
			return "%.2f" % float(params.get("value", 0.5))
		"path":
			var path_text := "%d 点" % (params.get("points", []) as Array).size()
			if bool(params.get("closed", false)):
				path_text += " · 闭合"
			return path_text
		"pixel_art":
			if int(params.get("source", 0)) == 1:
				var line_text := "路径线条 · 宽 %.3f" % float(params.get("width", 0.06))
				if bool(params.get("fill", false)):
					line_text += " · 填充"
				return line_text
			var channels := ["亮度", "透明度", "反向透明度"]
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
			return "速度 %.1f" % float(params.get("speed", 1.0))
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
		"warp":
			return "%.2f" % float(params.get("amount", 0.15))
		"math":
			return MATH_OPS[int(params["op"])]
		"blend":
			return BLEND_OPS[int(params["op"])]
		"output":
			return "%d steps" % int(params["steps"])
	return ""


## True when the graph samples neighbours or does a pass over the whole branch,
## so the preview should be generated at a lower resolution.
func is_expensive() -> bool:
	const HEAVY := [
		"echo",
		"tree",
		"scatter",
		"blur",
		"outline",
		"glow",
		"bloom",
		"warp",
		"area_warp",
		"mesh_warp",
		"crop_content",
	]
	for node: Dictionary in nodes:
		if HEAVY.has(str(node["type"])):
			return true
	return false


## True when the graph changes over time, so generating a layer has to produce
## one image per frame.
func uses_time() -> bool:
	for node: Dictionary in nodes:
		# Any animated parameter is a clock of its own, whatever the node does.
		var anim: Variant = node["params"].get("anim", null)
		if anim is Dictionary and not (anim as Dictionary).is_empty():
			return true
		if node["type"] == "time":
			return true
		if node["type"] == "echo" and bool(node["params"].get("animated", false)):
			return true
		if node["type"] == "tree":
			var tree_params: Dictionary = node["params"]
			# Sway alone already needs one image per frame, even without growth.
			if bool(tree_params.get("animate", false)):
				return true
			if float(tree_params.get("sway", 0.0)) > 0.0:
				return true
		if node["type"] == "particles" and particles_animate(node["params"]):
			return true
		if node["type"] == "pixel_art" and int(node["params"].get("frame_mode", 0)) == 2:
			return true
	return false


## Replaces the graph with a ready made animated pixel sea: two travelling waves
## added to some noise, posterized and mapped to a deep to light blue ramp.
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
	get_node_by_id(out)["params"].merge(
		{
			"steps": 5,
			"color_a": Color(0.04, 0.13, 0.32, 1.0),
			"color_mid": Color(0.13, 0.38, 0.6, 1.0),
			"color_b": Color(0.62, 0.91, 0.97, 1.0),
			"mid_position": 0.5,
		},
		true
	)


## Replaces the graph with a pixel tree that grows along the animation: the tree
## node reveals one generation of branches per frame, and the ramp goes from dark
## bark to bright leaves.
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
	get_node_by_id(out)["params"].merge(
		{
			"steps": 4,
			"color_a": Color(0.16, 0.1, 0.06, 1.0),
			"color_mid": Color(0.34, 0.24, 0.1, 1.0),
			"color_b": Color(0.62, 0.83, 0.35, 1.0),
			"mid_position": 0.55,
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
			"width": 0.05,
			"soft": 0.02,
			"profile": [0.35, 1.0, 0.9, 1.0, 0.25],
		},
		true
	)
	get_node_by_id(out)["params"].merge(
		{
			"steps": 4,
			"color_a": Color(0.12, 0.24, 0.09, 1.0),
			"color_mid": Color(0.35, 0.68, 0.24, 1.0),
			"color_b": Color(0.78, 0.95, 0.55, 1.0),
			"mid_position": 0.5,
			"transparent": true,
		},
		true
	)


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
	get_node_by_id(out)["params"].merge(
		{
			"steps": 4,
			"color_a": Color(0.08, 0.16, 0.28, 1.0),
			"color_mid": Color(0.28, 0.62, 0.78, 1.0),
			"color_b": Color(0.85, 0.97, 1.0, 1.0),
			"mid_position": 0.5,
			"transparent": true,
		},
		true
	)


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
				"width": 0.02,
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
		},
		true
	)
	get_node_by_id(out)["params"].merge(
		{
			"steps": 4,
			"color_a": Color(0.09, 0.18, 0.11, 1.0),
			"color_mid": Color(0.22, 0.45, 0.27, 1.0),
			"color_b": Color(0.46, 0.75, 0.4, 1.0),
			"mid_position": 0.55,
			"transparent": true,
		},
		true
	)


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
	connect_nodes(stem, scatter, 1)
	connect_nodes(scatter, blend, 1)
	connect_nodes(blend, out, 0)
	# The stem gets thinner towards its tip, so the vine reads as a growing line.
	get_node_by_id(stem_draw)["params"].merge(
		{
			"source": 1,
			"width": 0.035,
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
			"width": 0.02,
			"soft": 0.01,
			"fill": true,
		},
		true
	)
	get_node_by_id(scatter)["params"].merge(
		{
			"amount": 30,
			"mode": 1,
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
		},
		true
	)
	get_node_by_id(blend)["params"].merge({"op": 1, "factor": 1.0}, true)
	get_node_by_id(out)["params"].merge(
		{
			"steps": 4,
			"color_a": Color(0.1, 0.24, 0.12, 1.0),
			"color_mid": Color(0.26, 0.55, 0.24, 1.0),
			"color_b": Color(0.62, 0.88, 0.42, 1.0),
			"mid_position": 0.55,
			"transparent": true,
		},
		true
	)
