@tool
extends EditorPlugin
## Puts the sync dock next to the other docks, so the editor can trade files with
## a build of the application running on the same network.

const SyncDockScript := preload("res://addons/lan_sync/editor/SyncDock.gd")

var _dock: Control


func _enter_tree() -> void:
	_dock = SyncDockScript.new()
	_dock.name = "LAN Sync"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if not is_instance_valid(_dock):
		return
	remove_control_from_docks(_dock)
	_dock.queue_free()
	_dock = null
