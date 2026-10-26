##
## The smallest thing that is actually a chat.
##
## A `ChatlyClient`, a scrolling log, a line edit and a send button. It exists
## to be read as much as run: every call a game needs is in here once, and
## nothing else is.
##
## To run it: put your channel's public id in `PUBLIC_ID` below (or set
## `CHATLY_PUBLIC_ID` in the environment) and press play. A public id is the
## same string that goes in a `<script>` tag on a public web page — it is not
## a secret and not a credential. There is no API key anywhere in this addon,
## and `README.md` says why there must never be.
##
extends Control

## Your channel's public id. The one piece of configuration this needs.
const PUBLIC_ID := ""

## A transport label, so a player is told when replies will be slow rather
## than left wondering. This is the whole reason `transport_changed` exists:
## a client that claims realtime and silently has none is the failure the
## visitor contract document was written to prevent.
const TRANSPORT_COPY := {
	"realtime": "connected",
	"polling": "connected (messages may take a few seconds)",
	"none": "not connected",
}

var _chat: ChatlyClient
var _log: RichTextLabel
var _input: LineEdit
var _send: Button
var _status: Label
var _typing: Label


func _ready() -> void:
	_build_ui()

	var public_id := PUBLIC_ID
	if public_id.is_empty():
		public_id = OS.get_environment("CHATLY_PUBLIC_ID")
	if public_id.is_empty():
		_status.text = "Set PUBLIC_ID in demo.gd (or CHATLY_PUBLIC_ID in the environment)."
		_send.disabled = true
		return

	_chat = ChatlyClient.new()
	_chat.public_id = public_id
	add_child(_chat)

	_chat.message_received.connect(_on_message)
	_chat.transport_changed.connect(_on_transport)
	_chat.typing_changed.connect(_on_typing)
	_chat.error_occurred.connect(_on_error)

	_status.text = "connecting…"
	var opened := await _chat.open()
	if not opened:
		# `error_occurred` has already carried the server's own words.
		return
	_send.disabled = false
	if _chat.conversation_id().is_empty():
		_append("[i]Say something to start a conversation.[/i]")


func _on_message(message: Dictionary) -> void:
	# `authorType` is one of `contact` / `user` / `bot` / `system`. A tombstoned
	# message arrives with `deletedAt` set and an empty body — the server
	# redacts it in SQL, so this is the agent having deleted something.
	if message.get("deletedAt", null) != null:
		_append("[i](message removed)[/i]")
		return
	var author := str(message.get("authorType", "user"))
	var who := "You" if author == "contact" else "Support"
	var body := str(message.get("body", ""))
	if body.is_empty():
		# An attachment-only message, or a block message whose content is in
		# `blocks` rather than `body`. Rendering cards is a game's own job —
		# the data is on the message.
		body = "[i](attachment)[/i]" if not str(message.get("attachments", "")).is_empty() else "[i](no text)[/i]"
	_append("[b]%s:[/b] %s" % [who, body])

	# Tell the server how far we have read, so the agent's inbox stops showing
	# this thread as unread and the badge can come back DOWN.
	if author != "contact":
		await _chat.mark_read(str(message.get("id", "")))


func _on_transport(mode: String) -> void:
	_status.text = str(TRANSPORT_COPY.get(mode, mode))


func _on_typing(is_typing: bool) -> void:
	_typing.text = "Support is typing…" if is_typing else ""


func _on_error(message: String) -> void:
	# The server's refusals on the upload route in particular are copy written
	# for a visitor to read, so they go straight on screen.
	_append("[color=#c0392b]%s[/color]" % message)


func _on_send_pressed() -> void:
	var text := _input.text.strip_edges()
	if text.is_empty():
		return
	_input.text = ""
	_send.disabled = true
	await _chat.send(text)
	_send.disabled = false
	_input.grab_focus()


## A screenshot, which is the obvious thing a player wants to send about a bug.
func _on_screenshot_pressed() -> void:
	# `get_image()` has to happen after a frame has been drawn, or the texture
	# is whatever was last in the buffer.
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var record := await _chat.upload(image.save_png_to_buffer(), "screenshot.png", "image/png")
	if record.is_empty():
		# `error_occurred` already said why, in the server's own words.
		return
	await _chat.send("Here is what I am seeing.", [record])


func _append(line: String) -> void:
	_log.append_text(line + "\n")


# ── Built in code rather than in the .tscn ──────────────────────────────
#
# So the scene file stays a two-line stub that cannot rot, and so this file
# can be read top to bottom as the whole example. A real game would lay this
# out in the editor.
func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var title := Label.new()
	title.text = "Support"
	title.add_theme_font_size_override("font_size", 22)
	root.add_child(title)

	_status = Label.new()
	_status.text = "starting…"
	root.add_child(_status)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_log)

	_typing = Label.new()
	_typing.text = ""
	root.add_child(_typing)

	var row := HBoxContainer.new()
	root.add_child(row)

	_input = LineEdit.new()
	_input.placeholder_text = "Describe the problem…"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(func(_t: String) -> void: _on_send_pressed())
	row.add_child(_input)

	_send = Button.new()
	_send.text = "Send"
	_send.disabled = true
	_send.pressed.connect(_on_send_pressed)
	row.add_child(_send)

	var shot := Button.new()
	shot.text = "Screenshot"
	shot.pressed.connect(_on_screenshot_pressed)
	row.add_child(shot)
