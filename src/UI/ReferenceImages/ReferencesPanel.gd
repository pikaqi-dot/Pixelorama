class_name ReferencesPanel
extends PanelContainer
## Panel for reference image management

const REFERENCE_IMAGE_BUTTON := preload("res://src/UI/ReferenceImages/ReferenceImageButton.tscn")
## Section and key of the config file entry that remembers the last import folder.
const IMPORT_DIR_SECTION := "reference_images"
const IMPORT_DIR_KEY := "import_dir"

var list_btn_group := ButtonGroup.new()
var transform_button_group: ButtonGroup
var _import_dialog: FileDialog

@onready var list := %List as HFlowContainer
@onready var drag_highlight := $Overlay/DragHighlight as ColorRect
@onready var remove_btn := $ScrollContainer/Container/ReferenceEdit/Remove as Button
@onready var transform_tools_btns := $ScrollContainer/Container/Tools/TransformTools

# these will change their visibility if there are no references
@onready var tip: Label = $ScrollContainer/Container/Tip
@onready var import_tip: Label = $ScrollContainer/Container/Images/ImportTip
@onready var reference_edit: VBoxContainer = $ScrollContainer/Container/ReferenceEdit
@onready var tools: HBoxContainer = $ScrollContainer/Container/Tools


func _ready() -> void:
	Global.project_switched.connect(project_changed)
	OpenSave.reference_image_imported.connect(_on_references_changed)
	transform_button_group = transform_tools_btns.get_child(0).button_group
	transform_button_group.pressed.connect(_on_transform_tool_button_group_pressed)
	list_btn_group.pressed.connect(_on_reference_image_button_pressed)
	Global.canvas.reference_image_container.reference_image_changed.connect(
		_on_reference_image_changed
	)
	# We call this function to update the buttons
	_on_references_changed()
	_update_ui()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		drag_highlight.hide()


func _on_transform_tool_button_group_pressed(button: Button) -> void:
	Global.canvas.reference_image_container.mode = button.get_index()


## Lets the user pick local image files and imports them as reference images.
func _on_ImportButton_pressed() -> void:
	var dialog := _ensure_import_dialog()
	dialog.current_dir = _import_start_dir()
	dialog.popup_centered_ratio(0.7)


func _ensure_import_dialog() -> FileDialog:
	if is_instance_valid(_import_dialog):
		return _import_dialog

	var dialog := FileDialog.new()
	dialog.title = tr("Import Reference Images")
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	# Android's scoped storage hides the shared folders from Godot's own file
	# dialog, so the system picker, which can browse Downloads, is used there.
	dialog.use_native_dialog = Global.use_native_file_dialogs or OS.has_feature("android")
	dialog.add_to_group(&"FileDialogs")
	dialog.filters = _import_filters()
	dialog.files_selected.connect(_on_import_files_selected)
	add_child(dialog)
	_import_dialog = dialog
	return dialog


func _import_filters() -> PackedStringArray:
	var filters := PackedStringArray()
	for extension in Global.SUPPORTED_IMAGE_TYPES:
		filters.append("*.%s;" % extension)
	return filters


func _on_import_files_selected(paths: PackedStringArray) -> void:
	var imported := 0
	for path in paths:
		var image := _load_image_from_path(path)
		if image == null:
			continue
		OpenSave.import_reference_image_from_image(image)
		imported += 1
	if imported == 0:
		Global.popup_error(tr("The selected file(s) could not be imported as images."))
		return
	_remember_import_dir(paths[0])


## Loads a picked file, which may live outside of res:// on Android.
func _load_image_from_path(path: String) -> Image:
	var bytes := FileAccess.get_file_as_bytes(path)
	var image := Image.new()
	if not bytes.is_empty():
		if image.load_png_from_buffer(bytes) == OK:
			return image
		if image.load_jpg_from_buffer(bytes) == OK:
			return image
		if image.load_webp_from_buffer(bytes) == OK:
			return image
		if image.load_bmp_from_buffer(bytes) == OK:
			return image
		if image.load_tga_from_buffer(bytes) == OK:
			return image
		if image.load_svg_from_buffer(bytes) == OK:
			return image
	image = Image.new()
	if image.load(path) == OK:
		return image
	return null


## The folder the dialog starts in: the last one used, else the Desktop on
## desktop platforms and the Downloads folder on Android.
func _import_start_dir() -> String:
	var remembered := str(
		Global.config_cache.get_value(IMPORT_DIR_SECTION, IMPORT_DIR_KEY, "")
	)
	if not remembered.is_empty() and DirAccess.dir_exists_absolute(remembered):
		return remembered
	if OS.has_feature("android"):
		return _android_downloads_dir()
	var desktop := OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	if not desktop.is_empty():
		return desktop
	return OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)


## Android exposes the shared storage at a fixed path; only the folders the app
## is allowed to read are returned, so the picker can start there.
func _android_downloads_dir() -> String:
	var system_dir := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if not system_dir.is_empty() and DirAccess.dir_exists_absolute(system_dir):
		return system_dir
	for candidate in [
		"/storage/emulated/0/Download",
		"/storage/emulated/0/Downloads",
		"/sdcard/Download",
		"/sdcard/Downloads",
	]:
		if DirAccess.dir_exists_absolute(candidate):
			return candidate
	return "/storage/emulated/0/Download"


## Remembers the folder of the picked file for the next time the dialog opens.
func _remember_import_dir(file_path: String) -> void:
	var directory := file_path.get_base_dir()
	if directory.is_empty() or not DirAccess.dir_exists_absolute(directory):
		return
	# The system picker on Android may hand back a temporary copy, which would
	# point at app-private storage instead of the folder the user browsed.
	if directory.begins_with(ProjectSettings.globalize_path("user://")):
		return
	Global.config_cache.set_value(IMPORT_DIR_SECTION, IMPORT_DIR_KEY, directory)
	Global.config_cache.save(Global.CONFIG_PATH)


func _on_move_image_left_pressed() -> void:
	var index: int = Global.current_project.reference_index
	reorder_reference_image(index, index - 1)


func _on_move_image_right_pressed() -> void:
	var index: int = Global.current_project.reference_index
	reorder_reference_image(index, index + 1)


## This method allows you to reoreder reference image with undo redo support
## Please use this and not the method with the same name in project.gd
func reorder_reference_image(from: int, to: int, update_reference_index := true) -> void:
	var project := Global.current_project
	project.undo_redo.create_action("Reorder Reference Image")
	project.undo_redo.add_do_method(project.reorder_reference_image.bind(from, to))
	project.undo_redo.add_do_method(_on_references_changed)
	if update_reference_index:
		project.undo_redo.add_do_method(project.set_reference_image_index.bind(to))
	else:
		project.undo_redo.add_undo_method(
			project.set_reference_image_index.bind(project.reference_index)
		)
	project.undo_redo.add_do_method(_update_ui)

	project.undo_redo.add_undo_method(project.reorder_reference_image.bind(to, from))
	project.undo_redo.add_undo_method(_on_references_changed)
	if update_reference_index:
		project.undo_redo.add_undo_method(project.set_reference_image_index.bind(from))
	else:
		project.undo_redo.add_undo_method(
			project.set_reference_image_index.bind(project.reference_index)
		)

	project.undo_redo.add_undo_method(_update_ui)

	project.undo_redo.commit_action()


func _update_ui() -> void:
	var index: int = Global.current_project.reference_index

	# Enable the buttons as a default
	%MoveImageRightBtn.disabled = false
	%MoveImageLeftBtn.disabled = false
	reference_edit.visible = true

	if index == -1:
		%MoveImageLeftBtn.disabled = true
		%MoveImageRightBtn.disabled = true
		reference_edit.visible = false
	if index == 0:
		%MoveImageLeftBtn.disabled = true
	if index == Global.current_project.reference_images.size() - 1:
		%MoveImageRightBtn.disabled = true

	if %MoveImageLeftBtn.disabled:
		%MoveImageLeftBtn.mouse_default_cursor_shape = CURSOR_FORBIDDEN
	else:
		%MoveImageLeftBtn.mouse_default_cursor_shape = CURSOR_POINTING_HAND

	if %MoveImageRightBtn.disabled:
		%MoveImageRightBtn.mouse_default_cursor_shape = CURSOR_FORBIDDEN
	else:
		%MoveImageRightBtn.mouse_default_cursor_shape = CURSOR_POINTING_HAND

	# Update the remove button
	remove_btn.disabled = index == -1
	if remove_btn.disabled:
		remove_btn.mouse_default_cursor_shape = CURSOR_FORBIDDEN
	else:
		remove_btn.mouse_default_cursor_shape = CURSOR_POINTING_HAND


func _on_reference_image_button_pressed(button: Button) -> void:
	# We subtract 1 because we already have a default button to "select no reference image
	Global.current_project.set_reference_image_index(button.get_index() - 1)


# In case the signal is emitted for another node and not from a pressed button
func _on_reference_image_changed(index: int) -> void:
	_update_ui()
	# Update the buttons to show which one is pressed
	if list_btn_group.get_buttons().size() > 0:
		# First we loop through the buttons to "unpress them all"
		for b: Button in list_btn_group.get_buttons():
			b.set_pressed_no_signal(false)
		# Then we get the wanted button and we press it
		# NOTE: using list_btn_group.get_buttons()[index + 1] here was causing a bug that
		# if you re-arrange by drag and drop, then click on a button, then button before it
		# becomes selected instead of the clicked button
		if index + 1 < list.get_child_count():
			list.get_child(index + 1).set_pressed_no_signal(true)


func project_changed() -> void:
	var project_reference_index := Global.current_project.reference_index
	_on_references_changed()
	_update_ui()
	Global.current_project.set_reference_image_index(project_reference_index)


func _on_references_changed() -> void:
	# When we change the project we set the default
	Global.current_project.set_reference_image_index(-1)

	for c in list.get_children():
		if c is Button:
			c.button_group = null
		c.queue_free()

	# The default button
	var default := REFERENCE_IMAGE_BUTTON.instantiate()
	default.references_panel = self
	default.button_group = list_btn_group
	default.text = "None"
	default.get_child(0).visible = false  # Hide it's transparent checker
	default.button_pressed = true
	list.add_child(default)

	# if there are no references, hide the none button and show message
	tools.visible = true
	tip.visible = true
	import_tip.visible = false
	reference_edit.visible = true
	if Global.current_project.reference_images.size() == 0:
		default.visible = false
		tip.visible = false
		import_tip.visible = true
		reference_edit.visible = false

	# And update.
	for ref in Global.current_project.reference_images:
		var l: Button = REFERENCE_IMAGE_BUTTON.instantiate()
		l.references_panel = self
		l.button_group = list_btn_group
		if ref.texture:
			l.icon = ref.texture
		list.add_child(l)
