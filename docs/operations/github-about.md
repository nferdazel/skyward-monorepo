# GitHub repo settings

Copy-paste values for the repository's About panel. Written 2026-09-17.

## Description (240 chars, limit 350)

```text
Airline-tycoon simulation where the Go backend owns every number. Flutter client (Web & Desktop), Go simulation engine, PostgreSQL. Demand, fares, wear, and cash flow are computed server-side, so the client can never disagree with the tick.
```

Shorter alternative (117 chars), if the above feels crowded in the sidebar:

```text
Airline-tycoon sim: Flutter client, authoritative Go engine, PostgreSQL. The server owns every number the player sees.
```

## Website

Leave empty unless there is a public deployment. `https://api.qouver.com/skyward`
is the API, not a landing page, and pointing the repo at it would be misleading.

## Topics

```text
airline-simulation
tycoon-game
simulation
flutter
dart
golang
go
postgresql
monorepo
websocket
rest-api
game-development
authoritative-server
```

All of these are verifiable from the repo: Dart is the majority language (200
files) with Go second (63), SQL migrations are tracked, the client uses
`web_socket_channel`, and "authoritative-server" is the design rule the README
is built around. Nothing here is aspirational.

## Social preview

Not generated. GitHub renders the README's first screen when no image is set,
and that currently opens with the thesis rather than a logo. If a real image is
wanted later it should be a screenshot of the dashboard, since that is the only
visual the repo can honestly show.
