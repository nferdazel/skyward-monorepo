# Proposal: D3 — WebSocket token transport

Status: **answered 2026-09-17 — option A (one-time ticket), implemented** in
`c7ef0f2`. This document is kept as the decision record.
Last verified against code: 2026-09-17

## Problem

`GET /ws?token=<jwt>` carries the session JWT in the query string
(`apps/api/internal/handler/ws.go:76`, client builds the URL at
`apps/app/lib/core/realtime/go_realtime_client.dart:104`).

A URL is not a good place for a credential: it lands in access logs, proxy
logs, browser history, and `Referer` by default. The JWT here is a 24-hour
HS256 token (`auth.Sign` defaults `Exp` to 24h) with no refresh flow, so a
leaked one is valid for a full day.

### What I actually verified, and what I did not

I checked the claim "the JWT is in Caddy's logs" before treating it as the
motivation, because it is the usual reason this item exists:

- **Caddy does not log it.** `deploy/Caddyfile.api.qouver.com` has no `log`
  or `access log` directive, and `journalctl -u caddy` contains zero `"uri"`
  entries and zero `token=` strings over the last 7 days. There is no access
  log at all.
- **The API does not log it either.** `middleware.go` logs `r.URL.Path`
  (`:40`, `:110`, `:219`), never `RequestURI`. Dropping the query string is
  deliberate in that code today.
- Confirmed on the server over 7 days: `grep -c 'token='` is 0 for both
  Caddy and `skyward-api`.

So this is **not an active leak**. It is a trap laid for the future: the day
someone adds `log` to the Caddyfile (a normal thing to want), every JWT
becomes a log line, and that change looks unrelated to auth. The client is
also a Flutter app on web/desktop, where a URL can reach browser history.

I would rather state that honestly and let you decide the priority than
dress it up as an incident.

## Constraint that decides the design

A browser `WebSocket` cannot set custom headers on the handshake. So
`Authorization: Bearer` — the clean fix, and what every REST route already
does — is not available to the web client. The realistic options are below.

## Options

### A. One-time ticket (recommended)

1. New `POST /ws/ticket`, behind the existing `AuthGuard`. Returns a random
   opaque ticket valid ~30 seconds, single use, stored server-side.
2. Client calls it, then connects to `GET /ws?ticket=<opaque>`.
3. `ServeWS` validates the ticket instead of parsing the JWT.

- **Cost:** ~1 small endpoint, an in-memory ticket store with TTL, the client
  gains one REST round-trip before connecting, `checkOrigin` unchanged.
- **Placement:** the store belongs next to the hub in `internal/realtime`;
  invalidating on use is a map delete, so no new dependency.
- **Trade-off:** a new endpoint and an in-memory store. Single-use + short TTL
  means a leaked URL is worthless almost immediately, which is the point.
- **Reconnect:** the client reconnects on drop
  (`go_realtime_client.dart` has a generation-guarded backoff), so it must
  fetch a fresh ticket per attempt. Tickets are cheap and this is a handful of
  lines.

### B. `Sec-WebSocket-Protocol` subprotocol

Client passes the JWT as a subprotocol, e.g.
`new WebSocket(url, ['bearer', token])`; the server reads
`r.Header.Get("Sec-WebSocket-Protocol")` and must echo one token back or the
browser aborts the connection.

- **Cost:** smallest — no new endpoint, no store.
- **Trade-off:** the JWT is still the credential in flight; it is out of the
  URL and logs, but a proxy that logs protocols sees it, and misuse of this
  header (it is meant to negotiate protocols, not carry credentials) is a
  known smell. Echoing it back correctly is fiddly.

### C. Accept a header from native, keep query for web

Split behavior by client: native (desktop) sends a header, web keeps the
query param.

- **Trade-off:** two code paths and the web path keeps the problem. This
  solves nothing real; I include it only to be complete.

### D. Do nothing, record the decision

- **Trade-off:** zero risk now, by the evidence above. The trap stays armed
  for whoever enables access logging.

## Recommendation

**Option A.** It is the only one that makes a leaked URL useless, and its
cost is one endpoint and a small TTL map. B is cheaper but still puts the
24-hour JWT on the wire as a value a proxy may log; the point is to stop
using the session token as a URL parameter at all.

**If you would rather not add an endpoint right now, D is defensible** on the
evidence: nothing logs it today. In that case I would still add a short
comment at `ws.go:76` and in the Caddyfile saying the token is in the query
string on purpose and that enabling access logging would expose it, so the
trap is at least labelled.

## Scope if approved (A)

- `apps/api/internal/realtime/` — ticket store (issue, redeem, TTL sweep).
- `apps/api/internal/handler/ws.go` — `Ticket` handler behind `AuthGuard`;
  `ServeWS` reads `ticket`.
- `apps/api/cmd/server/main.go` — register `POST /ws/ticket`.
- `apps/app/lib/core/realtime/go_realtime_client.dart` — fetch ticket per
  connect attempt; keep the generation guard.
- Tests: store (issue/redeem/expiry/reuse), handler (401 without auth, 401 on
  bad/expired/reused ticket), client (fetches before connecting).
- Not touched: `checkOrigin`/AUDIT-05, the reconnect/backoff logic, the hub.

## Open questions for you

1. A, B, or D?
2. If A: ticket TTL 30 s and single-use — agreed? Or longer to survive a slow
   reconnect?
