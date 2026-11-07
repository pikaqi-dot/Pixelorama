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
## A scan has queued all of its probes.
signal scan_finished()
## The other side's manifest arrived: the list of what it has to offer.
signal peer_files_changed()

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
## How long a pull may go without hearing anything before it is abandoned. The
## link is kept, because the other side is probably asleep; only the half finished
## pull is dropped, so the next press of the button starts clean.
const TRANSFER_SILENCE := 15.0
## How long a computed hash is trusted. A round runs every three seconds, and
## re-reading every file that often is the one cost worth avoiding — but a
## filesystem timestamp only has one second of resolution, so the cache expires
## instead of being trusted forever.
const HASH_CACHE_TTL := 10.0
## How long to wait before asking the other side for a fresh list once a round has
## moved files: both sides write, and the list has to describe the end of that.
const RELIST_DELAY := 0.6
## Most files read from one folder. A pasted music library is not what this is for.
const MAX_FILES := 4000
const CONFIG_PATH := "user://lan_sync.cfg"
const IGNORED_NAMES := [".godot", ".import", ".git", ".DS_Store", "Thumbs.db"]
## Probes sent per frame while scanning. A /24 is 254 addresses, so the sweep of
## one network is finished in a handful of frames without ever blocking.
const SCAN_BATCH := 64
## Networks swept in one scan. A phone has one, a desktop with virtual adapters
## may have six, and probing all of them would only cost time.
const SCAN_MAX_PREFIXES := 4
## Virtual networks swept only after the real ones came back empty. Two is what
## keeps the worst case — a peer that is nowhere — as short as one ordinary scan.
const SCAN_FALLBACK_MAX := 2
## Dial attempts a sweep keeps open at once. Every address of a /24 is tried, but
## only this many sockets exist at a time, and the sweep cannot finish before the
## last of them does, so this is what decides how long a scan takes: a /24 is two
## rounds of 128 instead of three rounds of 96.
const SWEEP_WINDOW := 128
## How long one sweep dial may stay unresolved before it is given up on. A host
## that answers does so in single-digit milliseconds and a host with the port
## closed refuses at once, so this is only ever spent on addresses where nothing
## is plugged in; 1.5 seconds finds every real machine and stops paying for the
## empty rest of the subnet sooner.
const SWEEP_TIMEOUT := 1.5
## How long a single handshake dial may hang before it is called dead. A refused
## connection reports itself; a firewall that drops the packet says nothing at all.
const DIAL_TIMEOUT := 5.0
## How long a connected socket may stay silent before it is called "not one of
## us". Routers, printers and NAS boxes accept a connection on any port, and a
## real peer answers the hello in milliseconds, so nothing honest takes this long.
const HANDSHAKE_TIMEOUT := 4.0
## How long an address that accepted a connection without answering the hello is
## left alone. Long enough that a scan is not wasted redialling it, short enough
## that a phone which was asleep — the usual reason — is dialled again soon.
const DEAD_DIAL_TTL := 20.0
## How long to wait for the other side's file list before asking again, and how
## many times. A list that never arrives leaves the panel empty with no
## explanation, which reads exactly like "connected, and it has no files".
const MANIFEST_RETRY := 4.0
const MANIFEST_RETRIES := 2
## A pull waits on the other side hashing every file before it can answer, so
## silence there is work, not a fault. This is when the log says so, once.
const MANIFEST_QUIET_HINT := 8.0
## How long a silent peer is treated as asleep instead of gone. An Android app in
## the background has its main loop suspended and answers nothing until it comes
## back, so asking it every three seconds would only fill a socket buffer that
## nobody is reading.
const IDLE_SILENCE := 8.0
## A link that fell over is dialed again after this pause, then every retry.
const RECONNECT_DELAY := 1.0
const RECONNECT_RETRY := 3.0
## Dials at the remembered address before the network is swept as well. The same
## network usually answers on the first try; a phone that hopped to another Wi-Fi
## only answers a sweep, and dialling a dead address forever would never find it.
const RECONNECT_SCAN_AFTER := 3

## How one file of the shared folders compares between the two sides. The panels
## turn these into a tick and exclamation marks; the numbers are what they switch
## on, so the two of them cannot disagree.
enum FileState {
	## Both sides have it, same modification time: a sync would do nothing.
	SAME,
	## Both sides have it, the other side's copy is newer.
	REMOTE_NEWER,
	## Both sides have it, this side's copy is newer — a pull would overwrite it.
	REMOTE_OLDER,
	## Only the other side has it; a sync would create it here.
	REMOTE_ONLY,
	## Only this side has it; the other side never sees it.
	LOCAL_ONLY,
}

## Folder name to absolute path. The name is what the two peers match on.
var folders: Dictionary = {}
## What this peer calls itself in the other side's list.
var label := "Pixelorama"
var device_id := ""
var running := false
var sync_port := 0

## id -> {label, address, port, state, last_seen}
var peers: Dictionary = {}
## The file keys the other side last reported, for the panel's file list.
var peer_files: Array[String] = []
## The same list with what came alongside each key: {key, mtime, size, h}. The
## panel shows the timestamp, and the timestamp is also what decides whether a
## file is worth overwriting at all.
var peer_entries: Array[Dictionary] = []
## Keys a pull is narrowed to. Empty means "everything on the other side".
var _pull_keys: Array[String] = []
## This side's files, key -> {mtime, size}. Timestamps only: the panel needs to
## know what is newer, not what the bytes are, and hashing is the expensive part.
var local_entries: Dictionary = {}
## Seconds until the marks are checked again, and how long that check took.
var _marks_left := 0.0
var _marks_cost := 0
## Keys whose two copies are known to hold the same bytes even though their
## timestamps differ: a sync just moved one of them, and writing a file stamps it
## with the current time, so a pair a sync has just made equal can never show two
## equal timestamps again. key -> {h, mtime, size, pending}; valid only while this
## side's own file is untouched, `pending` meaning the other side has not been
## re-asked since and the bytes are believed to be the ones that were just moved.
var _known_same: Dictionary = {}
## Whether the other side's list should be asked for again once a transfer is over,
## and how long to wait first.
var _relist_wanted := false
var _relist_left := 0.0

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
## How many times a peer was heard while the current sweep was running. A peer
## that was already known still counts: it answered.
var _scan_hits := 0
## When the sweep began, so the report can say how long it took.
var _scan_started := 0
## Addresses a sweep still has to dial, and the dials it is waiting on.
var _sweep_queue: Array[String] = []
var _sweep_sockets: Array[Dictionary] = []
## Addresses known to listen on something other than the default port. A second
## copy of the application on one machine takes the next free port, and dialling
## only the default would never find it.
var _sweep_ports: Dictionary = {}
## Networks held back for the second round of a sweep, see [_fallback_prefixes].
var _scan_fallback: Array[String] = []
## This machine's own addresses, so a sweep never dials itself.
var _scan_own: Dictionary = {}
## Addresses a sweep already found to be "accepts a connection, is not a peer",
## so the same subnet is not dialled to them twice in one scan.
var _dead_dials: Dictionary = {}
var _scan_active := false
## Where the current link came from, for the peer list: a hello does not carry it.
var _peer_address := ""
var _peer_since := 0
## Counters of the current link, for the status line and the round summary.
var sent_files := 0
var received_files := 0
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
## The address and port the other side is actually listening on, remembered for
## the life of the session. Unlike the live socket's address this survives a
## dropped link, and unlike the accepted side's view it is a port worth dialling,
## so coming back from the background can go straight at it.
var _link_address := ""
var _link_port := 0
var _reconnect_at := 0
var _reconnect_address := ""
var _reconnect_port := 0
var _reconnect_tries := 0
## Dials since the link was last up. A phone that changed networks will never
## reach the old address again, so after a few misses the network is swept as
## well, which is the only thing that finds a peer on a new subnet.
var _reconnect_failures := 0
## path -> {size, mtime, hash, checked}. Rounds run every three seconds; reading
## every file that often would make an idle link cost as much as a busy one.
var _hash_cache: Dictionary = {}
## How many files each side offered in the last round, and whether a person asked
## for it — a round somebody asked for has to say what came of it, even "nothing".
var _local_file_count := 0
var _peer_file_count := 0
var _skipped_files := 0
var _manual_round := false
## Whether this side planned the round, and so knows both sides' file counts. The
## side that only answered does not, and must not report zeros as facts.
var _has_plan := false
## When the list was last asked for, and how many times it has been asked for
## again since, so silence from the other side becomes a line in the log.
var _manifest_since := 0
var _manifest_retries := 0
var _manifest_hinted := false
## Whether a manifest was asked for, and whether it was asked for in order to
## pull: a pull overwrites, it does not negotiate which copy is newer.
var _awaiting_manifest := false
var _pulling := false
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
		# Back on screen: dial the address that worked last time, right now, rather
		# than on some timer. That address is tried before anything else — a sweep
		# of the whole subnet is the fallback, not the first move. A phone that
		# changed networks cannot reach the old address, so a sweep is scheduled as
		# well once dialling has missed a few times. Nothing is pulled here:
		# pulling is the person's decision, not a side effect of switching apps.
		if _peer == null:
			if not _link_address.is_empty() and _link_port > 0:
				_reconnect_address = _link_address
				_reconnect_port = _link_port
				_reconnect_tries = 0
				_reconnect_at = Time.get_ticks_msec()
			if _reconnect_failures >= RECONNECT_SCAN_AFTER:
				_reconnect_failures = 0
				scan()


func _shift_deadlines(elapsed: int) -> void:
	if elapsed <= 0:
		return
	if _peer_since > 0:
		_peer_since += elapsed
	if _peer_last_rx > 0:
		_peer_last_rx += elapsed
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
	_poll_server()
	# Before _poll_peer, so the chunks appended here leave on this same frame.
	_poll_send()
	_poll_peer()
	_poll_manifest_wait()
	_poll_reconnect()
	_poll_watchdog()
	_poll_timeouts()
	_poll_marks(delta)
	_poll_relist(delta)


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
	_scan_fallback.clear()
	for attempt: Dictionary in _sweep_sockets:
		var socket: StreamPeerTCP = attempt["socket"]
		socket.disconnect_from_host()
	_sweep_sockets.clear()
	_sweep_ports.clear()
	if _dead_dials != null:
		_dead_dials.clear()
	_scan_active = false
	_reconnect_at = 0
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
	# Rebuilt rather than assumed, for the same reason as in [_poll_sweep].
	if _scan_fallback == null:
		_scan_fallback = []
	if _scan_own == null:
		_scan_own = {}
	if _dead_dials == null:
		_dead_dials = {}
	_scan_pending.clear()
	_sweep_queue.clear()
	_scan_fallback.clear()
	_scan_active = true
	_scan_hits = 0
	_scan_started = Time.get_ticks_msec()
	# Pressing scan again while a sweep is still running must not leave the old
	# dials holding the whole window: they point at addresses nobody answers and
	# would each sit there until their timeout, which is most of a scan's cost.
	for attempt: Dictionary in _sweep_sockets:
		var pending_socket: StreamPeerTCP = attempt["socket"]
		pending_socket.disconnect_from_host()
	_sweep_sockets.clear()
	_sweep_ports.clear()
	if not _link_address.is_empty() and _link_port > 0:
		_sweep_ports[_link_address] = _link_port
	# Broadcast first. Every peer on the network answers a broadcast probe at once,
	# so on a healthy network the list fills before the address-by-address dials
	# have even started. The sweep below is for the networks where UDP is blocked.
	_probe_broadcast()
	_scan_own.clear()
	for entry: Dictionary in local_ipv4_entries():
		_scan_own[str(entry["address"])] = true
	# The networks this device really sits on are dialled first and the virtual
	# adapters a desktop carries — Hyper-V, WSL, VPN tunnels — only if those came
	# back empty. Sweeping both at once doubled the work and, worse, let the host
	# of a virtual switch answer on the sync port and be adopted as the peer.
	var primary := _local_prefixes()
	_scan_fallback = _fallback_prefixes(primary)
	_queue_scan_phase(primary)
	if _sweep_queue.is_empty() and not _scan_fallback.is_empty():
		_queue_scan_phase(_scan_fallback)
		_scan_fallback.clear()
	log_line.emit(
		"正在扫描局域网（%d 个地址：UDP 探测 + TCP %d 直连）…"
		% [_scan_pending.size(), SYNC_PORT]
	)


## Adds one group of networks to the sweep. This machine's own addresses are
## skipped: dialling one of them would pair the application with itself.
func _queue_scan_phase(prefixes: Array[String]) -> void:
	for prefix: String in prefixes:
		for host in range(1, 255):
			var address := "%s%d" % [prefix, host]
			if _scan_own.has(address):
				continue
			_scan_pending.append(address)
			_sweep_queue.append(address)


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


## One line for the panel: what the link is doing at this moment. A list of peers
## says who is nearby; only this says whether anything is connected.
func link_text() -> String:
	if not running:
		return "未开始"
	if _peer != null:
		var who := _peer_label if not _peer_label.is_empty() else "对方"
		var where := _peer_address if not _peer_address.is_empty() else "?"
		match _phase:
			"connecting", "hello":
				return "正在连接 %s（%s）…" % [who, where]
			"manifest":
				return "已连接 %s（%s）· 正在核对清单" % [who, where]
			"transfer":
				return "已连接 %s（%s）· 正在传输" % [who, where]
			_:
				return "已连接 %s（%s）" % [who, where]
	if _reconnect_at > 0:
		return "已断开，重连中（%s:%d）" % [_reconnect_address, _reconnect_port]
	if not peers.is_empty():
		return "发现 %d 台设备，正在自动连接…" % peers.size()
	return "等待设备…"


## Pulls the other side's folder into this one, overwriting local files that
## differ. Nothing happens by itself: a sync is something a person asks for, and
## which side asks decides which way the files go.
func request_sync_now() -> void:
	if _peer == null:
		log_line.emit("还没连上：先点「扫描」或「按地址连接」")
		return
	if _phase == "manifest" or _phase == "transfer":
		log_line.emit("正在同步，稍等")
		return
	if _phase == "connecting" or _phase == "hello" or _phase == "await_consent" \
			or _phase == "consent":
		log_line.emit("还没连上，稍后再点")
		return
	_pull_keys.clear()
	_outbox.append({"t": "pull"})
	_awaiting_manifest = true
	_manifest_since = Time.get_ticks_msec()
	_manifest_retries = 0
	_manifest_hinted = false
	_pulling = true
	_manual_round = true
	_phase = "manifest"
	log_line.emit("开始拉取对方的文件…")


## Pulls exactly one file, by the key the panel shows. It runs over the same
## channel as a full sync, narrowed to one key, so a single .pxo can be replaced
## without touching anything else. A click on one file is a deliberate choice, so
## this is also the one case where an equal timestamp does not block the copy.
func request_file(key: String) -> void:
	if key.is_empty():
		return
	if _peer == null:
		log_line.emit("还没连上：先点「扫描」或「按地址连接」")
		return
	if _phase == "manifest" or _phase == "transfer":
		log_line.emit("正在同步，稍等")
		return
	_pull_keys = [key]
	_outbox.append({"t": "pull"})
	_awaiting_manifest = true
	_manifest_since = Time.get_ticks_msec()
	_manifest_retries = 0
	_manifest_hinted = false
	_pulling = true
	_manual_round = true
	_phase = "manifest"
	log_line.emit("准备同步 %s…" % key)


## Asks for the other side's file list without taking anything. Called once a link
## comes up, so the panel can show what is on offer before anybody pulls.
func list_peer_files() -> void:
	if _peer == null or _awaiting_manifest:
		return
	if _phase == "manifest" or _phase == "transfer":
		return
	_outbox.append({"t": "list"})
	_awaiting_manifest = true
	_manifest_since = Time.get_ticks_msec()
	_manifest_retries = 0
	_manifest_hinted = false
	_pulling = false
	_phase = "manifest"


## Rough file count of a folder, capped: enough to tell "this folder is empty"
## from "this folder is not" in the panel, not a full inventory.
func count_files(path: String) -> int:
	var total := 0
	var pending: Array[String] = [path]
	while not pending.is_empty() and total < 1000:
		var current: String = pending.pop_back()
		var directory := DirAccess.open(current)
		if directory == null:
			continue
		directory.list_dir_begin()
		var entry := directory.get_next()
		while not entry.is_empty():
			if not entry.begins_with(".") and not IGNORED_NAMES.has(entry):
				if directory.current_is_dir():
					pending.append(current.path_join(entry))
				else:
					total += 1
			entry = directory.get_next()
		directory.list_dir_end()
	return total


## Every file of every shared folder with just its timestamp and size. No hashing:
## the panel only needs to know what is newer, and this runs whenever the list is
## redrawn.
func refresh_local_entries() -> void:
	var started := Time.get_ticks_msec()
	local_entries.clear()
	for folder_name: String in folders:
		var root := str(folders[folder_name])
		if root.is_empty() or not DirAccess.dir_exists_absolute(real_path(root)):
			continue
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
				if not skip:
					if directory.current_is_dir():
						pending.append(full)
					else:
						seen += 1
						var relative := full.substr(root.length()).replace("\\", "/").lstrip("/")
						local_entries["%s/%s" % [folder_name, relative]] = {
							"mtime": FileAccess.get_modified_time(full),
							"size": _size_of(full),
						}
				entry = directory.get_next()
			directory.list_dir_end()
	_marks_cost = Time.get_ticks_msec() - started


## The button behind "refresh": read this side's timestamps again and ask the other
## side for a fresh list. Nothing is transferred, so it is always safe to press.
##
## The local half comes first — half of every mark is this side's own timestamps,
## and those change without a single byte arriving (saving in Pixelorama). The
## remote half is the other side's list, which is only re-sent when it is asked for.
## Every press says which of the two it got to, so a press never looks like nothing.
func refresh_file_list() -> void:
	refresh_local_entries()
	peer_files_changed.emit()
	var count := local_entries.size()
	if _peer == null:
		log_line.emit("还没连上：只重读了本机这 %d 个文件的时间戳" % count)
		return
	if _awaiting_manifest or _phase == "manifest" or _phase == "transfer":
		log_line.emit("本机 %d 个文件已重读；对方的清单正在路上，回来就显示" % count)
		return
	list_peer_files()
	log_line.emit("本机 %d 个文件已重读；正在向对方要最新清单…" % count)


## One row per file of either side, sorted, each with a [enum FileState] saying how
## the two copies compare. This is what the file lists draw.
func compare_entries() -> Array[Dictionary]:
	refresh_local_entries()
	# Read again is also the moment to forget "these are the bytes a sync moved":
	# a file that has been saved since is not those bytes any more, and a record
	# kept alive would keep the row green through any number of refreshes.
	_prune_known_same()
	var remote_keys := {}
	var rows: Array[Dictionary] = []
	for entry: Dictionary in peer_entries:
		var key := str(entry.get("key", ""))
		if key.is_empty():
			continue
		remote_keys[key] = true
		rows.append(_row_for(key, int(entry.get("mtime", 0)), str(entry.get("h", ""))))
	for key: String in local_entries:
		if remote_keys.has(key):
			continue
		rows.append(_row_for(key, -1, ""))
	rows.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return str(a["key"]) < str(b["key"])
	)
	return rows


## One row of [method compare_entries]. A negative [param remote_mtime] means the
## other side does not have the file at all.
##
## Equal timestamps are the cheap case and the usual one, but they cannot cover a
## pair a sync has just made identical: writing the file stamps it with "now", so
## the two timestamps stay apart for ever. That is what [member _known_same] is
## for, and the hash it remembers is what keeps it honest.
func _row_for(key: String, remote_mtime: int, remote_hash: String) -> Dictionary:
	var row := {
		"key": key,
		"remote_mtime": remote_mtime,
		"local_mtime": -1,
		"state": FileState.REMOTE_ONLY,
	}
	if not local_entries.has(key):
		return row
	var local: Dictionary = local_entries[key]
	var local_mtime := int(local.get("mtime", 0))
	row["local_mtime"] = local_mtime
	if remote_mtime < 0:
		row["state"] = FileState.LOCAL_ONLY
		return row
	if local_mtime == remote_mtime:
		row["state"] = FileState.SAME
		return row
	if _known_same_holds(key, local, remote_hash):
		row["state"] = FileState.SAME
	elif remote_mtime > local_mtime:
		row["state"] = FileState.REMOTE_NEWER
	else:
		row["state"] = FileState.REMOTE_OLDER
	return row


## Whether this key is one a sync has just made identical. The record only counts
## while this side's file is still the one that was written — same timestamp, same
## size — and while the other side either has not been asked since ([code]pending[/code])
## or still reports the very hash that was moved.
func _known_same_holds(key: String, local: Dictionary, remote_hash: String) -> bool:
	var known: Variant = _known_same.get(key)
	if not known is Dictionary:
		return false
	var record: Dictionary = known
	if int(record.get("mtime", -1)) != int(local.get("mtime", -2)):
		return false
	if int(record.get("size", -1)) != int(local.get("size", -2)):
		return false
	if bool(record.get("pending", false)):
		return true
	return not remote_hash.is_empty() and remote_hash == str(record.get("h", ""))


## Notes that both copies now hold the same bytes, so the row can show a tick
## without waiting for two timestamps to agree — they never will.
func _remember_same(key: String, path: String) -> void:
	if key.is_empty() or path.is_empty():
		return
	if not FileAccess.file_exists(path):
		return
	var described := _describe_file(path)
	_known_same[key] = {
		"h": str(described.get("h", "")),
		"mtime": int(described.get("mtime", 0)),
		"size": int(described.get("size", 0)),
		"pending": true,
	}


## A fresh list from the other side either confirms "these two copies are those
## bytes" or shows that they are not any more, and the record has to follow: it is
## the only thing standing between a just-synced pair and a row that stays red.
func _reconcile_known_same(remote: Dictionary) -> void:
	if _known_same.is_empty():
		return
	var stale: Array[String] = []
	for key: String in _known_same:
		if not remote.has(key):
			stale.append(key)
			continue
		var entry: Variant = remote[key]
		var hash := ""
		if entry is Dictionary:
			hash = str((entry as Dictionary).get("h", ""))
		if not hash.is_empty() and hash == str(_known_same[key].get("h", "")):
			_known_same[key]["pending"] = false
		else:
			stale.append(key)
	for key: String in stale:
		_known_same.erase(key)


## Drops the records this side's own folder has moved on from. Reading the folder
## again is the cheapest moment to do it, and doing it here is what makes 「刷新」
## honest straight away instead of up to half a minute later: a file saved since
## the sync is no longer the bytes that were moved, whatever the other side says.
func _prune_known_same() -> void:
	if _known_same.is_empty():
		return
	var stale: Array[String] = []
	for key: String in _known_same:
		var local: Variant = local_entries.get(key)
		if not local is Dictionary:
			stale.append(key)
			continue
		var record: Dictionary = _known_same[key]
		var entry: Dictionary = local
		if int(record.get("mtime", -1)) != int(entry.get("mtime", -2)):
			stale.append(key)
			continue
		if int(record.get("size", -1)) != int(entry.get("size", -2)):
			stale.append(key)
	for key: String in stale:
		_known_same.erase(key)


func set_folder(folder_name: String, path: String) -> void:
	folders[folder_name] = path
	# Hashes are keyed by absolute path, and the folders just changed.
	_hash_cache.clear()
	_known_same.clear()
	save_config()


func remove_folder(folder_name: String) -> void:
	folders.erase(folder_name)
	_hash_cache.clear()
	_known_same.clear()
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
	var primary := _local_prefixes()
	for prefix: String in primary:
		var directed := "%s255" % prefix
		if not targets.has(directed):
			targets.append(directed)
	# No peer ever sits behind a virtual switch, but one extra packet costs nothing
	# and missing a network that does have one costs the whole scan.
	for prefix: String in _fallback_prefixes(primary):
		var fallback_target := "%s255" % prefix
		if not targets.has(fallback_target):
			targets.append(fallback_target)
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
	# Anything heard during a sweep is an answer to it, whether or not the peer was
	# already in the list.
	if _scan_active:
		_scan_hits += 1
	if not address.is_empty():
		entry["address"] = address
		# A device that said its name is a peer again, whatever a sweep made of
		# the socket it once accepted and never answered on. The dictionary is
		# rebuilt when it is missing: a script edited while the editor is running
		# leaves the instances created before that edit with the new members
		# unset, and null answers nothing at all.
		if _dead_dials == null:
			_dead_dials = {}
		_dead_dials.erase(address)
	if port > 0:
		entry["port"] = port
	# A beacon is the only word on which port the peer listens on, and it keeps
	# arriving while the link is up. Keeping it here means a drop — or a phone
	# waking up on a different address — always has somewhere to dial.
	if id == _peer_id and port > 0 and not address.is_empty():
		_link_address = address
		_link_port = port
	if added:
		peers_changed.emit()
		log_line.emit("发现 %s（%s）" % [peer_label, address])


## Keeps the marks honest: a file edited while the list is open has to turn its
## tick into an exclamation without anybody pressing anything. Only the keys
## already listed are re-checked — one stat per file, not a walk of the folders —
## and the pause between checks grows with the folder and with how long the last
## full read took.
func _poll_marks(delta: float) -> void:
	if _peer == null:
		return
	_marks_left -= delta
	if _marks_left > 0.0:
		return
	_marks_left = clampf(
		2.0 + float(local_entries.size()) / 400.0 + float(_marks_cost) / 200.0, 2.0, 30.0
	)
	if _refresh_known_mtimes():
		peer_files_changed.emit()


## Re-reads the timestamp and size of every known local file. True when one of them
## moved, which is the panels' cue to redraw.
func _refresh_known_mtimes() -> bool:
	var changed := false
	var gone: Array[String] = []
	for key: String in local_entries:
		var path := _absolute(key)
		if path.is_empty():
			continue
		var mtime := FileAccess.get_modified_time(path)
		if mtime <= 0:
			# Deleted, or its folder went away: it is no longer part of this side,
			# and the row has to say so.
			gone.append(key)
			continue
		var size := _size_of(path)
		var entry: Dictionary = local_entries[key]
		if int(entry.get("mtime", 0)) != mtime or int(entry.get("size", -1)) != size:
			entry["mtime"] = mtime
			entry["size"] = size
			# Edited here, so whatever a sync left behind is no longer these bytes.
			_known_same.erase(key)
			changed = true
	for key: String in gone:
		local_entries.erase(key)
		_known_same.erase(key)
		changed = true
	return changed


## A round that moved something leaves the other side's list wrong in exactly the
## details the marks are made of — a file it now has, a timestamp it no longer
## uses — so one fresh list is asked for shortly after the round instead of leaving
## the panel describing the moment before it.
func _queue_relist() -> void:
	_relist_wanted = true
	_relist_left = RELIST_DELAY


func _poll_relist(delta: float) -> void:
	if not _relist_wanted:
		return
	_relist_left -= delta
	if _relist_left > 0.0:
		return
	if _peer == null:
		_relist_wanted = false
		return
	if _awaiting_manifest or _phase == "manifest":
		# A list is already on its way, which is what this was going to ask for.
		_relist_wanted = false
		return
	if _phase == "transfer":
		# The peer is still writing files, so its list would be about a folder it
		# is in the middle of changing.
		_relist_left = RELIST_DELAY
		return
	_relist_wanted = false
	list_peer_files()
	refresh_local_entries()
	peer_files_changed.emit()


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


## Asks every peer on every attached network to answer, in one packet per network
## instead of 254. This is the difference between a scan that finds the other side
## in under a second and one that waits for the next scheduled beacon.
func _probe_broadcast() -> void:
	if not _udp.is_bound():
		return
	var packet := "LANSYNC?|%d|%s|%s|%d" % [
		PROTOCOL, device_id, label.replace("|", " "), sync_port
	]
	var bytes := packet.to_utf8_buffer()
	for target: String in _broadcast_targets():
		_udp.set_dest_address(target, DISCOVERY_PORT)
		_udp.put_packet(bytes)


## Sends this device's beacon to one address, which is how a scan gets answered.
func _reply_beacon(to_address: String) -> void:
	var packet := "LANSYNC|%d|%s|%s|%d" % [
		PROTOCOL, device_id, label.replace("|", " "), sync_port
	]
	_udp.set_dest_address(to_address, DISCOVERY_PORT)
	_udp.put_packet(packet.to_utf8_buffer())


## The networks worth sweeping first, best first. A desktop can easily carry half a
## dozen addresses from virtual adapters and VPNs, and sweeping all of them would
## mean thousands of probes for one real network, so the real ones come first and
## the list is cut short. The rest go to [_fallback_prefixes] for a second round.
func _local_prefixes() -> Array[String]:
	var primary: Array[String] = []
	for entry: Dictionary in local_ipv4_entries():
		var address := str(entry.get("address", ""))
		var prefix := _prefix_of(address)
		if prefix.is_empty() or primary.has(prefix):
			continue
		var parts := address.split(".")
		# Carrier grade NAT, which is what a tunnel hands out, is never the LAN.
		if int(parts[0]) == 100 and int(parts[1]) >= 64 and int(parts[1]) <= 127:
			continue
		# An address ending in .1 is the gateway of its own network; on a desktop
		# that is usually a Hyper-V or WSL switch rather than the Wi-Fi, and the
		# only host that answers there is the desktop itself. Held back, see below.
		if address.ends_with(".1"):
			continue
		primary.append(prefix)
	# The network of the last address that actually answered comes first: a peer
	# that moved to another subnet would otherwise be pushed out by the prefix cap.
	var known := _prefix_of(_link_address)
	if not known.is_empty() and not primary.has(known):
		primary.push_front(known)
	if primary.size() > SCAN_MAX_PREFIXES:
		primary.resize(SCAN_MAX_PREFIXES)
	return primary


## The networks only worth a look when the real ones came back silent: gateways of
## virtual switches, tunnels, and whatever the prefix cap pushed off the front
## list. Sweeping them is what found the neighbour an adapter cannot answer for,
## but doing it up front meant dialling 500 addresses to find one peer.
func _fallback_prefixes(primary: Array[String]) -> Array[String]:
	var rest: Array[String] = []
	for entry: Dictionary in local_ipv4_entries():
		var address := str(entry.get("address", ""))
		var prefix := _prefix_of(address)
		if prefix.is_empty() or primary.has(prefix) or rest.has(prefix):
			continue
		var parts := address.split(".")
		if int(parts[0]) == 100 and int(parts[1]) >= 64 and int(parts[1]) <= 127:
			continue
		rest.append(prefix)
	if rest.size() > SCAN_FALLBACK_MAX:
		rest.resize(SCAN_FALLBACK_MAX)
	return rest


## The /24 an address belongs to, or an empty string when it is not worth sweeping.
static func _prefix_of(address: String) -> String:
	if address.is_empty() or address.begins_with("127.") or address.begins_with("169.254."):
		return ""
	var parts := address.split(".")
	if parts.size() != 4:
		return ""
	return "%s.%s.%s." % [parts[0], parts[1], parts[2]]


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
	var seconds := str(snappedf((Time.get_ticks_msec() - _scan_started) / 1000.0, 0.1))
	# What the button is asking is "what is nearby", so the list is the answer.
	# Comparing the count before and after said "no device replied" while the peer
	# sat right there in the list, simply because it was known before the sweep.
	if not peers.is_empty():
		if _scan_hits > 0:
			log_line.emit("扫描完成，附近 %d 台设备（%s 秒）" % [peers.size(), seconds])
		else:
			log_line.emit(
				"扫描完成，附近 %d 台设备；这次没收到回应，是之前发现过的（%s 秒）"
				% [peers.size(), seconds]
			)
		return
	# A dial that connected is a result even before the peer has said its name:
	# reporting silence while the link is up was the same mistake as above. A
	# socket nobody has said hello on is still only a candidate, and saying so is
	# what stops "已连上" from being printed for a printer with an open port.
	if _peer != null:
		if _peer_id.is_empty():
			log_line.emit(
				"扫描完成，%s:%d 接受了连接，正在握手确认（%s 秒）"
				% [_peer_address, _peer_port, seconds]
			)
		else:
			log_line.emit(
				"扫描完成，已连上 %s:%d（%s 秒）" % [_peer_address, _peer_port, seconds]
			)
		return
	# Silence has one usual cause on a desktop, and saying it here saves the
	# person a long hunt: the system firewall answering for the other side.
	log_line.emit("扫描完成，没有设备回应（%s 秒）" % seconds)
	log_line.emit(
		"若对方是 Windows：它的防火墙要放行入站 UDP %d 与 TCP %d（本机地址 %s）"
		% [DISCOVERY_PORT, SYNC_PORT, local_addresses()]
	)


## One batch of dials per frame, then the dials already open are checked. A dial
## that connects is not thrown away and re-dialed: it becomes the link, so the
## sweep and the handshake are the same connection.
func _poll_sweep() -> void:
	# Rebuilt rather than assumed: a script edited while the editor is running
	# leaves the instances created before that edit with these members unset.
	if _sweep_sockets == null:
		_sweep_sockets = []
	if _dead_dials == null:
		_dead_dials = {}
	if _scan_fallback == null:
		_scan_fallback = []
	# Somebody answered a beacon during this scan, and a broadcast reaches every
	# device on the network at once, so the dial half has nothing left to find.
	if _scan_active and _scan_hits > 0:
		_drop_pending_dials()
	if _sweep_queue.is_empty() and _sweep_sockets.is_empty():
		# The networks that matter came back empty, so the virtual adapters get
		# their turn now instead of having been swept alongside them. The verdict
		# itself is left to [_report_scan], one frame later.
		if _scan_active and _scan_hits == 0 and not _scan_fallback.is_empty() \
				and _peer == null:
			_queue_scan_phase(_scan_fallback)
			_scan_fallback.clear()
			if not _sweep_queue.is_empty():
				log_line.emit("主网段没找到设备，继续扫本机的虚拟网段…")
				_probe_broadcast()
		if _sweep_queue.is_empty():
			return
	var now := Time.get_ticks_msec()
	var sent := 0
	while not _sweep_queue.is_empty() \
			and sent < SWEEP_WINDOW - _sweep_sockets.size():
		var address: String = _sweep_queue.pop_back()
		if _dead_dials.has(address) \
				and now - int(_dead_dials[address]) < int(DEAD_DIAL_TTL * 1000.0):
			continue
		var socket := StreamPeerTCP.new()
		# A peer that once answered on a non-default port is dialled on that port.
		var target_port := int(_sweep_ports.get(address, SYNC_PORT))
		if socket.connect_to_host(address, target_port) != OK:
			continue
		_sweep_sockets.append(
			{"socket": socket, "address": address, "started": now, "port": target_port}
		)
		sent += 1
	var keep: Array[Dictionary] = []
	for attempt: Dictionary in _sweep_sockets:
		var socket: StreamPeerTCP = attempt["socket"]
		socket.poll()
		var state := socket.get_status()
		if state == StreamPeerTCP.STATUS_CONNECTED:
			# Taken over as the link, but only the hello proves it is a peer; a
			# device that merely accepts the connection is hung up by
			# [_poll_peer] after [constant HANDSHAKE_TIMEOUT] and never dialled again.
			if _peer == null:
				_adopt_peer(
					socket, str(attempt["address"]), int(attempt.get("port", SYNC_PORT))
				)
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


## Ends the dial half of a sweep early: nothing more has to be dialled once the
## answer is in hand, and a queued address costs a socket until it times out.
func _drop_pending_dials() -> void:
	for attempt: Dictionary in _sweep_sockets:
		var socket: StreamPeerTCP = attempt["socket"]
		socket.disconnect_from_host()
	_sweep_sockets.clear()
	_sweep_queue.clear()
	_scan_pending.clear()


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
	_link_address = address
	_link_port = port
	_reconnect_at = 0
	_reconnect_failures = 0
	_initiator = true
	_buffer = PackedByteArray()
	_phase = "connecting"
	if not quiet:
		log_line.emit("正在连接 %s:%d" % [address, port])


## Takes over a socket a sweep already dialed, so a connection that worked is not
## hung up and tried again through the beacon path.
func _adopt_peer(socket: StreamPeerTCP, address: String, port := SYNC_PORT) -> void:
	_drop_peer("")
	_peer = socket
	_peer_id = ""
	_peer_label = ""
	_peer_address = address
	_peer_port = port
	_peer_since = Time.get_ticks_msec()
	_peer_last_rx = Time.get_ticks_msec()
	_link_address = address
	_link_port = port
	_reconnect_at = 0
	_reconnect_failures = 0
	_initiator = true
	_buffer = PackedByteArray()
	_phase = "connecting"
	log_line.emit("已连上 %s:%d，握手中…" % [address, port])


## A link is dropped, but the address that worked is remembered: a phone that was
## in the background, or a Wi-Fi hiccup, must not end the session for good.
func _link_lost(reason: String) -> void:
	# Always the remembered listening address, never the live socket's one: the
	# side that accepted holds the peer's *ephemeral* port, which nothing listens
	# on. [_link_address] is written from whichever source knew better — the dial
	# itself, or a beacon heard since.
	var address := _link_address
	var port := _link_port
	if peers.has(_peer_id):
		var entry: Dictionary = peers[_peer_id]
		var heard_port := int(entry.get("port", 0))
		var heard_address := str(entry.get("address", ""))
		if heard_port > 0 and not heard_address.is_empty():
			address = heard_address
			port = heard_port
	_drop_peer(reason)
	if address.is_empty() or port <= 0:
		return
	_reconnect_address = address
	_reconnect_port = port
	_reconnect_tries = 0
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
	_reconnect_failures += 1
	if _reconnect_tries == 1 or _reconnect_tries % 10 == 0:
		log_line.emit(
			"重连 %s:%d（第 %d 次）" % [_reconnect_address, _reconnect_port, _reconnect_tries]
		)
	# The remembered address has stopped answering, which on a phone usually means
	# it is on another network now. Sweep as well; the dials above keep going, so a
	# peer that is still there is picked up by whichever arrives first.
	if _reconnect_failures == RECONNECT_SCAN_AFTER:
		log_line.emit("上次的地址连不上，开始扫描局域网")
		scan()
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
	_has_plan = false
	_pulling = false
	peer_files.clear()
	peer_files_changed.emit()
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
	# Connected is not the same as "one of us". A router, a printer and a NAS all
	# accept a connection on any port, and holding that socket would keep the real
	# peer out — one link at a time is the rule everywhere else.
	if _phase == "connecting" or _phase == "accepted" or _phase == "hello":
		if Time.get_ticks_msec() - _peer_since > int(HANDSHAKE_TIMEOUT * 1000.0):
			var silent := _peer_address
			var silent_port := _peer_port
			if _peer_id.is_empty():
				_dead_dials[silent] = Time.get_ticks_msec()
			_drop_peer("")
			log_line.emit(
				"%s:%d 接受连接但不握手，不是同步端" % [silent, silent_port]
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
		# The other side is pulling: hand over the list, and wait to be asked for
		# the files one by one. Nothing travels the other way — but only once this
		# side has agreed to the connection at all.
		"pull":
			if _phase == "connected" or _phase == "done" or _phase.is_empty():
				_send_manifest()
		# Just the list, no files: the other side wants to see what is on offer.
		"list":
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
			_report_round()
			# The other side has finished taking files, so its folder is not what
			# it was when this link came up. Ask for its list again: the panel here
			# must not keep showing timestamps from before the pull.
			list_peer_files()


## The other side accepted. Nothing is exchanged from here on until somebody presses
## the button: the link is a channel, not a schedule.
func _handle_hello_ok() -> void:
	if not _initiator:
		return
	_phase = "connected"
	_reconnect_failures = 0
	_note_peer("已连接")
	log_line.emit("已连上 %s；点「同步」把它那边的文件拉过来" % _peer_label)
	list_peer_files()


func _handle_hello_no() -> void:
	# Kept for compatibility with a peer that still gates the connection: this
	# build never sends it.
	log_line.emit("对方拒绝连接")
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
	var shared := _shared_folders(message.get("folders", []))
	if shared.is_empty():
		log_line.emit("没有同名的同步文件夹，什么也没做")
		_drop_peer("")
		return
	if _initiator:
		# The dialer already sent its own hello and is waiting for hello_ok. Saying
		# anything else here would send a second hello for every one received.
		_note_peer("连接中")
		return
	# Connecting is the whole handshake now: a link is accepted as soon as it is
	# understood, because there is nothing to approve — nothing moves until
	# somebody presses 「同步」 anyway, and that press is the approval.
	_outbox.append({"t": "hello_ok"})
	_phase = "connected"
	_reconnect_failures = 0
	_note_peer("已连接")
	log_line.emit("已连上 %s（%s）" % [_peer_label, _peer_address])
	list_peer_files()


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
	log_line.emit(_manifest_summary(manifest))


## The manifest as a line a person can check against a file manager: folder names
## with their counts and the first few file names. A count alone leaves the real
## question — "was my file in there at all?" — unanswered.
func _manifest_summary(manifest: Dictionary) -> String:
	var counts := {}
	var names: Array[String] = []
	for key: String in manifest:
		var parts := key.split("/", true, 1)
		var folder_name := str(parts[0])
		counts[folder_name] = int(counts.get(folder_name, 0)) + 1
		if names.size() < 6:
			names.append(key)
	var pieces: Array[String] = []
	for folder_name: String in counts:
		pieces.append("%s %d 个" % [folder_name, int(counts[folder_name])])
	if manifest.size() > names.size():
		names.append("…")
	return "清单：%s｜文件：%s" % [", ".join(pieces), ", ".join(names)]


## Fills the panel with what the other side has. The timestamp travels with the
## list because it is what a person reads to decide whether the copy on the other
## side is the one they want, and an empty list says so in words instead of
## leaving an empty box on screen.
func _show_remote(remote: Dictionary) -> void:
	var keys: Array[String] = []
	for key: String in remote:
		keys.append(key)
	keys.sort()
	peer_files = keys
	peer_entries.clear()
	for key: String in keys:
		var entry: Dictionary = remote[key]
		peer_entries.append(
			{
				"key": key,
				"mtime": int(entry.get("mtime", 0)),
				"size": int(entry.get("size", 0)),
				"h": str(entry.get("h", "")),
			}
		)
	# A fresh list is also the only evidence about whether a pair a sync just made
	# identical is still identical: it either confirms the record or shows that one
	# of the two copies has moved on since.
	_reconcile_known_same(remote)
	peer_files_changed.emit()
	if keys.is_empty():
		log_line.emit(
			"对方的共享目录里没有文件（对方那边可能报了「读不到这个目录」）"
		)
		return
	log_line.emit("对方" + _manifest_summary(remote))


func _handle_manifest(message: Dictionary) -> void:
	var files: Variant = message.get("files", [])
	var remote := {}
	if files is Array:
		for entry: Variant in files:
			if entry is Dictionary:
				remote[str((entry as Dictionary).get("key", ""))] = entry
	# Whatever it was asked for, a manifest is also the answer to "what has the
	# other side got", so the panel is filled from every single one. Insisting it
	# only counted when a request was outstanding is what left the file list empty
	# after a handshake both sides had already agreed to.
	_show_remote(remote)
	if not _awaiting_manifest:
		if _phase == "manifest":
			_phase = "connected"
		return
	_awaiting_manifest = false
	_manifest_retries = 0
	if not _pulling:
		# A list request: show what the other side has and stop there. Nothing is
		# fetched, because nothing was asked to be.
		_phase = "connected"
		return
	_pulling = false
	_plan_pull(remote)
	# Nothing to receive would leave the pull parked in "transfer" forever, and the
	# button would stop working: an empty pull is a finished pull.
	if _expecting == 0:
		_phase = "done"
		_report_if_idle()
		return
	_phase = "transfer"


## Everything the other side has, this side takes: the button is a pull, so the
## remote copy wins and a local file is overwritten whenever the content differs.
## Files that already match are left alone — rewriting identical bytes would only
## cost disk and time.
func _plan_pull(remote: Dictionary) -> void:
	var local := _build_manifest()
	_peer_file_count = remote.size()
	_local_file_count = local.size()
	_has_plan = true
	_get_queue.clear()
	_expecting = 0
	_received = 0
	_skipped_files = 0
	var unshared := 0
	var identical := 0
	var same_time := 0
	# A single-file pull is a deliberate click on one row, so it overrides the
	# timestamp rule below; a whole-folder sync obeys it.
	var forced := not _pull_keys.is_empty()
	for key: String in remote:
		if forced and not _pull_keys.has(key):
			continue
		# A key whose folder this side does not share would be asked for and then
		# dropped on arrival, leaving the pull waiting for a file that never lands.
		if _absolute(key).is_empty():
			unshared += 1
			continue
		if local.has(key):
			if str(local[key].get("h", "")) == str(remote[key].get("h", "-")):
				identical += 1
				# Same bytes with different timestamps is exactly what the
				# timestamps cannot describe: a tick, not an exclamation.
				_known_same[key] = {
					"h": str(local[key].get("h", "")),
					"mtime": int(local[key].get("mtime", 0)),
					"size": int(local[key].get("size", 0)),
					"pending": false,
				}
				continue
			# An identical modification time means both copies come from the same
			# write, so neither is newer and a sync has no business replacing one
			# with the other. Only a real edit moves the timestamp.
			if not forced \
					and int(local[key].get("mtime", -1)) == int(remote[key].get("mtime", -2)):
				same_time += 1
				continue
		_get_queue.append(key)
		_expecting += 1
	# "0 files moved" has four causes and only one of them is good news, so the
	# other three are said out loud instead of being left to be guessed at.
	_skipped_files = unshared + identical + same_time
	if unshared > 0:
		log_line.emit("%d 个文件所属的文件夹没有在本机共享，已跳过" % unshared)
	if identical > 0:
		log_line.emit("%d 个文件内容已经相同，已跳过" % identical)
	if same_time > 0:
		log_line.emit("%d 个文件修改时间相同，未覆盖" % same_time)
	for key: String in _get_queue:
		_outbox.append({"t": "get", "key": key})
	if _expecting == 0:
		_outbox.append({"t": "done"})
	# The narrow pull is spent once it has been turned into a get queue; leaving
	# it set would silently narrow the next full sync to the same single file.
	_pull_keys.clear()


## Puts a file on the outgoing list. Nothing is read here: the bytes are taken
## from disk a chunk at a time when the socket is ready for them.
func _enqueue_file(key: String) -> void:
	var path := _absolute(key)
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	# Already on its way, or already waiting: sending it twice would only make the
	# receiver write the same bytes again.
	if not _sending.is_empty() and str(_sending["key"]) == key:
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
	var key := str(_sending["key"])
	_outbox.append({"t": "file_end", "key": key})
	sent_files += 1
	_sending = {}
	# The other side is writing these exact bytes, so its row can be a tick without
	# waiting for two timestamps to agree; the next list it sends confirms the
	# record, and drops it if it no longer matches.
	_remember_same(key, _absolute(key))
	# No summary here: several files are served one after another, and a line per
	# file would read like several separate syncs. The summary comes with `done`.
	# The panels do get told, one file at a time: on the side that handed a file
	# over, "only here" is no longer true the moment it has left.
	file_synced.emit(_absolute(key), "out")


## The pull's summary waits until everything this side had to hand over has left.
func _report_if_idle() -> void:
	if not _sending.is_empty() or not _send_queue.is_empty():
		return
	_report_round()


func _handle_file_begin(message: Dictionary) -> void:
	var key := str(message.get("key", ""))
	var path := _absolute(key)
	if path.is_empty():
		return
	# A folder may be stored as a project path ("res://lan_shared"), and the
	# directory APIs here only understand real filesystem paths.
	var directory := real_path(path.get_base_dir())
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
		# Nothing landed, but the round still has to move on: a file that could not
		# be written would otherwise leave the round parked in "transfer" and stop
		# every later round for the rest of the session.
		log_line.emit("%s 写入失败，已跳过" % key)
		_finish_received()
		return
	handle.close()
	if written != declared:
		log_line.emit("%s 没有收全（%d/%d 字节），已跳过" % [key, written, declared])
		_finish_received()
		return
	_hash_cache.erase(path)
	_remember_same(key, path)
	file_synced.emit(path, "in")
	received_files += 1
	log_line.emit("收到 %s（%s）" % [key, _size_text(written)])
	_finish_received()


## One file is done, whichever way it ended. Counting only matters on the side
## that planned the round; the other side is answering, and for it every arriving
## file is simply good news.
func _finish_received() -> void:
	if _phase != "transfer":
		_note_peer("已同步")
		return
	_received += 1
	if _received < _expecting:
		return
	_outbox.append({"t": "done"})
	_phase = "done"
	_note_peer("已同步")
	_report_round()


## Asks again when the other side's list never arrives, and finally says so. A
## request nobody answers used to leave the panel empty for the rest of the
## session, which is indistinguishable from "connected, and it has no files".
func _poll_manifest_wait() -> void:
	if not _awaiting_manifest or _phase != "manifest":
		return
	var waited := Time.get_ticks_msec() - _manifest_since
	if _pulling:
		# A pull is waiting on the other side *building* the manifest: it hashes
		# every file and says nothing while it does, which for a folder of large
		# files is minutes. Re-asking would only start that over, so this waits —
		# and says why it is waiting, once.
		if not _manifest_hinted and waited >= int(MANIFEST_QUIET_HINT * 1000.0):
			_manifest_hinted = true
			log_line.emit("对方还在整理文件清单（文件多、体积大时会慢），请稍等")
		return
	if waited < int(MANIFEST_RETRY * 1000.0):
		return
	_manifest_since = Time.get_ticks_msec()
	_manifest_retries += 1
	if _manifest_retries > MANIFEST_RETRIES:
		_awaiting_manifest = false
		_phase = "connected"
		log_line.emit("对方一直没有回文件清单；再点一次「同步」看它这次回不回")
		return
	log_line.emit("对方还没回清单，再问一次（第 %d 次）" % _manifest_retries)
	_outbox.append({"t": "list"})


## A round stops when the peer stops answering mid-transfer. The link is kept —
## the other side is most likely asleep — but the half finished round is dropped,
## or the next one would never be asked for.
func _poll_watchdog() -> void:
	# Only a transfer is watched here. Waiting for a manifest is not silence to
	# be punished — the other side is hashing files, and [_poll_manifest_wait]
	# owns that wait, with its own retries and its own words.
	if _peer == null or _phase != "transfer":
		return
	if Time.get_ticks_msec() - _peer_last_rx < int(TRANSFER_SILENCE * 1000.0):
		return
	# Sending counts as being alive. The receiver says nothing while a file
	# streams in, so one big file over a slow link looked exactly like a dead
	# peer and the round was cancelled in the middle of it.
	if not _sending.is_empty() or not _write_left.is_empty() or not _outbox.is_empty():
		return
	_close_transfers()
	_outbox.clear()
	_write_left = PackedByteArray()
	_awaiting_manifest = false
	_has_plan = false
	_expecting = 0
	_received = 0
	_phase = "done"
	log_line.emit(
		"对方 %s 秒没有动静，这一轮停下了；再点「同步」会从头续上"
		% int(TRANSFER_SILENCE)
	)


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
	# A round nobody asked for stays quiet when it moved nothing; a round somebody
	# pressed 「同步」 for always answers, because silence there is
	# indistinguishable from "the button does nothing".
	var asked := _manual_round
	var planned := _has_plan
	_manual_round = false
	_has_plan = false
	if not asked and sent_files == _reported_sent and received_files == _reported_received:
		return
	_reported_sent = sent_files
	_reported_received = received_files
	# Both sides have just written files, and the marks compare this side's
	# timestamps against the other side's list: without asking for it again the
	# panel would keep describing the state from before the sync.
	_queue_relist()
	if not planned:
		# The side that only answered: it has no manifest of its own to compare,
		# so it reports what it handed over and nothing else.
		log_line.emit("已把 %d 个文件发给对方" % sent_files)
		return
	log_line.emit(
		"拉取完成：收到 %d 个，跳过 %d 个（本机 %d 个文件，对方 %d 个）"
		% [received_files, _skipped_files, _local_file_count, _peer_file_count]
	)
	if _local_file_count > 0 or _peer_file_count > 0:
		return
	log_line.emit("两侧的共享文件夹里都还没有文件：把文件存进去，再点「同步」")


func _note_peer(state: String) -> void:
	if not _peer_id.is_empty() and peers.has(_peer_id):
		peers[_peer_id]["state"] = state
		peers_changed.emit()


# Files.


## Manifest of every file the two peers may talk about, keyed by name/relative path.
##
## A folder that yields nothing says why. "Both sides have 0 files" while a file
## manager clearly shows files is the one report that cannot be acted on, so the
## three causes — no path, unreadable path, nothing to list — are named here
## instead of being folded into a zero.
func _build_manifest() -> Dictionary:
	var manifest := {}
	for folder_name: String in folders:
		var root := str(folders[folder_name])
		if root.is_empty():
			log_line.emit("%s：还没有设置路径" % folder_name)
			continue
		if not DirAccess.dir_exists_absolute(real_path(root)):
			log_line.emit("%s：读不到这个目录 %s" % [folder_name, root])
			continue
		var added := _scan(root, folder_name, manifest)
		if added == 0:
			log_line.emit("%s：目录里没有可同步的文件（%s）" % [folder_name, root])
			if root.contains("/storage/emulated/"):
				# Scoped storage shows an app only what it wrote itself, so a
				# folder with files in a file manager can still list nothing here.
				log_line.emit(
					"如果文件管理器里能看到文件，去「设置 → 应用 → Pixelorama → 特殊权限」授予「所有文件访问权限」"
				)
	return manifest


func _scan(root: String, folder_name: String, manifest: Dictionary) -> int:
	var pending: Array[String] = [root]
	var seen := 0
	var added := 0
	while not pending.is_empty() and seen < MAX_FILES:
		var current: String = pending.pop_back()
		var directory := DirAccess.open(current)
		if directory == null:
			if current != root:
				log_line.emit("读不到子目录 %s（权限？）" % current)
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
					manifest[key] = _describe_file(full)
					added += 1
			entry = directory.get_next()
		directory.list_dir_end()
	return added


## What the other side needs to know about one file: when it changed, how big it
## is, and what is in it. The hash is the expensive part, so a file that has not
## changed since the last round reuses the one already computed.
func _describe_file(path: String) -> Dictionary:
	var mtime := FileAccess.get_modified_time(path)
	var size := _size_of(path)
	var cached: Variant = _hash_cache.get(path)
	# Timestamp and size are both cheap and both have to agree: a save that keeps
	# the size but not the content is caught by the timestamp, and one that lands
	# in the same second but changes the size is caught by the size.
	if cached is Dictionary and int(cached["mtime"]) == mtime \
			and int(cached["size"]) == size \
			and Time.get_ticks_msec() - int(cached["checked"]) < int(HASH_CACHE_TTL * 1000.0):
		return {"mtime": mtime, "size": size, "h": str(cached["hash"])}
	var described := _hash_and_size(path)
	_hash_cache[path] = {
		"mtime": mtime,
		"size": int(described["size"]),
		"hash": str(described["hash"]),
		"checked": Time.get_ticks_msec(),
	}
	return {"mtime": mtime, "size": int(described["size"]), "h": str(described["hash"])}


## Size and hash in one pass over the file, because two passes would read it twice.
func _hash_and_size(path: String) -> Dictionary:
	var handle := FileAccess.open(path, FileAccess.READ)
	if handle == null:
		return {"size": 0, "hash": ""}
	var size := int(handle.get_length())
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var read := 0
	while read < size:
		var chunk := handle.get_buffer(mini(CHUNK_BYTES, size - read))
		if chunk.is_empty():
			break
		context.update(chunk)
		read += chunk.size()
	handle.close()
	return {"size": size, "hash": context.finish().hex_encode()}


func _size_of(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := int(file.get_length())
	file.close()
	return size




## The real filesystem path of a folder setting. The editor side keeps `shared`
## as "res://lan_shared" so the files land inside the project and show up in the
## FileSystem dock; the few APIs that insist on an absolute path go through here.
static func real_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path


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
