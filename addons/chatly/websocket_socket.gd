##
## `ChatlySocket` over Godot's own `WebSocketPeer`, speaking Engine.IO v4.
##
## ── Godot 4's networking surface, since the question gets asked ──────────
##
## Verified on 4.7.2 rather than assumed: `WebSocketPeer` exists, is
## instantiable, extends `PacketPeer`, and offers `connect_to_url`, `poll`,
## `send_text`, `get_ready_state`, `was_string_packet`, `get_close_code`,
## `get_close_reason` and `set_handshake_headers`. TLS comes from
## `connect_to_url("wss://…")` with the engine's own certificate bundle. So a
## Socket.IO client needs no native extension and no dependency — only the
## ~120-line codec in `engineio.gd`, because Socket.IO is a protocol ON TOP of
## WebSocket and `WebSocketPeer` does not know it.
##
## ── The two heartbeats, which are not the same heartbeat ────────────────
##
## `WebSocketPeer.heartbeat_interval` sends RFC 6455 PING frames, at the
## WebSocket layer. Engine.IO has its OWN ping: the server sends the text
## frame `2` every `pingInterval` and expects `3` back within `pingTimeout`.
## They are unrelated, and answering only the first is how a connection dies
## after 45 seconds with nothing in any log. `_handle` below answers `2` with
## `3` immediately, and `poll` treats a missing server ping as a dead link —
## measured against `delta` rather than wall-clock, so a game paused in the
## background does not come back thinking its socket died.
##
## ── Why `poll()` must be called every frame ────────────────────────────
##
## `WebSocketPeer` is not a Node and has no `_process`. Nothing moves until
## somebody calls `poll()`. `ChatlyClient._process` does it; a game driving
## this class directly has to as well, and a socket that never opens with no
## error anywhere is what forgetting looks like.
##
class_name ChatlyWebSocketSocket
extends ChatlySocket

## `preload` and not `ChatlyEngineIO`: a `class_name` reference is resolved
## at runtime and is not a constant expression, so `const X := ChatlyEngineIO`
## is a parse error. It only shows up when the file is COMPILED, which the
## test suite does not do for the addon until something instantiates it —
## so the first place it surfaced was the editor import pass.
const _EIO = preload("res://addons/chatly/engineio.gd")

var _url: String
var _auth: Dictionary
var _peer: WebSocketPeer = WebSocketPeer.new()

## `false` until the Socket.IO CONNECT is accepted. `socket_opened` fires on
## that, NOT on the WebSocket opening: the TCP/TLS/WebSocket layers can all
## succeed and the handshake still be refused, which for a visitor with a
## stale token is the ordinary case.
var _connected: bool = false
var _started: bool = false
var _finished: bool = false

## Seconds since the server's last Engine.IO ping, and the budget it has.
var _since_ping: float = 0.0
var _ping_budget: float = (
	float(_EIO.DEFAULT_PING_INTERVAL_MS + _EIO.DEFAULT_PING_TIMEOUT_MS) / 1000.0
)
var _saw_open: bool = false


func _init(handshake_url: String, auth: Dictionary) -> void:
	_url = handshake_url
	_auth = auth.duplicate(true)


func auth_payload() -> Dictionary:
	return _auth.duplicate(true)


func start() -> void:
	if _started:
		# Single-use by design — see the header of `socket.gd`. Reusing one is
		# how a stale credential gets replayed.
		push_error("[chatly] a ChatlyWebSocketSocket may be started only once")
		return
	_started = true
	var err := _peer.connect_to_url(_url)
	if err != OK:
		_finish("connect_to_url failed (%d)" % err)


func poll(delta: float) -> void:
	if _finished or not _started:
		return
	_peer.poll()
	match _peer.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			return
		WebSocketPeer.STATE_OPEN:
			while _peer.get_available_packet_count() > 0:
				var packet := _peer.get_packet()
				# The gateway speaks text. A binary frame here is a Socket.IO
				# binary attachment, which `decode` reports as ignored; the
				# bytes are dropped rather than mis-parsed as UTF-8.
				if _peer.was_string_packet():
					_handle(packet.get_string_from_utf8())
			if _saw_open:
				_since_ping += delta
				if _since_ping > _ping_budget:
					# The server stopped pinging. The WebSocket is still open
					# as far as the OS is concerned — this is the half-open
					# connection a mobile handover leaves behind, and without
					# this check it stays "connected" forever delivering
					# nothing.
					_peer.close(1000, "engine.io ping timeout")
					_finish("engine.io ping timeout")
			return
		WebSocketPeer.STATE_CLOSING:
			return
		_:
			var code := _peer.get_close_code()
			var reason := _peer.get_close_reason()
			if reason.is_empty():
				# -1 means the connection failed before a close frame: DNS, TLS,
				# a refused upgrade, a captive portal. Distinguished because
				# "no route to the server" and "the server closed us" call for
				# different messages on screen.
				reason = "closed before handshake" if code == -1 else "closed (%d)" % code
			_finish(reason)


func send_event(name: String, payload: Variant) -> void:
	if not _connected or _finished:
		return
	_peer.send_text(_EIO.encode_event(name, payload))


func stop() -> void:
	if _finished:
		return
	if _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		# The Engine.IO CLOSE first, so the server's `disconnect` fires now
		# rather than on its own timeout — which is what makes an agent see
		# the visitor leave promptly.
		_peer.send_text(_EIO.encode_close())
	_peer.close(1000, "client closed")
	_finished = true
	_connected = false


func _handle(frame: String) -> void:
	var packet := _EIO.decode(frame)
	match str(packet.get("kind", "")):
		_EIO.KIND_OPEN:
			_saw_open = true
			_since_ping = 0.0
			var interval := int(packet.get("ping_interval_ms", _EIO.DEFAULT_PING_INTERVAL_MS))
			var tolerance := int(packet.get("ping_timeout_ms", _EIO.DEFAULT_PING_TIMEOUT_MS))
			_ping_budget = float(interval + tolerance) / 1000.0
			# THE handshake. `{ "token": …, "kind": "visitor" }` becomes
			# `socket.handshake.auth` on the server, which is what
			# `handshakeAuthSchema.parse` reads.
			_peer.send_text(_EIO.encode_connect(_auth))
		_EIO.KIND_PING:
			_since_ping = 0.0
			_peer.send_text(_EIO.encode_pong())
		_EIO.KIND_CONNECT:
			_connected = true
			socket_opened.emit()
		_EIO.KIND_CONNECT_ERROR:
			var message := str(packet.get("message", ""))
			socket_refused.emit(message if not message.is_empty() else "handshake refused")
			# A refusal is terminal for this socket. The owner decides whether
			# to mint again and try, which is the only thing that can fix it.
			stop()
			socket_closed.emit("handshake refused")
		_EIO.KIND_EVENT:
			socket_event.emit(str(packet.get("name", "")), packet.get("payload", null))
		_EIO.KIND_DISCONNECT, _EIO.KIND_CLOSE:
			_finish("server disconnected")
		_:
			# `ignored`, `ack`, `pong`, `malformed`. Nothing the gateway sends a
			# visitor falls here, and a frame we cannot read must not be able
			# to crash a game's main loop.
			pass


func _finish(reason: String) -> void:
	if _finished:
		return
	_finished = true
	_connected = false
	socket_closed.emit(reason)
