##
## A transport that records what it was ASKED to send.
##
## ── The whole point, stated once ───────────────────────────────────────
##
## A fake that answers every route with whatever the SDK expects AGREES WITH
## THE BUG. That is not a hypothetical: all four Chatly mobile SDKs shipped a
## visitor contract the server does not speak, each with a green suite, and two
## of them posted `{ filename, mimeType, data }` to a presign route that
## accepts none of that shape. Every one of those tests asserted on a canned
## response.
##
## So this fake's job is to be *inspected*, not to be convincing. `requests`
## holds the url, headers and decoded body of every call in order, and the
## tests assert on those. `queue_*` lets a test script a sequence of answers,
## including refusals, so the recovery paths are exercised too.
##
## It deliberately does NOT invent a response shape for an unqueued route. An
## unqueued call answers 500 with a body naming the path, which fails loudly —
## because a fake that improvises a page envelope over a bare-array route is
## how two SDKs in this repository shipped a paginator that could never work.
##
extends ChatlyHttpTransport

## `[{ "url": String, "path": String, "headers": PackedStringArray,
##     "body": Dictionary, "raw": String, "method": String }]`
var requests: Array[Dictionary] = []

## FIFO of `{ "status": int, "body": String }`, keyed by path.
var _by_path: Dictionary = {}

## Standing answers, keyed by path. A separate dictionary rather than a
## sentinel suffix on the key: the first attempt used a NUL byte as the
## separator and Godot's parser refuses a NUL in source outright, which is
## the loud version of a failure this repository has already met quietly.
var _always: Dictionary = {}


func queue(path: String, status: int, body: Variant) -> void:
	if not _by_path.has(path):
		_by_path[path] = []
	var text: String = body if typeof(body) == TYPE_STRING else JSON.stringify(body)
	(_by_path[path] as Array).append({"status": status, "body": text})


## Queue the same answer for every subsequent call to a path.
func queue_always(path: String, status: int, body: Variant) -> void:
	var text: String = body if typeof(body) == TYPE_STRING else JSON.stringify(body)
	_always[path] = {"status": status, "body": text}


func post_json(url: String, headers: PackedStringArray, body: String) -> Dictionary:
	return _record(url, headers, body, PackedByteArray(), "POST")


func put_bytes(url: String, headers: PackedStringArray, bytes: PackedByteArray) -> Dictionary:
	return _record(url, headers, "", bytes, "PUT")


func _record(
	url: String, headers: PackedStringArray, body: String, bytes: PackedByteArray, method: String
) -> Dictionary:
	var path := _path_of(url)
	var parsed: Variant = JSON.parse_string(body) if not body.is_empty() else null
	requests.append({
		"url": url,
		"path": path,
		"headers": headers,
		"body": parsed if typeof(parsed) == TYPE_DICTIONARY else {},
		"raw": body,
		"bytes": bytes,
		"method": method,
	})

	var queued: Variant = _by_path.get(path, null)
	if typeof(queued) == TYPE_ARRAY and not (queued as Array).is_empty():
		return (queued as Array).pop_front()
	var always: Variant = _always.get(path, null)
	if typeof(always) == TYPE_DICTIONARY:
		return always
	return {
		"status": 500,
		"body": JSON.stringify({"error": {"code": "unqueued", "message": "no answer queued for %s" % path}}),
	}


## The path, with the scheme and host stripped and the query dropped.
static func _path_of(url: String) -> String:
	var sep := url.find("://")
	var rest := url.substr(sep + 3) if sep != -1 else url
	var slash := rest.find("/")
	if slash == -1:
		return "/"
	var path := rest.substr(slash)
	var q := path.find("?")
	return path.substr(0, q) if q != -1 else path


# ── Readers the tests use ────────────────────────────────────────────────

## Every request to one path, in order.
func to_path(path: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r: Dictionary in requests:
		if r["path"] == path:
			out.append(r)
	return out


## The first body sent to a path, or `{}`.
func first_body(path: String) -> Dictionary:
	var hits := to_path(path)
	return hits[0]["body"] if not hits.is_empty() else {}


func count_to(path: String) -> int:
	return to_path(path).size()


## Every path called, in order. Used to assert on SEQUENCE — that the mint
## happened before the socket opened, that the re-init happened before the
## replay.
func call_order() -> Array[String]:
	var out: Array[String] = []
	for r: Dictionary in requests:
		out.append(r["path"])
	return out


func header_value(request_index: int, name: String) -> String:
	if request_index < 0 or request_index >= requests.size():
		return ""
	var headers: PackedStringArray = requests[request_index]["headers"]
	var prefix := name.to_lower() + ":"
	for h: String in headers:
		if h.to_lower().begins_with(prefix):
			return h.substr(prefix.length()).strip_edges()
	return ""
