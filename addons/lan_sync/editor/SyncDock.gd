@tool
extends VBoxContainer
## Dock of the editor side: the folders this project shares, the peers found on
## the network, and a log of what moved. Everything that talks to the network
## lives in the core, so the dock is only a view of it.

const CoreScript := preload("res://addons/lan_sync/core/LanSyncCore.gd")
## Folder shared out of the box. Both sides default to the same name, so a fresh
## install on either end lines up without any setup at all.
const DEFAULT_NAME := "shared"
const DEFAULT_DIR := "res://lan_shared"
## After a file lands, the editor needs a moment before a scan picks it up.
const RESCAN_DELAY := 0.5

var _core: Node
var _folders: ItemList
var _peers: ItemList
var _log: RichTextLabel
var _status: Label
var _endpoint_edit: LineEdit
var _name_edit: LineEdit
var _path_edit: LineEdit
var _address_edit: LineEdit
var _start_button: Button
var _browse_dialog: EditorFileDialog
var _rescan_left := 0.0


func _ready() -> void:
	_build()
	_core = CoreScript.new()
	_core.name = "LanSyncCore"
	_core.log_line.connect(_on_log)
	_core.peers_changed.connect(_refresh_peers)
	_core.file_synced.connect(_on_file_synced)
	add_child(_core)
	if _core.folders.is_empty():
		_ensure_default_folder()
	_refresh_folders()
	_refresh_peers()
	_refresh_status()
	_on_log("本机网卡：%s" % str(_core.local_details()))
	_on_log("文件夹名两侧要一致；默认都是 %s" % DEFAULT_NAME)


func _process(delta: float) -> void:
	if _rescan_left <= 0.0:
		return
	_rescan_left -= delta
	if _rescan_left <= 0.0:
		var filesystem := EditorInterface.get_resource_filesystem()
		if filesystem != null:
			filesystem.scan()


func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var title := Label.new()
	title.text = "局域网同步"
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	# The address this machine answers on, on its own row: it is the one string
	# somebody types into the other device, so it must be copyable and present
	# before anything is started.
	add_child(_heading("本机地址（填到对方）"))
	var endpoint_row := HBoxContainer.new()
	_endpoint_edit = LineEdit.new()
	_endpoint_edit.editable = false
	_endpoint_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	endpoint_row.add_child(_endpoint_edit)
	var copy_button := Button.new()
	copy_button.text = "复制"
	copy_button.pressed.connect(_on_copy_endpoint)
	endpoint_row.add_child(copy_button)
	add_child(endpoint_row)

	add_child(_heading("同步文件夹"))
	_folders = ItemList.new()
	_folders.custom_minimum_size = Vector2(0, 70)
	add_child(_folders)
	var add_row := HBoxContainer.new()
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "名称（留空取目录名）"
	_name_edit.custom_minimum_size = Vector2(110, 0)
	add_row.add_child(_name_edit)
	_path_edit = LineEdit.new()
	_path_edit.placeholder_text = "留空则用 res://lan_shared/<名称>"
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_row.add_child(_path_edit)
	var browse_button := Button.new()
	browse_button.text = "浏览"
	browse_button.pressed.connect(_on_browse_folder)
	add_row.add_child(browse_button)
	var add_button := Button.new()
	add_button.text = "添加"
	add_button.pressed.connect(_on_add_folder)
	add_row.add_child(add_button)
	var remove_button := Button.new()
	remove_button.text = "移除"
	remove_button.pressed.connect(_on_remove_folder)
	add_row.add_child(remove_button)
	add_child(add_row)

	var run_row := HBoxContainer.new()
	_start_button = Button.new()
	_start_button.text = "开始"
	_start_button.pressed.connect(_on_start_pressed)
	run_row.add_child(_start_button)
	var scan_button := Button.new()
	scan_button.text = "扫描局域网"
	scan_button.pressed.connect(_on_scan_pressed)
	run_row.add_child(scan_button)
	var sync_button := Button.new()
	sync_button.text = "同步一次"
	sync_button.tooltip_text = "把对方的文件拉过来，覆盖本机同名文件"
	sync_button.pressed.connect(_on_sync_now_pressed)
	run_row.add_child(sync_button)
	var connect_button := Button.new()
	connect_button.text = "按地址连接"
	connect_button.pressed.connect(_on_connect_pressed)
	run_row.add_child(connect_button)
	add_child(run_row)

	_address_edit = LineEdit.new()
	_address_edit.placeholder_text = "地址 例 192.168.1.20:45990"
	add_child(_address_edit)

	add_child(_heading("附近设备"))
	_peers = ItemList.new()
	_peers.custom_minimum_size = Vector2(0, 50)
	add_child(_peers)

	add_child(_heading("日志"))
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 110)
	_log.scroll_following = true
	add_child(_log)


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.68, 0.72, 0.8))
	return label


func _ensure_default_folder() -> void:
	var absolute := ProjectSettings.globalize_path(DEFAULT_DIR)
	DirAccess.make_dir_recursive_absolute(absolute)
	_core.set_folder(DEFAULT_NAME, absolute)


func _refresh_folders() -> void:
	_folders.clear()
	for folder_name: String in _core.folders:
		var path := str(_core.folders[folder_name])
		_folders.add_item(
			"%s → %s（%d 个文件）" % [folder_name, path, int(_core.call("count_files", path))]
		)


func _refresh_peers() -> void:
	_peers.clear()
	for id: String in _core.peers:
		var entry: Dictionary = _core.peers[id]
		_peers.add_item(
			"%s · %s · %s" % [
				str(entry.get("label", id)),
				str(entry.get("address", "")),
				str(entry.get("state", "")),
			]
		)
	_refresh_status()


func _refresh_status() -> void:
	if _core == null:
		return
	if _core.running:
		_status.text = "%s · 已发 %d / 已收 %d" % [
			str(_core.call("link_text")),
			int(_core.get("sent_files")), int(_core.get("received_files"))
		]
	else:
		_status.text = "未开始 · 点「开始」后自动发现并连接另一侧"
	# Updated even while stopped: the address is what gets typed in by hand when
	# nothing else works, so it must not wait on a successful start.
	_endpoint_edit.text = str(_core.primary_endpoint())
	_endpoint_edit.tooltip_text = "全部地址：%s" % str(_core.local_endpoints())


func _on_copy_endpoint() -> void:
	var text := _endpoint_edit.text.strip_edges()
	if text.is_empty():
		return
	DisplayServer.clipboard_set(text)
	_on_log("已复制本机地址 %s" % text)


func _on_start_pressed() -> void:
	if _core.running:
		_core.stop()
		_start_button.text = "开始"
	else:
		if _core.start():
			_start_button.text = "停止"
	_refresh_status()


## Adding a folder should be one action, not a form. The name defaults to the
## directory's own name and the path defaults to the shared area, so selecting a
## directory and pressing 添加 is enough, and pressing it with nothing typed adds
## nothing.
func _on_add_folder() -> void:
	var folder_name := _name_edit.text.strip_edges()
	var path := _path_edit.text.strip_edges()
	if folder_name.is_empty():
		folder_name = _name_from_path(path)
	if folder_name.is_empty():
		_on_log("先选一个目录，或在「名称」里起个名字")
		return
	if path.is_empty():
		path = DEFAULT_DIR.path_join(folder_name)
	var absolute := path
	if path.begins_with("res://"):
		absolute = ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(absolute)
	_core.set_folder(folder_name, absolute)
	_name_edit.clear()
	_path_edit.clear()
	_refresh_folders()
	_refresh_status()
	_on_log("已添加 %s → %s" % [folder_name, absolute])


func _on_browse_folder() -> void:
	if is_instance_valid(_browse_dialog):
		_browse_dialog.queue_free()
	_browse_dialog = EditorFileDialog.new()
	_browse_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_browse_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_browse_dialog.title = "选择要同步的目录"
	_browse_dialog.dir_selected.connect(_on_folder_picked)
	add_child(_browse_dialog)
	_browse_dialog.popup_centered_ratio(0.5)


func _on_folder_picked(path: String) -> void:
	var picked := path.replace("\\", "/")
	# A directory inside the project reads better as res://, and both forms are
	# accepted by the core.
	var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/")
	if picked.begins_with(project_root):
		picked = "res://" + picked.trim_prefix(project_root)
	_path_edit.text = picked
	if _name_edit.text.strip_edges().is_empty():
		_name_edit.text = _name_from_path(picked)


## The last segment of a path, which is the folder name in every layout worth
## naming: "…/MyArt" is the folder "MyArt" on both sides.
func _name_from_path(path: String) -> String:
	return path.replace("\\", "/").trim_suffix("/").get_file()


func _on_remove_folder() -> void:
	var selected := _folders.get_selected_items()
	if selected.is_empty():
		return
	var names: Array = _core.folders.keys()
	var index: int = selected[0]
	if index < 0 or index >= names.size():
		return
	_core.remove_folder(str(names[index]))
	_refresh_folders()


func _on_scan_pressed() -> void:
	_core.scan()
	_refresh_status()


func _on_sync_now_pressed() -> void:
	_core.call("request_sync_now")
	_refresh_status()


func _on_connect_pressed() -> void:
	var text := _address_edit.text.strip_edges()
	if text.is_empty():
		return
	var port := int(CoreScript.SYNC_PORT)
	var parts := text.split(":")
	if parts.size() > 1:
		port = int(parts[1])
	_core.connect_to(parts[0], port)
	_refresh_status()


func _on_log(text: String) -> void:
	if not is_instance_valid(_log):
		return
	_log.append_text("[color=#9fb0c8]•[/color] %s\n" % text)


func _on_file_synced(path: String, direction: String) -> void:
	_rescan_left = RESCAN_DELAY
	_refresh_folders()
	_on_log("%s %s" % ["收到" if direction == "in" else "发出", path.get_file()])
