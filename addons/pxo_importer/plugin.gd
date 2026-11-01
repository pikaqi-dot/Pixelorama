@tool
extends EditorPlugin
## Wires Pixelorama projects into the editor:
##
## - the import plugin, so `.pxo` files under `res://` become [PxoProject]s;
## - the inspector plugin, so selecting one shows its frames instead of a bare
##   read-only property list.

const ImporterScript := preload("res://addons/pxo_importer/pxo_import_plugin.gd")
const InspectorScript := preload("res://addons/pxo_importer/pxo_inspector_plugin.gd")

var _importer: EditorImportPlugin
var _inspector: EditorInspectorPlugin


func _enter_tree() -> void:
	_importer = ImporterScript.new()
	add_import_plugin(_importer)
	_inspector = InspectorScript.new()
	add_inspector_plugin(_inspector)


func _exit_tree() -> void:
	if is_instance_valid(_inspector):
		remove_inspector_plugin(_inspector)
		_inspector = null
	if is_instance_valid(_importer):
		remove_import_plugin(_importer)
		_importer = null
