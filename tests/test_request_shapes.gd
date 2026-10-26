##
## What this client SENDS to each `/v1/widget/*` route.
##
## Every expectation here was read out of the zod schema in
## `apps/api/src/modules/widget/widget.schemas.ts` and the handler that parses
## it, not out of a doc. zod drops an unknown key silently, so a misnamed field
## is never a type error anywhere — it is a 400 at runtime, and a green suite
## everywhere else. That is how `uploadAttachment` shipped broken in two
## mobile SDKs for their whole lives.
##
extends ChatlyTestCase

const RecordingTransport = preload("res://tests/fakes/recording_transport.gd")
const MemoryStore = preload("res://tests/fakes/memory_store.gd")

const PUBLIC_ID := "ch_live_test"
const CONVERSATION := "0192f0c0-0000-7000-8000-000000000001"

var _transport: RecordingTransport
var _store: MemoryStore
var _rest: ChatlyRestClient


func _setup(token: String = "stored-visitor-token") -> void:
	_transport = RecordingTransport.new()
	_store = MemoryStore.new()
	_store.token = token
	_rest = ChatlyRestClient.new(PUBLIC_ID, _transport, _store, "api.chatlychat.com", true)


# ── init ─────────────────────────────────────────────────────────────────

func test_init_sends_public_id_and_a_parseable_page_url() -> void:
	_setup("")
	_transport.queue("/v1/widget/init", 201, {
		"session": {"token": "fresh", "contactId": "c1", "workspaceId": "w1"},
		"realtimeUrl": "wss://realtime.chatlychat.com",
	})
	await _rest.init_session()

	var body := _transport.first_body("/v1/widget/init")
	equal(body.get("publicId", ""), PUBLIC_ID, "publicId")
	# `widgetInitSchema.page.url` is `z.string().url()`, and a game has no
	# page. An unparseable value here would 400 `init`, and a failed `init`
	# means the chat never opens at all.
	var page: Dictionary = body.get("page", {})
	var url := str(page.get("url", ""))
	check(url.contains("://"), "page.url must parse as a URL, got %s" % url)
	# No stored token, so the key is OMITTED rather than sent empty:
	# `visitorToken` is `min(1)` and `""` would be a 400 on the first launch.
	absent(body, "visitorToken", "an absent token is absent, not an empty string")


func test_init_replays_a_stored_token_and_stores_the_fresh_one() -> void:
	_setup("token-on-disk")
	_transport.queue("/v1/widget/init", 201, {
		"session": {"token": "rotated-token", "contactId": "c1", "workspaceId": "w1"},
	})
	await _rest.init_session()

	equal(
		_transport.first_body("/v1/widget/init").get("visitorToken", ""),
		"token-on-disk",
		"the stored token is replayed so history is the same visitor's",
	)
	equal(_store.token, "rotated-token", "init rotated the token and it was persisted")


## The identity is remembered only once the server has ACCEPTED it, and only
## when it carries a hash. On a channel with verification enabled an unhashed
## claim is refused, so replaying one could only turn one refusal into two.
func test_an_unhashed_identity_is_not_remembered() -> void:
	_setup("")
	_transport.queue("/v1/widget/init", 201, {"session": {"token": "t", "contactId": "c"}})
	await _rest.init_session({"externalId": "player-7", "name": "Ava"})
	check(_store.identity.is_empty(), "no hash, so nothing to replay")

	_setup("")
	_transport.queue("/v1/widget/init", 201, {"session": {"token": "t", "contactId": "c"}})
	await _rest.init_session({"externalId": "player-7", "userHash": "abc123"})
	equal(_store.identity.get("externalId", ""), "player-7", "a hashed identity IS remembered")


# ── The realtime mint ────────────────────────────────────────────────────

func test_the_mint_body_is_exactly_what_the_schema_wants() -> void:
	_setup()
	_transport.queue("/v1/widget/realtime/token", 201, {"token": "rt", "expiresAt": "x"})
	await _rest.mint_realtime_token(CONVERSATION)

	var body := _transport.first_body("/v1/widget/realtime/token")
	# `widgetRealtimeTokenSchema` is exactly these three, all required.
	equal(body.size(), 3, "exactly { publicId, visitorToken, conversationId }")
	equal(body.get("publicId", ""), PUBLIC_ID, "publicId")
	equal(body.get("visitorToken", ""), "stored-visitor-token", "the SESSION token proves ownership here")
	equal(body.get("conversationId", ""), CONVERSATION, "conversationId")


# ── start and reply ──────────────────────────────────────────────────────

## `widgetStartSchema.locale` is `min(2).max(10)` while
## `widgetInitSchema.locale` is `min(2).max(64)`. A real BCP-47 tag from
## `OS.get_locale()` — `en-US-POSIX` is 11, `ja-JP-u-ca-japanese` is 19 —
## would be accepted at `init` and REFUSED here, so `start` sends none. The
## locale reaches the contact through `init` either way.
func test_start_sends_no_locale_because_the_bound_is_tighter_there() -> void:
	_transport = RecordingTransport.new()
	_store = MemoryStore.new()
	_store.token = "t"
	_rest = ChatlyRestClient.new(
		PUBLIC_ID, _transport, _store, "api.chatlychat.com", true, "ja-JP-u-ca-japanese"
	)
	_transport.queue("/v1/widget/conversations", 201, {"conversation": {"id": CONVERSATION}, "message": {"id": "m1"}})
	await _rest.start_conversation("hello")

	var body := _transport.first_body("/v1/widget/conversations")
	absent(body, "locale", "a 19-character tag would be a 400 on this route")
	equal(body.get("body", ""), "hello", "body")
	# `attachments` has a `.default([])`, so omitting it is correct and sending
	# an empty array is noise.
	absent(body, "attachments", "an empty attachment list is omitted")


func test_reply_names_the_conversation_in_the_body() -> void:
	_setup()
	_transport.queue("/v1/widget/messages", 201, {"id": "m2"})
	await _rest.reply(CONVERSATION, "still broken")

	var body := _transport.first_body("/v1/widget/messages")
	equal(body.get("conversationId", ""), CONVERSATION, "conversationId is in the BODY, not the path")
	# `channelPublicId` is what the Kotlin SDK sent where the server reads
	# `publicId`, so every one of its calls was a 400.
	absent(body, "channelPublicId", "the server reads 'publicId'")
	present(body, "publicId", "publicId")
	present(body, "visitorToken", "visitorToken")


## `widgetReplySchema` refuses `silent: true` with an empty body ("A silent
## message must carry text — it is what the bot reads").
func test_a_postback_is_silent_and_carries_its_structured_half() -> void:
	_setup()
	_transport.queue("/v1/widget/messages", 201, {"id": "m3"})
	await _rest.postback(CONVERSATION, "accept_quest", {"quest_id": 42}, true)

	var body := _transport.first_body("/v1/widget/messages")
	equal(body.get("silent", false), true, "silent")
	equal(body.get("body", ""), "accept_quest", "the value IS the body — it is what the bot reads")
	var payload: Dictionary = body.get("payload", {})
	equal(int(payload.get("quest_id", 0)), 42, "the structured half rides alongside")


# ── The lists ────────────────────────────────────────────────────────────

## Neither list route is paginated: `conversations/list` caps `limit` at 50 and
## `messages/list` at 200, and NEITHER has a cursor. Two SDKs in this
## repository shipped a paginator over a bare route with green suites, because
## their fake answered every route with a page envelope.
func test_list_limits_are_clamped_to_what_the_schema_accepts() -> void:
	_setup()
	_transport.queue("/v1/widget/conversations/list", 201, {"conversations": []})
	_transport.queue("/v1/widget/messages/list", 201, {"messages": []})
	await _rest.list_conversations(5000)
	await _rest.list_messages(CONVERSATION, 5000)

	equal(
		int(_transport.first_body("/v1/widget/conversations/list").get("limit", 0)),
		50,
		"conversations/list caps at 50",
	)
	equal(
		int(_transport.first_body("/v1/widget/messages/list").get("limit", 0)),
		200,
		"messages/list caps at 200",
	)
	absent(_transport.first_body("/v1/widget/messages/list"), "cursor", "there is no cursor")


# ── mark_read ────────────────────────────────────────────────────────────

## `widgetReadConversationSchema` is `{ publicId, visitorToken,
## upToMessageId? }` and NOTHING else. The conversation is in the path; a
## second source would have to be compared against the first. And there is no
## `readerType`/`contactId`, because both are DERIVED from the resolved
## session — a body field for either would let one visitor token clear another
## contact's badge in the same workspace, which RLS cannot catch.
func test_mark_read_puts_the_conversation_in_the_path_only() -> void:
	_setup()
	_transport.queue_always("/v1/widget/conversations/%s/read" % CONVERSATION, 201, {"readAt": "x", "upToMessageId": null})
	await _rest.mark_read(CONVERSATION, "0192f0c0-0000-7000-8000-0000000000ff")

	var hits := _transport.to_path("/v1/widget/conversations/%s/read" % CONVERSATION)
	equal(hits.size(), 1, "the id went into the path")
	var body: Dictionary = hits[0]["body"]
	absent(body, "conversationId", "the path carries it")
	absent(body, "readerType", "derived from the session server-side")
	absent(body, "contactId", "derived from the session server-side")
	equal(
		body.get("upToMessageId", ""),
		"0192f0c0-0000-7000-8000-0000000000ff",
		"the anchor makes the server RECOUNT rather than zero the badge",
	)


## Without an anchor the read means "everything" and the recount degenerates to
## 0. Omitting the key is how that is said; `""` would fail `uuidV7Schema`.
func test_mark_read_omits_an_empty_anchor_rather_than_sending_a_blank() -> void:
	_setup()
	_transport.queue_always("/v1/widget/conversations/%s/read" % CONVERSATION, 201, {"readAt": "x"})
	await _rest.mark_read(CONVERSATION)
	var body: Dictionary = _transport.to_path("/v1/widget/conversations/%s/read" % CONVERSATION)[0]["body"]
	absent(body, "upToMessageId", "an absent anchor is absent, not an empty string")


# ── Uploads: the trap, in full ───────────────────────────────────────────

## `widgetPresignSchema` is
## `{ visitorToken, publicId, filename, contentType, sizeBytes }`.
##
## React Native and Flutter both posted `{ filename, mimeType, data }` — a
## base64 blob — to this route. zod dropped `mimeType` and `data` as unknown
## keys and answered 400 on the missing `contentType`, so no attachment ever
## uploaded from either SDK, and both suites were green.
func test_presign_sends_contentType_and_never_mimeType_or_bytes() -> void:
	_setup()
	_transport.queue("/v1/widget/uploads/presign", 201, {
		"uploadId": "up-1",
		"url": "https://storage.example.com/signed",
		"method": "PUT",
		"headers": {"content-type": "image/png", "x-amz-acl": "private"},
		"publicUrl": "https://cdn.example.com/f.png",
		"expiresAt": "2026-10-25T13:00:00.000Z",
	})
	_transport.queue("/signed", 200, "")

	var bytes := PackedByteArray([1, 2, 3, 4, 5])
	var result := await _rest.upload_attachment(bytes, "bug.png", "image/png")

	var body := _transport.first_body("/v1/widget/uploads/presign")
	present(body, "contentType", "the presign schema's name is 'contentType'")
	equal(body.get("contentType", ""), "image/png", "contentType")
	absent(body, "mimeType", "'mimeType' is the key zod drops — this is THE bug")
	absent(body, "data", "the presign route takes no bytes at all")
	equal(int(body.get("sizeBytes", 0)), 5, "sizeBytes is the real byte length")
	equal(body.get("filename", ""), "bug.png", "filename")

	# Step 3 renames it back. Same string, two names, because that is what the
	# two schemas call it (`widgetPresignSchema` vs `widgetAttachmentSchema`).
	check(result.ok, "the upload succeeded: %s" % result.message)
	var record: Dictionary = result.data
	equal(record.get("mimeType", ""), "image/png", "the ATTACHMENT calls it 'mimeType'")
	absent(record, "contentType", "the attachment schema has no 'contentType'")
	equal(record.get("id", ""), "up-1", "the attachment id is the uploadId")
	equal(record.get("url", ""), "https://cdn.example.com/f.png", "the attachment url is the publicUrl")


## Step 2 is the bytes, to object storage, with every header the presign
## returned. Not multipart, not base64, and not to the Chatly API.
func test_the_bytes_go_straight_to_storage_with_the_presigned_headers() -> void:
	_setup()
	_transport.queue("/v1/widget/uploads/presign", 201, {
		"uploadId": "up-2",
		"url": "https://storage.example.com/signed",
		"method": "PUT",
		"headers": {"content-type": "image/png", "x-amz-meta-k": "v"},
		"publicUrl": "https://cdn.example.com/f.png",
		"expiresAt": "x",
	})
	_transport.queue("/signed", 200, "")
	await _rest.upload_attachment(PackedByteArray([9, 9, 9]), "s.png", "image/png")

	var puts := _transport.to_path("/signed")
	equal(puts.size(), 1, "one PUT to storage")
	equal(puts[0]["method"], "PUT", "the method the presign named")
	var sent_bytes: PackedByteArray = puts[0]["bytes"]
	equal(sent_bytes.size(), 3, "the raw bytes, not a wrapper")
	equal(sent_bytes[0], 9, "the bytes are the file's own")
	equal(puts[0]["raw"], "", "no JSON body, no multipart envelope, no base64")

	var headers: PackedStringArray = puts[0]["headers"]
	var joined := "|".join(headers).to_lower()
	check(joined.contains("x-amz-meta-k: v"), "EVERY presigned header is replayed, got %s" % joined)
	check(joined.contains("content-type: image/png"), "including content-type, got %s" % joined)


## The dev fallback: no object storage configured, so the API answers with a
## `data:` sentinel. PUTting to it produces a confusing transport error, so it
## is caught with words instead. Same guard as `uploadOne` in the web widget.
func test_a_data_url_from_an_unconfigured_deployment_is_caught_with_words() -> void:
	_setup()
	_transport.queue("/v1/widget/uploads/presign", 201, {
		"uploadId": "up-3", "url": "data:,", "method": "PUT", "headers": {},
		"publicUrl": "data:,", "expiresAt": "x",
	})
	var result := await _rest.upload_attachment(PackedByteArray([1]), "a.png", "image/png")
	check(not result.ok, "refused")
	equal(_transport.count_to("/"), 0, "nothing was PUT to the sentinel")
	check(result.message.contains("not configured"), "the message says what is wrong: %s" % result.message)


## The route refuses BEFORE presigning on three conditions, each with copy
## written for the VISITOR to read. A composer should be able to render
## `result.message` straight into the UI — and that copy used to be buried
## inside a developer string in the React Native SDK, which is the same as not
## having it.
func test_a_refusal_surfaces_the_servers_own_visitor_facing_copy() -> void:
	_setup()
	_transport.queue("/v1/widget/uploads/presign", 400, {
		"error": {"code": "upload_too_large", "message": "Files must be under 10 MB"},
	})
	var result := await _rest.upload_attachment(PackedByteArray([1, 2]), "big.png", "image/png")
	check(not result.ok, "refused")
	equal(result.message, "Files must be under 10 MB", "verbatim, ready to render")
	equal(result.code, "upload_too_large", "and the developer half is kept separately")


# ── Error parsing and recovery ───────────────────────────────────────────

## The API NESTS every error — `app-exception.filter.ts` ends with
## `send({ error: body })`. Reading `body.code` at the TOP level returns
## nothing for every real response, and that exact mistake has shipped three
## times here (the web widget, `sdk-js`, `sdk-react-native`), each time
## silently disabling the stale-session recovery that depends on it.
func test_the_error_code_is_read_from_the_nested_shape() -> void:
	var nested := ChatlyResult.parse_error_body(
		JSON.stringify({"error": {"code": "visitor_session_invalid", "message": "Session expired"}})
	)
	equal(nested["code"], "visitor_session_invalid", "nested code")
	equal(nested["message"], "Session expired", "nested message")

	# The un-nested fallback is kept deliberately: a proxy in front of the API
	# answers in its own shape, and a game reaches the internet through
	# whatever the player's network does.
	var flat := ChatlyResult.parse_error_body(JSON.stringify({"code": "gateway_timeout"}))
	equal(flat["code"], "gateway_timeout", "a proxy's own shape still parses")

	var garbage := ChatlyResult.parse_error_body("<html>502 Bad Gateway</html>")
	equal(garbage["code"], "", "HTML from a captive portal is not a crash")


## A 403 with a `visitor_session_*` code means the token on disk is no good.
## Re-init and replay, ONCE, reusing the idempotency key so a write that did
## land coalesces instead of double-sending.
func test_a_stale_session_re_inits_and_replays_with_the_same_key() -> void:
	_setup("dead-token")
	_transport.queue("/v1/widget/messages", 403, {
		"error": {"code": "visitor_session_upgrade_required", "message": "Re-authenticate"},
	})
	_transport.queue("/v1/widget/init", 201, {"session": {"token": "revived", "contactId": "c"}})
	_transport.queue("/v1/widget/messages", 201, {"id": "m9"})

	var result := await _rest.reply(CONVERSATION, "hello?")
	check(result.ok, "the caller never saw the failure: %s" % result.message)

	equal(
		_transport.call_order(),
		["/v1/widget/messages", "/v1/widget/init", "/v1/widget/messages"] as Array[String],
		"refuse, re-init, replay",
	)
	equal(_store.clear_token_calls, 1, "the DEAD token was cleared from the store, not just memory")

	var sends := _transport.to_path("/v1/widget/messages")
	equal(sends[1]["body"].get("visitorToken", ""), "revived", "the replay carried the NEW token")
	# Reused, so a write that did land coalesces server-side. Every widget
	# route is `@NoIdempotency()`, so the header is honoured if sent and never
	# demanded — which makes sending it on a replay free and not sending it a
	# double post.
	var first_key := _transport.header_value(0, "idempotency-key")
	var replay_key := _transport.header_value(2, "idempotency-key")
	check(not first_key.is_empty(), "an idempotency key was sent")
	equal(replay_key, first_key, "the replay reused the key rather than minting a second")


## A 403 that is NOT a session code must not be retried. A disallowed origin
## and a missing identity hash are both 403s, and retrying either fails again,
## more slowly.
func test_a_non_session_403_is_not_retried() -> void:
	_setup("t")
	_transport.queue("/v1/widget/messages", 403, {
		"error": {"code": "origin_not_allowed", "message": "This site is not allowed to chat"},
	})
	var result := await _rest.reply(CONVERSATION, "hi")
	check(not result.ok, "surfaced rather than swallowed")
	equal(_transport.count_to("/v1/widget/init"), 0, "no re-init was attempted")
	equal(result.message, "This site is not allowed to chat", "and the reason is the server's own")


## Recovery is bounded to ONE attempt. A second refusal is a real error.
func test_recovery_does_not_loop() -> void:
	_setup("dead")
	_transport.queue_always("/v1/widget/messages", 403, {
		"error": {"code": "visitor_session_invalid", "message": "no"},
	})
	_transport.queue_always("/v1/widget/init", 201, {"session": {"token": "new", "contactId": "c"}})
	var result := await _rest.reply(CONVERSATION, "hi")
	check(not result.ok, "the second refusal is returned")
	equal(_transport.count_to("/v1/widget/messages"), 2, "exactly two attempts, not a loop")


## A request that never reached a server is `status == 0`, not an invented 5xx.
## The difference is what lets a caller tell "the server refused me"
## (permanent) from "I never spoke to a server" (worth retrying).
func test_a_transport_failure_is_status_zero_and_not_a_fake_5xx() -> void:
	_setup()
	var dead := ChatlyHttpTransport.new()
	# The base class answers `{status: 0}` and pushes an error, which is
	# exactly the unreachable-server case.
	_rest = ChatlyRestClient.new(PUBLIC_ID, dead, _store)
	var result := await _rest.list_conversations()
	check(not result.ok, "not ok")
	equal(result.status, 0, "0 means 'never reached a server'")
	equal(result.code, "transport_failed", "and it is distinguishable from any HTTP code")
	dead.free()


# ── Misc ─────────────────────────────────────────────────────────────────

## `visitorToken` is OPTIONAL on the KB routes (`min(1).max(512).optional()`),
## so a player can search help before ever opening a thread. An empty string
## would fail `min(1)`, so it is omitted rather than sent blank.
func test_kb_search_omits_an_absent_token_rather_than_sending_an_empty_one() -> void:
	_setup("")
	_transport.queue("/v1/widget/kb/search", 201, {"results": []})
	await _rest.kb_search("how do I save")
	var body := _transport.first_body("/v1/widget/kb/search")
	absent(body, "visitorToken", "min(1) would refuse an empty string")
	equal(body.get("query", ""), "how do I save", "query")


## Keys must not collide. `randi()` is seeded from the same PRNG a game may
## have reseeded for determinism (a replay system, a seeded run), so two
## players — or one player twice — could produce the same key and have two
## different writes coalesced into one.
func test_idempotency_keys_do_not_repeat() -> void:
	var seen := {}
	for _i in 200:
		var key := ChatlyRestClient.new_idempotency_key()
		check(not seen.has(key), "a key repeated: %s" % key)
		seen[key] = true
	equal(seen.size(), 200, "200 distinct keys")
