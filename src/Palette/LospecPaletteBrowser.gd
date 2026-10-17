extends VBoxContainer
## Downloads palette lists, colors and pixel art previews from lospec.com.

## Emitted when the user chooses a palette. The dictionary contains:
## slug, title, author, colors (PackedColorArray), description, tags
signal palette_selected(palette_data: Dictionary)

const LIST_URL := "https://lospec.com/palette-list/load"
const SUGGEST_URL := "https://lospec.com/palette-list/suggest/"
const PALETTE_JSON_URL := "https://lospec.com/palette-list/%s.json"
const PALETTE_PAGE_URL := "https://lospec.com/palette-list/%s"
const CDN_URL := "https://cdn.lospec.com/"
const USER_AGENT := "Pixelorama Lospec Browser"
const SORT_VALUES: Array[String] = ["default", "alphabetical", "downloads", "newest"]
const MAX_PREVIEW_SWATCHES := 40  # Maximum drawn swatches per list item

enum Mode { BROWSE, SEARCH }

var _search_input: LineEdit
var _tag_input: LineEdit
var _sort_option: OptionButton
var _status_label: Label
var _search_button: Button
var _refresh_button: Button
var _load_more_button: Button
var _scroll: ScrollContainer
var _results_box: VBoxContainer

var _list_request: HTTPRequest
var _suggest_request: HTTPRequest

var _mode := Mode.BROWSE
var _is_loading := false
var _requested_page := 0
var _page := 0
var _total_count := 0
var _last_search_query := ""
var _pending_detail_requests := 0
var _detail_buffer: Array[Dictionary] = []


func _ready() -> void:
	custom_minimum_size = Vector2(0, 260)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_ui()

	_list_request = HTTPRequest.new()
	_list_request.timeout = 25.0
	add_child(_list_request)
	_list_request.request_completed.connect(_on_list_request_completed)

	_suggest_request = HTTPRequest.new()
	_suggest_request.timeout = 25.0
	add_child(_suggest_request)
	_suggest_request.request_completed.connect(_on_suggest_request_completed)


## Loads the palette list if it hasn't been loaded yet.
func ensure_loaded() -> void:
	if not is_inside_tree() or _is_loading:
		return
	if _results_box.get_child_count() == 0:
		refresh()


## Reloads the first page of the default palette list.
func refresh() -> void:
	_search_input.text = ""
	_tag_input.text = ""
	_reload_browse()


## Reloads the first page while keeping the current sort/tag filters.
func _reload_browse() -> void:
	_mode = Mode.BROWSE
	_page = 0
	_total_count = 0
	_clear_results()
	_request_page(0)


func _build_ui() -> void:
	var title := Label.new()
	title.text = "Lospec Palette Browser"
	title.add_theme_font_size_override("font_size", 16)
	add_child(title)

	var note := Label.new()
	note.text = "Palette colors and pixel art previews are loaded from lospec.com"
	note.add_theme_color_override("font_color", Color(0.72, 0.72, 0.72))
	add_child(note)

	var search_row := HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 6)
	add_child(search_row)

	_search_input = LineEdit.new()
	_search_input.placeholder_text = "Search palettes by name..."
	_search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_input.text_submitted.connect(_on_search_text_submitted)
	search_row.add_child(_search_input)

	_search_button = Button.new()
	_search_button.text = "Search"
	_search_button.pressed.connect(_on_search_pressed)
	search_row.add_child(_search_button)

	_refresh_button = Button.new()
	_refresh_button.text = "Browse"
	_refresh_button.tooltip_text = "Show the most popular palettes"
	_refresh_button.pressed.connect(refresh)
	search_row.add_child(_refresh_button)

	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 6)
	add_child(filter_row)

	var sort_label := Label.new()
	sort_label.text = "Sort:"
	filter_row.add_child(sort_label)

	_sort_option = OptionButton.new()
	_sort_option.add_item("Default")
	_sort_option.add_item("A-Z")
	_sort_option.add_item("Downloads")
	_sort_option.add_item("Newest")
	_sort_option.item_selected.connect(_on_sort_selected)
	filter_row.add_child(_sort_option)

	var tag_label := Label.new()
	tag_label.text = "Tag:"
	filter_row.add_child(tag_label)

	_tag_input = LineEdit.new()
	_tag_input.placeholder_text = "gameboy, retro, 16..."
	_tag_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tag_input.text_submitted.connect(_on_tag_text_submitted)
	filter_row.add_child(_tag_input)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 6)
	add_child(status_row)

	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.text = "Select this preset to load palettes from Lospec."
	status_row.add_child(_status_label)

	_load_more_button = Button.new()
	_load_more_button.text = "Load More"
	_load_more_button.disabled = true
	_load_more_button.pressed.connect(_on_load_more_pressed)
	status_row.add_child(_load_more_button)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0, 230)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_results_box = VBoxContainer.new()
	_results_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_results_box.add_theme_constant_override("separation", 4)
	_scroll.add_child(_results_box)


func _default_headers() -> PackedStringArray:
	return PackedStringArray(["Accept: application/json", "User-Agent: " + USER_AGENT])


func _set_loading(value: bool) -> void:
	_is_loading = value
	_search_button.disabled = value
	_refresh_button.disabled = value
	_load_more_button.disabled = value
	if value:
		_status_label.text = "Loading palettes from Lospec..."


func _clear_results() -> void:
	for child in _results_box.get_children():
		child.queue_free()


func _request_page(page: int) -> void:
	_mode = Mode.BROWSE
	_requested_page = page
	_set_loading(true)

	var tag := _tag_input.text.strip_edges().uri_encode()
	var sort_index := clampi(_sort_option.selected, 0, SORT_VALUES.size() - 1)
	var url := (
		"%s?colorNumberFilterType=any&colorNumber=8&page=%d&tag=%s&sortingType=%s"
		% [LIST_URL, page, tag, SORT_VALUES[sort_index]]
	)
	var err := _list_request.request(url, _default_headers())
	if err != OK:
		_set_loading(false)
		_status_label.text = "Failed to contact Lospec (error %d)." % err


func _on_list_request_completed(
	result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_set_loading(false)
		_status_label.text = "Network error while loading Lospec palettes."
		return
	if response_code != 200:
		_set_loading(false)
		_status_label.text = "Lospec returned HTTP %d." % response_code
		return

	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("palettes"):
		_set_loading(false)
		_status_label.text = "Could not parse the Lospec response."
		return

	var palettes: Array = parsed.get("palettes", [])
	_total_count = int(parsed.get("totalCount", 0))
	if _requested_page == 0:
		_clear_results()
	_page = _requested_page

	for palette_data in palettes:
		if typeof(palette_data) == TYPE_DICTIONARY:
			_add_palette_item(_normalize_palette(palette_data))

	_set_loading(false)
	var has_more := _results_box.get_child_count() < _total_count and not palettes.is_empty()
	_load_more_button.disabled = not has_more
	if _results_box.get_child_count() == 0:
		_status_label.text = "No palettes found."
	else:
		_status_label.text = (
			"Showing %d of %d palettes" % [_results_box.get_child_count(), _total_count]
		)


func _on_load_more_pressed() -> void:
	if _mode != Mode.BROWSE or _is_loading:
		return
	_request_page(_page + 1)


func _on_sort_selected(_index: int) -> void:
	_reload_browse()


func _on_tag_text_submitted(_text: String) -> void:
	_reload_browse()


func _on_search_text_submitted(_text: String) -> void:
	_on_search_pressed()


func _on_search_pressed() -> void:
	if _is_loading:
		return
	var query := _search_input.text.strip_edges()
	if query.is_empty():
		refresh()
		return

	_mode = Mode.SEARCH
	_last_search_query = query
	_page = 0
	_total_count = 0
	_pending_detail_requests = 0
	_detail_buffer.clear()
	_clear_results()
	_set_loading(true)
	_load_more_button.disabled = true

	var err := _suggest_request.request(SUGGEST_URL + query.uri_encode(), _default_headers())
	if err != OK:
		_set_loading(false)
		_status_label.text = "Failed to contact Lospec (error %d)." % err


func _on_suggest_request_completed(
	result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_set_loading(false)
		_status_label.text = "Could not search Lospec right now."
		return

	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY or parsed.is_empty():
		_set_loading(false)
		_status_label.text = 'No palettes found for "%s".' % _last_search_query
		return

	_pending_detail_requests = parsed.size()
	var order := 0
	for entry in parsed:
		if typeof(entry) != TYPE_DICTIONARY:
			_one_detail_finished()
			continue
		var slug := str(entry.get("slug", ""))
		var title := str(entry.get("title", slug))
		if slug.is_empty():
			_one_detail_finished()
			continue
		_request_palette_details(slug, title, order)
		order += 1


func _request_palette_details(slug: String, title: String, order: int) -> void:
	var http := HTTPRequest.new()
	http.timeout = 25.0
	add_child(http)
	http.request_completed.connect(_on_detail_request_completed.bind(http, slug, title, order))
	var err := http.request(PALETTE_JSON_URL % slug.uri_encode(), _default_headers())
	if err != OK:
		http.queue_free()
		_one_detail_finished()


func _on_detail_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	http: HTTPRequest,
	slug: String,
	title: String,
	order: int
) -> void:
	http.queue_free()
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) == TYPE_DICTIONARY:
			parsed["slug"] = slug
			parsed["_order"] = order
			if str(parsed.get("title", "")).is_empty():
				parsed["title"] = title
			if str(parsed.get("name", "")).is_empty():
				parsed["name"] = title
			_detail_buffer.append(parsed)
	_one_detail_finished()


func _one_detail_finished() -> void:
	if _pending_detail_requests <= 0:
		return
	_pending_detail_requests -= 1
	if _pending_detail_requests > 0:
		return

	_set_loading(false)
	_load_more_button.disabled = true
	_detail_buffer.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("_order", 0)) < int(b.get("_order", 0))
	)
	for palette_data in _detail_buffer:
		_add_palette_item(_normalize_palette(palette_data))
	if _results_box.get_child_count() == 0:
		_status_label.text = 'No palettes found for "%s".' % _last_search_query
	else:
		_status_label.text = 'Found %d palettes for "%s"' % [
			_results_box.get_child_count(), _last_search_query
		]


func _normalize_palette(data: Dictionary) -> Dictionary:
	var colors := PackedColorArray()
	# The list endpoint (/palette-list/load) returns "colorsArray" as hex strings
	# without a leading '#', while the official /{slug}.json endpoint returns
	# "colors". Accept both so browsing does not need one request per palette.
	var color_hexes: Array = []
	for key in ["colorsArray", "colors"]:
		if data.has(key) and data[key] is Array:
			color_hexes = data[key]
			break
	for hex in color_hexes:
		var value := str(hex).strip_edges()
		if value.is_empty():
			continue
		if not value.begins_with("#"):
			value = "#" + value
		colors.append(Color.from_string(value, Color.BLACK))

	var title := str(data.get("title", ""))
	if title.is_empty():
		title = str(data.get("name", "Unnamed Palette"))

	var author := ""
	var user: Variant = data.get("user", {})
	if typeof(user) == TYPE_DICTIONARY:
		author = str(user.get("name", ""))
	if author.is_empty():
		author = str(data.get("author", ""))

	var example_url := ""
	var examples: Variant = data.get("examples", [])
	if typeof(examples) == TYPE_ARRAY and not examples.is_empty():
		var example: Variant = examples[0]
		if typeof(example) == TYPE_DICTIONARY and example.has("image"):
			example_url = CDN_URL + str(example["image"])

	var color_count := colors.size()
	var reported_count: Variant = data.get("numberOfColors", 0)
	if color_count == 0 and typeof(reported_count) in [TYPE_INT, TYPE_FLOAT]:
		color_count = int(reported_count)

	return {
		"slug": str(data.get("slug", "")),
		"title": title,
		"author": author,
		"colors": colors,
		"number_of_colors": color_count,
		"description": str(data.get("description", "")),
		"downloads": str(data.get("downloads", "")),
		"tags": data.get("tags", []),
		"example_url": example_url,
	}


func _add_palette_item(palette: Dictionary) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_results_box.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	margin.add_child(row)

	var colors: PackedColorArray = palette.get("colors", PackedColorArray())
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(96, 64)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview.texture = _make_color_strip_texture(colors)
	row.add_child(preview)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)

	# The title links to the palette detail page on lospec.com, like on the website.
	var title_label := Label.new()
	title_label.text = str(palette.get("title", "Unnamed Palette"))
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.clip_text = true
	var slug := str(palette.get("slug", ""))
	if not slug.is_empty():
		title_label.mouse_filter = Control.MOUSE_FILTER_STOP
		title_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		title_label.tooltip_text = "Open this palette on lospec.com"
		title_label.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
		title_label.gui_input.connect(_on_palette_title_input.bind(slug))
	info.add_child(title_label)

	var details := PackedStringArray()
	details.append("%d colors" % int(palette.get("number_of_colors", colors.size())))
	var author := str(palette.get("author", ""))
	if not author.is_empty():
		details.append("by %s" % author)
	var downloads := str(palette.get("downloads", ""))
	if not downloads.is_empty():
		details.append("%s downloads" % downloads)
	var details_label := Label.new()
	details_label.text = " • ".join(details)
	details_label.add_theme_color_override("font_color", Color(0.72, 0.72, 0.72))
	details_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details_label.clip_text = true
	info.add_child(details_label)

	info.add_child(_make_swatch_strip(colors))

	var description := str(palette.get("description", ""))
	if not description.is_empty():
		panel.tooltip_text = description

	var use_button := Button.new()
	use_button.text = "Use Palette"
	use_button.pressed.connect(_on_use_palette_pressed.bind(palette))
	row.add_child(use_button)

	var example_url := str(palette.get("example_url", ""))
	if not example_url.is_empty():
		_load_preview_image(example_url, preview)


func _make_swatch_strip(colors: PackedColorArray) -> HBoxContainer:
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 0)
	strip.custom_minimum_size = Vector2(0, 10)

	var shown := mini(colors.size(), MAX_PREVIEW_SWATCHES)
	for i in shown:
		var swatch := ColorRect.new()
		swatch.color = colors[i]
		swatch.custom_minimum_size = Vector2(6, 10)
		swatch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		strip.add_child(swatch)

	if colors.size() > shown:
		var more := Label.new()
		more.text = " +%d" % (colors.size() - shown)
		strip.add_child(more)

	return strip


func _make_color_strip_texture(colors: PackedColorArray) -> Texture2D:
	if colors.is_empty():
		return null
	# Draw colors as a grid so wide palettes still get a readable thumbnail
	var columns := mini(colors.size(), 16)
	var rows := ceili(colors.size() / float(columns))
	var image := Image.create(columns, rows, false, Image.FORMAT_RGBA8)
	for i in colors.size():
		var column := i % columns
		var row := floori(float(i) / columns)
		image.set_pixel(column, row, colors[i])
	return ImageTexture.create_from_image(image)


func _load_preview_image(url: String, target: TextureRect) -> void:
	var http := HTTPRequest.new()
	http.timeout = 25.0
	# Store a weak reference, so a request finishing after the list item was freed
	# does not pass a dangling node as a bound callable argument.
	http.set_meta("preview_target", weakref(target))
	add_child(http)
	http.request_completed.connect(_on_preview_request_completed.bind(http))
	var err := http.request(url, PackedStringArray(["User-Agent: " + USER_AGENT]))
	if err != OK:
		http.queue_free()


func _on_preview_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	http: HTTPRequest
) -> void:
	var target_ref: WeakRef = http.get_meta("preview_target", null)
	http.queue_free()
	if target_ref == null:
		return
	var target: TextureRect = target_ref.get_ref() as TextureRect
	if not is_instance_valid(target):
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var image := Image.new()
	if image.load_png_from_buffer(body) != OK:
		return
	# Example images can be quite large; downscale them for the thumbnail.
	if image.get_width() > 256:
		var height := int(256.0 * image.get_height() / image.get_width())
		image.resize(256, maxi(height, 1), Image.INTERPOLATE_NEAREST)
	target.texture = ImageTexture.create_from_image(image)


## Opens the Lospec palette detail page when its title is clicked.
func _on_palette_title_input(event: InputEvent, slug: String) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			OS.shell_open(PALETTE_PAGE_URL % slug)


func _on_use_palette_pressed(palette: Dictionary) -> void:
	palette_selected.emit(palette)
	_status_label.text = "Selected: %s" % str(palette.get("title", ""))
