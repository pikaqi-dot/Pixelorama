extends Control
## Page of the drawing tabs that trades files with the Godot editor over the
## local network. It is the same engine the editor dock runs, so the folders are
## matched by name and neither side has to be told an address: the peers find
## each other by beacon and connect by themselves.

signal page_closed()

const CoreScript := preload("res://addons/lan_sync/core/LanSyncCore.gd")
const LogStyle := preload("res://addons/lan_sync/ui/log_style.gd")
const FileMarks := preload("res://addons/lan_sync/ui/file_marks.gd")
## Folder shared out of the box, named the same way the editor dock names its
## own, so a fresh build and a fresh dock line up with no setup at all.
const DEFAULT_NAME := "shared"
const DEFAULT_FOLDER := "user://lan_shared"
## Sub-folder of the system Downloads directory used on a phone.
const DOWNLOADS_SUBDIR := "Pixelorama"
## Sized for a phone in landscape: every row that is not the log is a row the
## log does not get, so the controls are deliberately short and tight.
const ROW_HEIGHT := 34
const MARGIN := 8
const SEPARATION := 5

var _core: Node
var _folders: ItemList
var _peers: ItemList
var _remote_files: ItemList
## What the file list is showing, so a double-click knows which row it was: the
## other side's copies, this side's own, and which of them is newer.
var _rows: Array[Dictionary] = []
var _log: RichTextLabel
var _status: Label
var _endpoint_edit: LineEdit
var _name_edit: LineEdit
var _path_edit: LineEdit
var _address_edit: LineEdit
var _start_button: Button
var _browse_dialog: FileDialog
## Folder management is a one-time chore, so it lives behind a toggle instead of
## taking four rows away from the log on every visit.
var _folder_box: VBoxContainer
var _folder_toggle: CheckButton


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if OS.get_name() == "Android":
		# Ask for the storage permissions the manifest declares. On Android 11+ the
		# all-files access cannot be requested this way and has to be granted in
		# system settings, which the log says when a folder lists nothing.
		OS.request_permissions()
	_build()
	_core = CoreScript.new()
	_core.name = "LanSyncCore"
	_core.log_line.connect(_on_log)
	_core.peers_changed.connect(_refresh_peers)
	_core.file_synced.connect(_on_file_synced)
	_core.peer_files_changed.connect(_refresh_remote_files)
	add_child(_core)
	if _core.folders.is_empty():
		var absolute := ProjectSettings.globalize_path(default_shared_root())
		absolute = absolute.path_join(DEFAULT_NAME)
		DirAccess.make_dir_recursive_absolute(absolute)
		_core.set_folder(DEFAULT_NAME, absolute)
	else:
		_migrate_private_folders()
	_refresh_folders()
	_refresh_peers()
	_refresh_remote_files()
	_refresh_status()
	# The Wi-Fi address changes when the phone reconnects, and the whole point of
	# the line is that it can be read out at the moment it is needed.
	var refresh := Timer.new()
	refresh.wait_time = 2.0
	refresh.autostart = true
	refresh.timeout.connect(_refresh_status)
	add_child(refresh)
	_on_log("本机网卡：%s" % str(_core.local_details()))
	_on_log("文件夹名两侧要一致；默认都是 %s" % DEFAULT_NAME)


## Where a new folder is created by default.
##
## On a phone the whole point is usually to get files out of the application, and
## its private directory is invisible to every file manager and gallery, so the
## system Downloads folder is used there — but only when it can really be written
## to, because storage scoping refuses it on some devices and a shared folder
## nobody can write to would be worse than a private one that works. The two
## arguments exist so the phone branch can be exercised from a desktop.
func default_shared_root(platform: String = "", downloads_dir: String = "") -> String:
	var system := platform if not platform.is_empty() else OS.get_name()
	if system != "Android":
		return DEFAULT_FOLDER
	var downloads := downloads_dir
	if downloads.is_empty():
		downloads = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if downloads.is_empty():
		return DEFAULT_FOLDER
	var candidate := downloads.path_join(DOWNLOADS_SUBDIR)
	if _writable(candidate):
		return candidate
	return DEFAULT_FOLDER


## Whether a directory can be created and a file dropped in it. Asked rather than
## assumed: on Android the answer depends on the storage scope, not on the path
## looking right.
func _writable(dir: String) -> bool:
	DirAccess.make_dir_recursive_absolute(dir)
	if not DirAccess.dir_exists_absolute(dir):
		return false
	var probe := dir.path_join(".lan_sync_write_probe")
	var file := FileAccess.open(probe, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string("ok")
	file.close()
	DirAccess.remove_absolute(probe)
	return true


## A phone built before the Downloads default keeps its folder inside the app's
## private directory, where nothing can see the files that arrive. Those entries
## are moved once, files and all, so an update does not quietly change where
## things live without saying so.
func _migrate_private_folders(platform: String = "", downloads_dir: String = "") -> void:
	var system := platform if not platform.is_empty() else OS.get_name()
	if system != "Android":
		return
	var private_root := ProjectSettings.globalize_path(DEFAULT_FOLDER)
	var root := ProjectSettings.globalize_path(default_shared_root(platform, downloads_dir))
	if root == private_root:
		return
	for folder_name: String in _core.folders.keys():
		var current := str(_core.folders[folder_name])
		if not current.begins_with(private_root):
			continue
		var target := root.path_join(folder_name)
		DirAccess.make_dir_recursive_absolute(target)
		_copy_tree(current, target)
		_core.set_folder(folder_name, target)
		_on_log("%s 已移到 %s" % [folder_name, target])


## Copies what the old folder held, without overwriting anything already there:
## which copy is newer is the sync's decision, not a migration's.
func _copy_tree(from_dir: String, to_dir: String) -> void:
	var directory := DirAccess.open(from_dir)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if not entry.begins_with("."):
			var source := from_dir.path_join(entry)
			var target := to_dir.path_join(entry)
			if directory.current_is_dir():
				DirAccess.make_dir_recursive_absolute(target)
				_copy_tree(source, target)
			elif not FileAccess.file_exists(target):
				DirAccess.copy_absolute(source, target)
		entry = directory.get_next()
	directory.list_dir_end()


func is_open() -> bool:
	return visible


func open_page() -> void:
	visible = true
	_refresh_status()


func pause_page() -> void:
	# Hidden, not merely idle. A page left visible while another tab is in front
	# sits on top of the canvas and takes its clicks, which is exactly how it
	# looked on the phone: the drawing tab seemed broken under a panel that was
	# supposed to be gone. The sync engine is a child node and keeps running.
	visible = false
	set_process(false)


func resume_page() -> void:
	visible = true
	set_process(true)
	_refresh_status()


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", MARGIN)
	margin.add_theme_constant_override("margin_top", MARGIN)
	margin.add_theme_constant_override("margin_right", MARGIN)
	margin.add_theme_constant_override("margin_bottom", MARGIN)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", SEPARATION)
	margin.add_child(column)

	# No page title: the tab already says 同步, and a title row costs the log a
	# whole line on a phone.
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 12)
	column.add_child(_status)

	# Address and copy share one row. It is still selectable and still there
	# before anything is started, it just no longer owns a heading and a row of
	# its own.
	var endpoint_row := HBoxContainer.new()
	endpoint_row.add_theme_constant_override("separation", SEPARATION)
	column.add_child(endpoint_row)
	endpoint_row.add_child(_heading("本机地址"))
	_endpoint_edit = LineEdit.new()
	_endpoint_edit.editable = false
	_endpoint_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_endpoint_edit.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	endpoint_row.add_child(_endpoint_edit)
	endpoint_row.add_child(_button("复制", _on_copy_endpoint))

	var run_row := HBoxContainer.new()
	run_row.add_theme_constant_override("separation", SEPARATION)
	column.add_child(run_row)
	_start_button = _button("开始", _on_start_pressed)
	run_row.add_child(_start_button)
	run_row.add_child(_button("扫描", _on_scan_pressed))
	# Which way the files go is the one thing about this button that is easy to
	# get wrong, so it is written down — in the tooltip, where it costs no row.
	var sync_button := _button("同步", _on_sync_now_pressed)
	sync_button.tooltip_text = "把对方的文件拉过来；修改时间相同的文件不会覆盖"
	run_row.add_child(sync_button)

	_folder_toggle = CheckButton.new()
	_folder_toggle.text = "文件夹与地址"
	_folder_toggle.add_theme_font_size_override("font_size", 12)
	_folder_toggle.custom_minimum_size = Vector2(0, 26)
	_folder_toggle.toggled.connect(_on_folder_toggle)
	column.add_child(_folder_toggle)

	_folder_box = VBoxContainer.new()
	_folder_box.add_theme_constant_override("separation", SEPARATION)
	_folder_box.visible = false
	column.add_child(_folder_box)
	_folders = ItemList.new()
	_folders.custom_minimum_size = Vector2(0, 56)
	_folder_box.add_child(_folders)
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", SEPARATION)
	_folder_box.add_child(add_row)
	_name_edit = _line_edit("名称（留空取目录名）")
	_name_edit.custom_minimum_size = Vector2(96, ROW_HEIGHT)
	add_row.add_child(_name_edit)
	_path_edit = _line_edit("留空则用默认目录")
	add_row.add_child(_path_edit)
	var folder_row := HBoxContainer.new()
	folder_row.add_theme_constant_override("separation", SEPARATION)
	_folder_box.add_child(folder_row)
	folder_row.add_child(_button("浏览", _on_browse_folder))
	folder_row.add_child(_button("添加", _on_add_folder))
	folder_row.add_child(_button("移到下载目录", _on_use_downloads))
	folder_row.add_child(_button("移除选中", _on_remove_folder))
	# Connecting by hand is a fallback that is reached for rarely, so it belongs
	# with the rest of the setup rather than in the row of everyday buttons.
	var address_row := HBoxContainer.new()
	address_row.add_theme_constant_override("separation", SEPARATION)
	_folder_box.add_child(address_row)
	_address_edit = _line_edit("地址 例 192.168.1.20:45990")
	address_row.add_child(_address_edit)
	address_row.add_child(_button("按地址连接", _on_connect_pressed))

	column.add_child(_heading("附近设备"))
	_peers = ItemList.new()
	_peers.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_peers.custom_minimum_size = Vector2(0, 44)
	column.add_child(_peers)

	# The other side's files and the log sit side by side. Both are read, both
	# want height, and stacking them only ever gave one of them a usable share.
	var panels := HBoxContainer.new()
	panels.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panels.add_theme_constant_override("separation", SEPARATION * 2)
	column.add_child(panels)

	var files_panel := VBoxContainer.new()
	files_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	files_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	files_panel.add_theme_constant_override("separation", SEPARATION)
	panels.add_child(files_panel)
	# Both sides, marked: a pull is a decision, and a decision needs to see which
	# copy is the newer one before it is made.
	var files_head := HBoxContainer.new()
	files_head.add_theme_constant_override("separation", SEPARATION)
	files_panel.add_child(files_head)
	var files_title := _heading("两边的文件")
	files_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	files_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	files_title.tooltip_text = FileMarks.LEGEND + "\n双击一行只同步这一个"
	files_head.add_child(files_title)
	# Reads both halves of the marks again and transfers nothing, so it is always
	# safe to press — the phone equivalent of "did it really update?".
	var refresh_button := _button("刷新", _on_refresh_files)
	refresh_button.tooltip_text = "重读本机文件时间戳，并向对方要一次最新清单"
	files_head.add_child(refresh_button)
	_remote_files = ItemList.new()
	_remote_files.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_remote_files.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_remote_files.custom_minimum_size = Vector2(0, 96)
	_remote_files.item_activated.connect(_on_remote_file_activated)
	files_panel.add_child(_remote_files)

	var log_panel := VBoxContainer.new()
	log_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_panel.add_theme_constant_override("separation", SEPARATION)
	panels.add_child(log_panel)
	var log_head := HBoxContainer.new()
	log_head.add_theme_constant_override("separation", SEPARATION)
	log_panel.add_child(log_head)
	var log_title := _heading("日志")
	log_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_head.add_child(log_title)
	log_head.add_child(_button("清空", _on_clear_log))
	_log = RichTextLabel.new()
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 96)
	_log.scroll_following = true
	_log.add_theme_font_size_override("normal_font_size", 11)
	log_panel.add_child(_log)

	column.add_child(_button("返回绘画", _on_close_pressed))


func _on_folder_toggle(pressed: bool) -> void:
	_folder_box.visible = pressed


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
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
		var path := str(_core.folders[folder_name])
		# The count is the answer to the first question anybody asks when nothing
		# moves: is there anything in there at all?
		_folders.add_item("%s → %s（%d 个文件）" % [folder_name, path, int(_core.call("count_files", path))])
	# The toggle carries the count so the collapsed state is still informative.
	if is_instance_valid(_folder_toggle):
		_folder_toggle.text = "文件夹与地址 · %d 个" % _core.folders.size()


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
	# Both sides, each row marked: same time, one side newer, or missing over
	# there. The comparing happens in the core, so the phone and the editor dock
	# cannot show different marks for the same folder.
	_rows = _core.call("compare_entries")
	if _rows.is_empty():
		# Which of the three it is decides what to do about it, so the box says it
		# instead of one sentence covering all of them.
		_remote_files.add_item(_empty_remote_text())
		_remote_files.set_item_disabled(0, true)
		return
	for index in _rows.size():
		var row: Dictionary = _rows[index]
		# The mark and the colour carry the whole message; the timestamp next to
		# them is what a person checks before deciding.
		_remote_files.add_item(FileMarks.text(row))
		_remote_files.set_item_custom_fg_color(index, FileMarks.color(int(row["state"])))
		_remote_files.set_item_tooltip(index, FileMarks.tooltip(row))


## Why the other side's list is empty: no link, a link still waiting for the list
## to come back, or a link that answered with nothing.
func _empty_remote_text() -> String:
	if _core == null or _core.get("_peer") == null:
		return "（还没连上对方）"
	if bool(_core.get("_awaiting_manifest")):
		return "（已连上，正在等对方回文件清单…）"
	return "（对方的共享目录里没有文件）"


## The 「刷新」 button: both halves of the marks are read again.
func _on_refresh_files() -> void:
	if _core == null or not _core.has_method("refresh_file_list"):
		_on_log("刷新不可用：同步核心还没准备好")
		return
	_core.call("refresh_file_list")
	_refresh_remote_files()


## One row was double-clicked: take that file and nothing else. A whole-folder
## sync is the button; this is for replacing the one project or image that is
## out of date without disturbing the rest. A row the other side does not have
## cannot be pulled, and says so instead of asking for a file that is not there.
func _on_remote_file_activated(index: int) -> void:
	if index < 0 or index >= _rows.size():
		return
	var row: Dictionary = _rows[index]
	var key := str(row.get("key", ""))
	if key.is_empty():
		return
	if int(row.get("state", 0)) == LanSyncCore.FileState.LOCAL_ONLY:
		_on_log("对方没有 %s，没法从这里拉；要给它，就在它那边点「同步」" % key)
		return
	_core.call("request_file", key)
	_refresh_status()


func _refresh_status() -> void:
	if _core == null or not visible:
		return
	if _core.running:
		# The link state first: "nearby 1" and "connected" are different things and
		# only this line tells them apart.
		_status.text = "%s\n文件夹 %d 个 · 已发 %d / 已收 %d" % [
			str(_core.call("link_text")),
			_core.folders.size(),
			int(_core.get("sent_files")),
			int(_core.get("received_files")),
		]
	else:
		_status.text = "未开始 · 点「开始」后会自动发现并连接同一局域网里的另一侧"
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


## Adding a folder should be one action. The name falls back to the directory's own
## name and the path to the shared area, so picking a directory and pressing 添加
## is enough — typing an absolute path on a phone keyboard is not a setup step
## anybody should have to perform.
func _on_add_folder() -> void:
	var folder_name := _name_edit.text.strip_edges()
	var path := _path_edit.text.strip_edges()
	if folder_name.is_empty():
		folder_name = _name_from_path(path)
	if folder_name.is_empty():
		_on_log("先点「浏览」选一个目录，或在「名称」里起个名字")
		return
	if path.is_empty():
		path = ProjectSettings.globalize_path(default_shared_root()).path_join(folder_name)
	DirAccess.make_dir_recursive_absolute(path)
	_core.set_folder(folder_name, path)
	_name_edit.clear()
	_path_edit.clear()
	_refresh_folders()
	_refresh_status()
	_on_log("已添加 %s → %s" % [folder_name, path])


func _on_browse_folder() -> void:
	if is_instance_valid(_browse_dialog):
		_browse_dialog.queue_free()
	_browse_dialog = FileDialog.new()
	_browse_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_browse_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_browse_dialog.title = "选择要同步的目录"
	# The built-in dialog rather than the platform one: on Android the native
	# picker only reaches the folders the system grants, while this one can at
	# least always show the app's own directory where the default shared folder
	# lives.
	_browse_dialog.current_dir = ProjectSettings.globalize_path(default_shared_root())
	_browse_dialog.dir_selected.connect(_on_folder_picked)
	add_child(_browse_dialog)
	_browse_dialog.popup_centered(Vector2i(int(size.x * 0.92), int(size.y * 0.85)))


func _on_folder_picked(path: String) -> void:
	_path_edit.text = path
	if _name_edit.text.strip_edges().is_empty():
		_name_edit.text = _name_from_path(path)


## The last segment of a path, which is the folder name on both sides.
func _name_from_path(path: String) -> String:
	return path.replace("\\", "/").trim_suffix("/").get_file()


## The folder operation a phone makes people want: move a shared folder somewhere
## a file manager and a gallery can actually see, without typing a path.
func _on_use_downloads() -> void:
	var selected := _folders.get_selected_items()
	var names: Array = _core.folders.keys()
	if selected.is_empty() or int(selected[0]) >= names.size():
		_on_log("先在列表里选中一个文件夹")
		return
	var folder_name := str(names[int(selected[0])])
	var root := ProjectSettings.globalize_path(default_shared_root())
	if root == ProjectSettings.globalize_path(DEFAULT_FOLDER):
		_on_log("这台设备没有可写的下载目录，文件留在 %s" % root)
		return
	var target := root.path_join(folder_name)
	if str(_core.folders[folder_name]) == target:
		_on_log("%s 已经在下载目录里了" % folder_name)
		return
	DirAccess.make_dir_recursive_absolute(target)
	_copy_tree(str(_core.folders[folder_name]), target)
	_core.set_folder(folder_name, target)
	_refresh_folders()
	_on_log("%s → %s" % [folder_name, target])


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


func _on_sync_now_pressed() -> void:
	_core.call("request_sync_now")
	_refresh_status()


func _on_connect_pressed() -> void:
	var text := _address_edit.text.strip_edges()
	if text.is_empty():
		# Silent failure reads as "the button does nothing"; the address field
		# lives in the collapsed setup now, so say where to type it.
		_on_log("先在「文件夹与地址」里填对方的地址，例如 192.168.1.20:45990")
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
	_on_log("%s %s" % ["收到" if direction == "in" else "发出", path.get_file()])
	_refresh_folders()
	# The marks are one file out of date from here on unless the list is rebuilt:
	# what just arrived is no longer "missing here", and what just left is no
	# longer "missing over there".
	_refresh_remote_files()


func _on_close_pressed() -> void:
	page_closed.emit()
