##
## The Engine.IO v4 / Socket.IO v5 codec, on literal strings.
##
## These are the frames `socket.io@4.7.5` + `engine.io@6.5.5` actually produce
## — the versions pinned in `pnpm-workspace.yaml`'s catalog and used by
## `apps/realtime`. `tests/live/` then proves the same codec against a real
## server, because a codec tested only against strings I wrote agrees with
## whatever I misremembered.
##
extends ChatlyTestCase

const EIO = preload("res://addons/chatly/engineio.gd")


# ── The handshake URL ────────────────────────────────────────────────────

## `EIO=4` is not optional. Omit it and engine.io answers HTTP 400 with
## `{"code":5,"message":"Unsupported protocol version"}`, which over a
## WebSocket upgrade surfaces as a bare handshake failure with nothing saying
## why.
func test_handshake_url_declares_the_protocol_version_and_transport() -> void:
	var url := EIO.handshake_url("https://realtime.chatlychat.com")
	equal(url, "wss://realtime.chatlychat.com/socket.io/?EIO=4&transport=websocket", "canonical")


## Both schemes are accepted because a human writing a config file reaches for
## whichever they saw last, and getting it wrong produces a connection that
## never opens with no message saying why.
func test_handshake_url_maps_every_scheme_to_ws_or_wss() -> void:
	equal(
		EIO.handshake_url("wss://r.example.com"),
		"wss://r.example.com/socket.io/?EIO=4&transport=websocket",
		"wss stays wss",
	)
	equal(
		EIO.handshake_url("http://localhost:4001"),
		"ws://localhost:4001/socket.io/?EIO=4&transport=websocket",
		"http becomes ws, and the port survives",
	)
	equal(
		EIO.handshake_url("ws://localhost:4001"),
		"ws://localhost:4001/socket.io/?EIO=4&transport=websocket",
		"ws stays ws",
	)


func test_handshake_url_normalises_slashes() -> void:
	equal(
		EIO.handshake_url("https://r.example.com/"),
		"wss://r.example.com/socket.io/?EIO=4&transport=websocket",
		"a trailing slash on the host does not double up",
	)
	equal(
		EIO.handshake_url("https://r.example.com", "realtime/"),
		"wss://r.example.com/realtime/?EIO=4&transport=websocket",
		"a path with no leading slash and a trailing one is normalised",
	)


# ── Encoding ─────────────────────────────────────────────────────────────

## `socket.handshake.auth` on the server IS this packet's payload. This is
## where `{ token, kind: "visitor" }` goes.
func test_connect_carries_the_auth_object_as_the_packet_payload() -> void:
	var frame := EIO.encode_connect({"token": "abc", "kind": "visitor"})
	check(frame.begins_with("40"), "EIO message + SIO connect, got %s" % frame)
	var decoded: Variant = JSON.parse_string(frame.substr(2))
	equal((decoded as Dictionary).get("kind", ""), "visitor", "kind survives the round trip")
	equal((decoded as Dictionary).get("token", ""), "abc", "token survives the round trip")


## A bare `40` is what `socket.io-client` sends with no auth. The server reads
## `{}` and `handshakeAuthSchema.parse` refuses it on the missing `token` —
## which is the correct and loud outcome, so it is encoded rather than
## prevented.
func test_an_empty_auth_encodes_as_a_bare_connect() -> void:
	equal(EIO.encode_connect({}), "40", "no payload at all")


func test_event_encodes_as_a_name_payload_pair() -> void:
	var frame := EIO.encode_event("message.read", {"conversationId": "c1"})
	check(frame.begins_with("42"), "EIO message + SIO event, got %s" % frame)
	var arr: Variant = JSON.parse_string(frame.substr(2))
	equal(typeof(arr), TYPE_ARRAY, "the payload is a two-element array")
	equal((arr as Array)[0], "message.read", "the event name is element 0")


func test_pong_and_close_are_single_characters() -> void:
	equal(EIO.encode_pong(), "3", "Engine.IO PONG")
	equal(EIO.encode_close(), "1", "Engine.IO CLOSE")


# ── Decoding ─────────────────────────────────────────────────────────────

## The server's very first frame. `pingInterval` and `pingTimeout` are read
## from it rather than assumed, because they are server configuration — and
## the two together are the budget after which a silent socket is dead.
func test_open_yields_the_sid_and_both_ping_numbers() -> void:
	var packet := EIO.decode(
		'0{"sid":"abc123","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}'
	)
	equal(packet["kind"], EIO.KIND_OPEN, "open")
	equal(packet["sid"], "abc123", "sid")
	equal(packet["ping_interval_ms"], 25000, "pingInterval — socket.io 4.7.5's default")
	equal(packet["ping_timeout_ms"], 20000, "pingTimeout — socket.io 4.7.5's default")


## An `open` frame with the numbers missing must not leave the budget at zero,
## which would mark every connection dead on its first frame.
func test_open_without_the_ping_numbers_falls_back_to_the_defaults() -> void:
	var packet := EIO.decode('0{"sid":"x"}')
	equal(packet["ping_interval_ms"], EIO.DEFAULT_PING_INTERVAL_MS, "interval default")
	equal(packet["ping_timeout_ms"], EIO.DEFAULT_PING_TIMEOUT_MS, "timeout default")


## The Engine.IO ping is NOT the WebSocket ping.
## `WebSocketPeer.heartbeat_interval` sends RFC 6455 PING frames at the
## WebSocket layer; this is a text frame `2` at the Engine.IO layer, and a
## client that answers only the first dies after `pingTimeout` with nothing in
## any log.
func test_ping_is_recognised_as_its_own_packet() -> void:
	equal(EIO.decode("2")["kind"], EIO.KIND_PING, "a bare 2 is the server's ping")
	equal(EIO.decode("3")["kind"], EIO.KIND_PONG, "a bare 3 is a pong")
	equal(EIO.decode("1")["kind"], EIO.KIND_CLOSE, "a bare 1 is close")


func test_connect_ack_is_distinguished_from_the_websocket_opening() -> void:
	var packet := EIO.decode('40{"sid":"socket-side-id"}')
	equal(packet["kind"], EIO.KIND_CONNECT, "the CONNECT was accepted")
	equal(packet["sid"], "socket-side-id", "the Socket.IO sid, which differs from the Engine.IO one")


## Where the gateway's `next(err)` lands. For a visitor it is almost always
## the bare `Unauthorized` that names neither of the two credentials — which
## is the whole reason the visitor contract document exists.
func test_connect_error_carries_the_servers_message() -> void:
	var packet := EIO.decode('44{"message":"Unauthorized"}')
	equal(packet["kind"], EIO.KIND_CONNECT_ERROR, "a refusal, not a drop")
	equal(packet["message"], "Unauthorized", "verbatim")


func test_connect_error_with_no_body_still_decodes() -> void:
	equal(EIO.decode("44")["kind"], EIO.KIND_CONNECT_ERROR, "no payload is still a refusal")


func test_event_yields_the_channel_name_and_the_envelope() -> void:
	var packet := EIO.decode(
		'42["event",{"v":1,"type":"message.created","id":"ev1","ts":1,"workspace_id":"w","payload":{"body":"hi"}}]'
	)
	equal(packet["kind"], EIO.KIND_EVENT, "event")
	equal(packet["name"], "event", "the gateway emits on the channel literally named 'event'")
	var envelope: Dictionary = packet["payload"]
	equal(envelope.get("type", ""), "message.created", "the envelope's own type")


## An EVENT that expects an ack is `42<id>[...]`. The gateway never asks a
## visitor for one, but mis-parsing the digits as part of the JSON would
## corrupt the frame rather than ignore it.
func test_an_ack_id_is_stripped_rather_than_breaking_the_json() -> void:
	var packet := EIO.decode('4217["event",{"type":"x"}]')
	equal(packet["kind"], EIO.KIND_EVENT, "still an event")
	equal(packet["ack_id"], 17, "the ack id was read")
	equal(packet["name"], "event", "and the JSON after it parsed")


## A namespaced packet is `<nsp>,` before the payload. The gateway registers
## only the default namespace, so this is defensive — but a namespace left in
## the JSON would make every frame malformed.
func test_a_namespace_is_parsed_off_the_front() -> void:
	var packet := EIO.decode('42/admin,["event",{"type":"x"}]')
	equal(packet["kind"], EIO.KIND_EVENT, "event")
	equal(packet["nsp"], "/admin", "the namespace was separated")
	equal(packet["name"], "event", "and the payload still parsed")


func test_the_default_namespace_is_reported_when_absent() -> void:
	equal(EIO.decode('42["event",{}]')["nsp"], EIO.DEFAULT_NAMESPACE, "implicit /")


## Binary attachments are reported as ignored rather than half-reassembled. A
## mis-framed binary stream would desynchronise every frame after it.
func test_binary_packets_are_ignored_not_misparsed() -> void:
	equal(EIO.decode('451-["event",{"_placeholder":true}]')["kind"], EIO.KIND_IGNORED, "binary event")
	equal(EIO.decode("461-[]")["kind"], EIO.KIND_IGNORED, "binary ack")


# ── Nothing from the network may crash a game ───────────────────────────

## A game's main loop must not be able to die on bytes it did not choose. A
## captive portal, a transparent proxy or a future server can all send
## something unexpected, so `decode` is total: it never returns null and never
## throws.
func test_decode_is_total() -> void:
	var hostile := [
		"",                  # an empty frame
		"4",                 # a message with no Socket.IO packet
		"40{",               # truncated JSON
		"42",                # an event with no array
		"42{}",              # an event whose payload is not an array
		"42[]",              # an event with an empty array
		"9",                 # an Engine.IO type that does not exist
		"<html>502</html>",  # a proxy's error page
		"0",                 # an open frame with no handshake object
		"0[]",               # an open frame whose payload is an array
		"42/no-comma",       # a namespace that never terminates
	]
	for frame: String in hostile:
		var packet := EIO.decode(frame)
		check(
			typeof(packet) == TYPE_DICTIONARY and packet.has("kind"),
			"decode(%s) must answer a dictionary with a kind" % JSON.stringify(frame),
		)
		check(
			str(packet["kind"]) in [
				EIO.KIND_MALFORMED, EIO.KIND_IGNORED, EIO.KIND_OPEN, EIO.KIND_CONNECT,
				EIO.KIND_EVENT, EIO.KIND_CLOSE, EIO.KIND_PING, EIO.KIND_PONG,
				EIO.KIND_CONNECT_ERROR, EIO.KIND_DISCONNECT, EIO.KIND_ACK,
			],
			"decode(%s) answered an unknown kind %s" % [JSON.stringify(frame), packet["kind"]],
		)
