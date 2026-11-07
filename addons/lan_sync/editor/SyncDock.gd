@tool
extends VBoxContainer
## Dock of the editor side: the folders this project shares, the peers found on
## the network, and a log of what moved. Everything that talks to the network
## lives in the core, so the dock is only a view of it.

const CoreScript := preload("res://addons/lan_sync/core/LanSyncCore.gd")
const LogStyle := preload("res://addons/lan_sync/ui/log_style.gd")
## Folder shared out of the box. Both sides default to the same name, so a fresh
## install on either end lines up without any setup at all.
const DEFAULT_NAME := "shared"
## The editor side puts it inside the project: the files are then real project
## files, visible in the FileSystem dock and in the project's own history.
const DEFAULT_DIR := "res://lan_shared"
## Where the in-app page puts the same folder — it has no project to write into.
## Only used to recognise a config the game wrote first, because the two sides
## share one config file on a desktop.
const PAGE_DIR := "user://lan_shared"
## After a file lands, the editor needs a moment before a scan picks it up.
const RESCAN_DELAY := 0.5

var _core: Node
var _folders: ItemList
var _peers: ItemList
var _remote_files: ItemList
var _log: RichTextLabel
var _status: Label
var _endpoint_edit: LineEdit
var _name_edit: LineEdit
var _path_edit: LineEdit
var _address_edit: LineEdit
var _start_button: Button
var _browse_dialog: EditorFileDialog
## The bar between the controls and the log, so the log can be given as much room
## as the dock has.
var _split: VSplitContainer
var _split_placed := false
## The bar between the file list and the log.
var _bottom: HSplitContainer
var _bottom_placed := false
var _rescan_left := 0.0


func _ready() -> void:
	_build()
	_core = CoreScript.new()
	_core.name = "LanSyncCore"
	_core.log_line.connect(_on_log)
	_core.peers_changed.connect(_refresh_peers)
	_core.file_synced.connect(_on_file_synced)
	_core.peer_files_changed.connect(_refresh_remote_files)
	add_child(_core)
	# Always checked, not only when there is nothing yet: the default folder is
	# also where a project expects its synced files, so a mapping left behind by
	# a run of the game itself is corrected instead of trusted.
	_ensure_default_folder()
	_refresh_folders()
	_refresh_peers()
	_refresh_remote_files()
	_refresh_status()
	_on_log("本机网卡：%s" % str(_core.local_details()))
	_on_log("文件夹名两侧要一致；默认都是 %s" % DEFAULT_NAME)


func _process(delta: float) -> void:
	# The dock has no size until the editor lays it out, so the divider is placed
	# the first frame that size is known: the log gets the bottom 40 percent.
	if not _split_placed and _split != null and _split.size.y > 60.0:
		_split_placed = true
		_split.split_offset = maxi(80, int(_split.size.y * 0.6))
	# Same for the bar between the files and the log: half each until dragged.
	if not _bottom_placed and _bottom != null and _bottom.size.x > 60.0:
		_bottom_placed = true
		_bottom.split_offset = maxi(60, int(_bottom.size.x * 0.5))
	if _rescan_left <= 0.0:
		return
	_rescan_left -= delta
	if _rescan_left <= 0.0:
		var filesystem := EditorInterface.get_resource_filesystem()
		if filesystem != null:
			filesystem.scan()


func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Two halves with a bar between them, and the bar can be dragged. A dock is
	# tall and narrow, and letting the controls above decide the log's height is
	# what flattened it: here the controls scroll, so the log keeps its share.
	_split = VSplitContainer.new()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_split)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_split.add_child(scroll)

	var controls := VBoxContainer.new()
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.size_flags_vertical = Control.SIZE_EXPAND_FILL
	controls.add_theme_constant_override("separation", 4)
	scroll.add_child(controls)

	var title := Label.new()
	title.text = "局域网同步"
	title.add_theme_font_size_override("font_size", 15)
	controls.add_child(title)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls.add_child(_status)

	# The address this machine answers on, on its own row: it is the one string
	# somebody types into the other device, so it must be copyable and present
	# before anything is started.
	controls.add_child(_heading("本机地址（填到对方）"))
	var endpoint_row := HBoxContainer.new()
	_endpoint_edit = LineEdit.new()
	_endpoint_edit.editable = false
	_endpoint_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	endpoint_row.add_child(_endpoint_edit)
	var copy_button := Button.new()
	copy_button.text = "复制"
	copy_button.pressed.connect(_on_copy_endpoint)
	endpoint_row.add_child(copy_button)
	controls.add_child(endpoint_row)

	controls.add_child(_heading("同步文件夹"))
	_folders = ItemList.new()
	_folders.custom_minimum_size = Vector2(0, 70)
	controls.add_child(_folders)
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
	controls.add_child(add_row)

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
	sync_button.text = "同步"
	sync_button.tooltip_text = "把对方的文件拉过来；修改时间相同的文件不会覆盖"
	sync_button.pressed.connect(_on_sync_now_pressed)
	run_row.add_child(sync_button)
	var connect_button := Button.new()
	connect_button.text = "按地址连接"
	connect_button.pressed.connect(_on_connect_pressed)
	run_row.add_child(connect_button)
	controls.add_child(run_row)

	_address_edit = LineEdit.new()
	_address_edit.placeholder_text = "地址 例 192.168.1.20:45990"
	controls.add_child(_address_edit)

	controls.add_child(_heading("附近设备"))
	_peers = ItemList.new()
	_peers.custom_minimum_size = Vector2(0, 50)
	controls.add_child(_peers)

	# The other side's files and the log sit side by side, the way the in-app page
	# has them: both are read while a sync runs, and stacking them in a narrow dock
	# only ever gave one of them a usable height. The bar between them drags.
	_bottom = HSplitContainer.new()
	_bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bottom.custom_minimum_size = Vector2(0, 150)
	_split.add_child(_bottom)

	# What the other side is offering, before anything is taken.
	var files_box := VBoxContainer.new()
	files_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	files_box.add_theme_constant_override("separation", 2)
	_bottom.add_child(files_box)
	var files_title := _heading("对方的文件")
	files_title.tooltip_text = "双击一行只同步这一个"
	files_box.add_child(files_title)
	_remote_files = ItemList.new()
	_remote_files.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_remote_files.custom_minimum_size = Vector2(0, 90)
	_remote_files.item_activated.connect(_on_remote_file_activated)
	files_box.add_child(_remote_files)

	var log_box := VBoxContainer.new()
	log_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_box.add_theme_constant_override("separation", 2)
	_bottom.add_child(log_box)

	var log_head := HBoxContainer.new()
	log_head.add_theme_constant_override("separation", 4)
	log_box.add_child(log_head)
	var log_title := _heading("日志")
	log_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	log_head.add_child(log_title)
	var clear_button := Button.new()
	clear_button.text = "清空"
	clear_button.tooltip_text = "清掉日志窗口里的内容，不影响同步"
	clear_button.pressed.connect(_on_clear_log)
	log_head.add_child(clear_button)

	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 90)
	_log.scroll_following = true
	log_box.add_child(_log)


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.68, 0.72, 0.8))
	return label


func _ensure_default_folder() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DEFAULT_DIR))
	var current := str(_core.folders.get(DEFAULT_NAME, ""))
	if current == DEFAULT_DIR:
		return
	if current.is_empty():
		_core.set_folder(DEFAULT_NAME, DEFAULT_DIR)
		_on_log("%s → %s（编辑器版默认放项目里）" % [DEFAULT_NAME, DEFAULT_DIR])
		return
	# The two sides share one config file on a desktop, so `shared` can be left
	# pointing at whatever the game — or an earlier setup — wrote: the page's own
	# `user://` default, or a folder that no longer exists. The dock is the editor,
	# so a mapping that leads nowhere goes back inside the project, where the
	# FileSystem dock shows it and where the project's own files live. A mapping
	# the person made on purpose, to a folder that is still there, is left alone.
	var page_default := ProjectSettings.globalize_path(PAGE_DIR)
	if current == page_default:
		_remap_default_folder(PAGE_DIR)
		return
	if not DirAccess.dir_exists_absolute(LanSyncCore.real_path(current)):
		_remap_default_folder(current)


## Points `shared` back at the project folder and says where it came from.
func _remap_default_folder(was: String) -> void:
	_core.set_folder(DEFAULT_NAME, DEFAULT_DIR)
	_on_log("同步文件夹 %s：%s → %s（编辑器版默认放项目里）" % [
		DEFAULT_NAME, was, DEFAULT_DIR
	])


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


func _refresh_remote_files() -> void:
	if not is_instance_valid(_remote_files):
		return
	_remote_files.clear()
	if _core.peer_entries.is_empty():
		# Which of the three it is decides what to do about it, so the box says it
		# instead of one sentence covering all of them.
		_remote_files.add_item(_empty_remote_text())
		_remote_files.set_item_disabled(0, true)
		return
	for entry: Dictionary in _core.peer_entries:
		_remote_files.add_item(
			"%s · %s" % [str(entry.get("key", "")), _mtime_text(int(entry.get("mtime", 0)))]
		)


## Why the other side's list is empty: no link, a link still waiting for the list
## to come back, or a link that answered with nothing.
func _empty_remote_text() -> String:
	if _core == null or _core.get("_peer") == null:
		return "（还没连上对方）"
	if bool(_core.get("_awaiting_manifest")):
		return "（已连上，正在等对方回文件清单…）"
	return "（对方的共享目录里没有文件）"


## A modification time as it reads in a file manager.
func _mtime_text(mtime: int) -> String:
	if mtime <= 0:
		return "时间未知"
	var when := Time.get_datetime_dict_from_unix_time(mtime)
	return "%02d-%02d %02d:%02d:%02d" % [
		int(when["month"]),
		int(when["day"]),
		int(when["hour"]),
		int(when["minute"]),
		int(when["second"]),
	]


## Double-clicking one row takes that file and nothing else, so a single stale
## project can be replaced without touching the rest of the folder.
func _on_remote_file_activated(index: int) -> void:
	if index < 0 or index >= _core.peer_entries.size():
		return
	var key := str(_core.peer_entries[index].get("key", ""))
	if key.is_empty():
		return
	_core.call("request_file", key)
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
		# The shared folder itself is `res://lan_shared`; anything else gets a
		# folder of its own name next to it, so one .pxo project can hold several.
		path = DEFAULT_DIR if folder_name == DEFAULT_NAME else DEFAULT_DIR.path_join(folder_name)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
	# The project path is what gets stored, so the panel reads "shared →
	# res://lan_shared" and the files stay where the project can see them.
	_core.set_folder(folder_name, path)
	_name_edit.clear()
	_path_edit.clear()
	_refresh_folders()
	_refresh_status()
	_on_log("已添加 %s → %s" % [folder_name, path])


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
	LogStyle.append_to(_log, text)


func _on_clear_log() -> void:
	LogStyle.clear(_log)


func _on_file_synced(path: String, direction: String) -> void:
	_rescan_left = RESCAN_DELAY
	_refresh_folders()
	_on_log("%s %s" % ["收到" if direction == "in" else "发出", path.get_file()])
