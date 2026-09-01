// Package handler — WebSocket handler (Fase 8).
package handler

import (
	"encoding/json"
	"net/http"
	"time"

	"skyward-api/internal/auth"
	"skyward-api/internal/httperr"
	"skyward-api/internal/realtime"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	// Browser origin check — dev lenient; prod via CORS-adjacent allowlist.
	CheckOrigin: func(r *http.Request) bool { return true },
}

const (
	writeWait  = 10 * time.Second
	pongWait   = 60 * time.Second
	pingPeriod = 50 * time.Second
	maxMsgSize = 1024
)

// WSServer — endpoint WS /ws?token=<jwt>.
type WSServer struct {
	Hub       *realtime.Hub
	JWTSecret []byte
}

type wsMessage struct {
	Action   string   `json:"action"` // subscribe | unsubscribe | ping
	Channels []string `json:"channels,omitempty"`
}

// ServeWS — handle upgrade + read/write pumps.
func (s *WSServer) ServeWS(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	if token == "" {
		httperr.WriteError(w, nil, httperr.Unauthorized("missing token"))
		return
	}
	claims, err := auth.Parse(token, s.JWTSecret)
	if err != nil || claims.Sub == "" {
		httperr.WriteError(w, nil, httperr.Unauthorized("invalid token"))
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}

	client := realtime.NewClient(s.Hub, claims.Sub)
	s.Hub.Register(client)

	// write pump
	go func() {
		ticker := time.NewTicker(pingPeriod)
		defer func() {
			ticker.Stop()
			conn.Close()
			s.Hub.Unregister(client)
		}()
		for {
			select {
			case msg, ok := <-client.Send:
				conn.SetWriteDeadline(time.Now().Add(writeWait))
				if !ok {
					conn.WriteMessage(websocket.CloseMessage, []byte{})
					return
				}
				if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
					return
				}
			case <-ticker.C:
				conn.SetWriteDeadline(time.Now().Add(writeWait))
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			}
		}
	}()

	// read pump (blocking — handler berakhir saat koneksi tutup)
	conn.SetReadLimit(maxMsgSize)
	conn.SetReadDeadline(time.Now().Add(pongWait))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			break
		}
		var m wsMessage
		if err := json.Unmarshal(data, &m); err != nil {
			continue
		}
		switch m.Action {
		case "subscribe":
			for _, ch := range m.Channels {
				s.Hub.Subscribe(client, ch)
			}
		case "unsubscribe":
			for _, ch := range m.Channels {
				s.Hub.Unsubscribe(client, ch)
			}
		case "ping":
			client.Send <- []byte(`{"type":"pong"}`)
		}
	}
}
