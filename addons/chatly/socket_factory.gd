##
## Opens one socket per connect ATTEMPT, with the auth it is handed.
##
## A factory rather than a constructor argument because the credential cannot
## be captured once: the visitor realtime token is conversation-scoped with a
## 1h TTL, so every attempt needs a freshly minted one. See `socket.gd` for
## the failure that shape prevents.
##
## This is also the seam the suite replaces. `tests/fakes/recording_factory.gd`
## records every `(url, auth)` pair, which is how
## `tests/test_realtime_handshake.gd` can assert that attempt two carried a
## DIFFERENT token from attempt one — the assertion no canned response can
## satisfy.
##
class_name ChatlySocketFactory
extends RefCounted


## `url` is already the full Engine.IO handshake URL from
## `ChatlyEngineIO.handshake_url`.
func open_socket(_url: String, _auth: Dictionary) -> ChatlySocket:
	push_error("[chatly] ChatlySocketFactory.open_socket must be overridden")
	return null
