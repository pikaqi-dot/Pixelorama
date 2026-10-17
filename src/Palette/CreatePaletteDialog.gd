extends ConfirmationDialog

const LospecBrowserScript := preload("res://src/Palette/LospecPaletteBrowser.gd")

## Emitted when user confirms their changes
signal saved(
	preset,
	name,
	comment,
	width,
	height,
	add_alpha_colors,
	colors_from,
	is_global,
	lospec_colors: PackedColorArray
)

enum { GLOBAL_PALETTE, PROJECT_PALETTE }

## Reference to current palette stored when dialog opens
var current_palette: Palette
## Colors downloaded from Lospec, used by the FROM_LOSPEC preset
var lospec_colors := PackedColorArray()

@onready var preset_input := $VBoxContainer/PaletteMetadata/Preset as OptionButton
@onready var name_input := $VBoxContainer/PaletteMetadata/Name as LineEdit
@onready var comment_input := $VBoxContainer/PaletteMetadata/Comment as TextEdit
@onready var width_input := $VBoxContainer/PaletteMetadata/Width as SpinBox
@onready var height_input := $VBoxContainer/PaletteMetadata/Height as SpinBox
@onready var alpha_colors_input := $VBoxContainer/ColorsSettings/AddAlphaColors as CheckBox
@onready var get_colors_from_input := (
	$VBoxContainer/ColorsSettings/GetColorsFrom/GetColorsFrom as OptionButton
)

@onready var colors_settings := $VBoxContainer/ColorsSettings as VBoxContainer
@onready var already_exists_warning := $VBoxContainer/AlreadyExistsWarning as Label
@onready var enter_name_warning := $VBoxContainer/EnterNameWarning as Label
@onready var palette_type_option := $VBoxContainer/PaletteMetadata/PaletteTypeOption as OptionButton
@onready var dialog_vbox := $VBoxContainer as VBoxContainer

var lospec_browser


func _ready() -> void:
	palette_type_option.add_item("Global Palette", GLOBAL_PALETTE)
	palette_type_option.add_item("Project Palette", PROJECT_PALETTE)

	# The Lospec browser is hidden unless the "From Lospec" preset is selected
	lospec_browser = LospecBrowserScript.new()
	lospec_browser.name = "LospecBrowser"
	dialog_vbox.add_child(lospec_browser)
	dialog_vbox.move_child(lospec_browser, colors_settings.get_index() + 1)
	lospec_browser.hide()
	lospec_browser.palette_selected.connect(_on_lospec_palette_selected)


## Opens dialog
func open(opened_current_palette: Palette) -> void:
	# Only to fill dialog when preset is FROM_CURRENT_PALETTE
	current_palette = opened_current_palette

	lospec_colors.clear()
	if is_instance_valid(lospec_browser):
		lospec_browser.hide()

	set_default_values()
	preset_input.selected = Palettes.NewPalettePresetType.EMPTY
	# Colors settings are only available for FROM_CURRENT_SPRITE and FROM_CURRENT_SELECTION presets
	colors_settings.hide()

	# Hide warning
	toggle_already_exists_warning(false)

	# Disable ok button until user enters name
	toggle_ok_button_disability(true)

	# Disable create "From Current Palette" if there's no palette
	preset_input.set_item_disabled(1, !current_palette)

	# Stop all inputs in the rest of the app
	Global.dialog_open(true)
	popup_centered_clamped()
	width_input.editable = true
	height_input.editable = true


## Resets all dialog values to default
func set_default_values() -> void:
	name_input.text = ""
	comment_input.text = ""
	width_input.value = Palette.DEFAULT_WIDTH
	height_input.value = Palette.DEFAULT_HEIGHT
	alpha_colors_input.button_pressed = true
	get_colors_from_input.selected = Palettes.GetColorsFrom.CURRENT_FRAME
	palette_type_option.set_item_disabled(GLOBAL_PALETTE, Global.global_palettes_readonly)
	if Global.global_palettes_readonly:
		palette_type_option.select(palette_type_option.get_item_index(PROJECT_PALETTE))


## Shows/hides a warning when palette already exists
func toggle_already_exists_warning(to_show: bool) -> void:
	already_exists_warning.visible = to_show

	# Required to resize window to correct size if warning causes content overflow
	size = size


func toggle_ok_button_disability(disable: bool) -> void:
	get_ok_button().disabled = disable
	enter_name_warning.visible = disable


func _on_CreatePaletteDialog_visibility_changed() -> void:
	Global.dialog_open(visible)


func _on_CreatePaletteDialog_confirmed() -> void:
	saved.emit(
		preset_input.selected,
		name_input.text,
		comment_input.text,
		width_input.value,
		height_input.value,
		alpha_colors_input.button_pressed,
		get_colors_from_input.selected,
		true if palette_type_option.selected == GLOBAL_PALETTE else false,
		lospec_colors
	)


func _on_Preset_item_selected(index: int) -> void:
	# Enable width and height inputs (can be disabled by current palette preset)
	width_input.editable = true
	height_input.editable = true
	toggle_already_exists_warning(false)
	toggle_ok_button_disability(true)

	lospec_colors.clear()
	lospec_browser.visible = index == Palettes.NewPalettePresetType.FROM_LOSPEC
	if lospec_browser.visible:
		lospec_browser.ensure_loaded()

	match index:
		Palettes.NewPalettePresetType.EMPTY:
			colors_settings.hide()
			set_default_values()
		Palettes.NewPalettePresetType.FROM_CURRENT_PALETTE:
			colors_settings.hide()
			# If any palette was selected, copy its settings to dialog
			if current_palette:
				name_input.text = current_palette.name
				comment_input.text = current_palette.comment
				width_input.value = current_palette.width
				height_input.value = current_palette.height
				toggle_already_exists_warning(true)
				# Copying palette presets grid size
				width_input.editable = false
				height_input.editable = false
		Palettes.NewPalettePresetType.FROM_CURRENT_SPRITE:
			colors_settings.show()
			set_default_values()
		Palettes.NewPalettePresetType.FROM_CURRENT_SELECTION:
			colors_settings.show()
			set_default_values()
		Palettes.NewPalettePresetType.FROM_LOSPEC:
			colors_settings.hide()
			set_default_values()

	# Resize the dialog after showing/hiding the Lospec browser or color settings
	_refresh_dialog_size()


## Fills the dialog metadata with the palette chosen in the Lospec browser
func _on_lospec_palette_selected(palette_data: Dictionary) -> void:
	var colors: Variant = palette_data.get("colors", PackedColorArray())
	if colors is PackedColorArray:
		lospec_colors = colors
	else:
		lospec_colors.clear()

	var palette_title := str(palette_data.get("title", "Lospec Palette"))
	name_input.text = palette_title

	var color_count := lospec_colors.size()
	var palette_width := clampi(color_count, 1, int(width_input.max_value))
	width_input.value = palette_width
	height_input.value = ceili(color_count / float(palette_width))

	var comment := "Imported from Lospec"
	var author := str(palette_data.get("author", ""))
	if not author.is_empty():
		comment += " (by %s)" % author
	var slug := str(palette_data.get("slug", ""))
	if not slug.is_empty():
		comment += "\nhttps://lospec.com/palette-list/" + slug
	comment_input.text = comment

	_on_Name_text_changed(palette_title)


## Resizes and recenters the dialog after a section is shown or hidden.
func _refresh_dialog_size() -> void:
	reset_size()
	popup_centered_clamped()


func _on_Name_text_changed(new_name: String) -> void:
	var disable_warning := false
	if Palettes.does_palette_exist(new_name):
		disable_warning = true

	toggle_already_exists_warning(disable_warning)
	toggle_ok_button_disability(disable_warning)

	# Disable ok button on empty name
	if new_name == "":
		toggle_ok_button_disability(true)
