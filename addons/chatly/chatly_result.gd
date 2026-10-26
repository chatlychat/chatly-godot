##
## The answer to every REST call: a value OR a refusal, never an exception.
##
## ── Why a result object and not an error signal ───────────────────────────
##
## GDScript has no exceptions, and a game's chat UI has to react to "that file
## type is not accepted" at the call site that tried to send the file. An
## out-of-band error signal would arrive detached from the call it belongs to,
## which for a client that may have several requests in flight is not
## recoverable information.
##
## ── Why `message` is the server's own words ───────────────────────────────
##
## Three of the upload route's refusals are copy written for the VISITOR to
## read: "File uploads are turned off for this chat", "That file type is not
## accepted: …", "Files must be under 10 MB"
## (`apps/api/src/modules/widget/widget-engagement.service.ts`). A composer
## should be able to render `result.message` straight into the UI. `status`
## and `code` carry the developer half.
##
## The API NESTS every error — `app-exception.filter.ts` ends with
## `send({ error: body })` — so a refusal on the wire is
## `{ "error": { "code": …, "message": … } }`. Reading `body.code` at the top
## level returns nothing for every real response, and that exact mistake has
## shipped three times in this repository (the web widget, `sdk-js`, and
## `sdk-react-native`), each time silently disabling the stale-session
## recovery that depends on it. `parse_error_body` below is the one parser.
##
class_name ChatlyResult
extends RefCounted

## True when the server answered 2xx.
var ok: bool = false

## The decoded JSON body on success. `null` for a 204 or an empty body.
var data: Variant = null

## HTTP status, or 0 when the request never reached a server (DNS, TLS,
## timeout, no route). A 0 is a transport failure and is RETRYABLE in a way
## that a 400 is not.
var status: int = 0

## The API's `error.code`, e.g. `visitor_session_invalid`. Empty when the
## refusal carried none or came from a proxy.
var code: String = ""

## Something a human can read. The server's `error.message` when it sent one,
## otherwise a developer-facing fallback that names the path and status.
var message: String = ""

## The path that was called, for logs.
var path: String = ""


static func success(result_data: Variant, http_status: int, request_path: String) -> ChatlyResult:
	var r := ChatlyResult.new()
	r.ok = true
	r.data = result_data
	r.status = http_status
	r.path = request_path
	return r


static func failure(http_status: int, body_text: String, request_path: String) -> ChatlyResult:
	var r := ChatlyResult.new()
	r.ok = false
	r.status = http_status
	r.path = request_path
	var parsed := parse_error_body(body_text)
	r.code = parsed["code"]
	var server_message: String = parsed["message"]
	if server_message.is_empty():
		r.message = "[chatly] %s failed: %d %s" % [request_path, http_status, body_text]
	else:
		r.message = server_message
	return r


## A refusal this client made on its own, before sending anything.
##
## Used only where the server's own 400 would describe the wrong thing — a
## zero-byte file is "sizeBytes must be greater than 0" on the wire, which is
## not what went wrong from the player's side. `status` stays 0 because no
## server was asked.
static func refused(refusal_code: String, human_message: String, request_path: String) -> ChatlyResult:
	var r := ChatlyResult.new()
	r.ok = false
	r.status = 0
	r.path = request_path
	r.code = refusal_code
	r.message = human_message
	return r


## A failure that never reached a server at all.
static func transport_failure(reason: String, request_path: String) -> ChatlyResult:
	var r := ChatlyResult.new()
	r.ok = false
	r.status = 0
	r.path = request_path
	r.code = "transport_failed"
	r.message = "[chatly] %s could not be reached: %s" % [request_path, reason]
	return r


## Pull `code` and `message` out of a refusal body, handling the API's nesting.
##
## Returns `{ "code": String, "message": String }`, both possibly empty. The
## un-nested fallback is kept deliberately: a proxy or a gateway in front of
## the API answers in its own shape, and on a game client that reaches the
## internet through whatever the player's network does, that is not rare.
static func parse_error_body(body_text: String) -> Dictionary:
	var out := {"code": "", "message": ""}
	var parsed: Variant = JSON.parse_string(body_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return out
	var root: Dictionary = parsed
	var nested: Variant = root.get("error", null)
	var source: Dictionary = nested if typeof(nested) == TYPE_DICTIONARY else root
	var code: Variant = source.get("code", null)
	var message: Variant = source.get("message", null)
	if typeof(code) == TYPE_STRING:
		out["code"] = code
	if typeof(message) == TYPE_STRING and not (message as String).is_empty():
		out["message"] = message
	return out


## Does this refusal mean "the visitor token on this device is no good"?
##
## Only the session codes are cured by fetching a new token. A disallowed
## origin and a missing identity hash are also 403s and retrying either would
## fail again, more slowly. Matched by PREFIX so a future third session code
## recovers for free — `visitor_session_upgrade_required` and
## `visitor_session_invalid` are the two that exist today.
func is_stale_session() -> bool:
	return status == 403 and code.begins_with("visitor_session_")
