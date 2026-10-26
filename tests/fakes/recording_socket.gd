##
## A socket that records the handshake it was opened with.
##
## This is the half a response-faking test cannot reach, and it is where every
## realtime bug in this repository has lived: `kind` omitted from the handshake
## (all four mobile SDKs), the session token passed instead of a minted one
## (Kotlin), a frozen auth object replayed on reconnect (all four).
##
## It never touches a network, so it has no `poll` behaviour and no state
## machine. A test drives it by hand: `accept()`, `refuse("Unauthorized")`,
## `drop("transport close")`, `deliver(envelope)`.
##
extends ChatlySocket

var url: String = ""
var auth: Dictionary = {}
var started: bool = false
var stopped: bool = false

## Every `send_event` call: `[{ "name": String, "payload": Variant }]`.
var sent: Array[Dictionary] = []


func _init(socket_url: String, handshake_auth: Dictionary) -> void:
	url = socket_url
	auth = handshake_auth.duplicate(true)


func auth_payload() -> Dictionary:
	return auth.duplicate(true)


func start() -> void:
	started = true


func poll(_delta: float) -> void:
	pass


func send_event(name: String, payload: Variant) -> void:
	sent.append({"name": name, "payload": payload})


func stop() -> void:
	stopped = true


# ── Driven by the test ───────────────────────────────────────────────────

## The gateway accepted the CONNECT.
func accept() -> void:
	socket_opened.emit()


## The gateway refused the handshake — for a visitor, almost always the bare
## `Unauthorized` that names neither credential.
func refuse(message: String = "Unauthorized") -> void:
	socket_refused.emit(message)
	socket_closed.emit("handshake refused")


## The connection dropped without a refusal: a tunnel closed, wifi changed.
func drop(reason: String = "transport close") -> void:
	socket_closed.emit(reason)


## One inbound envelope, on the channel the gateway actually emits on.
func deliver(envelope: Dictionary) -> void:
	socket_event.emit("event", envelope)


## An event on some OTHER channel, to prove the client ignores it. `"envelope"`
## is the name the React Native SDK listened on for its whole life, which
## matches nothing the server does.
func deliver_on(channel: String, envelope: Dictionary) -> void:
	socket_event.emit(channel, envelope)
