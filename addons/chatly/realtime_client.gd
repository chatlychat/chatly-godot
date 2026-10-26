##
## The visitor's live connection: mint, connect, reconnect, re-mint.
##
## ── The contract, and the four ways it has been got wrong ───────────────
##
## From `docs/prompts/5/mobile-sdk-visitor-contract.md`, which was written
## after all four mobile SDKs shipped a contract the server does not speak.
## Every one of the four defects is prevented by something in this file, and
## each is named where it is prevented:
##
##  1. **`kind: "visitor"` is mandatory.** `handshakeAuthSchema`
##     (`apps/realtime/src/gateway.ts:54-59`) is `{ token, kind? }` and `kind`
##     DEFAULTS TO AGENT. A handshake without it routes to
##     `authenticateHandshakeToken`, which verifies RS256 against the
##     platform's public key; a visitor's HS256 token fails that and the
##     gateway answers a bare `Unauthorized` naming neither credential. All
##     four SDKs omitted it, so realtime never worked in any of them, for
##     anyone, and failed without saying why. → `_auth_payload()`.
##
##  2. **The credential is not `session.token`.** That one is long-lived,
##     identifies the visitor, and is carried in the BODY of every REST call.
##     The gateway does not accept it. The realtime token is a separate
##     HS256 JWT from `POST /v1/widget/realtime/token`. Kotlin's own comment
##     told its reader to pass the wrong one. → this class never sees the
##     session token; it holds only a `mint` Callable.
##
##  3. **The token is conversation-scoped with a 1h TTL, so `auth` must be
##     re-read per connect ATTEMPT.** A frozen auth object is replayed on
##     reconnect and the socket dies silently for the rest of the session.
##     → `_open_attempt()` awaits `mint` every time, including the first, and
##     `ChatlySocket` is single-use so there is no object that could replay
##     one.
##
##  4. **The scope is one conversation.** The gateway joins
##     `v:<workspace>:<conversation>` from the token's own claim and registers
##     no `subscribe` listener for a visitor at all — so switching
##     conversations is a re-mint and a reconnect, not a second subscribe.
##     Reusing the socket keeps delivering the previous thread's events.
##     → `start()` tears down first, synchronously.
##
## ── Why reconnection is ours ───────────────────────────────────────────
##
## There is no Socket.IO client library for GDScript to delegate it to, which
## for once is a help: the browser client's per-attempt `auth` callback is the
## only reason it is safe to let a library reconnect, and the Java client's
## lack of one is why `packages/sdk-kotlin` also hand-rolls this. Backoff is
## 1s doubling to a 10s cap, matching the widget and the React Native client.
##
## ── Why `tick(delta)` and not a `Timer` ────────────────────────────────
##
## So the suite can advance time without sleeping. A fixed sleep in a test
## here would flake under `turbo`'s parallelism exactly as it has elsewhere in
## this repository, and `tick(11.0)` is both faster and deterministic.
##
class_name ChatlyRealtime
extends RefCounted

## Socket.IO channel names, as the gateway actually speaks them.
##
## Both of these were `"envelope"` in the React Native SDK, which matches
## nothing the server does: `apps/realtime/src/gateway.ts` EMITS on `"event"`
## and a visitor may publish `"message.read"`. So that client received nothing
## and its frames were never heard — the whole realtime surface was inert,
## silently, for every integrator.
const INBOUND_EVENT_CHANNEL := "event"
const MESSAGE_READ_CHANNEL := "message.read"

## The one string whose absence broke realtime in all four mobile SDKs.
const VISITOR_KIND := "visitor"

const RECONNECT_DELAY_SECONDS := 1.0
const RECONNECT_DELAY_MAX_SECONDS := 10.0

## Live, and the gateway has joined us to this conversation's room.
signal connected()

## The connection ended. A reconnect is already scheduled unless `stop()` was
## called.
signal disconnected(reason: String)

## One inbound realtime envelope: `{ v, type, id, ts, workspace_id, payload }`.
signal envelope_received(envelope: Dictionary)

## Live delivery is unavailable for a reason retrying will not fix — the mint
## was refused (404 for a conversation that is not this visitor's, 403 for a
## channel with an origin allow-list), or the handshake was.
##
## The right response is to fall back to polling, not to show a dead thread.
signal unavailable(reason: String)

var _url: String
var _mint: Callable
var _factory: ChatlySocketFactory
var _socket: ChatlySocket = null
var _conversation_id: String = ""
var _contact_id: String = ""

## Bumped by every `start()` and every `stop()`.
##
## A mint is a round trip. Without this, a mint that lands after the caller
## switched conversations (or closed the chat) would open a socket for a
## thread nobody is looking at — the same window the widget guards with its
## `currentToken === null` check.
var _generation: int = 0

var _attempt: int = 0
var _reconnect_in: float = -1.0
var _stood_down: bool = true
var _last_event_id: String = ""


## `mint` is `func(conversation_id: String) -> ChatlyResult`, and may be a
## coroutine. Injected rather than taking a `ChatlyRestClient` so this class
## holds no REST and can be tested without one.
func _init(
	realtime_url: String,
	mint: Callable,
	factory: ChatlySocketFactory = ChatlyWebSocketSocketFactory.new(),
) -> void:
	_url = ChatlyEngineIO.handshake_url(realtime_url)
	_mint = mint
	_factory = factory


## Where the socket opens, with the precedence the web widget uses.
##
## Mirrors `apps/widget/src/realtime-url.ts` deliberately rather than
## inventing a second rule: that file's own header records that the precedence
## "was wrong in production for a long time and nothing caught it".
##
## `from_server` is `init`'s `realtimeUrl`, which is NULLABLE — and null means
## "not configured", NOT "no realtime", so a client must not treat it as a
## refusal. The last-resort convention rewrites a leading `api.` to
## `realtime.`; it exists only so an older server is no worse off.
##
## Note the React Native SDK does NOT do this — it opens on `apiHost` — which
## reaches the realtime service only on a deployment that fronts both behind
## one host.
static func resolve_url(override: String, from_server: String, api_url: String) -> String:
	if not override.is_empty():
		return override
	if not from_server.is_empty():
		return from_server
	var sep := api_url.find("://")
	if sep == -1:
		return api_url
	var scheme := api_url.substr(0, sep)
	var rest := api_url.substr(sep + 3)
	if rest.begins_with("api."):
		rest = "realtime." + rest.substr(4)
	return "%s://%s" % [scheme, rest]


## Open a socket scoped to one conversation.
##
## `contact_id` is needed only for `emit_read`: the gateway refuses a receipt
## whose `readerId` does not match the socket's own token claim, so a receipt
## that does not name its reader can never be accepted.
func start(conversation_id: String, contact_id: String = "") -> void:
	# FIRST and synchronously. An await before this would leave the previous
	# socket alive across a conversation switch, delivering the old thread's
	# events into the new one.
	stop()
	_stood_down = false
	_conversation_id = conversation_id
	_contact_id = contact_id
	_attempt = 0
	await _open_attempt(_generation)


## Close, and stop reconnecting.
func stop() -> void:
	# Bumped so a mint still in flight stands down rather than opening a
	# socket for a conversation nobody is looking at.
	_generation += 1
	_stood_down = true
	_attempt = 0
	_reconnect_in = -1.0
	if _socket != null:
		var old := _socket
		_socket = null
		old.stop()


func is_connected_live() -> bool:
	return _socket != null and not _stood_down


## Drive the socket and the reconnect clock. Call every frame.
func tick(delta: float) -> void:
	if _socket != null:
		_socket.poll(delta)
	if _reconnect_in >= 0.0:
		_reconnect_in -= delta
		if _reconnect_in < 0.0:
			_reconnect_in = -1.0
			# Fire and forget: `_open_attempt` is a coroutine and `tick` is
			# called from `_process`, which cannot await.
			_open_attempt(_generation)


## Report a read receipt — the one event a visitor may publish.
##
## The payload is `messageReadPayloadSchema` IN FULL. Kotlin's used to be
## `{ conversationId, messageId }`, which the gateway's `safeParse` rejected on
## three missing required fields AND a misnamed anchor, after which the handler
## returned silently. Even a successful parse would then have been refused: the
## visitor branch requires `readerType == "contact"` and
## `readerId == contactId` from the socket's own token.
##
## `readAt` is ISO-8601 with a `Z` offset because the schema is
## `z.string().datetime()`, which with no options accepts ONLY `Z` and rejects
## a device-local offset like `+01:00`.
func emit_read(up_to_message_id: String = "") -> void:
	if _socket == null or _conversation_id.is_empty() or _contact_id.is_empty():
		return
	var payload := {
		"conversationId": _conversation_id,
		"readAt": Time.get_datetime_string_from_system(true, false) + "Z",
		"readerType": "contact",
		"readerId": _contact_id,
	}
	if not up_to_message_id.is_empty():
		payload["upToMessageId"] = up_to_message_id
	_socket.send_event(MESSAGE_READ_CHANNEL, payload)


## The handshake payload, built fresh for each attempt.
##
## `kind` is not optional from our side even though it is optional in the
## schema. Omitting it is the single defect behind "mobile realtime does not
## work" in all four mobile SDKs.
static func _auth_payload(token: String) -> Dictionary:
	return {"token": token, "kind": VISITOR_KIND}


func _open_attempt(generation: int) -> void:
	if generation != _generation or _stood_down:
		return

	# Mint FIRST, every time, including the first attempt. This is the whole
	# of defect 3: a token captured once is replayed on every reconnect, and a
	# socket that drops after an hour comes back with an expired credential.
	var minted: ChatlyResult = await _mint.call(_conversation_id)
	if generation != _generation or _stood_down:
		# Stood down while the mint was in flight — switched, or closed.
		return

	if not minted.ok:
		# A 404 means this conversation is not the caller's own; a 403 means
		# the channel has an origin allow-list and a native client sends no
		# `Origin`. Neither is cured by retrying, and neither is a dead
		# thread: REST still works, so the caller should poll.
		unavailable.emit(minted.message)
		return

	var token := ""
	if typeof(minted.data) == TYPE_DICTIONARY:
		token = str((minted.data as Dictionary).get("token", ""))
	if token.is_empty():
		unavailable.emit("the mint answered no token")
		return

	var socket := _factory.open_socket(_url, _auth_payload(token))
	if socket == null:
		unavailable.emit("no socket could be opened")
		return

	socket.socket_opened.connect(_on_opened.bind(generation))
	socket.socket_closed.connect(_on_closed.bind(generation))
	socket.socket_event.connect(_on_event.bind(generation))
	socket.socket_refused.connect(_on_refused.bind(generation))

	if generation != _generation or _stood_down:
		socket.stop()
		return
	_socket = socket
	socket.start()


func _on_opened(generation: int) -> void:
	if generation != _generation:
		return
	_attempt = 0
	connected.emit()


func _on_closed(reason: String, generation: int) -> void:
	if generation != _generation or _stood_down:
		return
	_socket = null
	disconnected.emit(reason)
	_schedule_reconnect()


## A REFUSED handshake, as opposed to a dropped connection.
##
## Reported but NOT treated as terminal, and the distinction is the point. The
## overwhelmingly likely cause is a token that aged past its 1h TTL while the
## socket was asleep — and the cure for that is precisely a re-mint, which the
## scheduled reconnect performs. Giving up here would turn the one failure
## this file is built to survive into a permanent one.
func _on_refused(message: String, generation: int) -> void:
	if generation != _generation:
		return
	unavailable.emit("the realtime gateway refused the handshake: %s" % message)


func _on_event(name: String, payload: Variant, generation: int) -> void:
	if generation != _generation:
		return
	if name != INBOUND_EVENT_CHANNEL:
		return
	if typeof(payload) != TYPE_DICTIONARY:
		return
	var env: Dictionary = payload
	var event_id := str(env.get("id", ""))
	if not event_id.is_empty():
		_last_event_id = event_id
	envelope_received.emit(env)


func _schedule_reconnect() -> void:
	if _stood_down or _reconnect_in >= 0.0:
		return
	_attempt += 1
	var shift := mini(_attempt - 1, 4)
	_reconnect_in = minf(
		RECONNECT_DELAY_SECONDS * float(1 << shift), RECONNECT_DELAY_MAX_SECONDS
	)


## The last envelope id seen, for a REST catch-up after a gap.
##
## There is no replay for a visitor: the gateway registers its `subscribe`
## listener (which is what carries `lastEventId`) on AGENT connections only. So
## this is an input to a history refetch, not to a socket frame — and the right
## catch-up for a visitor is `POST /v1/widget/messages/list`.
func last_event_id() -> String:
	return _last_event_id
