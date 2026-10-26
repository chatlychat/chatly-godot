##
## The four assertions `docs/prompts/5/mobile-sdk-visitor-contract.md` §4 asks
## for, plus the scope rule. Every one is about what the CLIENT SENT.
##
## §4 is explicit about why: "A fake transport that answers every route with
## whatever the SDK asked for will agree with the bug — that trap has already
## cost this repo a day twice." So nothing here asserts on a canned response.
## The subject is `factory.opened`, which is the auth payload the gateway
## would actually see.
##
extends ChatlyTestCase

const RecordingFactory = preload("res://tests/fakes/recording_factory.gd")
const RecordingSocket = preload("res://tests/fakes/recording_socket.gd")

## The long-lived `session.token` from `POST /v1/widget/init`. The gateway does
## NOT accept it, and three of the four mobile SDKs passed it anyway.
const SESSION_TOKEN := "visitor-session-token-from-init"

const CONVERSATION := "0192f0c0-0000-7000-8000-000000000001"
const CONTACT := "0192f0c0-0000-7000-8000-000000000002"

var _mint_calls: int = 0


## Mints a DIFFERENT token each call, which is what makes the per-attempt test
## able to tell a fresh credential from a replayed one. A minter that answered
## the same string every time would pass whether or not the client re-read it.
func _mint(_conversation_id: String) -> ChatlyResult:
	_mint_calls += 1
	return ChatlyResult.success(
		{"token": "minted-token-%d" % _mint_calls, "expiresAt": "2026-10-25T13:00:00.000Z"},
		201,
		"/v1/widget/realtime/token",
	)


func _refusing_mint(_conversation_id: String) -> ChatlyResult:
	_mint_calls += 1
	return ChatlyResult.failure(
		404,
		JSON.stringify({"error": {"code": "not_found", "message": "Conversation not found"}}),
		"/v1/widget/realtime/token",
	)


func _fresh(factory: RecordingFactory, mint: Callable = _mint) -> ChatlyRealtime:
	_mint_calls = 0
	return ChatlyRealtime.new("https://realtime.chatlychat.com", mint, factory)


# ── 1. The handshake carries `kind: "visitor"` ───────────────────────────

## `handshakeAuthSchema` (`apps/realtime/src/gateway.ts:54-59`) makes `kind`
## optional and it DEFAULTS TO AGENT. A handshake without it routes to
## `authenticateHandshakeToken`, which verifies RS256 against the platform's
## public key — so a visitor's HS256 token fails and the gateway answers a bare
## `Unauthorized` naming neither credential.
##
## Omitting this one string is the single defect behind "mobile realtime does
## not work" in all four mobile SDKs. Delete `kind` from
## `ChatlyRealtime._auth_payload` and this is the test that goes red.
func test_handshake_declares_kind_visitor() -> void:
	var factory := RecordingFactory.new()
	var rt := _fresh(factory)
	await rt.start(CONVERSATION, CONTACT)

	equal(factory.count(), 1, "one socket opened")
	var auth := factory.auth_at(0)
	present(auth, "kind", "the handshake must declare its credential class")
	equal(auth.get("kind", ""), "visitor", "kind must be exactly the string 'visitor'")


## The gateway parses `{ token, kind }` and nothing else. Extra keys are not an
## error — zod drops them — but a handshake carrying `workspaceId` and
## `contactId` (which is what the React Native client used to send) is a sign
## the author believed the gateway reads them, and it does not: a visitor's
## room comes from the token's own claims.
func test_handshake_carries_only_token_and_kind() -> void:
	var factory := RecordingFactory.new()
	var rt := _fresh(factory)
	await rt.start(CONVERSATION, CONTACT)

	var auth := factory.auth_at(0)
	equal(auth.size(), 2, "the handshake is exactly { token, kind }")
	absent(auth, "workspaceId", "the workspace comes from the token's claims")
	absent(auth, "contactId", "the contact comes from the token's claims")
	absent(auth, "conversationId", "the conversation comes from the token's claims")


# ── 2. The token came from the mint route, not from init ─────────────────

## There are two visitor credentials and they are not interchangeable.
## `session.token` is long-lived, identifies the visitor and is carried in the
## BODY of every REST call; the realtime token is HS256, conversation-scoped,
## 1h TTL, and is the only one the gateway accepts.
##
## `packages/sdk-kotlin`'s own comment told its reader to pass the first one.
func test_token_is_minted_not_the_session_token() -> void:
	var factory := RecordingFactory.new()
	var rt := _fresh(factory)
	await rt.start(CONVERSATION, CONTACT)

	var auth := factory.auth_at(0)
	equal(_mint_calls, 1, "the mint route was called")
	equal(auth.get("token", ""), "minted-token-1", "the socket got the MINTED token")
	not_equal(
		auth.get("token", ""),
		SESSION_TOKEN,
		"the session token from init is refused by the gateway and must never be sent",
	)


## The mint happens BEFORE the socket is built, not after.
##
## Stated as its own test because the ordering is what makes the credential
## per-attempt. A client that opened the socket and then minted would have one
## socket and one token and no way to pair them.
func test_mint_precedes_the_socket() -> void:
	var factory := RecordingFactory.new()
	var rt := _fresh(factory)
	check(factory.count() == 0 and _mint_calls == 0, "nothing happens before start()")
	await rt.start(CONVERSATION, CONTACT)
	equal(_mint_calls, 1, "exactly one mint")
	equal(factory.count(), 1, "exactly one socket")


# ── 3. A second attempt re-reads the payload ─────────────────────────────

## THE test. The realtime token is conversation-scoped with a 1h TTL, so a
## frozen auth object is replayed verbatim on every reconnect — and a player
## whose connection dropped after an hour reconnects with an expired
## credential and is refused, silently, for the rest of the session.
##
## All four mobile SDKs had this. The browser client avoids it with a
## per-attempt `auth` CALLBACK; GDScript has no socket.io client to give us
## one, so `ChatlyRealtime` mints before every attempt and `ChatlySocket` is
## single-use so there is no object that could replay a credential.
##
## This goes red if `_open_attempt` is changed to reuse a minted token.
func test_second_attempt_re_mints_rather_than_replaying() -> void:
	var factory := RecordingFactory.new()
	var rt := _fresh(factory)
	await rt.start(CONVERSATION, CONTACT)

	var first := factory.socket_at(0) as RecordingSocket
	first.accept()
	# The connection drops — a tunnel closed, the carrier handed over.
	first.drop("transport close")

	# Backoff is 1s on the first retry; 11s covers it with room and costs no
	# wall-clock time, which is the point of driving the clock by hand.
	rt.tick(11.0)
	# `tick` fires `_open_attempt` without awaiting it (it is called from
	# `_process`, which cannot await), so let the coroutine run to completion.
	await Engine.get_main_loop().process_frame

	equal(factory.count(), 2, "a second socket was opened")
	equal(_mint_calls, 2, "the token was minted again for the second attempt")
	var second := factory.auth_at(1)
	equal(second.get("token", ""), "minted-token-2", "attempt two used the FRESH token")
	not_equal(
		second.get("token", ""),
		factory.auth_at(0).get("token", ""),
		"attempt two must not replay attempt one's credential",
	)
	equal(second.get("kind", ""), "visitor", "kind survives the reconnect too")


## A refused handshake also re-mints, and that is deliberate rather than an
## oversight.
##
## The overwhelmingly likely cause of a refusal is a token that aged past its
## 1h TTL while the socket was asleep, and the cure for that is precisely a
## re-mint. Treating a refusal as terminal would turn the one failure this
## client is built to survive into a permanent one.
func test_a_refused_handshake_is_reported_and_retried_with_a_new_token() -> void:
	var factory := RecordingFactory.new()
	var rt := _fresh(factory)
	var reasons: Array[String] = []
	rt.unavailable.connect(func(reason: String) -> void: reasons.append(reason))
	await rt.start(CONVERSATION, CONTACT)

	# The bare word the gateway answers with, naming neither credential.
	(factory.socket_at(0) as RecordingSocket).refuse("Unauthorized")

	equal(reasons.size(), 1, "the refusal was reported so the caller can fall back")
	check(
		reasons[0].contains("Unauthorized"),
		"the server's own words survive to the caller, got: %s" % reasons[0],
	)

	rt.tick(11.0)
	await Engine.get_main_loop().process_frame
	equal(_mint_calls, 2, "a refusal re-mints rather than giving up")
	not_equal(
		factory.auth_at(1).get("token", ""),
		factory.auth_at(0).get("token", ""),
		"the retry after a refusal carries a new credential",
	)


# ── 4. Scope: one token, one conversation ────────────────────────────────

## The gateway joins `v:<workspace>:<conversation>` from the token's own claim
## and registers no `subscribe` listener for a visitor at all. So a
## conversation switch is a re-mint and a reconnect — reusing the socket would
## keep delivering the previous thread's events.
##
## `start()` must therefore tear down FIRST and synchronously. An await before
## the teardown leaves the old socket alive across the switch.
func test_switching_conversations_opens_a_new_socket_and_stops_the_old_one() -> void:
	var factory := RecordingFactory.new()
	var rt := _fresh(factory)
	await rt.start(CONVERSATION, CONTACT)
	var first := factory.socket_at(0) as RecordingSocket
	first.accept()

	await rt.start("0192f0c0-0000-7000-8000-00000000000b", CONTACT)

	equal(factory.count(), 2, "the switch opened a second socket")
	check(first.stopped, "the first socket was stopped, not left listening")
	equal(_mint_calls, 2, "the second conversation got its own token")


## A mint is a round trip, and `stop()` may land while one is in flight.
## Connecting anyway would open a socket for a thread nobody is looking at —
## the same window the widget guards with its `currentToken === null` check.
func test_stop_during_an_in_flight_mint_opens_no_socket() -> void:
	var factory := RecordingFactory.new()
	# A one-slot holder, because a GDScript lambda captures a local BY VALUE: `rt` assigned after the lambda is
	# built would still be null inside it (Godot 4.7 reports "Nonexistent function 'stop' in base 'Nil'").
	var holder: Array = [null]
	# A minter that stops the client from inside itself, which is the tightest
	# version of the race: the generation moves between the await and the
	# factory call.
	var racing_mint := func(_cid: String) -> ChatlyResult:
		(holder[0] as ChatlyRealtime).stop()
		return ChatlyResult.success({"token": "late"}, 201, "/v1/widget/realtime/token")
	var rt := ChatlyRealtime.new("https://realtime.chatlychat.com", racing_mint, factory)
	holder[0] = rt

	await rt.start(CONVERSATION, CONTACT)
	equal(factory.count(), 0, "a mint that lands after stop() must not open a socket")


# ── Delivery ─────────────────────────────────────────────────────────────

## The gateway EMITS on `"event"`. The React Native client listened on
## `"envelope"` for its whole life, which matches nothing the server does — so
## it received nothing, silently, for every integrator.
func test_envelopes_arrive_on_the_event_channel_only() -> void:
	var factory := RecordingFactory.new()
	var rt := _fresh(factory)
	var received: Array[Dictionary] = []
	rt.envelope_received.connect(func(e: Dictionary) -> void: received.append(e))
	await rt.start(CONVERSATION, CONTACT)

	var socket := factory.socket_at(0) as RecordingSocket
	socket.accept()
	socket.deliver({"v": 1, "type": "message.created", "id": "ev-1", "payload": {"body": "hi"}})
	equal(received.size(), 1, "an envelope on 'event' is delivered")
	equal(rt.last_event_id(), "ev-1", "the envelope id is remembered for a REST catch-up")

	socket.deliver_on("envelope", {"v": 1, "type": "message.created", "id": "ev-2"})
	equal(received.size(), 1, "an envelope on 'envelope' is NOT delivered — the server never sends one there")


## `message.read` is the one event a visitor may publish, and the payload is
## `messageReadPayloadSchema` IN FULL.
##
## Kotlin's used to be `{ conversationId, messageId }`, which the gateway's
## `safeParse` rejected on three missing required fields AND a misnamed anchor,
## after which the handler returned silently. Even a successful parse would
## then have been refused: the visitor branch requires `readerType == "contact"`
## and `readerId == contactId` from the socket's own token, so a receipt that
## does not name its reader can never be accepted.
func test_read_receipt_carries_the_whole_schema() -> void:
	var factory := RecordingFactory.new()
	var rt := _fresh(factory)
	await rt.start(CONVERSATION, CONTACT)
	var socket := factory.socket_at(0) as RecordingSocket
	socket.accept()

	rt.emit_read("0192f0c0-0000-7000-8000-0000000000ff")
	equal(socket.sent.size(), 1, "one frame was published")
	equal(socket.sent[0]["name"], "message.read", "on the channel the gateway listens on")

	var payload: Dictionary = socket.sent[0]["payload"]
	equal(payload.get("conversationId", ""), CONVERSATION, "conversationId")
	equal(payload.get("readerType", ""), "contact", "readerType must be 'contact'")
	equal(payload.get("readerId", ""), CONTACT, "readerId must be the socket's own contact")
	equal(
		payload.get("upToMessageId", ""),
		"0192f0c0-0000-7000-8000-0000000000ff",
		"the anchor is 'upToMessageId', not 'messageId'",
	)
	absent(payload, "messageId", "'messageId' is the name that was silently rejected")

	# `z.string().datetime()` with no options accepts ONLY a `Z` offset and
	# rejects a device-local one like `+01:00`. A player's machine is in
	# whatever timezone it is in, so this is not a theoretical failure.
	var read_at := str(payload.get("readAt", ""))
	check(read_at.ends_with("Z"), "readAt must end in Z, got %s" % read_at)
	check(read_at.contains("T"), "readAt must be ISO-8601, got %s" % read_at)
	check(not read_at.contains("+"), "readAt must carry no numeric offset, got %s" % read_at)


# ── Falling back ─────────────────────────────────────────────────────────

## A refused mint is not a dead thread. A 404 means the conversation is not
## this visitor's own; a 403 means the channel has an origin allow-list and a
## native client sends no `Origin`. Neither is cured by retrying and neither
## stops REST working, so the caller is told to poll rather than shown nothing.
func test_a_refused_mint_reports_unavailable_and_opens_no_socket() -> void:
	var factory := RecordingFactory.new()
	var rt := _fresh(factory, _refusing_mint)
	var reasons: Array[String] = []
	rt.unavailable.connect(func(reason: String) -> void: reasons.append(reason))

	await rt.start(CONVERSATION, CONTACT)
	equal(factory.count(), 0, "no socket is opened without a credential")
	equal(reasons.size(), 1, "the caller is told, so it can fall back to polling")
	check(
		reasons[0].contains("Conversation not found"),
		"the server's own message reaches the caller, got: %s" % reasons[0],
	)
