# Chatly for Godot

Talk to a Chatly agent from inside a Godot 4 game: the visitor conversation contract of the web widget, in GDScript,
with **no third-party code** — `HTTPRequest` for HTTP and `WebSocketPeer` for realtime. It adds one node, `ChatlyClient`.

What is in it: the visitor session (resumed across launches), a conversation (history, send, postbacks, read
receipts, typing, file upload), realtime with automatic fallback to polling and a signal that says which one you
have, help-centre search, and event tracking.

What is not: a UI. The `demo/` scene is the smallest possible chat; draw yours however your game does.

## Install

Godot 4.3 or newer.

**From a release** (recommended): download `chatly-godot-addon-v0.1.0.zip` from the
[latest release](https://github.com/chatlychat/chatly-godot/releases/latest), unzip it into your project's root so
that `addons/chatly/plugin.cfg` exists, then enable **Project → Project Settings → Plugins → Chatly**.

**From git**: copy the `addons/chatly` folder of this repository into your project's `addons/` folder.

## Use

```gdscript
extends Node

var chat := ChatlyClient.new()

func _ready() -> void:
	chat.public_id = "YOUR_WIDGET_PUBLIC_ID"
	add_child(chat)
	chat.message_received.connect(func(m: Dictionary) -> void: print(m.get("body", "")))
	chat.transport_changed.connect(func(mode: String) -> void: print("transport: ", mode))
	if await chat.open():
		await chat.send("my quest log is empty")
```

`message_received` fires only for rows the player should see (silent postbacks are filtered). `transport_changed`
fires with `"realtime"` or `"polling"`, so you can tell the player that replies may take a few seconds instead of
leaving them wondering. `envelope_received` carries every realtime envelope (typing, reads, assignment, host
capabilities) for the cases you want to handle yourself.

## No API key, ever

A public id is the same string that goes in a `<script>` tag on a public web page; it is not a secret. A `ck_` API key
is a standing workspace credential, and a shipped game hands it to every player. If you use identity verification,
compute the `userHash` on **your own server** and pass it to `open({...})`.

## Origins

A channel that restricts allowed origins refuses a native client, which sends none. The addon falls back to polling
rather than failing; leave the origin list empty on the channel your game uses if you want push.

## Tests

```sh
godot --headless --path . --import
godot --headless --path . --script tests/run_tests.gd
```

64 tests, no network: the HTTP transport and the socket are injected fakes, and the assertions are on what the addon
*sent* (the handshake carries `kind: "visitor"`, the socket token comes from the mint route, a second connect attempt
mints again). The runner exits 1 on a failure, on an empty run, and on a suite that does not compile.

## Versions

Developed and tested on Godot 4.7.2. `project.godot` declares the 4.3 feature level.

---

## About this repository

This is a **mirror**. `chatly-godot` is built from a private monorepo where the rest
of the platform, its migrations and its contract checks live, so a pull request here
cannot be merged directly — but a patch is still the fastest way to get something
fixed and we will port it with attribution.

What you can do here: read the source, run the tests, open an issue, or open a PR
and we will treat the diff as the proposal.

Issues: https://github.com/chatlychat/chatly-godot/issues · Docs: https://chatlychat.com/docs
