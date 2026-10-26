##
## Where the long-lived visitor token lives between launches.
##
## ── What is stored, and what it is worth ─────────────────────────────────
##
## `session.token` from `POST /v1/widget/init`. Keeping it is what makes a
## returning player's chat history theirs rather than a fresh anonymous
## thread. It identifies ONE visitor on ONE channel and can do nothing else:
## it cannot read another contact's conversation, cannot reach any agent-side
## route, and is not a workspace credential.
##
## **It is not a `ck_` API key and must never be one.** A `ck_` key is a
## standing workspace credential, and a game ships to players who can
## decompile it — `.pck` files are trivially unpacked and `export_presets`
## encryption only raises the price. A visitor token in a player's own save
## directory discloses that player's own chat to that player.
##
## ── Why plaintext, stated rather than hidden ────────────────────────────
##
## `user://` is `~/Library/Application Support/Godot/app_userdata/<game>` on
## macOS and the equivalent elsewhere: readable by anything running as that
## user. Godot offers `FileAccess.open_encrypted_with_pass`, but the pass
## would have to ship inside the same binary, which moves the secret rather
## than protecting it. Every other Chatly mobile SDK makes the same trade
## (`sdk-react-native` uses AsyncStorage, which is also plaintext), and the
## honest version is to say so here.
##
## ── Why the identity is stored separately and only sometimes ────────────
##
## `identity` is replayed after the server refuses a stale session, and it is
## only ever remembered when it carries a `user_hash`. On a channel with
## identity verification enabled an unhashed claim is refused, so replaying
## one could only turn one refusal into two. Without a hash the client re-inits
## anonymously and history returns the moment the game calls `identify()`
## again. This mirrors `rememberedIdentity()` in `apps/widget/src/client.ts`.
##
class_name ChatlyTokenStore
extends RefCounted

const _SECTION := "session"
const _KEY_TOKEN := "visitor_token"
const _KEY_IDENTITY := "identity"

## Namespaced by `publicId` so a game embedding two channels (a support one
## and an in-world NPC one, say) does not hand one channel's token to the
## other — which the API would refuse, leaving the second channel permanently
## broken for that player.
var _path: String = ""
var _config: ConfigFile = ConfigFile.new()


func _init(public_id: String, directory: String = "user://chatly") -> void:
	var safe := public_id.strip_edges()
	# A `publicId` reaches here from the game's own config, but it ends up in
	# a filename, so anything that could escape the directory is replaced
	# rather than trusted. `String.validate_filename()` would also do it; this
	# is explicit about which characters survive.
	var cleaned := ""
	for i in safe.length():
		var c := safe.unicode_at(i)
		var is_alnum := (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		cleaned += safe.substr(i, 1) if (is_alnum or c == 45 or c == 95) else "_"
	if cleaned.is_empty():
		cleaned = "default"
	DirAccess.make_dir_recursive_absolute(directory)
	_path = "%s/%s.cfg" % [directory, cleaned]
	# A missing file is the ordinary first-launch case, not an error.
	_config.load(_path)


func get_token() -> String:
	return str(_config.get_value(_SECTION, _KEY_TOKEN, ""))


func set_token(token: String) -> void:
	_config.set_value(_SECTION, _KEY_TOKEN, token)
	_save()


## Drop only the credential, keeping the remembered identity so a recovery can
## replay it.
func clear_token() -> void:
	_config.erase_section_key(_SECTION, _KEY_TOKEN)
	_save()


## Forget this device's session entirely — backs `logout()`.
##
## Drops the identity too: after a sign-out, a stale-session recovery must NOT
## quietly re-identify as the player who just signed out.
func clear_all() -> void:
	_config.clear()
	_save()


func get_identity() -> Dictionary:
	var v: Variant = _config.get_value(_SECTION, _KEY_IDENTITY, {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


func set_identity(identity: Dictionary) -> void:
	_config.set_value(_SECTION, _KEY_IDENTITY, identity)
	_save()


func _save() -> void:
	var err := _config.save(_path)
	if err != OK:
		# A read-only or full disk. The session still works for this launch —
		# it just will not survive a restart — so this is a warning and not a
		# refusal to chat.
		push_warning("[chatly] could not persist session to %s (error %d)" % [_path, err])
