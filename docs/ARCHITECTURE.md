# Architecture

orbit is a small SwiftUI app with three layers: **views**, the **Hermes client**, and **storage**.

```
Features (SwiftUI views)
   │  read/observe                         │ one per open chat
   ▼                                       ▼
HermesClient.shared ──────────────▶ HermesConversation
 (REST, sign-in, sessions,            (gateway WebSocket,
  settings, @Observable)               JSON-RPC, streaming)
   │
   ▼
ConversationCache · Keychain · UserDefaults
```

## HermesClient

`orbit/Hermes/HermesClient.swift` is a main-actor `@Observable` singleton. It owns:

- **Settings:** the address and username (in `UserDefaults`), and the password and Cloudflare Access
  secret (in the Keychain). Each property writes itself back through `didSet`.
- **Sign-in:** `GET /api/status` decides the mode. An open dashboard has its session token scraped from
  the HTML page. A protected dashboard uses `POST /auth/password-login`, which sets a cookie on an ephemeral
  `URLSession`. Concurrent callers share one in-flight sign-in task. A single 401 triggers one re-sign-in.
- **Sessions:** `GET /api/sessions` (filtered to human chats) and `GET /api/sessions/{key}/messages`.
- **Gateway upgrade:** builds the `wss://…/api/ws` request, with either the page token or a single-use
  ticket from `POST /api/auth/ws-ticket` sent as a `Sec-WebSocket-Protocol`.

## HermesConversation

`orbit/Hermes/HermesConversation.swift` represents one chat: its own WebSocket, the runtime session ID
(from `session.create` or `session.resume`), and pending JSON-RPC calls held as continuations. It
publishes events to the view through closures (`onDelta`, `onComplete`, `onError`, `onTitle`). A 15-second
`gateway.ping` heartbeat keeps the socket alive.

## Storage

- `ConversationCache` keeps the session list and up to 25 recent transcripts as JSON files in
  `Application Support/<hash of address+username>/`, excluded from iCloud backups. The client prefetches
  stale conversations after every session refresh.
- `Keychain` is a minimal generic-password wrapper, with service `orbit.hermes` and accessibility
  `AfterFirstUnlock`.

## Views

- `Features/Chats/ContentView` is the root `NavigationStack`: a searchable session list, settings, and new chat.
- `Features/Chat/ChatInterfaceView` is the conversation screen. It renders from the cache first, then
  refreshes, and streams deltas into the last assistant bubble. Assistant replies render through MarkdownUI.
- `Features/Settings/SettingsView` holds the server address, credentials, Cloudflare Access fields, and the
  connection status.
