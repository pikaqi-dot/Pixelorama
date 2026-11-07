@tool
extends RefCounted
## How one row of the file list is drawn: a symbol, a colour and a sentence.
##
## Both the editor dock and the in-app page go through here, so a colour cannot
## come to mean one thing on the desktop and another on the phone.
##
## The marks are written from the point of view of the side looking at them, and
## red always means "there is something for this side to do":
##
## [codeblock]
## ✓  green:      the two copies hold the same bytes — nothing to do
## ❗ red:        the other side is newer — this side has to update
## ❗ yellow:     this side is newer — nothing to do here, the other side pulls
## ✗  red:        this side has no copy — a sync creates it here
## ✗  grey:       the other side has no copy — nothing to do here, it pulls
## [/codeblock]
##
## A file only one side has therefore shows ✗ on the side that is missing it in
## red, and on the side that owns it in grey, which is where a person would look
## for "why has my neighbour not got this yet".

const COLOR_SAME := Color("#7fd6a8")
## Red: this side has something to update. Used for "the other side is newer" and
## for "this side has no copy yet".
const COLOR_MINE := Color("#e86a6a")
## Yellow: the other side is the one that has to act.
const COLOR_THEIRS := Color("#e8b46a")
## Grey: the file is not on the other side. Nothing to do from here.
const COLOR_NEUTRAL := Color("#8a8f99")

const SYMBOL_SAME := "✓"
const SYMBOL_DIFFERS := "❗"
const SYMBOL_MISSING := "✗"

## One line for the heading's tooltip, so the marks are explained where they are.
const LEGEND := (
	"✓ 一致｜❗ 时间不同（红=对方更新，本机点「同步」才会更新；黄=本机较新，等对方来拉）"
	+ "｜✗ 只有一个（红=本机缺，同步会补上；灰=对方缺，对方同步才有）"
)


static func symbol(state: int) -> String:
	match state:
		LanSyncCore.FileState.SAME:
			return SYMBOL_SAME
		LanSyncCore.FileState.REMOTE_ONLY, LanSyncCore.FileState.LOCAL_ONLY:
			return SYMBOL_MISSING
		_:
			return SYMBOL_DIFFERS


static func color(state: int) -> Color:
	match state:
		LanSyncCore.FileState.SAME:
			return COLOR_SAME
		# Both of these are "this side must act": the other side is newer, or this
		# side has no copy at all.
		LanSyncCore.FileState.REMOTE_NEWER, LanSyncCore.FileState.REMOTE_ONLY:
			return COLOR_MINE
		# The other side is behind, or lacks the file. Waiting is all this side can
		# do, because a sync only pulls.
		LanSyncCore.FileState.REMOTE_OLDER:
			return COLOR_THEIRS
		_:
			return COLOR_NEUTRAL


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
			return "%s\n两端内容一致（%s），同步会跳过" % [key, local_time]
		LanSyncCore.FileState.REMOTE_NEWER:
			return "%s\n对方更新：对方 %s，本机 %s\n→ 本机要更新：点「同步」用对方的覆盖本地" % [
				key, remote_time, local_time
			]
		LanSyncCore.FileState.REMOTE_OLDER:
			return "%s\n本机较新：对方 %s，本机 %s\n→ 本机不用动；对方点「同步」才会换成这一版" % [
				key, remote_time, local_time
			]
		LanSyncCore.FileState.REMOTE_ONLY:
			return "%s\n本机还没有这个文件（对方 %s）\n→ 本机要取：点「同步」会新建" % [
				key, remote_time
			]
		_:
			return "%s\n对方没有这个文件（本机 %s）\n→ 本机不用动；在对方点「同步」才会拿到" % [
				key, local_time
			]


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
