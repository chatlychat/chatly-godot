##
## `ChatlyClient` — the transport choice, and the renderer-facing filters.
##
extends ChatlyTestCase

const RecordingTransport = preload("res://tests/fakes/recording_transport.gd")
const RecordingFactory = preload("res://tests/fakes/recording_factory.gd")
const RecordingSocket = preload("res://tests/fakes/recording_socket.gd")
const MemoryStore = preload("res://tests/fakes/memory_store.gd")

const CONVERSATION := "0192f0c0-0000-7000-8000-000000000001"
const CONTACT := "0192f0c0-0000-7000-8000-000000000002"

var _transport: RecordingTransport
var _factory: RecordingFactory
var _client: ChatlyClient
var _messages: Array[Dictionary] = []
var _envelopes: Array[Dictionary] = []
var _transports: Array[String] = []


## Builds a client with an existing thread, a working mint, and the socket
## seam replaced.
func _build(with_thread: bool = true) -> void:
	_messages = []
	_envelopes = []
	_transports = []
	_transport = RecordingTransport.new()
	_factory = RecordingFactory.new()

	_transport.queue_always("/v1/widget/init", 201, {
		"session": {"token": "t", "contactId": CONTACT, "workspaceId": "w1"},
		"realtimeUrl": "wss://realtime.chatlychat.com",
	})
	if with_thread:
		_transport.queue_always("/v1/widget/conversations/list", 201, {
			"conversations": [{"id": CONVERSATION, "status": "open", "subject": null}],
		})
	else:
		_transport.queue_always("/v1/widget/conversations/list", 201, {"conversations": []})
	_transport.queue_always("/v1/widget/messages/list", 201, {"messages": []})
	_transport.queue_always("/v1/widget/realtime/token", 201, {"token": "rt-1", "expiresAt": "x"})

	_client = ChatlyClient.new()
	_client.public_id = "ch_live_test"
	_client.injected_transport = _transport
	_client.injected_socket_factory = _factory
	_client.injected_store = MemoryStore.new()
	Engine.get_main_loop().root.add_child(_client)

	_client.message_received.connect(func(m: Dictionary) -> void: _messages.append(m))
	_client.envelope_received.connect(func(e: Dictionary) -> void: _envelopes.append(e))
	_client.transport_changed.connect(func(mode: String) -> void: _transports.append(mode))


func _teardown() -> void:
	if _client != null:
		_client.queue_free()
		_client = null


# ── THE filter ───────────────────────────────────────────────────────────

## `hiddenFromContact` is carried by the realtime envelope and NOT by the REST
## list, which filters it in SQL (`widget-conversations.service.ts:388`). The
## asymmetry is deliberate on the server's side — the same envelope goes to the
## agent inbox, which is meant to render the row.
##
## So a client that appends the realtime payload straight to a chat log draws
## every silent postback as a player bubble: the dialogue option the game sent
## with `choose("accept_quest")` appears as if the player typed it. And then it
## VANISHES on the next launch, because the list route never returns it — two
## sides disagreeing about what was said, with nothing on screen to say so.
##
## Delete the guard in `ChatlyClient._deliver` and this is the test that goes
## red.
func test_a_hidden_message_never_reaches_the_renderer() -> void:
	await _build()
	await _client.open()
	var socket := _factory.last_socket() as RecordingSocket
	socket.accept()

	socket.deliver({
		"v": 1, "type": "message.created", "id": "ev-1", "ts": 1, "workspace_id": "w1",
		"payload": {"id": "m-hidden", "body": "accept_quest", "authorType": "contact", "hiddenFromContact": true},
	})
	socket.deliver({
		"v": 1, "type": "message.created", "id": "ev-2", "ts": 2, "workspace_id": "w1",
		"payload": {"id": "m-visible", "body": "Taking the quest!", "authorType": "agent", "hiddenFromContact": false},
	})

	equal(_messages.size(), 1, "only the visible one was delivered to the renderer")
	equal(_messages[0].get("id", ""), "m-visible", "and it is the right one")
	# Unfiltered, for anything that genuinely wants the hidden row.
	equal(_envelopes.size(), 2, "both envelopes reach envelope_received")
	_teardown()


## A payload with no `hiddenFromContact` at all must render. The key is absent
## on the REST projection and on an older server, and defaulting to "hidden"
## would blank the entire thread.
func test_a_message_with_no_hidden_flag_renders() -> void:
	await _build()
	await _client.open()
	var socket := _factory.last_socket() as RecordingSocket
	socket.accept()
	socket.deliver({
		"v": 1, "type": "message.created", "id": "ev-1", "ts": 1, "workspace_id": "w1",
		"payload": {"id": "m-1", "body": "hello", "authorType": "agent"},
	})
	equal(_messages.size(), 1, "absent means visible, not hidden")
	_teardown()


## The visitor's own messages DO flow back through the socket —
## `visitorShouldReceive` forwards them deliberately, for multi-tab
## consistency. So without de-duplication a player sees everything they send
## twice.
func test_a_message_is_delivered_once_even_when_both_paths_carry_it() -> void:
	await _build()
	await _client.open()
	var socket := _factory.last_socket() as RecordingSocket
	socket.accept()

	_transport.queue("/v1/widget/messages", 201, {"id": "m-mine", "body": "hi", "authorType": "contact"})
	await _client.send("hi")
	equal(_messages.size(), 1, "the optimistic echo drew once")

	# The server's copy of the same message comes back over the socket.
	socket.deliver({
		"v": 1, "type": "message.created", "id": "ev-9", "ts": 9, "workspace_id": "w1",
		"payload": {"id": "m-mine", "body": "hi", "authorType": "contact"},
	})
	equal(_messages.size(), 1, "and the socket echo did not draw it a second time")
	_teardown()


# ── Transport selection, and saying which ───────────────────────────────

func test_a_working_socket_reports_the_realtime_transport() -> void:
	await _build()
	await _client.open()
	equal(_factory.count(), 1, "a socket was opened")
	(_factory.last_socket() as RecordingSocket).accept()
	equal(_client.transport(), ChatlyClient.TRANSPORT_REALTIME, "realtime")
	check(_transports.has(ChatlyClient.TRANSPORT_REALTIME), "and the game was told")
	_teardown()


## THE fallback. A refused mint — a 403 because the channel has an origin
## allow-list (a game sends no `Origin`, and the mint route re-runs
## `enforceOrigin`), or a 404 because the conversation is not this visitor's —
## is not cured by retrying and does not stop REST working.
##
## A client that claimed realtime here and silently had none is the failure
## this whole package is written against.
func test_a_refused_mint_falls_back_to_polling_and_says_so() -> void:
	await _build()
	# Replace the mint answer with the 403 a channel with an origin allow-list
	# produces for a native client.
	_transport.queue_always("/v1/widget/realtime/token", 403, {
		"error": {"code": "origin_not_allowed", "message": "This origin is not allowed"},
	})
	await _client.open()

	equal(_factory.count(), 0, "no socket could be opened")
	equal(_client.transport(), ChatlyClient.TRANSPORT_POLLING, "so it polls")
	check(_transports.has(ChatlyClient.TRANSPORT_POLLING), "and the game was told, not left guessing")
	check(_client.polling.is_running(), "the poller is actually running")
	_teardown()


## `use_realtime = false` skips the socket entirely — for a build targeting a
## network that kills WebSockets.
func test_realtime_can_be_turned_off_outright() -> void:
	await _build()
	_client.use_realtime = false
	await _client.open()
	equal(_factory.count(), 0, "no socket was even attempted")
	equal(_transport.count_to("/v1/widget/realtime/token"), 0, "and no token was minted")
	equal(_client.transport(), ChatlyClient.TRANSPORT_POLLING, "polling")
	_teardown()


## A single blip must NOT start the poller: `ChatlyRealtime` already has a
## reconnect scheduled with backoff, and a poller started here would race the
## recovered socket and both would deliver the same message.
func test_a_transient_drop_does_not_start_the_poller() -> void:
	await _build()
	await _client.open()
	var socket := _factory.last_socket() as RecordingSocket
	socket.accept()
	socket.drop("transport close")

	check(not _client.polling.is_running(), "a drop is handled by backoff, not by polling")
	_teardown()


# ── Resuming ─────────────────────────────────────────────────────────────

## A player who alt-tabbed out mid-conversation and came back must not get a
## second thread.
func test_open_resumes_the_most_recent_thread() -> void:
	await _build(true)
	await _client.open()
	equal(_client.conversation_id(), CONVERSATION, "resumed")
	equal(_transport.count_to("/v1/widget/conversations"), 0, "no new thread was started")
	_teardown()


## With no thread yet, `open()` must not invent one — `widgetStartSchema`
## refuses an empty body, and a thread is created by the first message.
func test_open_with_no_history_waits_for_the_first_message() -> void:
	await _build(false)
	await _client.open()
	equal(_client.conversation_id(), "", "no conversation yet")
	equal(_factory.count(), 0, "and no socket, because a visitor token names no thread")
	equal(_client.transport(), ChatlyClient.TRANSPORT_NONE, "nothing is claimed")

	_transport.queue("/v1/widget/conversations", 201, {
		"conversation": {"id": CONVERSATION}, "message": {"id": "m1", "body": "help"},
	})
	await _client.send("help")
	equal(_client.conversation_id(), CONVERSATION, "the first message opened the thread")
	equal(_factory.count(), 1, "and brought up the socket")
	_teardown()


## `id` is the ONLY field both response arms of `POST /v1/widget/conversations`
## carry. The blocked-contact arm returns the raw `conversations` row with
## fifteen columns the DTO does not publish and a FLATTENED `agentHandling*`
## where the DTO nests it — so a client that read anything else off it would
## work until a contact was blocked.
func test_start_reads_only_the_id_so_the_blocked_arm_still_works() -> void:
	await _build(false)
	await _client.open()
	# The blocked arm's shape: a raw row, flattened and with extra columns.
	_transport.queue("/v1/widget/conversations", 201, {
		"conversation": {
			"id": CONVERSATION, "workspaceId": "w1", "brandId": "b1", "channelType": "web",
			"agentHandlingState": null, "agentHandlingActorUserId": null,
			"unreadContactCount": 0, "audience": null, "reopenCount": 0,
		},
		"message": {"id": "m1", "body": "help"},
	})
	await _client.send("help")
	equal(_client.conversation_id(), CONVERSATION, "the id was read from the raw row too")
	_teardown()


# ── Typing ───────────────────────────────────────────────────────────────

## `typing.start`/`typing.stop` reach a visitor for `actorType` `agent` AND
## `bot`. The allow-list read `=== 'agent'` alone for a while, so a bot's
## typing published an envelope no visitor socket was ever sent — the
## filtering is the server's job, so this client forwards whatever arrives.
func test_typing_envelopes_become_a_boolean() -> void:
	await _build()
	await _client.open()
	var socket := _factory.last_socket() as RecordingSocket
	socket.accept()

	var states: Array[bool] = []
	_client.typing_changed.connect(func(t: bool) -> void: states.append(t))

	socket.deliver({"v": 1, "type": "typing.start", "id": "e1", "ts": 1, "workspace_id": "w",
		"payload": {"conversationId": CONVERSATION, "actorType": "bot"}})
	socket.deliver({"v": 1, "type": "typing.stop", "id": "e2", "ts": 2, "workspace_id": "w",
		"payload": {"conversationId": CONVERSATION, "actorType": "agent"}})

	equal(states, [true, false] as Array[bool], "start then stop")
	equal(_messages.size(), 0, "a typing envelope is not a message")
	_teardown()


# ── Read receipts: two writes, on purpose ───────────────────────────────

## The REST write is the ROW — it survives a restart and is what moves
## `unreadContactCount`. The socket frame is the advisory tick in the agent's
## inbox. None of the four mobile SDKs called the REST route at all, so the
## unread count could only ever go UP.
func test_mark_read_writes_the_row_and_ticks_the_socket() -> void:
	await _build()
	await _client.open()
	var socket := _factory.last_socket() as RecordingSocket
	socket.accept()
	_transport.queue_always(
		"/v1/widget/conversations/%s/read" % CONVERSATION, 201, {"readAt": "x", "upToMessageId": null}
	)

	await _client.mark_read("0192f0c0-0000-7000-8000-0000000000ff")
	equal(
		_transport.count_to("/v1/widget/conversations/%s/read" % CONVERSATION),
		1,
		"the durable row was written",
	)
	equal(socket.sent.size(), 1, "and the live tick was published")
	equal(socket.sent[0]["name"], "message.read", "on the right channel")
	_teardown()


# ── URL precedence ───────────────────────────────────────────────────────

## Mirrors `apps/widget/src/realtime-url.ts` deliberately rather than
## inventing a second rule — that file's own header records that the
## precedence "was wrong in production for a long time and nothing caught it".
func test_the_realtime_url_precedence_matches_the_web_widget() -> void:
	equal(
		ChatlyRealtime.resolve_url("wss://mine.example.com", "wss://server.example.com", "https://api.chatlychat.com"),
		"wss://mine.example.com",
		"an explicit override wins",
	)
	equal(
		ChatlyRealtime.resolve_url("", "wss://server.example.com", "https://api.chatlychat.com"),
		"wss://server.example.com",
		"then init's own realtimeUrl",
	)
	# `realtimeUrl` is NULLABLE and null means "not configured", NOT "no
	# realtime" — so an empty value must fall through rather than disable the
	# socket.
	equal(
		ChatlyRealtime.resolve_url("", "", "https://api.chatlychat.com"),
		"https://realtime.chatlychat.com",
		"then the api. -> realtime. convention",
	)
	equal(
		ChatlyRealtime.resolve_url("", "", "http://localhost:4000"),
		"http://localhost:4000",
		"a host that does not start with api. is left alone",
	)
