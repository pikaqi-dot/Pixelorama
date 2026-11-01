@tool
extends EditorPlugin
## Registers the `.pxo` import plugin, so Pixelorama projects under `res://`
## become ordinary Godot resources the moment they are dropped in.

const ImporterScript := preload("res://addons/pxo_importer/pxo_import_plugin.gd")

var _importer: EditorImportPlugin


func _enter_tree() -> void:
	_importer = ImporterScript.new()
	add_import_plugin(_importer)


func _exit_tree() -> void:
	if is_instance_valid(_importer):
		remove_import_plugin(_importer)
		_importer = null
