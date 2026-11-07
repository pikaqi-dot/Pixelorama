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
## ❗ red:        same timestamp but different bytes — a double click picks
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
	+ "｜❗ 红「时间相同 内容不同」=同一秒里各写了一次，双击这一行用对方的覆盖"
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
		# All of these are "this side must act": the other side is newer, this side
		# has no copy at all, or the two copies differ and the clock cannot say
		# which is which.
		LanSyncCore.FileState.REMOTE_NEWER, LanSyncCore.FileState.REMOTE_ONLY, \
			LanSyncCore.FileState.SAME_TIME_DIFFERS:
			return COLOR_MINE
		# The other side is behind, or lacks the file. Waiting is all this side can
		# do, because a sync only pulls.
		LanSyncCore.FileState.REMOTE_OLDER:
			return COLOR_THEIRS
		_:
			return COLOR_NEUTRAL


## The row text: the mark, the key, and the time that matters for that mark.
##
## A tick usually means the two timestamps are the same, and then the time is
## worth showing. A tick that came from "a sync just moved these bytes" does not:
## writing a file stamps it with the current time on whichever side received it,
## so the two copies legitimately read different times while holding the same
## content. Printing one of them next to the tick would only look like a lie, so
## such a row says 内容一致 and leaves both times to the tooltip.
static func text(row: Dictionary) -> String:
	var state := int(row.get("state", 0))
	var key := str(row.get("key", ""))
	if state == LanSyncCore.FileState.SAME and _times_differ(row):
		return "%s %s · 内容一致" % [symbol(state), key]
	if state == LanSyncCore.FileState.SAME_TIME_DIFFERS:
		return "%s %s · 时间相同 内容不同" % [symbol(state), key]
	var mtime := int(row.get("remote_mtime", -1))
	if mtime < 0:
		mtime = int(row.get("local_mtime", -1))
	return "%s %s · %s" % [symbol(state), key, mtime_text(mtime)]


## Both sides have a timestamp and they are not the same one.
static func _times_differ(row: Dictionary) -> bool:
	var local_mtime := int(row.get("local_mtime", -1))
	var remote_mtime := int(row.get("remote_mtime", -1))
	if local_mtime <= 0 or remote_mtime <= 0:
		return false
	return local_mtime != remote_mtime


## The sentence behind the mark, for the row's tooltip.
static func tooltip(row: Dictionary) -> String:
	var key := str(row.get("key", ""))
	var local_time := mtime_text(int(row.get("local_mtime", -1)))
	var remote_time := mtime_text(int(row.get("remote_mtime", -1)))
	match int(row.get("state", 0)):
		LanSyncCore.FileState.SAME:
			if not _times_differ(row):
				return "%s\n两端内容一致，修改时间也相同（%s），同步会跳过" % [key, local_time]
			return (
				"%s\n两端内容一致：本机 %s，对方 %s"
				% [key, local_time, remote_time]
				+ "\n→ 时间不同是正常的：同步写文件会用「写入那一刻」当修改时间，"
				+ "两边的写入时刻不一样，内容却是同一份（哈希相同）"
			)
		LanSyncCore.FileState.SAME_TIME_DIFFERS:
			return (
				"%s\n两边修改时间相同（%s），内容却不同：两边在同一个「秒」里各写过一次，"
				% [key, local_time]
				+ "时间戳分不出谁新\n→ 双击这一行（或右键）用对方的覆盖本机"
			)
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


## The row text inside a tree: the mark, the file name alone (the folders it sits
## in are ancestor items now), and the time that matters for that mark.
static func short_text(row: Dictionary) -> String:
	var state := int(row.get("state", 0))
	var key := str(row.get("key", ""))
	if state == LanSyncCore.FileState.SAME and _times_differ(row):
		return "%s %s · 内容一致" % [symbol(state), key.get_file()]
	if state == LanSyncCore.FileState.SAME_TIME_DIFFERS:
		return "%s %s · 时间相同 内容不同" % [symbol(state), key.get_file()]
	var mtime := int(row.get("remote_mtime", -1))
	if mtime < 0:
		mtime = int(row.get("local_mtime", -1))
	return "%s %s · %s" % [symbol(state), key.get_file(), mtime_text(mtime)]


## Fills [param tree] with one item per row, folding the folder part of each key
## into folder items, so "art/ui/button.png" is a file under "art/" → "ui/".
##
## A file item's metadata is [code]{"index": i}[/code], an index into
## [param rows]; a folder item's is [code]{"folder": "art/ui/"}[/code], which is
## the prefix a double-click asks the core to pull. A folder takes the strongest
## mark of the files under it — red ("this side must act") wins over yellow, grey
## over green — so a collapsed folder stays informative.
##
## Returns the file items, one per entry of [param rows] and in the same order, so
## a panel can put the selection back after a redraw.
static func fill_tree(tree: Tree, rows: Array, empty_hint := "") -> Array[TreeItem]:
	var items: Array[TreeItem] = []
	tree.clear()
	var root := tree.create_item()
	if rows.is_empty():
		if not empty_hint.is_empty():
			var empty := tree.create_item(root)
			empty.set_text(0, empty_hint)
			empty.set_selectable(0, false)
			empty.set_custom_color(0, COLOR_NEUTRAL)
		return items
	var folders := {}
	var folder_states := {}
	for index in rows.size():
		var row: Dictionary = rows[index]
		var key := str(row.get("key", ""))
		var parts := key.split("/")
		var parent := root
		var path := ""
		for depth in parts.size() - 1:
			path = parts[depth] if path.is_empty() else "%s/%s" % [path, parts[depth]]
			if folders.has(path):
				parent = folders[path]
				continue
			var folder_item := tree.create_item(parent)
			folder_item.set_text(0, "%s/" % parts[depth])
			folder_item.set_metadata(0, {"folder": "%s/" % path})
			folder_item.set_tooltip_text(
				0, "%s/\n双击同步这个文件夹下的全部文件" % path
			)
			folder_item.set_custom_color(0, COLOR_NEUTRAL)
			folders[path] = folder_item
			parent = folder_item
		var item := tree.create_item(parent)
		item.set_text(0, short_text(row))
		item.set_custom_color(0, color(int(row.get("state", 0))))
		item.set_tooltip_text(0, tooltip(row))
		item.set_metadata(0, {"index": index})
		items.append(item)
		# Every ancestor folder remembers this mark, so its colour can answer
		# "is there anything in here for me to do" without being expanded.
		path = ""
		for depth in parts.size() - 1:
			path = parts[depth] if path.is_empty() else "%s/%s" % [path, parts[depth]]
			if not folder_states.has(path):
				folder_states[path] = []
			(folder_states[path] as Array).append(int(row.get("state", 0)))
	for path: String in folder_states:
		if folders.has(path):
			(folders[path] as TreeItem).set_custom_color(0, _group_color(folder_states[path]))
	return items


## The strongest mark among the rows under one folder.
static func _group_color(states: Array) -> Color:
	var waiting := false
	var neutral := false
	for value: Variant in states:
		match int(value):
			LanSyncCore.FileState.REMOTE_NEWER, LanSyncCore.FileState.REMOTE_ONLY, \
				LanSyncCore.FileState.SAME_TIME_DIFFERS:
				return COLOR_MINE
			LanSyncCore.FileState.REMOTE_OLDER:
				waiting = true
			LanSyncCore.FileState.LOCAL_ONLY:
				neutral = true
	if waiting:
		return COLOR_THEIRS
	if neutral:
		return COLOR_NEUTRAL
	return COLOR_SAME


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
