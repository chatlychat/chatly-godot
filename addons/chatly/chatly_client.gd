##
## The node a game adds to its scene. Everything else in this addon is behind it.
##
## ── Minimal use ────────────────────────────────────────────────────────
##
##     var chat := ChatlyClient.new()
##     chat.public_id = "ch_live_xxx"
##     add_child(chat)
##     chat.message_received.connect(_on_message)
##     await chat.open()                       # init + resume or create a thread
##     await chat.send("my quest log is empty")
##
## `open()` is a coroutine; so are `send()` and the rest. Nothing here blocks a
## frame — the HTTP work is on `HTTPRequest`'s own thread.
##
## ── The two transports, and why the game is told which ────────────────
##
## `open()` tries the socket, and falls back to polling when the mint or the
## handshake is refused — a 403 on a channel with an origin allow-list (a game
## sends no `Origin`), a 404 on a conversation that is not this visitor's, an
## operator who never set `VISITOR_REALTIME_JWT_SECRET`. `transport_changed`
## fires with `"realtime"` or `"polling"` so the UI can say "messages may take
## a few seconds" instead of leaving the player wondering.
##
## It must never claim realtime and silently not have it. That is the exact
## failure `docs/prompts/5/mobile-sdk-visitor-contract.md` exists to prevent,
## and it is why `transport_changed` is a signal rather than a comment.
##
## ── `hidden_from_contact` is filtered here, and it matters ────────────
##
## The REST list route filters `hidden_from_contact = false` in SQL
## (`widget-conversations.service.ts:388`). **The realtime envelope does not.**
## `messageEventPayload` carries the flag deliberately, because the same
## envelope goes to the agent inbox, which is meant to render the row.
##
## So a Godot client that appends the realtime payload straight to a chat log
## would draw every silent postback as a player bubble — the dialogue choice
## the game sent with `postback(..., silent = true)` appears as if the player
## typed `accept_quest` — and then that bubble vanishes on the next launch,
## because the list route never returns it. Two sides disagreeing about what
## was said, with nothing on screen to say so.
##
## `message_received` therefore omits hidden rows. Anything that genuinely
## wants them has `envelope_received`, which is unfiltered.
##
## `@chatlychat/core` makes the opposite choice and keeps hidden rows in the
## data for the renderer to drop. That is right for a library whose consumer
## writes the renderer; here the signal IS the renderer-facing surface, so the
## filter belongs on this side of it.
##
## ── No API key. Ever. ────────────────────────────────────────────────
##
## A `ck_` key is a standing workspace credential and a shipped game can be
## decompiled. `public_id` is the channel's public identifier — the same string
## that sits in a `<script>` tag on a public web page — and `visitorToken` is
## scoped to one visitor on one channel. If a future change to this file wants
## an API key, the thing to change is not this file.
##
class_name ChatlyClient
extends Node

## A message the player should see. Hidden rows are already filtered out.
signal message_received(message: Dictionary)

## Every realtime envelope, unfiltered: typing, reads, assignment, closure,
## reactions, cobrowse invitations, host capabilities. Empty on the polling
## transport, which has no equivalent.
signal envelope_received(envelope: Dictionary)

## An agent or bot started/stopped typing. Realtime only.
signal typing_changed(is_typing: bool)

## `"realtime"` or `"polling"`. Fires on every change, including the first.
signal transport_changed(mode: String)

## Something the player should be told, in the server's own words where it had
## any — the upload refusals in particular are copy written to be read.
signal error_occurred(message: String)

const TRANSPORT_REALTIME := "realtime"
const TRANSPORT_POLLING := "polling"
const TRANSPORT_NONE := "none"

## The channel's public id. The one piece of configuration a game must supply.
@export var public_id: String = ""

## Override the API host. Leave empty for `api.chatlychat.com`.
@export var api_host: String = ""

## Override where the socket opens. Leave empty to use `init`'s `realtimeUrl`,
## then the `api.` → `realtime.` convention.
@export var realtime_url_override: String = ""

## `false` only for a local `pnpm dev` against plain HTTP.
@export var secure: bool = true

## Set `false` to skip the socket entirely and poll. Useful for a build
## targeting a network that kills WebSockets.
@export var use_realtime: bool = true

## BCP-47 and an IANA zone. Empty means "ask the engine".
@export var locale: String = ""
@export var timezone: String = ""

var rest: ChatlyRestClient = null
var realtime: ChatlyRealtime = null
var polling: ChatlyPolling = null

var _transport: String = TRANSPORT_NONE
var _conversation_id: String = ""
var _contact_id: String = ""
var _transport_node: ChatlyHttpTransport = null
var _store: ChatlyTokenStore = null
var _socket_factory: ChatlySocketFactory = null
var _opened: bool = false

## Injected by the suite. A game leaves both null and gets the real ones.
var injected_transport: ChatlyHttpTransport = null
var injected_socket_factory: ChatlySocketFactory = null
var injected_store: ChatlyTokenStore = null


func _ready() -> void:
	_build()


func _build() -> void:
	if rest != null:
		return
	if public_id.strip_edges().is_empty():
		push_error("[chatly] ChatlyClient.public_id is required")
		return

	if injected_transport != null:
		_transport_node = injected_transport
	else:
		_transport_node = ChatlyGodotHttpTransport.new()
		_transport_node.name = "ChatlyHttp"
		add_child(_transport_node)

	_store = injected_store if injected_store != null else ChatlyTokenStore.new(public_id)
	_socket_factory = (
		injected_socket_factory
		if injected_socket_factory != null
		else ChatlyWebSocketSocketFactory.new()
	)

	rest = ChatlyRestClient.new(
		public_id,
		_transport_node,
		_store,
		api_host if not api_host.is_empty() else ChatlyRestClient.DEFAULT_API_HOST,
		secure,
		locale if not locale.is_empty() else OS.get_locale(),
		timezone if not timezone.is_empty() else _system_timezone(),
	)
	polling = ChatlyPolling.new(rest)
	polling.message_received.connect(_on_polled_message)
	polling.poll_failed.connect(_on_poll_failed)


## IANA zone name, e.g. `Europe/London`.
##
## `Time.get_time_zone_from_system()` answers `{ bias, name }`, and `name` is
## an ABBREVIATION on some platforms (`GMT`, `BST`) rather than a zone. The
## server stores it on `contacts.timezone` and uses it for business hours, so
## an abbreviation is worse than nothing — it would be stored and then fail to
## resolve. Empty when we cannot do better, and `init` simply omits the field.
static func _system_timezone() -> String:
	var tz := Time.get_time_zone_from_system()
	var name := str(tz.get("name", ""))
	return name if name.contains("/") else ""


func _process(delta: float) -> void:
	if realtime != null:
		realtime.tick(delta)
	if polling != null:
		polling.tick(delta)


## Boot a session, resume the player's most recent thread or wait for a first
## message, and bring up the best available transport.
##
## `identity` is optional and is `{ externalId, name, email, userHash }`. Send
## `userHash` whenever the channel has identity verification on; without it a
## verified channel refuses the claim. The hash is an HMAC over the external id
## with the channel's secret and **must be computed by your own server** — a
## game that ships the secret has published it.
func open(identity: Dictionary = {}) -> bool:
	_build()
	if rest == null:
		return false

	var booted := await rest.init_session(identity)
	if not booted.ok:
		error_occurred.emit(booted.message)
		return false
	_opened = true

	var session: Variant = (booted.data as Dictionary).get("session", {})
	if typeof(session) == TYPE_DICTIONARY:
		_contact_id = str((session as Dictionary).get("contactId", ""))

	var from_server := ""
	var reported: Variant = (booted.data as Dictionary).get("realtimeUrl", null)
	if typeof(reported) == TYPE_STRING:
		from_server = reported

	# Resume the most recent thread if there is one. A player who alt-tabbed
	# out mid-conversation and came back should not get a second thread, and
	# an anonymous visitor with no contact yet gets `{ conversations: [] }`
	# rather than an error.
	var threads := await rest.list_conversations(5)
	if threads.ok and typeof(threads.data) == TYPE_DICTIONARY:
		var rows: Variant = (threads.data as Dictionary).get("conversations", [])
		if typeof(rows) == TYPE_ARRAY and not (rows as Array).is_empty():
			var first: Variant = (rows as Array)[0]
			if typeof(first) == TYPE_DICTIONARY:
				_conversation_id = str((first as Dictionary).get("id", ""))

	if not _conversation_id.is_empty():
		await _load_history()
		await _attach_transport(from_server)
	return true


## The thread this client is on, or `""` before the first message.
func conversation_id() -> String:
	return _conversation_id


## Which transport is live: `"realtime"`, `"polling"` or `"none"`.
func transport() -> String:
	return _transport


## Send a message, opening the thread if this is the first one.
##
## `attachments` are records from `upload()`. The server refuses a blank body
## with no attachments ("Send a message or an attachment"), so this does too,
## with words rather than a 400.
func send(body: String, attachments: Array = []) -> bool:
	if rest == null:
		return false
	if body.strip_edges().is_empty() and attachments.is_empty():
		error_occurred.emit("Send a message or an attachment.")
		return false

	if _conversation_id.is_empty():
		var started := await rest.start_conversation(body, attachments)
		if not started.ok:
			error_occurred.emit(started.message)
			return false
		var d: Dictionary = started.data if typeof(started.data) == TYPE_DICTIONARY else {}
		var conv: Variant = d.get("conversation", {})
		if typeof(conv) == TYPE_DICTIONARY:
			# `id` is the ONLY field both response arms carry. The
			# blocked-contact arm returns the raw `conversations` row with
			# fifteen columns the DTO does not publish and a flattened
			# `agentHandling*`; reading anything else off it would work until
			# it did not.
			_conversation_id = str((conv as Dictionary).get("id", ""))
		_note_own_message(d.get("message", null))
		if not _conversation_id.is_empty():
			var from_server := ""
			await _attach_transport(from_server)
		return true

	var sent := await rest.reply(_conversation_id, body, attachments)
	if not sent.ok:
		error_occurred.emit(sent.message)
		return false
	_note_own_message(sent.data)
	return true


## A dialogue choice or card button: text the bot reads, with no player bubble.
##
## `silent` defaults true because that is what makes a quest-dialogue option
## work — the bot hears `accept_quest`, the player does not see their own click
## echoed. `payload` is the structured half the bot author reads.
func choose(value: String, payload: Dictionary = {}, silent: bool = true) -> bool:
	if rest == null or _conversation_id.is_empty():
		error_occurred.emit("There is no conversation to answer yet.")
		return false
	var result := await rest.postback(_conversation_id, value, payload, silent)
	if not result.ok:
		error_occurred.emit(result.message)
		return false
	_note_own_message(result.data)
	return true


## Persist how far the player has read, and tick the agent's "Read" live.
##
## Two writes on purpose: the REST one is the row (it survives a restart and
## is what moves `unreadContactCount`), and the socket one is the advisory tick
## in the agent's inbox. Doing only the second means the unread count can only
## ever go up.
func mark_read(up_to_message_id: String = "") -> void:
	if rest == null or _conversation_id.is_empty():
		return
	if realtime != null:
		realtime.emit_read(up_to_message_id)
	var result := await rest.mark_read(_conversation_id, up_to_message_id)
	if not result.ok:
		# Not surfaced to the player: a read receipt failing is not something
		# they did or can fix, and a toast about it would be noise.
		push_warning("[chatly] mark_read refused: %s" % result.message)


## Upload bytes and get back the attachment record `send()` wants.
##
## A screenshot is the obvious use:
##     var image := get_viewport().get_texture().get_image()
##     var rec := await chat.upload(image.save_png_to_buffer(), "bug.png", "image/png")
##     if not rec.is_empty():
##         await chat.send("this happened", [rec])
func upload(bytes: PackedByteArray, filename: String, mime_type: String) -> Dictionary:
	if rest == null:
		return {}
	var result := await rest.upload_attachment(bytes, filename, mime_type)
	if not result.ok:
		# The three refusals here are written for the visitor to read — "That
		# file type is not accepted: …", "Files must be under 10 MB" — so they
		# go straight to the UI.
		error_occurred.emit(result.message)
		return {}
	return result.data if typeof(result.data) == TYPE_DICTIONARY else {}


## Search the workspace's help centre. Works before any conversation exists.
func search_help(query: String, limit: int = 8, profile: String = "") -> Array:
	if rest == null:
		return []
	var result := await rest.kb_search(query, limit, profile)
	if not result.ok or typeof(result.data) != TYPE_DICTIONARY:
		return []
	var rows: Variant = (result.data as Dictionary).get("results", [])
	return rows if typeof(rows) == TYPE_ARRAY else []


## Report a named event — feeds CDP audiences and workflow triggers.
func track(event_name: String, properties: Dictionary = {}) -> void:
	if rest == null:
		return
	var result := await rest.track(event_name, properties)
	if not result.ok:
		push_warning("[chatly] track(%s) refused: %s" % [event_name, result.message])


## Forget this device's session. The next `open()` starts anonymous.
func logout() -> void:
	_teardown()
	if rest != null:
		rest.logout()
	_conversation_id = ""
	_contact_id = ""
	_opened = false


func _exit_tree() -> void:
	_teardown()


func _teardown() -> void:
	if realtime != null:
		realtime.stop()
		realtime = null
	if polling != null:
		polling.stop()
	_set_transport(TRANSPORT_NONE)


# ── Transport selection ───────────────────────────────────────────────────

func _attach_transport(realtime_url_from_server: String) -> void:
	if _conversation_id.is_empty():
		return
	if not use_realtime:
		_start_polling()
		return

	var url := ChatlyRealtime.resolve_url(
		realtime_url_override, realtime_url_from_server, rest.base_url()
	)
	realtime = ChatlyRealtime.new(url, _mint_for_realtime, _socket_factory)
	realtime.connected.connect(_on_realtime_connected)
	realtime.disconnected.connect(_on_realtime_disconnected)
	realtime.envelope_received.connect(_on_envelope)
	realtime.unavailable.connect(_on_realtime_unavailable)
	await realtime.start(_conversation_id, _contact_id)


## The mint, as a Callable, so `ChatlyRealtime` holds no REST client.
func _mint_for_realtime(conversation_id: String) -> ChatlyResult:
	return await rest.mint_realtime_token(conversation_id)


func _on_realtime_connected() -> void:
	if polling != null and polling.is_running():
		# Recovered. Stop paying for both.
		polling.stop()
	_set_transport(TRANSPORT_REALTIME)


func _on_realtime_disconnected(_reason: String) -> void:
	# A reconnect is already scheduled with backoff. Polling is NOT started
	# here: a one-second blip would otherwise start a poller that then races
	# the recovered socket, and both would deliver the same message.
	pass


func _on_realtime_unavailable(reason: String) -> void:
	# This is the arm that matters. The mint or the handshake was refused for a
	# reason retrying will not fix, so the thread falls back to polling rather
	# than looking dead.
	push_warning("[chatly] live delivery unavailable (%s) — falling back to polling" % reason)
	_start_polling()


func _start_polling() -> void:
	if polling == null or _conversation_id.is_empty():
		return
	if polling.is_running():
		return
	polling.start(_conversation_id, _seen_ids)
	_set_transport(TRANSPORT_POLLING)


func _set_transport(mode: String) -> void:
	if _transport == mode:
		return
	_transport = mode
	transport_changed.emit(mode)


# ── Message bookkeeping ───────────────────────────────────────────────────

## Ids already emitted, so the two transports cannot double-deliver one
## message and the sender's own echo does not draw twice.
var _seen_ids: Array = []


func _load_history() -> void:
	var result := await rest.list_messages(_conversation_id, 50)
	if not result.ok or typeof(result.data) != TYPE_DICTIONARY:
		return
	var rows: Variant = (result.data as Dictionary).get("messages", [])
	if typeof(rows) != TYPE_ARRAY:
		return
	for row: Variant in (rows as Array):
		if typeof(row) == TYPE_DICTIONARY:
			_deliver(row)


## Record a message this client just sent, so the realtime echo of it is not
## delivered a second time.
##
## The visitor's own messages DO flow through the socket — `visitorShouldReceive`
## forwards them deliberately, for multi-tab consistency — so without this a
## player sees everything they send twice.
func _note_own_message(message: Variant) -> void:
	if typeof(message) != TYPE_DICTIONARY:
		return
	var id := str((message as Dictionary).get("id", ""))
	if id.is_empty():
		return
	if not _seen_ids.has(id):
		_seen_ids.append(id)
	if polling != null:
		polling.mark_seen(id)
	_deliver(message, true)


func _on_polled_message(message: Dictionary) -> void:
	_deliver(message)


func _on_poll_failed(reason: String) -> void:
	push_warning("[chatly] poll failed: %s" % reason)


func _on_envelope(envelope: Dictionary) -> void:
	envelope_received.emit(envelope)
	var kind := str(envelope.get("type", ""))
	var payload: Variant = envelope.get("payload", null)
	if typeof(payload) != TYPE_DICTIONARY:
		return
	var p: Dictionary = payload
	match kind:
		"message.created", "message.updated":
			_deliver(p)
		"typing.start":
			typing_changed.emit(true)
		"typing.stop":
			typing_changed.emit(false)
		_:
			# `message.deleted`, `conversation.*`, `message.read`,
			# `message.reaction_changed`, `cobrowse.*`,
			# `host.capability_invoked`. All reach `envelope_received` above;
			# a game that wants them handles them there. Not folded into
			# `message_received`, because none of them is a message.
			pass


func _deliver(message: Dictionary, own: bool = false) -> void:
	var id := str(message.get("id", ""))
	if id.is_empty():
		return
	if not own and _seen_ids.has(id):
		return
	if not _seen_ids.has(id):
		_seen_ids.append(id)

	# See this file's header. The realtime envelope carries
	# `hiddenFromContact`; the REST list filters it in SQL and never sends one.
	# A silent postback drawn as a player bubble is the bug this line prevents.
	if message.get("hiddenFromContact", false) == true:
		return

	message_received.emit(message)
