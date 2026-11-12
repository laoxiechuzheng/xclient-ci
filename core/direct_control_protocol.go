package core

type OpenDirectSocketParams struct {
	SessionID string `json:"sessionId"`
	Host      string `json:"host"`
	Port      int    `json:"port"`
}

type OpenDirectSocketResult struct {
	ConnectionID string `json:"connectionId"`
	BridgePort   int    `json:"bridgePort"`
	Ticket       string `json:"ticket"`
	ExpiresInMs  int64  `json:"expiresInMs"`
}

type CloseDirectSocketParams struct {
	SessionID    string `json:"sessionId"`
	ConnectionID string `json:"connectionId"`
}

type CloseDirectSessionParams struct {
	SessionID string `json:"sessionId"`
}
