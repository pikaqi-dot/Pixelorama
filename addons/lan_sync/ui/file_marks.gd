@tool
extends RefCounted
## How one row of the file list is drawn: a symbol, a colour and a sentence.
##
## Both the editor dock and the in-app page go through here, so a colour cannot
## come to mean one thing on the desktop and another on the phone.
##
## [codeblock]
## ✓  both sides, same modification time — a sync would do nothing
## ❗ yellow: the other side is newer, or this side has no copy yet
## ❗ red:    the other side is older — a pull would overwrite a newer local file
## ✗  red:   only this side has it, the other side never sees it
## [/codeblock]

const COLOR_SAME := Color("#7fd6a8")
const COLOR_NEWER := Color("#e8b46a")
const COLOR_OLDER := Color("#e86a6a")
const COLOR_LOCAL_ONLY := Color("#e86a6a")

const SYMBOL_SAME := "✓"
const SYMBOL_DIFFERS := "❗"
const SYMBOL_MISSING_THERE := "✗"

## One line for the heading's tooltip, so the marks are explained where they are.
const LEGEND := "✓ 两端一致｜❗ 时间不同（黄=对方更新，红=对方较旧，拉取会覆盖本地）｜✗ 对方没有"


static func symbol(state: int) -> String:
	match state:
		LanSyncCore.FileState.SAME:
			return SYMBOL_SAME
		LanSyncCore.FileState.LOCAL_ONLY:
			return SYMBOL_MISSING_THERE
		_:
			return SYMBOL_DIFFERS


static func color(state: int) -> Color:
	match state:
		LanSyncCore.FileState.SAME:
			return COLOR_SAME
		LanSyncCore.FileState.REMOTE_NEWER, LanSyncCore.FileState.REMOTE_ONLY:
			return COLOR_NEWER
		LanSyncCore.FileState.LOCAL_ONLY:
			return COLOR_LOCAL_ONLY
		_:
			return COLOR_OLDER


## The row text: the mark, the key, and the time that matters for that mark.
static func text(row: Dictionary) -> String:
	var state := int(row.get("state", 0))
	var mtime := int(row.get("remote_mtime", -1))
	if mtime < 0:
		mtime = int(row.get("local_mtime", -1))
	return "%s %s · %s" % [symbol(state), str(row.get("key", "")), mtime_text(mtime)]


## The sentence behind the mark, for the row's tooltip.
static func tooltip(row: Dictionary) -> String:
	var key := str(row.get("key", ""))
	var local_time := mtime_text(int(row.get("local_mtime", -1)))
	var remote_time := mtime_text(int(row.get("remote_mtime", -1)))
	match int(row.get("state", 0)):
		LanSyncCore.FileState.SAME:
			return "%s\n两端修改时间一致（%s），同步会跳过" % [key, local_time]
		LanSyncCore.FileState.REMOTE_NEWER:
			return "%s\n对方更新：对方 %s，本地 %s\n同步会用对方的覆盖本地" % [
				key, remote_time, local_time
			]
		LanSyncCore.FileState.REMOTE_OLDER:
			return "%s\n对方较旧：对方 %s，本地 %s\n同步会覆盖较新的本地文件" % [
				key, remote_time, local_time
			]
		LanSyncCore.FileState.REMOTE_ONLY:
			return "%s\n本地还没有这个文件（对方 %s），同步会新建" % [key, remote_time]
		_:
			return "%s\n对方没有这个文件（本地 %s）" % [key, local_time]


## A modification time as it reads in a file manager.
static func mtime_text(mtime: int) -> String:
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
