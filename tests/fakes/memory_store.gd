##
## A `ChatlyTokenStore` with no disk.
##
## The real one writes to `user://`, which in a headless test run is a real
## directory that would persist between runs — so one test's token would leak
## into the next, and a suite that passes once would fail on a clean machine
## (or the reverse, which is worse).
##
extends ChatlyTokenStore

var token: String = ""
var identity: Dictionary = {}

## Counts, so a test can assert the dead token was actually CLEARED rather
## than only replaced in memory. The React Native SDK's recovery had that
## exact bug: it dropped the in-memory cache and left the token on disk, so
## the next launch repeated the failure.
var clear_token_calls: int = 0
var clear_all_calls: int = 0


func _init(_public_id: String = "test", _directory: String = "") -> void:
	# Deliberately does NOT call super(): the parent's `_init` creates a
	# directory and loads a file, and this fake exists to touch neither.
	pass


func get_token() -> String:
	return token


func set_token(value: String) -> void:
	token = value


func clear_token() -> void:
	clear_token_calls += 1
	token = ""


func clear_all() -> void:
	clear_all_calls += 1
	token = ""
	identity = {}


func get_identity() -> Dictionary:
	return identity


func set_identity(value: Dictionary) -> void:
	identity = value.duplicate(true)
