class_name ShaderGraph
extends RefCounted
## A tiny node graph that turns procedural nodes into a pixel image.
##
## Every node produces a single grayscale value between 0 and 1 for a pixel. The
## [code]output[/code] node turns that value into a color with a two stop ramp and
## a limited number of steps, which keeps the result pixel art friendly.

## Node types and how many inputs they take.
const NODE_TYPES := {
	"noise": {"label": "Noise", "inputs": 0},
	"gradient": {"label": "Gradient", "inputs": 0},
	"radial": {"label": "Radial", "inputs": 0},
	"checker": {"label": "Checker", "inputs": 0},
	"time": {"label": "Time", "inputs": 0},
	"wave": {"label": "Wave", "inputs": 1},
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
		"time":
			return {}
		"wave":
			return {"frequency": 2.0, "angle": 0.0, "amplitude": 1.0}
		"checker":
			return {"cell": 8.0}
		"math":
			return {"op": 0, "amount": 0.5, "steps": 4}
		"blend":
			return {"op": 0, "factor": 0.5}
		"output":
			return {
				"steps": 2,
				"color_a": Color(0.09, 0.09, 0.12, 1.0),
				"color_b": Color(0.95, 0.95, 0.98, 1.0),
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
	var steps := maxi(int(output["params"]["steps"]), 2)
	var color_a: Color = output["params"]["color_a"]
	var color_b: Color = output["params"]["color_b"]
	var source := _input_id(output, 0)
	for y in size.y:
		for x in size.x:
			var value := clampf(_eval(source, x, y, size, 0), 0.0, 1.0)
			var step := floori(value * steps)
			var ramp := clampf(float(step) / float(steps - 1), 0.0, 1.0)
			var color := color_a.lerp(color_b, ramp)
			if step >= steps:
				color = color_b
			image.set_pixel(x, y, color)
	return image


func _input_id(node: Dictionary, slot: int) -> String:
	var inputs: Dictionary = node["inputs"]
	return str(inputs.get(slot, ""))


## Value of [param node_id] for the pixel at [param x], [param y].
func _eval(node_id: String, x: int, y: int, size: Vector2i, depth: int) -> float:
	if node_id.is_empty() or depth > 32:
		return 0.0
	var node := get_node_by_id(node_id)
	if node.is_empty():
		return 0.0
	var params: Dictionary = node["params"]
	var size_vec := Vector2(size)
	match str(node["type"]):
		"noise":
			return _noise_value(node_id, params, x, y)
		"gradient":
			var direction := Vector2.from_angle(deg_to_rad(float(params["angle"])))
			var normalized := (Vector2(x, y) / size_vec) - Vector2(0.5, 0.5)
			var shift := float(params.get("offset", 0.0))
			return clampf(0.5 + normalized.dot(direction) * 1.414 + shift, 0.0, 1.0)
		"radial":
			var center := Vector2(float(params["center_x"]), float(params["center_y"]))
			var distance := ((Vector2(x, y) / size_vec) - center).length()
			var value := clampf(1.0 - distance / maxf(float(params["radius"]), 0.001), 0.0, 1.0)
			value = pow(value, maxf(float(params.get("falloff", 1.0)), 0.05))
			return 1.0 - value if bool(params["invert"]) else value
		"checker":
			var cell := maxf(float(params["cell"]), 1.0)
			var odd := (floori(x / cell) + floori(y / cell)) % 2
			return 1.0 if odd == 1 else 0.0
		"time":
			return clampf(time, 0.0, 1.0)
		"wave":
			# A travelling sine: the phase comes from a time node, the direction and
			# frequency shape the crests, so the result reads as moving water.
			var phase := clampf(_eval(_input_id(node, 0), x, y, size, depth + 1), 0.0, 1.0)
			var travel := Vector2.from_angle(deg_to_rad(float(params["angle"])))
			var position := Vector2(x, y) / size_vec
			var wave := 0.5 + 0.5 * sin(
				TAU * (position.dot(travel) * float(params["frequency"]) + phase)
			)
			return lerpf(0.5, wave, clampf(float(params["amplitude"]), 0.0, 1.0))
		"math":
			var source := clampf(_eval(_input_id(node, 0), x, y, size, depth + 1), 0.0, 1.0)
			return _math_value(int(params["op"]), source, params)
		"blend":
			var a := clampf(_eval(_input_id(node, 0), x, y, size, depth + 1), 0.0, 1.0)
			var b := clampf(_eval(_input_id(node, 1), x, y, size, depth + 1), 0.0, 1.0)
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
			return clampf(_eval(_input_id(node, 0), x, y, size, depth + 1), 0.0, 1.0)
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
func _noise_value(node_id: String, params: Dictionary, x: int, y: int) -> float:
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
	return clampf(noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5, 0.0, 1.0)


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
		"time":
			return "帧相位"
		"wave":
			return "%.1f 周期 · %d°" % [float(params["frequency"]), int(params["angle"])]
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
			"color_b": Color(0.56, 0.89, 0.96, 1.0),
		},
		true
	)
