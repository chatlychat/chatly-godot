##
## The no-socket path: `POST /v1/widget/messages/list` on a clock.
##
## ── Why this exists, and why it is not a lesser feature ────────────────
##
## `@chatlychat/core` works with no socket library at all — omit the socket
## factory and it polls — and the web widget keeps a polling fallback for
## exactly this reason. There are three cases where a game client has no live
## socket and a thread still has to work:
##
##  1. The mint was REFUSED. A 403 because the channel has an origin
##     allow-list (a native client sends no `Origin`, and `enforceOrigin` runs
##     on the mint route), or a 404 because the conversation is not this
##     visitor's own. Retrying does not fix either.
##  2. The player's network kills WebSockets — a corporate proxy, a captive
##     portal, an aggressive mobile carrier. HTTP POST still gets through.
##  3. An operator deployment where `VISITOR_REALTIME_JWT_SECRET` is unset in
##     production, which makes `authenticateVisitorHandshakeToken` throw
##     `Visitor realtime is not configured` for every visitor.
##
## A slower thread is not a dead thread. What must not happen is a client that
## claims realtime and silently never connects, which is the failure this
## whole package is written against.
##
## ── Why it polls MESSAGES and not conversations ───────────────────────
##
## `conversations/list` carries `lastMessagePreview`, which is a truncated
## string and not a message. `messages/list` is the authoritative projection —
## and it is the one that applies the tombstone redaction and filters
## `hidden_from_contact` server-side, so a polled thread shows exactly what
## the visitor is entitled to see with no client-side filtering needed.
##
## ── The honest cost ───────────────────────────────────────────────────
##
## A reply arrives up to `interval_seconds` late, and typing indicators,
## read receipts and cobrowse invitations do not arrive at all — they are
## socket-only events with no REST equivalent. `ChatlyClient` reports which
## transport is in use so a game can say "messages may take a few seconds"
## rather than leaving the player wondering.
##
class_name ChatlyPolling
extends RefCounted

## One newly seen message. Same shape as the `messages/list` projection:
## `{ id, authorType, kind, body, blocks, canvas, attachments, createdAt,
## deletedAt, reactions }`.
signal message_received(message: Dictionary)

## A refetch failed. Not fatal — the next tick tries again — but a run of
## these is worth surfacing.
signal poll_failed(reason: String)

## How long between refetches. Four seconds is a compromise: a support reply
## is not a twitch input, and a game that polls every second for a thread
## nobody is looking at is burning a player's battery and our rate limit.
var interval_seconds: float = 4.0

var _rest: ChatlyRestClient
var _conversation_id: String = ""
var _elapsed: float = 0.0
var _running: bool = false
var _in_flight: bool = false

## Ids already handed to the caller.
##
## A SET and not a high-water mark, deliberately. Ids here are mixed UUID v4
## and v7 across this product, so they cannot be ordered — `docs` records
## eighteen lists that were in random order while claiming to be sorted. The
## list route returns oldest-first by `created_at`, but "newer than the last
## id I saw" is not a question an id can answer, so membership is the only
## sound test.
var _seen: Dictionary = {}


func _init(rest: ChatlyRestClient) -> void:
	_rest = rest


## Begin polling one conversation.
##
## `known_ids` seeds the seen set from whatever the caller already rendered, so
## switching from realtime to polling mid-thread does not replay the thread.
func start(conversation_id: String, known_ids: Array = []) -> void:
	_conversation_id = conversation_id
	_seen.clear()
	for id: Variant in known_ids:
		_seen[str(id)] = true
	_running = true
	# Fire immediately rather than after one interval: the caller switched to
	# polling because something went wrong, and a four-second blank is how
	# that reads as broken.
	_elapsed = interval_seconds


func stop() -> void:
	_running = false
	_conversation_id = ""
	_elapsed = 0.0


func is_running() -> bool:
	return _running


## Drive the clock. Call every frame.
func tick(delta: float) -> void:
	if not _running or _conversation_id.is_empty():
		return
	_elapsed += delta
	if _elapsed < interval_seconds:
		return
	_elapsed = 0.0
	if _in_flight:
		# A refetch is still out. Skipping rather than queueing: on a slow
		# link, queueing turns one slow request into a growing pile of them,
		# all asking the same question.
		return
	_refetch()


func _refetch() -> void:
	_in_flight = true
	var result: ChatlyResult = await _rest.list_messages(_conversation_id, 50)
	_in_flight = false
	if not _running:
		# Stopped while the request was in flight.
		return
	if not result.ok:
		poll_failed.emit(result.message)
		return
	if typeof(result.data) != TYPE_DICTIONARY:
		poll_failed.emit("the message list answered a non-object")
		return
	var messages: Variant = (result.data as Dictionary).get("messages", [])
	if typeof(messages) != TYPE_ARRAY:
		return
	for row: Variant in (messages as Array):
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var message: Dictionary = row
		var id := str(message.get("id", ""))
		if id.is_empty() or _seen.has(id):
			continue
		_seen[id] = true
		message_received.emit(message)


## Remember an id without emitting it — for the sender's own optimistic echo,
## and for messages the realtime path already delivered.
func mark_seen(message_id: String) -> void:
	if not message_id.is_empty():
		_seen[message_id] = true
