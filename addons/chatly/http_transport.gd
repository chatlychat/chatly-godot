##
## The HTTP seam. One method, overridden twice: once for real, once for tests.
##
## ── Why this is a seam and not just `HTTPRequest` inline ──────────────────
##
## Every one of the four mobile SDKs shipped a broken visitor contract with a
## GREEN suite, because each test asserted on a canned response. A fake
## transport that answers whatever the SDK asked for agrees with the bug. The
## half a fake cannot fake is **what the client sent** — so the seam is placed
## here, at the last point before the bytes leave, and `tests/fakes/
## recording_transport.gd` keeps every request body for the suite to assert on.
##
## ── Why `Node` and not `RefCounted` ──────────────────────────────────────
##
## `HTTPRequest` is a `Node` (verified: `ClassDB.get_parent_class("HTTPRequest")`
## is `Node`) and does nothing until it is inside the scene tree. So the real
## transport has to be in the tree too, and the base class matches it so a
## caller can hold either one in the same typed field.
##
## ── Why `post_json` is awaited even though a fake returns instantly ──────
##
## `await` on a call that turns out not to be a coroutine returns the value
## directly — verified on Godot 4.7.2, no warning, no error. So the call site
## writes `await transport.post_json(...)` unconditionally, the real transport
## suspends on `request_completed`, and the recording one returns on the spot.
## The suite therefore needs no frames to run and no sleeps to settle, which
## matters: a fixed sleep in a test here would flake under `turbo`'s
## parallelism exactly as it has elsewhere in this repository.
##
class_name ChatlyHttpTransport
extends Node

## POST a JSON body and return `{ "status": int, "body": String }`.
##
## `status` is 0 when the request never reached a server. Implementations must
## not raise: a game's main loop cannot be allowed to die because a player's
## wifi dropped mid-request.
func post_json(_url: String, _headers: PackedStringArray, _body: String) -> Dictionary:
	push_error("[chatly] ChatlyHttpTransport.post_json must be overridden")
	return {"status": 0, "body": ""}


## PUT raw bytes with exactly the headers the presign response supplied.
##
## Separate from `post_json` because step 2 of an upload is **the bytes**, to
## object storage, not multipart and not base64 — and because it is the one
## request in this client that does not go to the Chatly API at all.
func put_bytes(_url: String, _headers: PackedStringArray, _bytes: PackedByteArray) -> Dictionary:
	push_error("[chatly] ChatlyHttpTransport.put_bytes must be overridden")
	return {"status": 0, "body": ""}
