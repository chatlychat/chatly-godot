##
## The real factory. One `ChatlyWebSocketSocket` per attempt.
##
class_name ChatlyWebSocketSocketFactory
extends ChatlySocketFactory


func open_socket(url: String, auth: Dictionary) -> ChatlySocket:
	return ChatlyWebSocketSocket.new(url, auth)
