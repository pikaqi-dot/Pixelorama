@tool
extends RefCounted
## The one place log lines are formatted, shared by the in-app page and the
## editor dock so the same event reads the same way in both.
##
## Every line gets a timestamp, a symbol, and a colour that says what kind of
## event it was. The classification is done on the text the core already emits:
## those strings are written here, so a keyword is a stable contract rather than
## a guess at arbitrary input.

## Older lines are dropped past this many, or a long session would grow the
## control without bound.
const MAX_LINES := 400

const COLOR_TEXT := "#cdd6e4"
const COLOR_LINK := "#7fd6a8"
const COLOR_TRANSFER := "#79c0e8"
const COLOR_WARN := "#e8b46a"
const COLOR_SCAN := "#b79ce8"
const COLOR_LIST := "#9aa4b4"
const COLOR_TIME := "#5b6472"

## Nothing worked. Checked first, because a line that failed is a warning even
## when it also mentions connecting or transferring.
##
## These are phrases, not single words, on purpose: "跳过 0 个" in a summary is
## good news, and a folder that is simply empty is not an error.
const WARN_WORDS := [
	"失败",
	"无法",
	"错误",
	"读不到",
	"拒绝",
	"占用",
	"连不上",
	"还没连上",
	"不匹配",
	"不是同步端",
	"没有同名",
	"没有可写",
	"都还没有文件",
	"没有设备回应",
]
const LINK_WORDS := ["已连上", "已连接", "连接断了", "重连", "正在连接", "断开", "让出"]
const TRANSFER_WORDS := ["收到", "发送", "拉取完成", "已把", "同步完成"]
const SCAN_WORDS := ["扫描", "发现", "附近"]
const LIST_WORDS := ["清单", "对方的"]


## Formats one line and appends it, trimming the oldest lines past the cap.
static func append_to(label: RichTextLabel, text: String) -> void:
	if not is_instance_valid(label):
		return
	label.append_text(formatted(text))
	while label.get_paragraph_count() > MAX_LINES:
		label.remove_paragraph(0)


## The full bbcode line, for callers that build their own container.
static func formatted(text: String) -> String:
	var color := color_for(text)
	return "[color=%s]%s[/color] [color=%s]%s[/color] [color=%s]%s[/color]\n" % [
		COLOR_TIME,
		Time.get_time_string_from_system(),
		color,
		icon_for(text),
		color,
		_escape(text),
	]


static func color_for(text: String) -> String:
	if _mentions(text, WARN_WORDS):
		return COLOR_WARN
	if _mentions(text, LINK_WORDS):
		return COLOR_LINK
	if _mentions(text, TRANSFER_WORDS):
		return COLOR_TRANSFER
	if _mentions(text, SCAN_WORDS):
		return COLOR_SCAN
	if _mentions(text, LIST_WORDS):
		return COLOR_LIST
	return COLOR_TEXT


static func icon_for(text: String) -> String:
	if _mentions(text, WARN_WORDS):
		return "!"
	if _mentions(text, LINK_WORDS):
		return "◆"
	if _mentions(text, TRANSFER_WORDS):
		return "↔"
	if _mentions(text, SCAN_WORDS):
		return "…"
	if _mentions(text, LIST_WORDS):
		return "≡"
	return "•"


static func _mentions(text: String, words: Array) -> bool:
	for word in words:
		if text.contains(str(word)):
			return true
	return false


## A file name may contain square brackets, which bbcode would try to read as a
## tag and silently swallow.
static func _escape(text: String) -> String:
	return text.replace("[", "[lb]")
