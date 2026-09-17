// Package handler — WebSocket handler (Fase 8).
package handler

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"skyward-api/internal/httperr"
	"skyward-api/internal/middleware"
	"skyward-api/internal/realtime"

	"github.com/gorilla/websocket"
)

// WSServer — endpoint WS /ws?ticket=<opaque>.
//
// Tiketnya diterbitkan `POST /ws/ticket` (di belakang AuthGuard) dan ditukar
// di sini. Token tidak lagi lewat query string: browser tidak bisa memasang
// header pada handshake WebSocket, jadi JWT ditukar dulu lewat REST.
type WSServer struct {
	Hub       *realtime.Hub
	JWTSecret []byte

	// Tickets — tiket sekali pakai, dibagi dengan handler penerbitnya.
	Tickets *realtime.TicketStore

	// AllowedOrigins — sama dengan sumber CORS (CORS_ALLOWED_ORIGINS). Kosong
	// = tanpa batasan (dev). Browser origin di luar daftar ditolak (AUDIT-05).
	AllowedOrigins []string
}

// originHost — "https://Host:Port" → "host" (lower, tanpa port/scheme).
func originHost(s string) string {
	s = strings.ToLower(s)
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	if i := strings.LastIndex(s, ":"); i > 0 {
		s = s[:i]
	}
	return strings.Trim(s, "/")
}

// checkOrigin — (AUDIT-05) dulu selalu true. Rules:
//   - Origin kosong ⇒ allow: bukan browser (dart:io/desktop/curl); tidak ada
//     vektor cross-site tanpa Origin.
//   - AllowedOrigins kosong ⇒ allow (dev, tidak ada allowlist terkonfigurasi).
//   - selain itu: host Origin harus ada di allowlist (port longgar, sama seperti
//     penanganan host di CORS middleware).
func (s *WSServer) checkOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" || len(s.AllowedOrigins) == 0 {
		return true
	}
	h := originHost(origin)
	if h == "" {
		return false
	}
	for _, a := range s.AllowedOrigins {
		if originHost(a) == h {
			return true
		}
	}
	return false
}

const (
	writeWait  = 10 * time.Second
	pongWait   = 60 * time.Second
	pingPeriod = 50 * time.Second
	maxMsgSize = 1024
)

type wsMessage struct {
	Action   string   `json:"action"` // subscribe | unsubscribe | ping
	Channels []string `json:"channels,omitempty"`
}

// Ticket — terbitkan tiket sekali pakai untuk handshake WS.
//
// Dipasang di belakang AuthGuard, jadi user_id datang dari JWT di header
// Authorization seperti endpoint REST lain. Responsnya hanya berisi tiket dan
// umurnya; tiketnya sendiri buram dan tidak membawa identitas.
func (s *WSServer) Ticket(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		httperr.WriteError(w, nil, httperr.Unauthorized("missing user context"))
		return
	}

	tok, err := s.Tickets.Issue(userID)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal("could not issue ticket"))
		return
	}

	httperr.WriteJSON(w, http.StatusOK, map[string]any{
		"ticket":     tok,
		"expires_in": int(realtime.TicketTTL().Seconds()),
	})
}

// ServeWS — handle upgrade + read/write pumps.
func (s *WSServer) ServeWS(w http.ResponseWriter, r *http.Request) {
	ticket := r.URL.Query().Get("ticket")
	if ticket == "" {
		httperr.WriteError(w, nil, httperr.Unauthorized("missing ticket"))
		return
	}

	// Sekali pakai: penukaran yang gagal sekalipun menghabiskan tiketnya,
	// jadi percobaan ulang harus meminta tiket baru.
	userID, ok := s.Tickets.Redeem(ticket)
	if !ok {
		httperr.WriteError(w, nil, httperr.Unauthorized("invalid or expired ticket"))
		return
	}

	conn, err := (&websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		CheckOrigin:     s.checkOrigin,
	}).Upgrade(w, r, nil)
	if err != nil {
		return
	}

	client := realtime.NewClient(s.Hub, userID)
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
			client.TrySend([]byte(`{"type":"pong"}`))
		}
	}
}
