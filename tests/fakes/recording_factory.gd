##
## Records every `(url, auth)` the realtime client opened a socket with.
##
## `opened` is the list the handshake tests assert on. It is per ATTEMPT, which
## is the whole reason the factory is a seam at all: the test that catches the
## frozen-credential bug is "attempt two carried a different token from
## attempt one", and only a per-attempt record can answer it.
##
extends ChatlySocketFactory

const RecordingSocket = preload("res://tests/fakes/recording_socket.gd")

## `[{ "url": String, "auth": Dictionary, "socket": RecordingSocket }]`
var opened: Array[Dictionary] = []


func open_socket(url: String, auth: Dictionary) -> ChatlySocket:
	var socket := RecordingSocket.new(url, auth)
	opened.append({"url": url, "auth": auth.duplicate(true), "socket": socket})
	return socket


func count() -> int:
	return opened.size()


func auth_at(index: int) -> Dictionary:
	return opened[index]["auth"] if index >= 0 and index < opened.size() else {}


func socket_at(index: int) -> ChatlySocket:
	return opened[index]["socket"] if index >= 0 and index < opened.size() else null


func last_socket() -> ChatlySocket:
	return socket_at(opened.size() - 1)
