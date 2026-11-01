@tool
extends EditorImportPlugin
## Makes Godot treat a `.pxo` like any other art asset.
##
## Drop a Pixelorama project anywhere under `res://` and Godot imports it into a
## [PxoProject], which carries every frame, every layer, and a ready-made
## [SpriteFrames]. Re-saving the project in Pixelorama and switching back to
## Godot re-imports it, the same way a `.png` would be.

const ReaderScript := preload("res://addons/pxo_importer/pxo_reader.gd")

## Bumped whenever what ends up inside the imported resource changes. Godot
## compares it with the version recorded for each `.pxo` and re-imports when they
## differ; without it a resource built by an older reader keeps being loaded, and
## the new fields look like they were never there (greyed-out buttons, empty
## tile lists).
const FORMAT_VERSION := 2


func _get_format_version() -> int:
	return FORMAT_VERSION


func _get_importer_name() -> String:
	return "pxo_project"


func _get_visible_name() -> String:
	return "Pixelorama Project"


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["pxo"])


func _get_save_extension() -> String:
	return "res"


func _get_resource_type() -> String:
	return "Resource"


func _get_priority() -> float:
	# Nothing else claims .pxo, but saying so keeps another importer from
	# quietly winning the file.
	return 1.0


func _get_import_order() -> int:
	return 0


func _get_preset_count() -> int:
	return 1


func _get_preset_name(preset_index: int) -> String:
	return "Pixelorama 项目"


func _get_import_options(path: String, preset_index: int) -> Array[Dictionary]:
	return [
		{
			"name": "import_composite_only",
			"default_value": false,
			"property_hint": PROPERTY_HINT_NONE,
			"hint_string": "",
			"usage": PROPERTY_USAGE_DEFAULT,
		},
		{
			"name": "layer_filter",
			"default_value": "",
			"property_hint": PROPERTY_HINT_NONE,
			"hint_string": "逗号分隔的层名；留空表示导入全部图层",
			"usage": PROPERTY_USAGE_DEFAULT,
		},
	]


func _get_option_visibility(path: String, option_name: StringName, options: Dictionary) -> bool:
	return true


func _import(
	source_file: String,
	save_path: String,
	options: Dictionary,
	platform_variants: Array[String],
	gen_files: Array[String]
) -> Error:
	var project: PxoProject = ReaderScript.read(source_file, options)
	if project == null:
		return ERR_FILE_CORRUPT
	if bool(options.get("import_composite_only", false)):
		# The flattened frames are all a plain AnimatedSprite2D needs, and
		# dropping the per-layer images makes the imported resource much smaller.
		for frame: PxoFrame in project.frames:
			frame.layer_images.clear()
	var err := ResourceSaver.save(project, "%s.%s" % [save_path, _get_save_extension()])
	if err != OK:
		push_error("PXO: 保存 %s 失败（错误 %d）" % [save_path, err])
	return err
