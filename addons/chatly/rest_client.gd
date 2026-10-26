##
## The `/v1/widget/*` REST surface, as a VISITOR speaks it.
##
## ── Every route here was verified against its handler ────────────────────
##
## Not against a doc, and not against `packages/sdk-spec/surface.json` (which
## is the BACKEND-SDK contract and carries no widget routes). The manifest's
## own first version listed two routes that do not exist, so the rule in this
## repository is to read the controller. Each method below names the handler
## and the zod schema it was checked against:
##
##   POST /v1/widget/init                      widget.controller.ts:71
##   POST /v1/widget/realtime/token            widget.controller.ts:179
##   POST /v1/widget/conversations             widget-conversations.controller.ts:91
##   POST /v1/widget/messages                  widget-conversations.controller.ts:197
##   POST /v1/widget/conversations/list        widget-conversations.controller.ts:226
##   POST /v1/widget/messages/list             widget-conversations.controller.ts:277
##   POST /v1/widget/conversations/:id/read    widget-conversations.controller.ts:516
##   POST /v1/widget/kb/search                 widget-kb.controller.ts:33
##   POST /v1/widget/kb/article                widget-kb.controller.ts:67
##   POST /v1/widget/uploads/presign           widget-engagement.controller.ts:65
##   POST /v1/widget/events                    widget-engagement.controller.ts:129
##
## All of them are POST, all of them carry `publicId` + `visitorToken` in the
## BODY rather than a header, and all of them sit on classes decorated
## `@Public()` + `@NoIdempotency()` — so an `Idempotency-Key` is honoured if
## sent and never demanded. We send one anyway: the recovery path below
## REPLAYS a write, and a replay without a key is a double send.
##
## ── The credential, said once ────────────────────────────────────────────
##
## There is no API key in this file and there must never be one. A `ck_` key
## is a standing workspace credential; a decompiled game hands an attacker the
## workspace. This is a visitor client, and `visitorToken` is the only
## credential it holds.
##
class_name ChatlyRestClient
extends RefCounted

## `api.chatlychat.com`.
##
## Spelled out rather than left to the caller because getting this wrong has
## already cost this project real harm: `sdk-react-native@0.1.1` shipped to npm
## with `api.chatly.com` — a live domain belonging to somebody else — so every
## app that followed the README and omitted the host sent its visitor sessions
## and messages to a third party. `check-published-package-hosts.mjs` now
## requires a published default to be a `chatlychat.com` host.
const DEFAULT_API_HOST := "api.chatlychat.com"

var _public_id: String
var _api_url: String
var _transport: ChatlyHttpTransport
var _store: ChatlyTokenStore
var _locale: String
var _timezone: String

## Set from the last `init()` so callers do not have to thread it through.
var session: Dictionary = {}


func _init(
	public_id: String,
	transport: ChatlyHttpTransport,
	store: ChatlyTokenStore,
	api_host: String = DEFAULT_API_HOST,
	secure: bool = true,
	locale: String = "",
	timezone: String = "",
) -> void:
	_public_id = public_id
	_transport = transport
	_store = store
	_api_url = "%s://%s" % ["https" if secure else "http", api_host]
	_locale = locale
	_timezone = timezone


func base_url() -> String:
	return _api_url


func visitor_token() -> String:
	return _store.get_token()


# ── Session ────────────────────────────────────────────────────────────────

## `POST /v1/widget/init` — bootstrap a visitor session.
##
## Answers `{ session: { token, visitorKey, contactId, workspaceId, … },
## workspace, branding, features, online, behavior, copy, profiles,
## realtimeUrl, quickReactions }` (`widgetInitResultSchema`).
##
## `realtimeUrl` is NULLABLE and null means "not configured", not "no
## realtime" — the client falls back to its own derivation. See
## `ChatlyRealtime.resolve_url`, which mirrors
## `apps/widget/src/realtime-url.ts` rather than inventing a second rule.
##
## `page.url` has to be a valid URL (`z.string().url()`), and a game has no
## page. `app://godot` is what the React Native SDK sends in the same spot
## (`app://ios`), and it parses.
func init_session(identity: Dictionary = {}) -> ChatlyResult:
	var body := {
		"publicId": _public_id,
		"page": {"url": "app://godot", "title": "game"},
	}
	var stored := _store.get_token()
	if not stored.is_empty():
		body["visitorToken"] = stored
	# `widgetInitSchema.locale` is `min(2).max(64)` — note the DIFFERENT bound
	# on `widgetStartSchema.locale`, which is `max(10)` and is why `start()`
	# below sends no locale at all.
	if not _locale.is_empty():
		body["locale"] = _locale
	if not _timezone.is_empty():
		body["timezone"] = _timezone
	if not identity.is_empty():
		body["identity"] = identity

	var result := await _post("/v1/widget/init", body)
	if result.ok and typeof(result.data) == TYPE_DICTIONARY:
		var d: Dictionary = result.data
		var s: Variant = d.get("session", null)
		if typeof(s) == TYPE_DICTIONARY:
			session = s
			var token := str((s as Dictionary).get("token", ""))
			if not token.is_empty():
				_store.set_token(token)
		# Remembered only once the server has ACCEPTED the identity, and only
		# when it carries a hash — an unverifiable replay could only ever turn
		# one refusal into two.
		if not identity.is_empty() and identity.has("userHash"):
			_store.set_identity(identity)
	return result


## Forget this device's session. The next `init_session()` starts anonymous.
func logout() -> void:
	session = {}
	_store.clear_all()


# ── Realtime credential ───────────────────────────────────────────────────

## `POST /v1/widget/realtime/token` — mint the ONE credential the Socket.IO
## gateway accepts from a visitor.
##
## HS256, scoped to a single conversation, 1h TTL
## (`VISITOR_REALTIME_TOKEN_TTL_SECONDS` in
## `packages/auth/src/visitor-token.ts`). The long-lived `session.token` from
## `init` is NOT accepted there: `handshakeAuthSchema` makes `kind` optional
## and it DEFAULTS TO AGENT, so a handshake carrying the session token is
## verified as RS256 against the platform public key, fails, and the gateway
## answers a bare `Unauthorized` naming neither credential.
##
## 404s (`NotFoundError('Conversation')`) when the conversation is not this
## visitor's own — the mint checks `conv.contactId === session.contactId`.
##
## 403s when the channel has an origin allow-list, because a native client
## sends no `Origin`/`Referer` and the route re-runs `enforceOrigin`. A
## customer who restricts origins for their website breaks their own game
## client; that is existing server behaviour and not something this SDK can
## fix, but it must not be papered over as a generic network error — hence the
## `message` carrying the server's own words.
func mint_realtime_token(conversation_id: String) -> ChatlyResult:
	return await _post("/v1/widget/realtime/token", {
		"publicId": _public_id,
		"visitorToken": _store.get_token(),
		"conversationId": conversation_id,
	})


# ── Conversations and messages ────────────────────────────────────────────

## `POST /v1/widget/conversations` — open a thread with a first message.
##
## `widgetStartSchema` refuses a body that is blank with no attachments
## ("Send a message or an attachment"), so this does not offer an empty start.
##
## Deliberately sends NO `locale`: `widgetStartSchema.locale` is
## `min(2).max(10)` while `widgetInitSchema.locale` is `min(2).max(64)`, and a
## real BCP-47 tag from `OS.get_locale()` — `en-US-POSIX` is 11 characters,
## `ja-JP-u-ca-japanese` is 19 — would be refused HERE while being accepted at
## `init`. The locale reaches the contact through `init` either way.
##
## The response is a `oneOf`: the ordinary arm returns the conversation DTO,
## the blocked-contact arm returns the raw `conversations` row with fifteen
## extra columns and a flattened `agentHandling*`. `id` is the only field both
## arms carry, so that is the only one this client reads off it.
func start_conversation(body: String, attachments: Array = []) -> ChatlyResult:
	var payload := {
		"publicId": _public_id,
		"visitorToken": _store.get_token(),
		"body": body,
	}
	if not attachments.is_empty():
		payload["attachments"] = attachments
	return await _post("/v1/widget/conversations", payload)


## `POST /v1/widget/messages` — reply on an existing thread.
func reply(conversation_id: String, body: String, attachments: Array = []) -> ChatlyResult:
	var payload := {
		"publicId": _public_id,
		"visitorToken": _store.get_token(),
		"conversationId": conversation_id,
		"body": body,
	}
	if not attachments.is_empty():
		payload["attachments"] = attachments
	return await _post("/v1/widget/messages", payload)


## A card's `postback`: a reply the bot reads, optionally with no visible bubble.
##
## `silent` is what makes a dialogue choice work — the agent hears
## `accept_quest` and the player does not see their own click echoed as a chat
## line. `widgetReplySchema` refuses `silent: true` with an empty body ("A
## silent message must carry text — it is what the bot reads"), so `value` is
## required here.
##
## `payload` is the machine-readable half, stored under
## `messages.metadata.postback`. Keys are bounded (`max(40)`) but not
## charset-checked: the card's author and the bot's author agree on them
## between themselves.
func postback(
	conversation_id: String,
	value: String,
	payload: Dictionary = {},
	silent: bool = true,
) -> ChatlyResult:
	var body := {
		"publicId": _public_id,
		"visitorToken": _store.get_token(),
		"conversationId": conversation_id,
		"body": value,
	}
	if not payload.is_empty():
		body["payload"] = payload
	if silent:
		body["silent"] = true
	return await _post("/v1/widget/messages", body)


## `POST /v1/widget/conversations/list` — this visitor's threads.
##
## NOT paginated: `limit` caps at 50 and there is no cursor, so this client
## must not declare a page envelope over it. Two SDKs in this repository
## shipped a paginator over a bare-array route with green suites because their
## fake transport answered every route with a page envelope.
##
## A visitor with no contact yet gets `{ "conversations": [] }`, not an error.
func list_conversations(limit: int = 20) -> ChatlyResult:
	return await _post("/v1/widget/conversations/list", {
		"publicId": _public_id,
		"visitorToken": _store.get_token(),
		"limit": clampi(limit, 1, 50),
	})


## `POST /v1/widget/messages/list` — one thread's messages, OLDEST FIRST.
##
## Also not paginated; `limit` caps at 200. The projection is nine columns with
## the tombstone redaction applied in SQL (a deleted message arrives with
## `deletedAt` set, `body` empty, `blocks`/`canvas` null, `attachments` `[]`),
## and it filters `hidden_from_contact = false` SERVER-SIDE — which the
## realtime envelope does not. See `ChatlyClient` for why that asymmetry
## matters to a renderer.
func list_messages(conversation_id: String, limit: int = 50) -> ChatlyResult:
	return await _post("/v1/widget/messages/list", {
		"publicId": _public_id,
		"visitorToken": _store.get_token(),
		"conversationId": conversation_id,
		"limit": clampi(limit, 1, 200),
	})


## `POST /v1/widget/conversations/:id/read` — persist how far the player read.
##
## The DURABLE half of a read receipt, and distinct from the realtime
## `message.read` tick, which is advisory. Without this the unread count can
## only go UP: it survives restarts and the agent inbox never learns the
## player saw the thread.
##
## `up_to_message_id` is optional and the two cases are NOT the same write.
## With an anchor the server RECOUNTS the replies newer than it, so a reply
## that landed between rendering and this request survives. Without one the
## read means "everything" and the recount degenerates to 0. Send the newest
## message actually shown.
##
## The id is validated as `uuidV7Schema` server-side, so a non-UUID anchor is
## a 400 rather than being ignored — passing `""` omits it, which is the
## intended way to say "everything".
##
## There is no `conversationId` in the body: the path carries it. And no
## `readerType`/`contactId` — both are DERIVED from the resolved session,
## because a body field for either would let one visitor token clear another
## contact's badge in the same workspace, which RLS cannot catch.
func mark_read(conversation_id: String, up_to_message_id: String = "") -> ChatlyResult:
	var body := {
		"publicId": _public_id,
		"visitorToken": _store.get_token(),
	}
	if not up_to_message_id.is_empty():
		body["upToMessageId"] = up_to_message_id
	return await _post(
		"/v1/widget/conversations/%s/read" % conversation_id.uri_encode(), body
	)


# ── Knowledge base ────────────────────────────────────────────────────────

## `POST /v1/widget/kb/search`.
##
## `visitorToken` is OPTIONAL here (`min(1).max(512).optional()`) — a player
## can search help before ever opening a thread. An empty string would fail
## `min(1)`, so it is omitted rather than sent blank.
##
## `profile` is a NAME, not a collection list: the server turns it into
## collection ids. A client-supplied id list would be no scoping at all.
func kb_search(query: String, limit: int = 8, profile: String = "") -> ChatlyResult:
	var body := {"publicId": _public_id, "query": query, "limit": clampi(limit, 1, 20)}
	var token := _store.get_token()
	if not token.is_empty():
		body["visitorToken"] = token
	if not _locale.is_empty():
		# `max(35)` here, and deliberately not validated as BCP-47 server-side:
		# an unparseable tag means "no filter" rather than a 400 on a public
		# endpoint. Truncated rather than dropped so a long tag still narrows.
		body["locale"] = _locale.substr(0, 35)
	if not profile.is_empty():
		body["profile"] = profile
	return await _post("/v1/widget/kb/search", body)


## `POST /v1/widget/kb/article` — one article by slug.
func kb_article(slug: String, profile: String = "") -> ChatlyResult:
	var body := {"publicId": _public_id, "slug": slug}
	var token := _store.get_token()
	if not token.is_empty():
		body["visitorToken"] = token
	if not profile.is_empty():
		body["profile"] = profile
	return await _post("/v1/widget/kb/article", body)


# ── Telemetry ─────────────────────────────────────────────────────────────

## `POST /v1/widget/events` — a named event with properties.
##
## Feeds CDP audiences and workflow triggers. `tracked: false` is the
## anonymous case and a 200: an event with no contact has nothing to attach
## to, and refusing would make this throw for most players most of the time.
func track(event_name: String, properties: Dictionary = {}) -> ChatlyResult:
	var body := {
		"publicId": _public_id,
		"visitorToken": _store.get_token(),
		"name": event_name,
	}
	if not properties.is_empty():
		body["properties"] = properties
	return await _post("/v1/widget/events", body)


# ── Uploads ───────────────────────────────────────────────────────────────

## Upload bytes and return the attachment record a message carries.
##
## THREE steps, and the first is where two of the four mobile SDKs were wrong
## for their whole lives. They posted `{ filename, mimeType, data }` — a
## base64 blob — to a route that accepts
## `{ visitorToken, publicId, filename, contentType, sizeBytes }` and takes no
## bytes at all. zod dropped `mimeType` and `data` as unknown keys and
## answered 400 on the missing `contentType`, so no attachment ever uploaded.
##
##   1. presign — the API mints the key under `workspaces/<id>/…`, so a
##      visitor cannot choose where their file lands;
##   2. the bytes go STRAIGHT to object storage with the returned method and
##      every returned header. Not multipart. Not base64. The bytes;
##   3. the attachment record, which renames `contentType` to `mimeType` —
##      the same string under two names, because that is what the two schemas
##      call it (`widgetPresignSchema` vs `widgetAttachmentSchema`).
##
## The route refuses BEFORE presigning on three conditions — attachments off
## for the channel, a MIME type outside `WIDGET_UPLOAD_MIME`, a file over the
## channel's cap — each with copy written for the visitor to read. Do not
## pre-check the size here: the cap is per channel and the server owns it.
##
## A natural use in a game is a screenshot: `get_viewport().get_texture()
## .get_image().save_png_to_buffer()` produces exactly the `PackedByteArray`
## this wants.
func upload_attachment(
	bytes: PackedByteArray, filename: String, mime_type: String
) -> ChatlyResult:
	var size_bytes := bytes.size()
	if size_bytes <= 0:
		# `widgetPresignSchema.sizeBytes` is `int().positive()`, so a zero-byte
		# file is a 400. Refused here with words rather than sent to collect
		# one, because "sizeBytes must be greater than 0" is not what went
		# wrong from the player's side.
		return ChatlyResult.refused(
			"empty_file",
			"That file is empty, so there is nothing to send.",
			"/v1/widget/uploads/presign",
		)

	var presigned := await _post("/v1/widget/uploads/presign", {
		"publicId": _public_id,
		"visitorToken": _store.get_token(),
		"filename": filename,
		# `contentType` on the way in, `mimeType` on the way out. Same string.
		"contentType": mime_type,
		"sizeBytes": size_bytes,
	})
	if not presigned.ok:
		return presigned
	if typeof(presigned.data) != TYPE_DICTIONARY:
		return ChatlyResult.transport_failure(
			"presign answered a non-object", "/v1/widget/uploads/presign"
		)

	var p: Dictionary = presigned.data
	var url := str(p.get("url", ""))
	# Dev fallback: no object storage configured. The API answers with a
	# `data:` sentinel rather than a real URL, and PUTting to it would throw a
	# confusing transport error. Same guard as `uploadOne` in the web widget.
	if url.begins_with("data:"):
		return ChatlyResult.transport_failure(
			"file uploads are not configured on this deployment", "upload"
		)

	var headers := PackedStringArray()
	var supplied: Variant = p.get("headers", {})
	if typeof(supplied) == TYPE_DICTIONARY:
		for key: Variant in (supplied as Dictionary):
			headers.append("%s: %s" % [str(key), str((supplied as Dictionary)[key])])

	var put: Dictionary = await _transport.put_bytes(url, headers, bytes)
	var put_status: int = put.get("status", 0)
	if put_status < 200 or put_status >= 300:
		return ChatlyResult.transport_failure(
			"object storage refused the bytes (%d)" % put_status, "upload"
		)

	return ChatlyResult.success({
		"id": p.get("uploadId", ""),
		"filename": filename,
		"mimeType": mime_type,
		"sizeBytes": size_bytes,
		"url": p.get("publicUrl", ""),
	}, 200, "upload")


# ── The one place a request is actually sent ──────────────────────────────

func _post(path: String, body: Dictionary, idempotency_key: String = "", is_retry: bool = false) -> ChatlyResult:
	var key := idempotency_key if not idempotency_key.is_empty() else new_idempotency_key()
	var headers := PackedStringArray([
		"content-type: application/json",
		"accept: application/json",
		"idempotency-key: " + key,
	])
	var answer: Dictionary = await _transport.post_json(
		_api_url + path, headers, JSON.stringify(body)
	)
	var status: int = answer.get("status", 0)
	var text: String = str(answer.get("body", ""))

	if status == 0:
		return ChatlyResult.transport_failure(str(answer.get("reason", "unknown")), path)

	if status < 200 or status >= 300:
		var failed := ChatlyResult.failure(status, text, path)
		if failed.is_stale_session() and not is_retry:
			return await _recover_session(path, body, key)
		return failed

	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	return ChatlyResult.success(parsed, status, path)


## The server refused the token on this device. Get a new one and replay, once.
##
## This is what a mid-session player hits on the deploy that closes the
## identity-verification bypass: the token on disk predates signed visitor
## sessions and is refused rather than honoured. Without this the game surfaces
## one failed send and only self-heals on the NEXT launch, because the dead
## token stays on disk. Handled rather than surfaced, because from the player's
## side nothing has gone wrong.
##
## The idempotency key is REUSED, so a write that did land coalesces
## server-side instead of double-sending. `is_retry` bounds recovery to one
## attempt: a second refusal is a real error and is returned.
func _recover_session(path: String, body: Dictionary, idempotency_key: String) -> ChatlyResult:
	var retry := body.duplicate(true)
	var identity := _store.get_identity()
	_store.clear_token()

	if path == "/v1/widget/init":
		# Re-boot in place: drop the dead token, keep whatever identity the
		# caller asked for, falling back to the remembered one.
		retry.erase("visitorToken")
		if not retry.has("identity") and not identity.is_empty():
			retry["identity"] = identity
	else:
		var reinit := await init_session(identity)
		if not reinit.ok:
			return reinit
		retry["visitorToken"] = _store.get_token()
	return await _post(path, retry, idempotency_key, true)


## A key for the `Idempotency-Key` header.
##
## `Crypto.generate_random_bytes` rather than `randi()`: the latter is seeded
## from the same PRNG a game may have reseeded for determinism (a replay
## system, a seeded run), and two players — or one player twice — colliding on
## a key would coalesce two different writes into one.
static func new_idempotency_key() -> String:
	var crypto := Crypto.new()
	return "godot-" + crypto.generate_random_bytes(16).hex_encode()
