class_name ShaderGraph
extends RefCounted
## A tiny node graph that turns procedural nodes into a pixel image.
##
## Every node produces a single grayscale value between 0 and 1 for a pixel. The
## [code]output[/code] node turns that value into a color with a three stop ramp
## and a limited number of steps, which keeps the result pixel art friendly.

## Node types and how many inputs they take.
const NODE_TYPES := {
	"noise": {"label": "Noise", "inputs": 0},
	"gradient": {"label": "Gradient", "inputs": 0},
	"radial": {"label": "Radial", "inputs": 0},
	"checker": {"label": "Checker", "inputs": 0},
	"constant": {"label": "Constant", "inputs": 0},
	"time": {"label": "Time", "inputs": 0},
	"wave": {"label": "Wave", "inputs": 1},
	"transform": {"label": "Transform", "inputs": 1},
	"warp": {"label": "Warp", "inputs": 2},
	"math": {"label": "Math", "inputs": 1},
	"blend": {"label": "Blend", "inputs": 2},
	"output": {"label": "Output", "inputs": 1},
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
## Coordinates closer than this to a pixel are treated as that pixel. Only used to
## cancel the floating point noise of rotations by right angles.
const SNAP_STEP := 0.000001

## Nodes of the graph, as dictionaries: id, type, position, params, inputs.
var nodes: Array[Dictionary] = []
## Animation phase between 0 and 1, read by the [code]time[/code] node.
var time := 0.0
var _next_id := 1
var _noise_cache := {}
var _noise_signature := {}


func _init() -> void:
	reset_to_default()


## Starts over with a noise feeding an output, so the graph always has a result.
func reset_to_default() -> void:
	nodes.clear()
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


func remove_node(id: String) -> void:
	for i in range(nodes.size() - 1, -1, -1):
		if nodes[i]["id"] == id:
			nodes.remove_at(i)
	_noise_cache.erase(id)
	_noise_signature.erase(id)
	for node: Dictionary in nodes:
		var inputs: Dictionary = node["inputs"]
		for slot in inputs.keys():
			if inputs[slot] == id:
				inputs.erase(slot)


func get_node_by_id(id: String) -> Dictionary:
	for node: Dictionary in nodes:
		if node["id"] == id:
			return node
	return {}


## Snapshot of the whole graph, stored on the layers this graph created so they
## can be edited again later.
func to_dict() -> Dictionary:
	return {"nodes": nodes.duplicate(true), "next_id": _next_id}


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
		"constant":
			return {"value": 0.5}
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
			}
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
			}
	return {}


## Generates the image of the graph. [param size] is in pixels.
func generate(size: Vector2i) -> Image:
	size.x = maxi(size.x, 1)
	size.y = maxi(size.y, 1)
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	var output_id := output_node_id()
	if output_id.is_empty():
		image.fill(Color(0, 0, 0, 0))
		return image
	var output := get_node_by_id(output_id)
	var output_params: Dictionary = output["params"]
	var steps := maxi(int(output_params["steps"]), 2)
	var color_a: Color = output_params["color_a"]
	var color_mid: Color = output_params.get("color_mid", color_a)
	var color_b: Color = output_params["color_b"]
	var mid_position := clampf(float(output_params.get("mid_position", 0.5)), 0.05, 0.95)
	var source := _input_id(output, 0)
	for y in size.y:
		for x in size.x:
			var value := clampf(_eval(source, Vector2(x, y), size, 0), 0.0, 1.0)
			var step := floori(value * steps)
			var ramp := clampf(float(step) / float(steps - 1), 0.0, 1.0)
			image.set_pixel(x, y, _ramp_color(color_a, color_mid, color_b, mid_position, ramp))
	return image


static func _ramp_color(a: Color, mid: Color, b: Color, mid_position: float, t: float) -> Color:
	if t <= mid_position:
		return a.lerp(mid, t / mid_position)
	return mid.lerp(b, (t - mid_position) / (1.0 - mid_position))


func _input_id(node: Dictionary, slot: int) -> String:
	var inputs: Dictionary = node["inputs"]
	return str(inputs.get(slot, ""))


## Value of [param node_id] at the pixel (or the mapped canvas position) [param uv].
func _eval(node_id: String, uv: Vector2, size: Vector2i, depth: int) -> float:
	if node_id.is_empty() or depth > 32:
		return 0.0
	var node := get_node_by_id(node_id)
	if node.is_empty():
		return 0.0
	var params: Dictionary = node["params"]
	var size_vec := Vector2(size)
	var normalized := uv / size_vec
	match str(node["type"]):
		"noise":
			return _noise_value(node_id, params, uv)
		"gradient":
			var direction := Vector2.from_angle(deg_to_rad(float(params["angle"])))
			var shift := float(params.get("offset", 0.0))
			return clampf(
				0.5 + (normalized - Vector2(0.5, 0.5)).dot(direction) * 1.414 + shift, 0.0, 1.0
			)
		"radial":
			var center := Vector2(float(params["center_x"]), float(params["center_y"]))
			var distance := (normalized - center).length()
			var value := clampf(1.0 - distance / maxf(float(params["radius"]), 0.001), 0.0, 1.0)
			value = pow(value, maxf(float(params.get("falloff", 1.0)), 0.05))
			return 1.0 - value if bool(params["invert"]) else value
		"checker":
			var cell := maxf(float(params["cell"]), 1.0)
			var odd := (floori(uv.x / cell) + floori(uv.y / cell)) % 2
			return 1.0 if odd == 1 else 0.0
		"constant":
			return clampf(float(params.get("value", 0.5)), 0.0, 1.0)
		"time":
			# Loops of the animation and a per node offset, so several time driven
			# parts of a graph can run out of phase.
			var loops := maxf(float(params.get("speed", 1.0)), 0.0)
			return fposmod(time * loops + float(params.get("offset", 0.0)), 1.0)
		"wave":
			var phase := clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
			var travel := Vector2.from_angle(deg_to_rad(float(params["angle"])))
			var wave := 0.5 + 0.5 * sin(
				TAU * (normalized.dot(travel) * float(params["frequency"]) + phase)
			)
			return lerpf(0.5, wave, clampf(float(params["amplitude"]), 0.0, 1.0))
		"transform":
			# Maps the canvas position before the input is sampled, so any branch
			# can be scaled, rotated, moved or tiled.
			var pivot := size_vec * 0.5
			var mapped := (uv - pivot).rotated(deg_to_rad(float(params["angle"])))
			mapped /= maxf(float(params["scale"]), 0.01)
			mapped += pivot
			mapped += (
				Vector2(float(params["offset_x"]), float(params["offset_y"])) * size_vec
			)
			# cos(90°) is not exactly zero, so a quarter turn leaves a ~1e-16 wobble
			# that flips pixels sitting on a color step. Snapping far below a pixel
			# removes the wobble without touching the visible result.
			mapped = mapped.snapped(Vector2(SNAP_STEP, SNAP_STEP))
			if bool(params.get("tile", false)):
				mapped = Vector2(fposmod(mapped.x, size_vec.x), fposmod(mapped.y, size_vec.y))
			return clampf(_eval(_input_id(node, 0), mapped, size, depth + 1), 0.0, 1.0)
		"warp":
			# The first input is the field, the second one the image being distorted.
			var amount := float(params.get("amount", 0.15)) * size_vec.y
			var field_x := _eval(_input_id(node, 0), uv, size, depth + 1) - 0.5
			var field_y := (
				_eval(_input_id(node, 0), uv + Vector2(37.0, 61.0), size, depth + 1) - 0.5
			)
			var shifted := uv + Vector2(field_x, field_y) * amount * 2.0
			return clampf(_eval(_input_id(node, 1), shifted, size, depth + 1), 0.0, 1.0)
		"math":
			var source := clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
			return _math_value(int(params["op"]), source, params)
		"blend":
			var a := clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
			var b := clampf(_eval(_input_id(node, 1), uv, size, depth + 1), 0.0, 1.0)
			var factor := clampf(float(params["factor"]), 0.0, 1.0)
			var blended := 0.0
			match BLEND_OPS[int(params["op"])]:
				"Mix":
					return lerpf(a, b, factor)
				"Add":
					blended = a + b
				"Multiply":
					blended = a * b
				"Screen":
					blended = 1.0 - (1.0 - a) * (1.0 - b)
				"Difference":
					blended = absf(a - b)
			return clampf(lerpf(a, blended, factor), 0.0, 1.0)
		"output":
			return clampf(_eval(_input_id(node, 0), uv, size, depth + 1), 0.0, 1.0)
	return 0.0


func _math_value(op: int, source: float, params: Dictionary) -> float:
	var amount := float(params["amount"])
	match MATH_OPS[op]:
		"Add":
			return clampf(source + amount, 0.0, 1.0)
		"Subtract":
			return clampf(source - amount, 0.0, 1.0)
		"Multiply":
			return clampf(source * amount, 0.0, 1.0)
		"Min":
			return minf(source, amount)
		"Max":
			return maxf(source, amount)
		"Step":
			return 1.0 if source >= amount else 0.0
		"Sine":
			return 0.5 + 0.5 * sin(source * TAU * maxf(amount, 0.0))
		"Posterize":
			var steps := maxi(int(params["steps"]), 2)
			return clampf(floorf(source * steps) / float(steps - 1), 0.0, 1.0)
		"Invert":
			return 1.0 - source
	return source


## Noise is sampled with [FastNoiseLite], which is cached per node.
func _noise_value(node_id: String, params: Dictionary, uv: Vector2) -> float:
	var signature := "%d|%.4f|%d|%d|%.4f" % [
		int(params["noise_type"]),
		float(params["scale"]),
		int(params["octaves"]),
		int(params["seed"]),
		float(params["gain"]),
	]
	var noise: FastNoiseLite = _noise_cache.get(node_id, null)
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
		"constant":
			return "%.2f" % float(params.get("value", 0.5))
		"time":
			return "速度 %.1f" % float(params.get("speed", 1.0))
		"wave":
			return "%.1f 周期 · %d°" % [float(params["frequency"]), int(params["angle"])]
		"transform":
			return "×%.2f · %d°" % [float(params["scale"]), int(params["angle"])]
		"warp":
			return "%.2f" % float(params.get("amount", 0.15))
		"math":
			return MATH_OPS[int(params["op"])]
		"blend":
			return BLEND_OPS[int(params["op"])]
		"output":
			return "%d steps" % int(params["steps"])
	return ""


## True when the graph changes over time, so generating a layer has to produce
## one image per frame.
func uses_time() -> bool:
	for node: Dictionary in nodes:
		if node["type"] == "time":
			return true
	return false


## Replaces the graph with a ready made animated pixel sea: two travelling waves
## added to some noise, posterized and mapped to a deep to light blue ramp.
func build_ocean_preset() -> void:
	nodes.clear()
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
