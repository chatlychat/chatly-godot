##
## Engine.IO v4 / Socket.IO v5 wire codec — pure, no I/O, no WebSocket.
##
## ── Why this file exists at all ────────────────────────────────────────────
##
## The realtime gateway is Socket.IO, not bare WebSocket. `apps/realtime/src/
## main.ts` constructs `new Server(httpServer, { path: '/socket.io' })` from
## `socket.io@4.7.5` (pinned in `pnpm-workspace.yaml`'s catalog), which carries
## `engine.io@6.5.5`. That pair is **Engine.IO protocol 4** and **Socket.IO
## protocol 5**, and the whole of what this client needs from them is small
## enough to read in one sitting:
##
##   Engine.IO frames a text packet as `<type><payload>`:
##     0  open   — server's first frame, `0{"sid":…,"pingInterval":…}`
##     1  close
##     2  ping   — server-initiated; the client MUST answer `3`
##     3  pong
##     4  message — the payload is a Socket.IO packet
##
##   Socket.IO frames its own packet as `<type>[<nsp>,][<ackId>]<json>`:
##     0  CONNECT        — ours carries the handshake `auth` object
##     1  DISCONNECT
##     2  EVENT          — `["event", {envelope}]`
##     3  ACK
##     4  CONNECT_ERROR  — a refused handshake arrives here, with a reason
##     5/6 BINARY        — the gateway never sends these; we ignore them
##
## So a whole connect is: WebSocket to `…/socket.io/?EIO=4&transport=websocket`,
## read `0{…}`, send `40{"token":…,"kind":"visitor"}`, read `40{"sid":…}`,
## then read `42["event",{…}]` forever and answer every `2` with a `3`.
##
## ── Why a codec rather than a dependency ──────────────────────────────────
##
## There is no Socket.IO client for GDScript, and adding one would be adding a
## dependency, which CLAUDE.md §2 does not permit without approval. This is
## ~120 lines of string handling against a frozen, versioned protocol, and it
## is separated from the socket so every branch is testable WITHOUT a network:
## `tests/test_engineio.gd` drives it on literal strings, and
## `tests/live/` drives the socket against a real `socket.io@4.7.5` server.
##
## ── The one thing to be careful of ────────────────────────────────────────
##
## `decode()` never throws and never returns null. A malformed frame from a
## proxy, a captive portal, or a future server is `KIND_MALFORMED`, and an
## unrecognised-but-well-formed one is `KIND_IGNORED`. A game's main loop must
## not be able to crash on bytes it did not choose.
##
class_name ChatlyEngineIO
extends RefCounted

## Engine.IO packet types (the first character of a frame).
const EIO_OPEN := "0"
const EIO_CLOSE := "1"
const EIO_PING := "2"
const EIO_PONG := "3"
const EIO_MESSAGE := "4"

## Socket.IO packet types (the first character AFTER an `EIO_MESSAGE`).
const SIO_CONNECT := "0"
const SIO_DISCONNECT := "1"
const SIO_EVENT := "2"
const SIO_ACK := "3"
const SIO_CONNECT_ERROR := "4"
const SIO_BINARY_EVENT := "5"
const SIO_BINARY_ACK := "6"

## `decode()` result `kind`s. Exhaustive: every frame maps to one of these.
const KIND_OPEN := "open"
const KIND_CLOSE := "close"
const KIND_PING := "ping"
const KIND_PONG := "pong"
const KIND_CONNECT := "connect"
const KIND_CONNECT_ERROR := "connect_error"
const KIND_DISCONNECT := "disconnect"
const KIND_EVENT := "event"
const KIND_ACK := "ack"
const KIND_IGNORED := "ignored"
const KIND_MALFORMED := "malformed"

## The default namespace. The gateway registers no others, so every packet we
## send omits it and every packet we receive should carry it implicitly.
const DEFAULT_NAMESPACE := "/"

## Engine.IO's own defaults, used only until the server's `open` frame tells
## us its real ones. `socket.io@4.7.5` ships 25s/20s.
const DEFAULT_PING_INTERVAL_MS := 25000
const DEFAULT_PING_TIMEOUT_MS := 20000


## Build the WebSocket URL for an Engine.IO v4 websocket-transport connection.
##
## `base` may be given as `http(s)://` or `ws(s)://` — a human writing a
## config file will reach for whichever they saw last, and both are accepted
## because getting this wrong produces a connection that never opens with no
## message saying why. `https`/`wss` map to `wss`, everything else to `ws`.
##
## `EIO=4` is not optional. Omit it and engine.io answers HTTP 400 with
## `{"code":5,"message":"Unsupported protocol version"}`, which over a
## WebSocket upgrade surfaces as a bare handshake failure.
static func handshake_url(base: String, path: String = "/socket.io") -> String:
	var trimmed := base.strip_edges()
	while trimmed.ends_with("/"):
		trimmed = trimmed.substr(0, trimmed.length() - 1)
	var scheme := "wss"
	var rest := trimmed
	var sep := trimmed.find("://")
	if sep != -1:
		var given := trimmed.substr(0, sep).to_lower()
		rest = trimmed.substr(sep + 3)
		scheme = "wss" if (given == "https" or given == "wss") else "ws"
	var norm_path := path.strip_edges()
	if not norm_path.begins_with("/"):
		norm_path = "/" + norm_path
	while norm_path.ends_with("/"):
		norm_path = norm_path.substr(0, norm_path.length() - 1)
	return "%s://%s%s/?EIO=4&transport=websocket" % [scheme, rest, norm_path]


## The Socket.IO CONNECT packet that carries the handshake `auth` object.
##
## This is where `{ "token": …, "kind": "visitor" }` goes, and it is the whole
## reason this codec is hand-written rather than skipped: `socket.handshake.auth`
## on the server IS this packet's payload. An empty dictionary encodes as a
## bare `40`, which is what `socket.io-client` sends when a caller passes no
## auth — the server reads `{}` and `handshakeAuthSchema.parse` refuses it on
## the missing `token`, which is the correct and loud outcome.
static func encode_connect(auth: Dictionary) -> String:
	if auth.is_empty():
		return EIO_MESSAGE + SIO_CONNECT
	return EIO_MESSAGE + SIO_CONNECT + JSON.stringify(auth)


## An outbound EVENT, e.g. `encode_event("message.read", {…})` → `42["message.read",{…}]`.
static func encode_event(name: String, payload: Variant) -> String:
	return EIO_MESSAGE + SIO_EVENT + JSON.stringify([name, payload])


## The answer to a server `2`. Sending nothing here is how a connection dies
## after `pingTimeout` with no error anywhere.
static func encode_pong() -> String:
	return EIO_PONG


## The client-initiated close, so the server's `disconnect` fires promptly
## rather than on its own timeout.
static func encode_close() -> String:
	return EIO_CLOSE


## Decode one text frame.
##
## Always returns a Dictionary with a `kind` key. Never null, never throws.
static func decode(frame: String) -> Dictionary:
	if frame.is_empty():
		return {"kind": KIND_MALFORMED, "raw": frame}
	var head := frame.substr(0, 1)
	var rest := frame.substr(1)
	match head:
		EIO_OPEN:
			var parsed: Variant = JSON.parse_string(rest)
			if typeof(parsed) != TYPE_DICTIONARY:
				return {"kind": KIND_MALFORMED, "raw": frame}
			var d: Dictionary = parsed
			return {
				"kind": KIND_OPEN,
				"sid": str(d.get("sid", "")),
				"ping_interval_ms": int(d.get("pingInterval", DEFAULT_PING_INTERVAL_MS)),
				"ping_timeout_ms": int(d.get("pingTimeout", DEFAULT_PING_TIMEOUT_MS)),
			}
		EIO_CLOSE:
			return {"kind": KIND_CLOSE}
		EIO_PING:
			return {"kind": KIND_PING}
		EIO_PONG:
			return {"kind": KIND_PONG}
		EIO_MESSAGE:
			return _decode_socketio(rest, frame)
		_:
			return {"kind": KIND_IGNORED, "raw": frame}


static func _decode_socketio(body: String, raw: String) -> Dictionary:
	if body.is_empty():
		return {"kind": KIND_MALFORMED, "raw": raw}
	var kind := body.substr(0, 1)
	var tail := body.substr(1)

	# Namespace, when present, is `<nsp>,` and always starts with `/`.
	var nsp := DEFAULT_NAMESPACE
	if tail.begins_with("/"):
		var comma := tail.find(",")
		if comma == -1:
			nsp = tail
			tail = ""
		else:
			nsp = tail.substr(0, comma)
			tail = tail.substr(comma + 1)

	# An ack id is leading decimal digits. Read with explicit code points
	# rather than `is_valid_int()` on a prefix, because `-` and `+` are valid
	# in an int and are not valid here.
	var digits := ""
	while not tail.is_empty():
		var c := tail.unicode_at(0)
		if c < 48 or c > 57:
			break
		digits += tail.substr(0, 1)
		tail = tail.substr(1)
	var ack_id := digits.to_int() if not digits.is_empty() else -1

	match kind:
		SIO_CONNECT:
			var data: Variant = JSON.parse_string(tail) if not tail.is_empty() else {}
			return {
				"kind": KIND_CONNECT,
				"nsp": nsp,
				"sid": str((data as Dictionary).get("sid", "")) if typeof(data) == TYPE_DICTIONARY else "",
			}
		SIO_CONNECT_ERROR:
			# The gateway's `next(err)` lands here. socket.io wraps it as
			# `{"message":"Unauthorized"}` — the bare word that names neither
			# of the two visitor credentials, which is the whole reason
			# `docs/prompts/5/mobile-sdk-visitor-contract.md` exists. We pass
			# it up verbatim and the realtime client adds the context.
			var err: Variant = JSON.parse_string(tail) if not tail.is_empty() else {}
			var message := ""
			if typeof(err) == TYPE_DICTIONARY:
				message = str((err as Dictionary).get("message", ""))
			elif typeof(err) == TYPE_STRING:
				message = str(err)
			return {"kind": KIND_CONNECT_ERROR, "nsp": nsp, "message": message}
		SIO_DISCONNECT:
			return {"kind": KIND_DISCONNECT, "nsp": nsp}
		SIO_EVENT:
			var arr: Variant = JSON.parse_string(tail)
			if typeof(arr) != TYPE_ARRAY or (arr as Array).is_empty():
				return {"kind": KIND_MALFORMED, "raw": raw}
			var a: Array = arr
			return {
				"kind": KIND_EVENT,
				"nsp": nsp,
				"name": str(a[0]),
				"payload": a[1] if a.size() > 1 else null,
				"ack_id": ack_id,
			}
		SIO_ACK:
			return {"kind": KIND_ACK, "nsp": nsp, "ack_id": ack_id}
		SIO_BINARY_EVENT, SIO_BINARY_ACK:
			# The gateway emits JSON only. A binary attachment would arrive as
			# this header plus N following binary frames; we do not reassemble
			# them, and saying so here is better than a half-implementation
			# that mis-frames the stream.
			return {"kind": KIND_IGNORED, "raw": raw}
		_:
			return {"kind": KIND_IGNORED, "raw": raw}
