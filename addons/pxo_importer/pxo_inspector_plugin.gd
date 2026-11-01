@tool
extends EditorInspectorPlugin
## Puts a picture at the top of the Inspector whenever a [PxoProject] is
## selected, which is what double-clicking an imported `.pxo` opens.
##
## Without this an imported project shows only a read-only property list: the
## frames and layers are there, but nothing says whether the import worked.

const PreviewScript := preload("res://addons/pxo_importer/pxo_preview.gd")


func _can_handle(object: Object) -> bool:
	return object is PxoProject


func _parse_begin(object: Object) -> void:
	var project := object as PxoProject
	if project == null:
		return
	var preview: Control = PreviewScript.new()
	preview.call("setup", project)
	add_custom_control(preview)
