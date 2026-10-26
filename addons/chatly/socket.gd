##
## One Socket.IO connection, behind an interface.
##
## ── Why this is an interface at all ─────────────────────────────────────
##
## So a test can see **the handshake it was opened with**. The auth payload is
## the half a fake transport cannot fake, and the half every realtime bug in
## this repository has lived in: all four mobile SDKs omitted `kind: 'visitor'`
## and all four had green suites, because each asserted on a canned response
## rather than on what it sent. `packages/sdk-kotlin` arrived at the same
## shape for the same reason (`RealtimeSocket` + `RealtimeSocketFactory`).
##
## ── Why one socket per ATTEMPT rather than a reconnecting object ─────────
##
## The visitor realtime token is conversation-scoped with a 1h TTL. A socket
## that holds its own credential and reconnects on its own backoff replays the
## credential it was built with — so a player whose connection dropped after
## an hour reconnects with an expired token and is refused, silently, for the
## rest of the session. That is the bug all four mobile SDKs shipped.
##
## The browser client dodges it with a per-attempt `auth` CALLBACK
## (`apps/widget/src/realtime-client.ts`). We have no such client, so this
## object is deliberately single-use: `ChatlyRealtime` drives reconnection
## itself, mints a fresh token, and builds a NEW socket each time. Reusing one
## is the one thing that must not happen, which is why there is no `restart()`.
##
class_name ChatlySocket
extends RefCounted

## The Socket.IO CONNECT was accepted — the gateway has joined us to
## `v:<workspace>:<conversation>` from the token's own claims.
signal socket_opened()

## The connection ended. `reason` is the server's words when it gave any.
signal socket_closed(reason: String)

## An inbound Socket.IO EVENT. The gateway emits on `"event"` and the payload
## is the realtime envelope `{ v, type, id, ts, workspace_id, payload }`.
signal socket_event(name: String, payload: Variant)

## The handshake was REFUSED, as opposed to dropped. Arrives as a Socket.IO
## CONNECT_ERROR, which is where the gateway's `next(err)` lands — and for a
## visitor that is almost always `Unauthorized`, the bare word that names
## neither of the two credentials.
signal socket_refused(message: String)


## Open it. Call exactly once per instance.
func start() -> void:
	push_error("[chatly] ChatlySocket.start must be overridden")


## Drive the connection. Called every frame by the owner; `delta` is seconds,
## and is used for the Engine.IO ping timeout rather than wall-clock time so a
## paused game does not count as a dead connection.
func poll(_delta: float) -> void:
	pass


## Publish. The only event a visitor may send is `message.read`.
func send_event(_name: String, _payload: Variant) -> void:
	push_error("[chatly] ChatlySocket.send_event must be overridden")


## Close and release every listener. Safe to call more than once.
func stop() -> void:
	pass


## The handshake auth this socket was built with.
##
## Exposed so a test can assert on it directly, though the test that matters
## asserts on what the FACTORY was handed — that is the value the gateway
## actually sees.
func auth_payload() -> Dictionary:
	return {}
