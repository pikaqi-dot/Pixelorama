@tool
class_name LanSyncCore
extends Node
## Two way file sync over a local network, shared by the built application and by
## the Godot editor plugin.
##
## Discovery is a UDP beacon sent once a second on one fixed port, so two peers
## find each other without anybody typing an address. The sync itself runs over
## TCP: each side sends a manifest of its folders, the peer with the smaller id
## decides what has to move, and both sides end up holding the same files. A file
## is only ever replaced, never deleted, because a delete on one side is far more
## often an accident than an instruction.
##
## Folders are matched by name, so the two machines do not need the same layout:
## the editor can keep "shared" at res://shared while the application keeps it in
## its user folder, and they still line up.

signal peers_changed()
signal log_line(text: String)
signal file_synced(path: String, direction: String)

## Version of the wire format. A peer speaking another one is reported instead of
## being half understood.
const PROTOCOL := 1
const DISCOVERY_PORT := 45999
## First port tried for the sync socket. A few more are tried after it, so a
## second copy of the application on one machine can still be reached.
const SYNC_PORT := 45990
const SYNC_PORT_TRIES := 8
const BEACON_INTERVAL := 1.0
## A peer not heard from for this long is shown as gone.
const PEER_TIMEOUT := 5.0
## Largest single file that is moved. A bigger one is left alone and reported,
## which keeps a stray video out of the memory of a phone.
const MAX_FILE_BYTES := 1_500_000
## Most files read from one folder. A pasted music library is not what this is for.
const MAX_FILES := 4000
const CONFIG_PATH := "user://lan_sync.cfg"
const IGNORED_NAMES := [".godot", ".import", ".git", ".DS_Store", "Thumbs.db"]

## Folder name to absolute path. The name is what the two peers match on.
var folders: Dictionary = {}
## What this peer calls itself in the other side's list.
var label := "Pixelorama"
var device_id := ""
var running := false
var sync_port := 0

## id -> {label, address, port, state, last_seen}
var peers: Dictionary = {}

var _udp := PacketPeerUDP.new()
var _server := TCPServer.new()
var _peer: StreamPeerTCP = null
var _peer_id := ""
var _peer_label := ""
var _initiator := false
var _buffer := PackedByteArray()
var _beacon_left := 0.0
var _outbox: Array = []
var _get_queue: Array[String] = []
var _expecting := 0
var _received := 0
var _phase := ""


func _init() -> void:
	device_id = "%s-%s" % [str(Time.get_unix_time_from_system()), str(randi() % 100000)]
	load_config()


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	if not running:
		return
	_beacon_left -= delta
	if _beacon_left <= 0.0:
		_beacon_left = BEACON_INTERVAL
		_broadcast()
	_poll_discovery()
	_poll_server()
	_poll_peer()
	_poll_timeouts()


# Public API.


func start() -> bool:
	if running:
		return true
	sync_port = 0
	for step in SYNC_PORT_TRIES:
		# listen() answers with an Error, and OK is zero: asking if it is truthy
		# would read a success as a failure and keep the port that did not open.
		if _server.listen(SYNC_PORT + step) == OK:
			sync_port = SYNC_PORT + step
			break
	if sync_port == 0:
		log_line.emit("无法监听同步端口 %d–%d" % [SYNC_PORT, SYNC_PORT + SYNC_PORT_TRIES - 1])
		return false
	# The discovery port can only be bound once per machine, so a second copy of
	# the application falls back to sending beacons only: the other side still
	# finds it, and an address can always be typed in by hand.
	if _udp.bind(DISCOVERY_PORT) != OK:
		log_line.emit("发现端口被占用，只能被对方发现（可手动输入地址）")
	else:
		_udp.set_broadcast_enabled(true)
	running = true
	_beacon_left = 0.0
	set_process(true)
	log_line.emit("已开始：%s · 端口 %d" % [label, sync_port])
	return true


func stop() -> void:
	_udp.close()
	_server.stop()
	_drop_peer("")
	running = false
	set_process(false)
	peers.clear()
	peers_changed.emit()
	log_line.emit("已停止")


## Connects without waiting for a beacon, for a network that blocks broadcast.
func connect_to(address: String, port: int) -> void:
	if address.is_empty():
		return
	if not running and not start():
		return
	_open_peer(address, port, "", "")


func set_folder(folder_name: String, path: String) -> void:
	folders[folder_name] = path
	save_config()


func remove_folder(folder_name: String) -> void:
	folders.erase(folder_name)
	save_config()


func save_config() -> void:
	var config := ConfigFile.new()
	config.set_value("device", "label", label)
	for folder_name: String in folders:
		config.set_value("folders", folder_name, str(folders[folder_name]))
	config.save(CONFIG_PATH)


func load_config() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	label = str(config.get_value("device", "label", label))
	folders.clear()
	if not config.has_section("folders"):
		return
	for folder_name: String in config.get_section_keys("folders"):
		folders[folder_name] = str(config.get_value("folders", folder_name, ""))


# Discovery.


func _broadcast() -> void:
	if not _udp.is_bound():
		return
	var packet := "LANSYNC|%d|%s|%s|%d" % [
		PROTOCOL, device_id, label.replace("|", " "), sync_port
	]
	_udp.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_udp.put_packet(packet.to_utf8_buffer())


func _poll_discovery() -> void:
	if not _udp.is_bound():
		return
	while _udp.get_available_packet_count() > 0:
		var data := _udp.get_packet()
		var address := _udp.get_packet_ip()
		var parts := data.get_string_from_utf8().split("|")
		if parts.size() < 5 or parts[0] != "LANSYNC":
			continue
		if int(parts[1]) != PROTOCOL or parts[2] == device_id:
			continue
		_remember_peer(parts[2], parts[3], address, int(parts[4]))
		# Only the smaller id dials, so two peers never end up with two links.
		if _peer == null and device_id < parts[2]:
			_open_peer(address, int(parts[4]), parts[2], parts[3])


func _remember_peer(id: String, peer_label: String, address: String, port: int) -> void:
	var added := not peers.has(id)
	if added:
		peers[id] = {"label": peer_label, "address": address, "port": port, "state": "附近"}
	var entry: Dictionary = peers[id]
	entry["label"] = peer_label
	entry["last_seen"] = Time.get_ticks_msec()
	if not address.is_empty():
		entry["address"] = address
	if port > 0:
		entry["port"] = port
	if added:
		peers_changed.emit()
		log_line.emit("发现 %s（%s）" % [peer_label, address])


func _poll_timeouts() -> void:
	var now := Time.get_ticks_msec()
	var gone: Array[String] = []
	for id: String in peers:
		if id == _peer_id:
			continue
		if now - int(peers[id].get("last_seen", 0)) > int(PEER_TIMEOUT * 1000.0):
			gone.append(id)
	for id in gone:
		var peer_label := str(peers[id].get("label", id))
		peers.erase(id)
		log_line.emit("离开 %s" % peer_label)
	if not gone.is_empty():
		peers_changed.emit()


# Transport.


func _poll_server() -> void:
	while _server.is_connection_available():
		var incoming := _server.take_connection()
		if incoming == null:
			continue
		if _peer != null:
			# One link at a time; another copy on the network waits its turn.
			incoming.disconnect_from_host()
			continue
		_peer = incoming
		_peer_id = ""
		_peer_label = ""
		_initiator = false
		_buffer = PackedByteArray()
		_phase = "accepted"


func _open_peer(address: String, port: int, id: String, peer_label: String) -> void:
	_drop_peer("")
	var socket := StreamPeerTCP.new()
	if socket.connect_to_host(address, port) != OK:
		log_line.emit("连接 %s:%d 失败" % [address, port])
		return
	_peer = socket
	_peer_id = id
	_peer_label = peer_label
	_initiator = true
	_buffer = PackedByteArray()
	_phase = "connecting"
	log_line.emit("正在连接 %s:%d" % [address, port])


func _drop_peer(reason: String) -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	_peer_id = ""
	_peer_label = ""
	_initiator = false
	_phase = ""
	_buffer = PackedByteArray()
	_outbox.clear()
	_get_queue.clear()
	_expecting = 0
	_received = 0
	if not reason.is_empty():
		log_line.emit(reason)


func _poll_peer() -> void:
	if _peer == null:
		return
	_peer.poll()
	var state := _peer.get_status()
	if state == StreamPeerTCP.STATUS_ERROR or state == StreamPeerTCP.STATUS_NONE:
		_drop_peer("连接已断开")
		return
	if state != StreamPeerTCP.STATUS_CONNECTED:
		return
	if _phase == "connecting" or _phase == "accepted":
		_phase = "hello"
		_outbox.push_front(
			{
				"t": "hello",
				"proto": PROTOCOL,
				"id": device_id,
				"label": label,
				"folders": folders.keys(),
			}
		)
	_read_available()
	_write_outbox()


func _read_available() -> void:
	while _peer.get_available_bytes() > 0:
		var chunk: Array = _peer.get_partial_data(_peer.get_available_bytes())
		if int(chunk[0]) != OK:
			return
		var bytes: PackedByteArray = chunk[1]
		if bytes.is_empty():
			return
		_buffer.append_array(bytes)
	# One message per line, so a message split over packets is simply joined.
	while true:
		var newline := _buffer.find(10)
		if newline < 0:
			break
		var line := _buffer.slice(0, newline).get_string_from_utf8()
		_buffer = _buffer.slice(newline + 1)
		_handle_line(line)


func _write_outbox() -> void:
	if _peer == null:
		return
	while not _outbox.is_empty():
		var message: Dictionary = _outbox.front()
		var bytes := (JSON.stringify(message) + "\n").to_utf8_buffer()
		if _peer.put_data(bytes) != OK:
			return
		_outbox.pop_front()


# Messages.


func _handle_line(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return
	var message: Dictionary = parsed
	match str(message.get("t", "")):
		"hello":
			_handle_hello(message)
		"request":
			_send_manifest()
		"manifest":
			_handle_manifest(message)
		"get":
			_send_file(str(message.get("key", "")))
		"file":
			_receive_file(message)
		"done":
			_phase = "done"
			log_line.emit("同步完成")


func _handle_hello(message: Dictionary) -> void:
	if int(message.get("proto", 0)) != PROTOCOL:
		log_line.emit("对方协议版本不同，已断开")
		_drop_peer("")
		return
	if _peer_id.is_empty():
		_peer_id = str(message.get("id", ""))
	_peer_label = str(message.get("label", "?"))
	_remember_peer(_peer_id, _peer_label, "", 0)
	_note_peer("已连接")
	var shared := _shared_folders(message.get("folders", []))
	if shared.is_empty():
		log_line.emit("没有同名的同步文件夹，什么也没做")
		_drop_peer("")
		return
	log_line.emit("已连接 %s · 共同文件夹 %s" % [_peer_label, ", ".join(shared)])
	if _initiator:
		_phase = "manifest"
		_outbox.append({"t": "request"})


func _shared_folders(remote_names: Variant) -> Array[String]:
	var result: Array[String] = []
	if not remote_names is Array:
		return result
	for folder_name: String in folders:
		if (remote_names as Array).has(folder_name):
			result.append(folder_name)
	return result


func _send_manifest() -> void:
	var files: Array = []
	var manifest := _build_manifest()
	for key: String in manifest:
		var entry: Dictionary = manifest[key]
		files.append(
			{"key": key, "mtime": entry["mtime"], "size": entry["size"], "h": entry["h"]}
		)
	_outbox.append({"t": "manifest", "files": files})


func _handle_manifest(message: Dictionary) -> void:
	if not _initiator:
		return
	var remote_names := {}
	var files: Variant = message.get("files", [])
	var remote := {}
	if files is Array:
		for entry: Variant in files:
			if entry is Dictionary:
				remote[str((entry as Dictionary).get("key", ""))] = entry
				remote_names[str((entry as Dictionary).get("key", ""))] = true
	_plan(remote)
	_phase = "transfer"


## Decides what moves. Both sides send a hash, so a file that only changed its
## timestamp is left alone, and the newer one wins when the content differs.
func _plan(remote: Dictionary) -> void:
	var local := _build_manifest()
	_get_queue.clear()
	_expecting = 0
	_received = 0
	for key: String in remote:
		var remote_entry: Dictionary = remote[key]
		if local.has(key):
			var local_entry: Dictionary = local[key]
			if int(local_entry.get("h", 0)) == int(remote_entry.get("h", -1)):
				continue
			if int(remote_entry.get("mtime", 0)) <= int(local_entry.get("mtime", 0)):
				_queue_push(key, local_entry)
				continue
		_get_queue.append(key)
		_expecting += 1
	for key: String in local:
		if not remote.has(key):
			_queue_push(key, local[key])
	for key: String in _get_queue:
		_outbox.append({"t": "get", "key": key})
	if _expecting == 0:
		_outbox.append({"t": "done"})


func _queue_push(key: String, entry: Dictionary) -> void:
	var bytes := _read_file(key)
	if bytes.is_empty():
		return
	_outbox.append(
		{
			"t": "file",
			"key": key,
			"mtime": int(entry.get("mtime", 0)),
			"data": Marshalls.raw_to_base64(bytes),
		}
	)


func _send_file(key: String) -> void:
	var bytes := _read_file(key)
	if bytes.is_empty():
		_outbox.append({"t": "file", "key": key, "data": ""})
		return
	_outbox.append(
		{
			"t": "file",
			"key": key,
			"mtime": FileAccess.get_modified_time(_absolute(key)),
			"data": Marshalls.raw_to_base64(bytes),
		}
	)


func _receive_file(message: Dictionary) -> void:
	var key := str(message.get("key", ""))
	var data := str(message.get("data", ""))
	if key.is_empty() or data.is_empty():
		return
	var bytes := Marshalls.base64_to_raw(data)
	if bytes.size() > MAX_FILE_BYTES:
		log_line.emit("%s 太大，已跳过" % key)
		return
	var path := _absolute(key)
	if path.is_empty():
		return
	var directory := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		log_line.emit("无法写入 %s" % key)
		return
	file.store_buffer(bytes)
	file.close()
	file_synced.emit(path, "in")
	log_line.emit("收到 %s" % key)
	if not _initiator:
		_note_peer("已同步")
		return
	_received += 1
	if _received >= _expecting:
		_outbox.append({"t": "done"})
		_note_peer("已同步")
		log_line.emit("同步完成")


func _note_peer(state: String) -> void:
	if not _peer_id.is_empty() and peers.has(_peer_id):
		peers[_peer_id]["state"] = state
		peers_changed.emit()


# Files.


## Manifest of every file the two peers may talk about, keyed by name/relative path.
func _build_manifest() -> Dictionary:
	var manifest := {}
	for folder_name: String in folders:
		var root := str(folders[folder_name])
		if root.is_empty() or not DirAccess.dir_exists_absolute(root):
			continue
		_scan(root, folder_name, manifest)
	return manifest


func _scan(root: String, folder_name: String, manifest: Dictionary) -> void:
	var pending: Array[String] = [root]
	var seen := 0
	while not pending.is_empty() and seen < MAX_FILES:
		var current: String = pending.pop_back()
		var directory := DirAccess.open(current)
		if directory == null:
			continue
		directory.list_dir_begin()
		var entry := directory.get_next()
		while not entry.is_empty() and seen < MAX_FILES:
			var skip := entry.begins_with(".") or IGNORED_NAMES.has(entry)
			var full := current.path_join(entry)
			var is_dir := directory.current_is_dir()
			if not skip:
				if is_dir:
					pending.append(full)
				else:
					seen += 1
					var relative := full.substr(root.length()).replace("\\", "/").lstrip("/")
					var key := "%s/%s" % [folder_name, relative]
					var size := _size_of(full)
					manifest[key] = {
						"mtime": FileAccess.get_modified_time(full),
						"size": size,
						"h": hash(FileAccess.get_file_as_bytes(full)) if size > 0 else 0,
					}
			entry = directory.get_next()
		directory.list_dir_end()


func _size_of(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := int(file.get_length())
	file.close()
	return size


func _read_file(key: String) -> PackedByteArray:
	var path := _absolute(key)
	if path.is_empty() or not FileAccess.file_exists(path):
		return PackedByteArray()
	if _size_of(path) > MAX_FILE_BYTES:
		log_line.emit("%s 超过大小上限，已跳过" % key)
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


## Turns a manifest key back into a real path. The first segment is the folder
## name, the rest is relative to it, and anything that climbs out is refused.
func _absolute(key: String) -> String:
	var parts := key.replace("\\", "/").split("/", true, 1)
	if parts.size() < 2:
		return ""
	var folder_name := parts[0]
	var relative := parts[1]
	if relative.contains("..") or not folders.has(folder_name):
		return ""
	return str(folders[folder_name]).path_join(relative)
