// Package realtime — WebSocket hub untuk reflection layer (Fase 8).
//
// Prinsip: realtime = notification layer, BUKAN source of truth.
// Server broadcast {type:"change", channel, event} — client merespon dengan
// refetch via REST (arsitektur resync eksplisit yang sudah ada). Payload row
// penuh bisa ditambahkan nanti bila perlu.
package realtime

import (
	"encoding/json"
	"log/slog"
	"sync"
)

// Hub — pusat koneksi & channel.
type Hub struct {
	mu       sync.Mutex
	clients  map[*Client]bool
	channels map[string]map[*Client]bool // channel name → set of clients
	logger   *slog.Logger
}

// NewHub — buat hub.
func NewHub(logger *slog.Logger) *Hub {
	return &Hub{
		clients:  map[*Client]bool{},
		channels: map[string]map[*Client]bool{},
		logger:   logger,
	}
}

// Client — satu koneksi WS.
type Client struct {
	hub      *Hub
	UserID   string
	Send     chan []byte
	channels map[string]bool
	mu       sync.Mutex
}

// NewClient — buat client terdaftar pada hub.
func NewClient(hub *Hub, userID string) *Client {
	return &Client{hub: hub, UserID: userID, Send: make(chan []byte, 16), channels: map[string]bool{}}
}

// Register — daftarkan client baru ke hub.
func (h *Hub) Register(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[c] = true
}

// Unregister — hapus client + lepas semua channel.
func (h *Hub) Unregister(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, c)
	for ch := range c.channels {
		if set, ok := h.channels[ch]; ok {
			delete(set, c)
			if len(set) == 0 {
				delete(h.channels, ch)
			}
		}
	}
	close(c.Send)
}

// Subscribe — client subscribe channel.
func (h *Hub) Subscribe(c *Client, channel string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.channels[channel] == nil {
		h.channels[channel] = map[*Client]bool{}
	}
	h.channels[channel][c] = true
	c.mu.Lock()
	if c.channels == nil {
		c.channels = map[string]bool{}
	}
	c.channels[channel] = true
	c.mu.Unlock()
}

// Unsubscribe — client lepas channel.
func (h *Hub) Unsubscribe(c *Client, channel string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if set, ok := h.channels[channel]; ok {
		delete(set, c)
		if len(set) == 0 {
			delete(h.channels, channel)
		}
	}
	c.mu.Lock()
	delete(c.channels, channel)
	c.mu.Unlock()
}

// Event — payload broadcast.
type Event struct {
	Type    string `json:"type"`              // "change" | "pong"
	Channel string `json:"channel,omitempty"` // "fleet_aircraft", ...
	Event   string `json:"event,omitempty"`   // "INSERT" | "UPDATE" | "DELETE" | "world_tick"
	At      string `json:"at,omitempty"`      // ISO timestamp
}

// Broadcast — kirim event ke semua client subscriber channel.
func (h *Hub) Broadcast(channel, event string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	clients := h.channels[channel]
	if len(clients) == 0 {
		return
	}
	msg, err := json.Marshal(Event{Type: "change", Channel: channel, Event: event})
	if err != nil {
		return
	}
	for c := range clients {
		select {
		case c.Send <- msg:
		default:
			// slow client — biarkan writer pump menangani timeout
		}
	}
	if h.logger != nil {
		h.logger.Debug("broadcast", "channel", channel, "event", event, "clients", len(clients))
	}
}

// BroadcastAll — kirim event ke SEMUA client (untuk perubahan global).
func (h *Hub) BroadcastAll(event string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	msg, _ := json.Marshal(Event{Type: "change", Event: event})
	for c := range h.clients {
		select {
		case c.Send <- msg:
		default:
		}
	}
}
