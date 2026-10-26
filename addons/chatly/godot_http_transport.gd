##
## The real HTTP transport: one `HTTPRequest` per in-flight call.
##
## ── Why a child node per request and not one reused node ─────────────────
##
## `HTTPRequest` handles exactly one request at a time — a second `request()`
## before `request_completed` returns `ERR_BUSY`. A chat client has concurrent
## calls as a matter of course (a mint racing a history fetch racing a send),
## so the node is per-call and freed when the call settles. `queue_free()`
## rather than `free()`, because freeing a node from inside the handler for
## its own signal is a use-after-free.
##
## ── Threads are ON, and that is the point ────────────────────────────────
##
## `set_use_threads(true)` puts the socket work on `HTTPRequest`'s own thread.
## Without it a slow TLS handshake stalls the frame it started on, which in a
## game is a visible hitch at exactly the moment the player opened the chat.
## Not available on the Web export, where Godot ignores it and uses the
## browser's own async fetch; both paths still deliver through
## `request_completed`, so nothing above this file changes.
##
class_name ChatlyGodotHttpTransport
extends ChatlyHttpTransport

## Seconds before a request is abandoned. Deliberately shorter than a player's
## patience: a dead API should degrade the chat, not freeze the thought that
## the chat is working.
var timeout_seconds: float = 15.0


func post_json(url: String, headers: PackedStringArray, body: String) -> Dictionary:
	return await _run(url, headers, HTTPClient.METHOD_POST, body, PackedByteArray(), false)


func put_bytes(url: String, headers: PackedStringArray, bytes: PackedByteArray) -> Dictionary:
	return await _run(url, headers, HTTPClient.METHOD_PUT, "", bytes, true)


func _run(
	url: String,
	headers: PackedStringArray,
	method: int,
	text_body: String,
	raw_body: PackedByteArray,
	raw: bool,
) -> Dictionary:
	var req := HTTPRequest.new()
	req.use_threads = true
	req.timeout = timeout_seconds
	# Accepting gzip saves a player on a phone tether real bytes on a history
	# fetch, and Godot inflates it before the signal fires.
	req.accept_gzip = true
	add_child(req)

	var err: int
	if raw:
		err = req.request_raw(url, headers, method, raw_body)
	else:
		err = req.request(url, headers, method, text_body)
	if err != OK:
		req.queue_free()
		return {"status": 0, "body": "", "reason": "request() returned %d" % err}

	var answer: Array = await req.request_completed
	req.queue_free()

	# `request_completed(result, response_code, headers, body)`.
	var result: int = answer[0]
	var response_code: int = answer[1]
	var raw_bytes: PackedByteArray = answer[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		# No HTTP status exists in this case, and `response_code` is 0. Keeping
		# it 0 rather than inventing a 5xx is what lets the caller tell "the
		# server refused me" from "I never spoke to a server" — the first is
		# permanent, the second is worth retrying.
		return {
			"status": 0,
			"body": "",
			"reason": _result_reason(result),
		}
	return {"status": response_code, "body": raw_bytes.get_string_from_utf8()}


## `HTTPRequest.Result` as something a log reader can act on.
static func _result_reason(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: return "chunked body size mismatch"
		HTTPRequest.RESULT_CANT_CONNECT: return "cannot connect"
		HTTPRequest.RESULT_CANT_RESOLVE: return "cannot resolve host"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "connection error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "TLS handshake failed"
		HTTPRequest.RESULT_NO_RESPONSE: return "no response"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "body too large"
		HTTPRequest.RESULT_REQUEST_FAILED: return "request failed"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: return "too many redirects"
		HTTPRequest.RESULT_TIMEOUT: return "timed out"
		_: return "transport error %d" % result
