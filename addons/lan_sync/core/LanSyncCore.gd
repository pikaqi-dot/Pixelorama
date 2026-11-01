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
## A device asked to sync and is waiting for this side to say yes.
signal consent_requested(id: String, peer_label: String, address: String)
## A scan has queued all of its probes.
signal scan_finished()

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
## Bytes read from disk per message. A file of any size moves in these: the whole
## file is never held in memory, so the ceiling is the disk, not the phone.
const CHUNK_BYTES := 262144
## Chunks handed to the socket per frame, which is also what stops a long send
## from freezing the UI of the side doing the sending.
const CHUNKS_PER_FRAME := 4
## How often a finished link asks for another round. A sync is not an event that
## happens once when two devices meet: a file saved ten seconds later has to
## travel too, and asking again is cheaper than reconnecting.
const RESYNC_INTERVAL := 3.0
## Most files read from one folder. A pasted music library is not what this is for.
const MAX_FILES := 4000
const CONFIG_PATH := "user://lan_sync.cfg"
const IGNORED_NAMES := [".godot", ".import", ".git", ".DS_Store", "Thumbs.db"]
## Probes sent per frame while scanning. A /24 is 254 addresses, so the sweep of
## one network is finished in about a tenth of a second without ever blocking.
const SCAN_BATCH := 24
## Networks swept in one scan. A phone has one, a desktop with virtual adapters
## may have six, and probing all of them would only cost time.
const SCAN_MAX_PREFIXES := 4
## A request nobody answers must not hold a connection open forever.
const CONSENT_TIMEOUT := 30.0
## Dial attempts a sweep keeps open at once. Every address of a /24 is tried, but
## only this many sockets exist at a time, so a phone never holds 254 of them.
const SWEEP_WINDOW := 48
## How long one sweep dial may stay unresolved before it is given up on.
const SWEEP_TIMEOUT := 3.0
## How long a single handshake dial may hang before it is called dead. A refused
## connection reports itself; a firewall that drops the packet says nothing at all.
const DIAL_TIMEOUT := 5.0
## How long a silent peer is treated as asleep instead of gone. An Android app in
## the background has its main loop suspended and answers nothing until it comes
## back, so asking it every three seconds would only fill a socket buffer that
## nobody is reading.
const IDLE_SILENCE := 8.0
## A link that fell over is dialed again after this pause, then every retry.
const RECONNECT_DELAY := 1.0
const RECONNECT_RETRY := 3.0

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
## Addresses still to probe, and the label of a hello waiting for an answer.
var _scan_pending: Array[String] = []
var _scan_base_peers := 0
var _consent_at := 0
var _consent_label := ""
var _consent_address := ""
## Addresses a sweep still has to dial, and the dials it is waiting on.
var _sweep_queue: Array[String] = []
var _sweep_sockets: Array[Dictionary] = []
var _scan_active := false
## Where the current link came from, for the peer list: a hello does not carry it.
var _peer_address := ""
var _peer_since := 0
## Counters of the current link, for the status line and the round summary.
var sent_files := 0
var received_files := 0
var _resync_left := 0.0
## What the last report said, so a round that moved nothing stays out of the log.
var _reported_sent := 0
var _reported_received := 0
## Files waiting to be sent, and the one being read right now.
var _send_queue: Array[Dictionary] = []
var _sending: Dictionary = {}
## The file being written on this side.
var _receiving: Dictionary = {}
## Bytes of a message the socket did not take yet.
var _write_left := PackedByteArray()
## When the peer last said anything, and where to dial it again after a loss.
var _peer_last_rx := 0
var _peer_port := 0
var _reconnect_at := 0
var _reconnect_address := ""
var _reconnect_port := 0
var _reconnect_tries := 0
## Whether a manifest was asked for, so either side can start a round.
var _awaiting_manifest := false
## When the application was paused, and how long it was away.
var _paused_at := 0


func _init() -> void:
	device_id = "%s-%s" % [str(Time.get_unix_time_from_system()), str(randi() % 100000)]
	load_config()


func _ready() -> void:
	set_process(false)


## A phone that opens a file picker leaves the application: the main loop stops,
## but the clock does not. Every deadline is shifted by the time it was away, or
## the link would time out and a consent request would die while the person is
## still choosing a folder.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_paused_at = Time.get_ticks_msec()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		if _paused_at > 0:
			_shift_deadlines(Time.get_ticks_msec() - _paused_at)
		_paused_at = 0
		# Back on screen: either the link survived the nap and gets a round right
		# away, or it died while the app was suspended and is dialed again now
		# instead of on some timer.
		if _peer != null:
			request_sync_now()
		elif not _reconnect_address.is_empty():
			_reconnect_at = Time.get_ticks_msec()


func _shift_deadlines(elapsed: int) -> void:
	if elapsed <= 0:
		return
	if _peer_since > 0:
		_peer_since += elapsed
	if _peer_last_rx > 0:
		_peer_last_rx += elapsed
	if _consent_at > 0:
		_consent_at += elapsed
	for id: String in peers:
		var entry: Dictionary = peers[id]
		entry["last_seen"] = int(entry.get("last_seen", 0)) + elapsed


func _process(delta: float) -> void:
	if not running:
		return
	_beacon_left -= delta
	if _beacon_left <= 0.0:
		_beacon_left = BEACON_INTERVAL
		_broadcast()
	_poll_scan()
	_poll_sweep()
	_report_scan()
	_poll_discovery()
	_poll_consent()
	_poll_server()
	# Before _poll_peer, so the chunks appended here leave on this same frame.
	_poll_send()
	_poll_peer()
	_poll_reconnect()
	_poll_resync(delta)
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
	_scan_pending.clear()
	_sweep_queue.clear()
	for attempt: Dictionary in _sweep_sockets:
		var socket: StreamPeerTCP = attempt["socket"]
		socket.disconnect_from_host()
	_sweep_sockets.clear()
	_scan_active = false
	_reconnect_at = 0
	_consent_at = 0
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


## Sweeps the networks this device is on with one small UDP probe per address.
## That is what turns "wait for a beacon" into "go and look": nothing is connected
## to, nothing is left in TIME_WAIT, and whoever answers tells us its TCP port, so
## no port is ever guessed at.
## Sweeps the networks this device is on, two ways at once. The UDP probe finds
## anybody whose replies can reach us; the TCP dial finds anybody we can reach,
## which is the direction a Windows firewall with inbound blocked still allows.
## Only the dial half can find a machine that cannot answer, so both are sent.
func scan() -> void:
	if not running:
		log_line.emit("先点开始，再扫描")
		return
	_scan_pending.clear()
	_sweep_queue.clear()
	_scan_active = true
	_scan_base_peers = peers.size()
	var own := {}
	for entry: Dictionary in local_ipv4_entries():
		own[str(entry["address"])] = true
	for prefix: String in _local_prefixes():
		for host in range(1, 255):
			var address := "%s%d" % [prefix, host]
			# Dialling this very machine would pair it with itself.
			if own.has(address):
				continue
			_scan_pending.append(address)
			_sweep_queue.append(address)
	log_line.emit(
		"正在扫描局域网（%d 个地址：UDP 探测 + TCP %d 直连）…"
		% [_scan_pending.size(), SYNC_PORT]
	)


## The IPv4 addresses this device answers on, for the status line. Somebody has to
## read one of these out loud when the two sides cannot find each other.
func local_addresses() -> String:
	var list: Array[String] = []
	for entry: Dictionary in local_ipv4_entries():
		list.append(str(entry["address"]))
	return ", ".join(list)


## The same addresses with the port attached. "10.52.20.82:45990" is the exact text
## to type on the other device, so it is handed over ready-made instead of being
## assembled from two separate lines by eye.
func local_endpoints() -> String:
	var list: Array[String] = []
	for entry: Dictionary in local_ipv4_entries():
		var text := str(entry["address"])
		if sync_port > 0:
			text += ":%d" % sync_port
		list.append(text)
	return ", ".join(list)


## The one to read out loud: the first address, which is the Wi-Fi whenever the
## system reports one, with the port once the listener is up.
func primary_endpoint() -> String:
	var entries := local_ipv4_entries()
	if entries.is_empty():
		return ""
	var text := str(entries[0]["address"])
	if sync_port > 0:
		text += ":%d" % sync_port
	return text


## Interface by interface, for the log. On a phone the Wi-Fi is "wlan0" and the
## cellular link is "rmnet_data0"; which one is the Wi-Fi is the whole question
## when nothing connects, so the name is kept next to the address.
func local_details() -> String:
	var list: Array[String] = []
	for entry: Dictionary in local_ipv4_entries():
		var nic_name := str(entry["interface"])
		if nic_name.is_empty():
			list.append(str(entry["address"]))
		else:
			list.append("%s %s" % [nic_name, str(entry["address"])])
	return ", ".join(list)


## Every usable IPv4 with the adapter that owns it, most reachable first. This
## asks the interfaces rather than the flat address list because only the
## interface knows which address is the Wi-Fi: a desktop carries a dozen from
## Hyper-V, WSL and tunnels, and those are the ones a phone can never reach.
func local_ipv4_entries() -> Array[Dictionary]:
	var lan: Array[Dictionary] = []
	var other: Array[Dictionary] = []
	var host_only: Array[Dictionary] = []
	var seen: Dictionary = {}
	for nic: Dictionary in IP.get_local_interfaces():
		# Windows puts a GUID in "name" and the readable one in "friendly"; Linux
		# and Android already hand over "wlan0" in "name". The readable name is
		# what says which adapter is the Wi-Fi, so it wins when it is there.
		var nic_name := str(nic.get("friendly", ""))
		if nic_name.is_empty():
			nic_name = str(nic.get("name", ""))
		var nic_key := nic_name.to_lower()
		var addresses: PackedStringArray = nic.get("addresses", PackedStringArray())
		for address: String in addresses:
			var usable := _usable_ipv4(address)
			if usable.is_empty() or seen.has(usable):
				continue
			seen[usable] = true
			var entry := {"address": usable, "interface": nic_name}
			if usable.ends_with(".1"):
				host_only.append(entry)
			elif nic_key.begins_with("wl") or nic_key.begins_with("wifi") \
					or nic_key.begins_with("eth") or nic_key.begins_with("en") \
					or nic_key.begins_with("ap") or nic_key.begins_with("以太"):
				lan.append(entry)
			else:
				other.append(entry)
	# An empty enumeration happens on platforms where the interface list is not
	# wired up; the flat list still answers, it just cannot name the adapter.
	if seen.is_empty():
		for address: String in IP.get_local_addresses():
			var fallback := _usable_ipv4(address)
			if fallback.is_empty() or seen.has(fallback):
				continue
			seen[fallback] = true
			other.append({"address": fallback, "interface": ""})
	var result: Array[Dictionary] = []
	result.append_array(lan)
	result.append_array(other)
	result.append_array(host_only)
	return result


## The address when the LAN could reach it, and an empty string when it could not:
## IPv6, loopback, link local, and the carrier grade NAT a tunnel hands out all
## look like an answer and are none.
func _usable_ipv4(address: String) -> String:
	if address.is_empty() or address.contains(":"):
		return ""
	if address.begins_with("127.") or address.begins_with("169.254."):
		return ""
	var parts := address.split(".")
	if parts.size() != 4:
		return ""
	if int(parts[0]) == 100 and int(parts[1]) >= 64 and int(parts[1]) <= 127:
		return ""
	return address


## Answers the device that asked to sync. Nothing moves until this is called, on
## the side that received the connection.
func answer_consent(agree: bool) -> void:
	if _consent_at == 0 or _peer == null:
		return
	_consent_at = 0
	if agree:
		_outbox.append({"t": "hello_ok"})
		_phase = "manifest"
		_note_peer("已连接")
		log_line.emit("已允许 %s 同步" % _consent_label)
		return
	_outbox.append({"t": "hello_no"})
	_drop_peer("已拒绝 %s" % _consent_label)


## Asks the current link for another round, without waiting for the timer. The
## other side answers with its manifest, so either end can start one.
func request_sync_now() -> void:
	if _peer == null:
		log_line.emit("还没连上：先点「扫描局域网」或「按地址连接」")
		return
	if _phase == "manifest" or _phase == "transfer":
		log_line.emit("正在同步，稍等")
		return
	_outbox.append({"t": "request"})
	_awaiting_manifest = true
	_phase = "manifest"
	log_line.emit("请求同步…")


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
	var bytes := packet.to_utf8_buffer()
	# The limited broadcast address leaves by whichever interface the routing
	# table happens to prefer, and on a machine carrying Hyper-V, WSL and a VPN
	# that is often not the Wi-Fi. Each network's own broadcast address is sent
	# as well, so the beacon is on every wire this device is plugged into.
	for target: String in _broadcast_targets():
		_udp.set_dest_address(target, DISCOVERY_PORT)
		_udp.put_packet(bytes)


func _broadcast_targets() -> Array[String]:
	var targets: Array[String] = ["255.255.255.255"]
	for prefix: String in _local_prefixes():
		var directed := "%s255" % prefix
		if not targets.has(directed):
			targets.append(directed)
	return targets


func _poll_discovery() -> void:
	if not _udp.is_bound():
		return
	while _udp.get_available_packet_count() > 0:
		var data := _udp.get_packet()
		var address := _udp.get_packet_ip()
		var parts := data.get_string_from_utf8().split("|")
		if parts[0] == "LANSYNC?":
			# Somebody is sweeping the network. Answering this one address only
			# keeps a scan as cheap for the swept as it is for the sweeper.
			if parts.size() >= 3 and int(parts[1]) == PROTOCOL and parts[2] != device_id:
				_reply_beacon(address)
			continue
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
		# The socket knows where it came from, and a hello does not: without this
		# the peer list would show a device with no address, which is exactly the
		# thing somebody needs when the connection keeps failing.
		_peer_address = str(incoming.get_connected_host())
		_peer_port = int(incoming.get_connected_port())
		_peer_since = Time.get_ticks_msec()
		_peer_last_rx = Time.get_ticks_msec()
		_reconnect_at = 0
		_initiator = false
		_buffer = PackedByteArray()
		_phase = "accepted"


## Sends this device's beacon to one address, which is how a scan gets answered.
func _reply_beacon(to_address: String) -> void:
	var packet := "LANSYNC|%d|%s|%s|%d" % [
		PROTOCOL, device_id, label.replace("|", " "), sync_port
	]
	_udp.set_dest_address(to_address, DISCOVERY_PORT)
	_udp.put_packet(packet.to_utf8_buffer())


## The networks worth sweeping, best first. A desktop can easily carry half a
## dozen addresses from virtual adapters and VPNs, and sweeping all of them would
## mean thousands of probes for one real network, so the home ranges come first
## and the list is cut short.
func _local_prefixes() -> Array[String]:
	var result: Array[String] = []
	# The order the system hands out is the interface order, which puts the real
	# adapter before the virtual ones, so it is kept rather than re-sorted: on this
	# kind of machine 192.168.x is just as likely to be a Hyper-V switch as a home
	# network.
	for address: String in IP.get_local_addresses():
		if address.begins_with("127.") or address.begins_with("169.254."):
			continue
		var parts := address.split(".")
		if parts.size() != 4:
			continue
		var second := int(parts[1])
		# Carrier grade NAT, which is what a tunnel hands out, is never the LAN.
		if int(parts[0]) == 100 and second >= 64 and second <= 127:
			continue
		var prefix := "%s.%s.%s." % [parts[0], parts[1], parts[2]]
		if not result.has(prefix):
			result.append(prefix)
	if result.size() > SCAN_MAX_PREFIXES:
		result.resize(SCAN_MAX_PREFIXES)
	return result


## One batch of probes per frame, so a sweep never blocks the drawing view.
func _poll_scan() -> void:
	if _scan_pending.is_empty():
		return
	var sent := 0
	while not _scan_pending.is_empty() and sent < SCAN_BATCH:
		if not _udp.is_bound():
			_scan_pending.clear()
			return
		var host: String = _scan_pending.pop_back()
		var packet := "LANSYNC?|%d|%s|%s|%d" % [
			PROTOCOL, device_id, label.replace("|", " "), sync_port
		]
		_udp.set_dest_address(host, DISCOVERY_PORT)
		_udp.put_packet(packet.to_utf8_buffer())
		sent += 1


## Says how a scan ended, once both halves of it are done: the probes and the
## dials finish at different times, and reporting after the first one would
## announce silence while connections are still being attempted.
func _report_scan() -> void:
	if not _scan_active:
		return
	if not _scan_pending.is_empty() or not _sweep_queue.is_empty():
		return
	if not _sweep_sockets.is_empty():
		return
	_scan_active = false
	scan_finished.emit()
	if peers.size() > _scan_base_peers:
		log_line.emit("扫描完成，找到 %d 台设备" % (peers.size() - _scan_base_peers))
		return
	# Silence has one usual cause on a desktop, and saying it here saves the
	# person a long hunt: the system firewall answering for the other side.
	log_line.emit("扫描完成，没有设备回应")
	log_line.emit(
		"若对方是 Windows：它的防火墙要放行入站 UDP %d 与 TCP %d（本机地址 %s）"
		% [DISCOVERY_PORT, SYNC_PORT, local_addresses()]
	)


## One batch of dials per frame, then the dials already open are checked. A dial
## that connects is not thrown away and re-dialed: it becomes the link, so the
## sweep and the handshake are the same connection.
func _poll_sweep() -> void:
	if _sweep_queue.is_empty() and _sweep_sockets.is_empty():
		return
	var now := Time.get_ticks_msec()
	var sent := 0
	while not _sweep_queue.is_empty() \
			and sent < SWEEP_WINDOW - _sweep_sockets.size():
		var address: String = _sweep_queue.pop_back()
		var socket := StreamPeerTCP.new()
		if socket.connect_to_host(address, SYNC_PORT) != OK:
			continue
		_sweep_sockets.append({"socket": socket, "address": address, "started": now})
		sent += 1
	var keep: Array[Dictionary] = []
	for attempt: Dictionary in _sweep_sockets:
		var socket: StreamPeerTCP = attempt["socket"]
		socket.poll()
		var state := socket.get_status()
		if state == StreamPeerTCP.STATUS_CONNECTED:
			if _peer == null:
				_adopt_peer(socket, str(attempt["address"]))
			else:
				socket.disconnect_from_host()
			continue
		if state == StreamPeerTCP.STATUS_ERROR or state == StreamPeerTCP.STATUS_NONE:
			continue
		if now - int(attempt["started"]) > int(SWEEP_TIMEOUT * 1000.0):
			socket.disconnect_from_host()
			continue
		keep.append(attempt)
	_sweep_sockets = keep


## Keeps a finished link alive for later changes. Only the side that dialed asks,
## so two timers never trade manifests across one socket; whoever ended up as the
## responder is asked by the next round anyway.
func _poll_resync(delta: float) -> void:
	if _peer == null or not _initiator:
		return
	if _phase != "done" or _awaiting_manifest:
		return
	# A peer that has said nothing for a while is asleep, not gone: an Android app
	# in the background answers nothing at all, and every request typed into that
	# silence is one more message it has to work through when it wakes up.
	if Time.get_ticks_msec() - _peer_last_rx > int(IDLE_SILENCE * 1000.0):
		return
	_resync_left -= delta
	if _resync_left > 0.0:
		return
	_resync_left = RESYNC_INTERVAL
	_outbox.append({"t": "request"})
	_awaiting_manifest = true
	_phase = "manifest"


## A request nobody answers must not hold a connection open forever.
func _poll_consent() -> void:
	if _consent_at == 0:
		return
	if Time.get_ticks_msec() - _consent_at > int(CONSENT_TIMEOUT * 1000.0):
		_consent_at = 0
		log_line.emit("确认超时，已断开")
		_drop_peer("")


func _open_peer(
	address: String, port: int, id: String, peer_label: String, quiet := false
) -> void:
	_drop_peer("")
	var socket := StreamPeerTCP.new()
	if socket.connect_to_host(address, port) != OK:
		if not quiet:
			log_line.emit("连接 %s:%d 失败" % [address, port])
		return
	_peer = socket
	_peer_id = id
	_peer_label = peer_label
	_peer_address = address
	_peer_port = port
	_peer_since = Time.get_ticks_msec()
	_peer_last_rx = Time.get_ticks_msec()
	_reconnect_at = 0
	_initiator = true
	_buffer = PackedByteArray()
	_phase = "connecting"
	if not quiet:
		log_line.emit("正在连接 %s:%d" % [address, port])


## Takes over a socket a sweep already dialed, so a connection that worked is not
## hung up and tried again through the beacon path.
func _adopt_peer(socket: StreamPeerTCP, address: String) -> void:
	_drop_peer("")
	_peer = socket
	_peer_id = ""
	_peer_label = ""
	_peer_address = address
	_peer_port = SYNC_PORT
	_peer_since = Time.get_ticks_msec()
	_peer_last_rx = Time.get_ticks_msec()
	_reconnect_at = 0
	_initiator = true
	_buffer = PackedByteArray()
	_phase = "connecting"
	log_line.emit("已连上 %s:%d，等待对方确认" % [address, SYNC_PORT])


## A link is dropped, but the address that worked is remembered: a phone that was
## in the background, or a Wi-Fi hiccup, must not end the session for good.
func _link_lost(reason: String) -> void:
	var address := _peer_address
	var port := _peer_port
	# Only a port somebody is listening on is worth dialling. The dialer knows its
	# own target; the side that accepted holds the peer's *ephemeral* port, and the
	# beacon is the only other place that knows the listening one. Dialling a dead
	# port would also hold the slot that a good incoming connection needs.
	var dialable := _initiator
	if peers.has(_peer_id):
		var entry: Dictionary = peers[_peer_id]
		var heard_port := int(entry.get("port", 0))
		var heard_address := str(entry.get("address", ""))
		if heard_port > 0 and not heard_address.is_empty():
			address = heard_address
			port = heard_port
			dialable = true
	if not dialable:
		address = ""
	_drop_peer(reason)
	if address.is_empty() or port <= 0:
		return
	_reconnect_address = address
	_reconnect_port = port
	_reconnect_at = Time.get_ticks_msec() + int(RECONNECT_DELAY * 1000.0)
	log_line.emit("连接断了，%d 秒后重连 %s:%d" % [int(RECONNECT_DELAY), address, port])


## Retries the last working address until it answers again. The beacon cannot be
## relied on here: a peer that is asleep sends nothing, and the point of this is
## that nobody has to press anything.
func _poll_reconnect() -> void:
	if _peer != null or _reconnect_at == 0:
		return
	var now := Time.get_ticks_msec()
	if now < _reconnect_at:
		return
	_reconnect_at = now + int(RECONNECT_RETRY * 1000.0)
	_reconnect_tries += 1
	if _reconnect_tries == 1 or _reconnect_tries % 10 == 0:
		log_line.emit(
			"重连 %s:%d（第 %d 次）" % [_reconnect_address, _reconnect_port, _reconnect_tries]
		)
	_open_peer(_reconnect_address, _reconnect_port, "", "", true)


func _drop_peer(reason: String) -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	_peer_id = ""
	_peer_label = ""
	_peer_address = ""
	_peer_port = 0
	_peer_since = 0
	_peer_last_rx = 0
	_initiator = false
	_phase = ""
	_awaiting_manifest = false
	_resync_left = 0.0
	_consent_at = 0
	_buffer = PackedByteArray()
	_write_left = PackedByteArray()
	_outbox.clear()
	_get_queue.clear()
	_close_transfers()
	_expecting = 0
	_received = 0
	sent_files = 0
	received_files = 0
	_reported_sent = 0
	_reported_received = 0
	if not reason.is_empty():
		log_line.emit(reason)


func _poll_peer() -> void:
	if _peer == null:
		return
	_peer.poll()
	var state := _peer.get_status()
	if state == StreamPeerTCP.STATUS_ERROR or state == StreamPeerTCP.STATUS_NONE:
		_link_lost("连接已断开")
		return
	if state != StreamPeerTCP.STATUS_CONNECTED:
		# A refused connection reports itself at once; one a firewall drops reports
		# nothing at all, so the wait has to end here or the link looks alive for
		# the rest of the session while nothing will ever arrive.
		if Time.get_ticks_msec() - _peer_since > int(DIAL_TIMEOUT * 1000.0):
			_link_lost(
				"连接 %s 超时：对方没有应答，多半是它的防火墙拦了 TCP %d"
				% [_peer_address, SYNC_PORT]
			)
		return
	if _phase == "connecting" or _phase == "accepted":
		_phase = "hello"
		_reconnect_tries = 0
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
		_peer_last_rx = Time.get_ticks_msec()
	# One message per line, so a message split over packets is simply joined.
	while true:
		var newline := _buffer.find(10)
		if newline < 0:
			break
		var line := _buffer.slice(0, newline).get_string_from_utf8()
		_buffer = _buffer.slice(newline + 1)
		_handle_line(line)


## Writes what fits and keeps the rest. put_data() would drop the tail of a
## message the socket could not take in one go, which for a 256 KB chunk means a
## corrupted file nobody notices until the receiver compares the sizes.
func _write_outbox() -> void:
	if _peer == null:
		return
	if not _write_left.is_empty():
		if not _flush_write():
			return
	while not _outbox.is_empty():
		var message: Dictionary = _outbox.front()
		_write_left = (JSON.stringify(message) + "\n").to_utf8_buffer()
		_outbox.pop_front()
		if not _flush_write():
			return


## Pushes the pending bytes into the socket, keeping whatever did not fit.
func _flush_write() -> bool:
	var result: Array = _peer.put_partial_data(_write_left)
	if int(result[0]) != OK:
		return false
	var sent: int = result[1]
	if sent >= _write_left.size():
		_write_left = PackedByteArray()
		return true
	_write_left = _write_left.slice(sent)
	return false


# Messages.


func _handle_line(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return
	var message: Dictionary = parsed
	match str(message.get("t", "")):
		"hello":
			_handle_hello(message)
		"hello_ok":
			_handle_hello_ok()
		"hello_no":
			_handle_hello_no()
		"request":
			_send_manifest()
		"manifest":
			_handle_manifest(message)
		"get":
			_enqueue_file(str(message.get("key", "")))
		"file_begin":
			_handle_file_begin(message)
		"file_chunk":
			_handle_file_chunk(message)
		"file_end":
			_handle_file_end(message)
		"done":
			_phase = "done"
			_resync_left = RESYNC_INTERVAL
			_report_round()


## The other side agreed: from here on this side may ask for the manifest.
func _handle_hello_ok() -> void:
	if not _initiator or _phase != "await_consent":
		return
	_phase = "manifest"
	_awaiting_manifest = true
	_note_peer("已连接")
	log_line.emit("对方已同意，开始同步")
	_outbox.append({"t": "request"})


func _handle_hello_no() -> void:
	log_line.emit("对方拒绝了这次同步")
	_drop_peer("")


func _handle_hello(message: Dictionary) -> void:
	if int(message.get("proto", 0)) != PROTOCOL:
		log_line.emit("对方协议版本不同，已断开")
		_drop_peer("")
		return
	if _peer_id.is_empty():
		_peer_id = str(message.get("id", ""))
	_peer_label = str(message.get("label", "?"))
	_remember_peer(_peer_id, _peer_label, _peer_address, 0)
	_note_peer("已连接")
	var shared := _shared_folders(message.get("folders", []))
	if shared.is_empty():
		log_line.emit("没有同名的同步文件夹，什么也没做")
		_drop_peer("")
		return
	if _initiator:
		# The dialer asks for nothing until the other side has agreed, so a probe
		# of the network never turns into a sync nobody approved.
		_phase = "await_consent"
		_note_peer("等待对方确认")
		log_line.emit("已连上 %s，等待对方确认" % _peer_label)
		return
	_consent_at = Time.get_ticks_msec()
	_consent_label = _peer_label
	_consent_address = str(peers.get(_peer_id, {}).get("address", ""))
	_phase = "consent"
	_note_peer("待确认")
	log_line.emit("%s（%s）请求同步，等待本机同意" % [_peer_label, _consent_address])
	consent_requested.emit(_peer_id, _peer_label, _consent_address)


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
	# Whoever asked for it plans the round, so a look at the peer's list is only
	# answered when one was actually requested.
	if not _awaiting_manifest:
		return
	_awaiting_manifest = false
	var remote_names := {}
	var files: Variant = message.get("files", [])
	var remote := {}
	if files is Array:
		for entry: Variant in files:
			if entry is Dictionary:
				remote[str((entry as Dictionary).get("key", ""))] = entry
				remote_names[str((entry as Dictionary).get("key", ""))] = true
	_plan(remote)
	# Nothing to receive would leave the round parked in "transfer" forever, and
	# the next round would never be asked for: a link that has nothing to do is a
	# finished round, not a hung one.
	if _expecting == 0:
		_phase = "done"
		_resync_left = RESYNC_INTERVAL
		_report_round()
		return
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
			if str(local_entry.get("h", "")) == str(remote_entry.get("h", "-")):
				continue
			if int(remote_entry.get("mtime", 0)) <= int(local_entry.get("mtime", 0)):
				_enqueue_file(key)
				continue
		_get_queue.append(key)
		_expecting += 1
	for key: String in local:
		if not remote.has(key):
			_enqueue_file(key)
	for key: String in _get_queue:
		_outbox.append({"t": "get", "key": key})
	if _expecting == 0:
		_outbox.append({"t": "done"})


## Puts a file on the outgoing list. Nothing is read here: the bytes are taken
## from disk a chunk at a time when the socket is ready for them.
func _enqueue_file(key: String) -> void:
	var path := _absolute(key)
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	for queued: Dictionary in _send_queue:
		if str(queued["key"]) == key:
			return
	_send_queue.append({"key": key, "path": path})


## Reads the next chunks of the file being sent, a few per frame, so a long send
## neither stalls the frame nor fills memory with the whole file.
func _poll_send() -> void:
	if _peer == null:
		return
	# Backpressure: while the socket is still swallowing the last chunk, reading
	# more of the file would only pile the whole thing up in memory again.
	if not _write_left.is_empty() or _outbox.size() > 8:
		return
	var moves := 0
	while moves < CHUNKS_PER_FRAME:
		if _sending.is_empty():
			if _send_queue.is_empty():
				return
			_start_file()
			if _sending.is_empty():
				return
		var handle: FileAccess = _sending["handle"]
		var left: int = int(_sending["size"]) - int(_sending["sent"])
		if left <= 0:
			_finish_file()
			moves += 1
			continue
		var bytes := handle.get_buffer(mini(CHUNK_BYTES, left))
		if bytes.is_empty():
			_finish_file()
			moves += 1
			continue
		_sending["sent"] = int(_sending["sent"]) + bytes.size()
		_outbox.append(
			{
				"t": "file_chunk",
				"key": _sending["key"],
				"data": Marshalls.raw_to_base64(bytes),
			}
		)
		moves += 1


func _start_file() -> void:
	var queued: Dictionary = _send_queue.pop_front()
	var handle := FileAccess.open(str(queued["path"]), FileAccess.READ)
	if handle == null:
		return
	var size := int(handle.get_length())
	_sending = {
		"key": str(queued["key"]),
		"handle": handle,
		"size": size,
		"sent": 0,
	}
	_outbox.append(
		{"t": "file_begin", "key": str(queued["key"]), "size": size}
	)
	log_line.emit("发送 %s（%s）" % [str(queued["key"]), _size_text(size)])


func _finish_file() -> void:
	if _sending.is_empty():
		return
	var handle: FileAccess = _sending["handle"]
	handle.close()
	_outbox.append({"t": "file_end", "key": _sending["key"]})
	sent_files += 1
	_sending = {}


func _handle_file_begin(message: Dictionary) -> void:
	var key := str(message.get("key", ""))
	var path := _absolute(key)
	if path.is_empty():
		return
	var directory := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle == null:
		# The rest of the file is still read and dropped, so the sender is never
		# left pushing into a socket nobody is draining.
		log_line.emit("无法写入 %s" % key)
	_receiving = {
		"key": key,
		"path": path,
		"handle": handle,
		"size": int(message.get("size", 0)),
		"written": 0,
	}


func _handle_file_chunk(message: Dictionary) -> void:
	if _receiving.is_empty():
		return
	if str(message.get("key", "")) != str(_receiving["key"]):
		return
	var bytes := Marshalls.base64_to_raw(str(message.get("data", "")))
	var handle: FileAccess = _receiving["handle"]
	if handle != null:
		handle.store_buffer(bytes)
	_receiving["written"] = int(_receiving["written"]) + bytes.size()


func _handle_file_end(message: Dictionary) -> void:
	if _receiving.is_empty():
		return
	var key := str(_receiving["key"])
	var path := str(_receiving["path"])
	var handle: FileAccess = _receiving["handle"]
	var written := int(_receiving["written"])
	var declared := int(_receiving["size"])
	_receiving = {}
	if handle == null:
		return
	handle.close()
	if written != declared:
		log_line.emit("%s 没有收全（%d/%d 字节）" % [key, written, declared])
		return
	file_synced.emit(path, "in")
	received_files += 1
	log_line.emit("收到 %s（%s）" % [key, _size_text(written)])
	# Counting only matters on the side that planned the round; the other side is
	# answering, and for it every arriving file is simply good news.
	if _phase != "transfer":
		_note_peer("已同步")
		return
	_received += 1
	if _received >= _expecting:
		_outbox.append({"t": "done"})
		_phase = "done"
		_resync_left = RESYNC_INTERVAL
		_note_peer("已同步")
		_report_round()


## A link can die with a file half read. Both handles are closed here, or the
## next round would write into the file the previous one still had open.
func _close_transfers() -> void:
	if not _sending.is_empty():
		var out_handle: FileAccess = _sending["handle"]
		out_handle.close()
		_sending = {}
	if not _receiving.is_empty():
		var in_handle: FileAccess = _receiving["handle"]
		if in_handle != null:
			in_handle.close()
		_receiving = {}
	_send_queue.clear()


func _size_text(bytes: int) -> String:
	if bytes < 1048576:
		return "%.1f KB" % (float(bytes) / 1024.0)
	return "%.2f MB" % (float(bytes) / 1048576.0)


## A round that moved nothing is the normal case once two devices agree, and
## saying so every three seconds would bury the lines that matter.
func _report_round() -> void:
	if sent_files == _reported_sent and received_files == _reported_received:
		return
	_reported_sent = sent_files
	_reported_received = received_files
	log_line.emit("同步完成：发出 %d 个，收到 %d 个" % [sent_files, received_files])


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
						"h": _file_hash(full),
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


## The content hash, read in blocks and folded as it goes. Loading a file to
## compare it would put a copy of it in memory on both machines, which is the
## one thing a file sync must never do.
func _file_hash(path: String) -> String:
	var handle := FileAccess.open(path, FileAccess.READ)
	if handle == null:
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var size := int(handle.get_length())
	var read := 0
	while read < size:
		var chunk := handle.get_buffer(mini(CHUNK_BYTES, size - read))
		if chunk.is_empty():
			break
		context.update(chunk)
		read += chunk.size()
	handle.close()
	return context.finish().hex_encode()


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
