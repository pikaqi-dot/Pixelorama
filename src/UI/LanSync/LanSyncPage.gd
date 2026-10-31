extends Control
## Page of the drawing tabs that trades files with the Godot editor over the
## local network. It is the same engine the editor dock runs, so the folders are
## matched by name and neither side has to be told an address: the peers find
## each other by beacon and connect by themselves.

signal page_closed()

const CoreScript := preload("res://addons/lan_sync/core/LanSyncCore.gd")
## Folder shared out of the box, named the same way the editor dock names its
## own, so a fresh build and a fresh dock line up with no setup at all.
const DEFAULT_NAME := "shared"
const DEFAULT_FOLDER := "user://lan_shared"
const ROW_HEIGHT := 44
const MARGIN := 14

var _core: Node
var _folders: ItemList
var _peers: ItemList
var _log: RichTextLabel
var _status: Label
var _name_edit: LineEdit
var _path_edit: LineEdit
var _address_edit: LineEdit
var _start_button: Button
var _consent_dialog: ConfirmationDialog


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_core = CoreScript.new()
	_core.name = "LanSyncCore"
	_core.log_line.connect(_on_log)
	_core.peers_changed.connect(_refresh_peers)
	_core.file_synced.connect(_on_file_synced)
	_core.consent_requested.connect(_on_consent_requested)
	add_child(_core)
	if _core.folders.is_empty():
		var absolute := ProjectSettings.globalize_path(DEFAULT_FOLDER)
		DirAccess.make_dir_recursive_absolute(absolute)
		_core.set_folder(DEFAULT_NAME, absolute)
	_refresh_folders()
	_refresh_peers()
	_refresh_status()
	_on_log("文件夹名两侧要一致；默认都是 %s" % DEFAULT_NAME)


func is_open() -> bool:
	return visible


func open_page() -> void:
	visible = true


func pause_page() -> void:
	set_process(false)


func resume_page() -> void:
	set_process(true)


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", MARGIN)
	margin.add_theme_constant_override("margin_top", MARGIN)
	margin.add_theme_constant_override("margin_right", MARGIN)
	margin.add_theme_constant_override("margin_bottom", MARGIN)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var title := Label.new()
	title.text = "局域网同步"
	title.add_theme_font_size_override("font_size", 18)
	column.add_child(title)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 13)
	column.add_child(_status)

	column.add_child(_heading("同步文件夹"))
	_folders = ItemList.new()
	_folders.custom_minimum_size = Vector2(0, 70)
	column.add_child(_folders)
	var add_row := HBoxContainer.new()
	_name_edit = _line_edit("名称")
	_name_edit.custom_minimum_size = Vector2(80, ROW_HEIGHT)
	add_row.add_child(_name_edit)
	_path_edit = _line_edit("绝对路径（可留空，用默认目录）")
	add_row.add_child(_path_edit)
	column.add_child(add_row)
	var folder_row := HBoxContainer.new()
	folder_row.add_child(_button("添加", _on_add_folder))
	folder_row.add_child(_button("移除选中", _on_remove_folder))
	column.add_child(folder_row)

	var run_row := HBoxContainer.new()
	_start_button = _button("开始", _on_start_pressed)
	run_row.add_child(_start_button)
	run_row.add_child(_button("扫描局域网", _on_scan_pressed))
	run_row.add_child(_button("按地址连接", _on_connect_pressed))
	column.add_child(run_row)
	_address_edit = _line_edit("地址 例 192.168.1.20:45990")
	column.add_child(_address_edit)

	column.add_child(_heading("附近设备"))
	_peers = ItemList.new()
	_peers.custom_minimum_size = Vector2(0, 60)
	column.add_child(_peers)

	column.add_child(_heading("日志"))
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_log.add_theme_font_size_override("normal_font_size", 12)
	column.add_child(_log)

	column.add_child(_button("返回绘画", _on_close_pressed))


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.68, 0.72, 0.8))
	return label


func _line_edit(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	return edit


func _button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	button.pressed.connect(handler)
	return button


func _refresh_folders() -> void:
	_folders.clear()
	for folder_name: String in _core.folders:
		_folders.add_item("%s → %s" % [folder_name, str(_core.folders[folder_name])])


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
	if not _core.running:
		_status.text = "未开始 · 点「开始」让同一局域网里的编辑器找到这台设备"
		return
	_status.text = "运行中 · %s · 端口 %d · 文件夹 %d 个" % [
		str(_core.label), int(_core.sync_port), _core.folders.size()
	]


func _on_start_pressed() -> void:
	if _core.running:
		_core.stop()
		_start_button.text = "开始"
	else:
		if _core.start():
			_start_button.text = "停止"
	_refresh_status()


func _on_add_folder() -> void:
	var folder_name := _name_edit.text.strip_edges()
	if folder_name.is_empty():
		_on_log("先给文件夹起个名字，两侧名字要一样")
		return
	var path := _path_edit.text.strip_edges()
	if path.is_empty():
		path = ProjectSettings.globalize_path(DEFAULT_FOLDER.path_join(folder_name))
	DirAccess.make_dir_recursive_absolute(path)
	_core.set_folder(folder_name, path)
	_name_edit.clear()
	_path_edit.clear()
	_refresh_folders()
	_refresh_status()


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
	_refresh_status()


func _on_scan_pressed() -> void:
	_core.scan()
	_refresh_status()


## Another device wants to sync. Nothing moves until this is answered, and the
## dialog is the whole point: a scan finds devices, it does not trust them.
func _on_consent_requested(id: String, peer_label: String, address: String) -> void:
	if is_instance_valid(_consent_dialog):
		_consent_dialog.queue_free()
	_consent_dialog = ConfirmationDialog.new()
	_consent_dialog.title = "同步请求"
	_consent_dialog.dialog_text = "%s（%s）请求同步文件。\n同意后，两侧同名文件夹会保持一致。" % [
		peer_label, address
	]
	_consent_dialog.ok_button_text = "同意"
	_consent_dialog.cancel_button_text = "拒绝"
	_consent_dialog.confirmed.connect(_core.answer_consent.bind(true))
	_consent_dialog.canceled.connect(_core.answer_consent.bind(false))
	add_child(_consent_dialog)
	_consent_dialog.popup_centered(Vector2i(360, 150))
	_on_log("%s 请求同步，等待确认" % peer_label)


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
	if is_instance_valid(_log):
		_log.append_text("[color=#9fb0c8]•[/color] %s\n" % text)


func _on_file_synced(path: String, direction: String) -> void:
	_on_log("%s %s" % ["收到" if direction == "in" else "发出", path.get_file()])


func _on_close_pressed() -> void:
	page_closed.emit()
