# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Cursor, Copilot, …) working in this repository.
Human contributors should read [CONTRIBUTING.md](CONTRIBUTING.md). Everything here applies to them too.

## What this project is

orbit is a SwiftUI iOS/iPadOS client for a **Hermes Agent** dashboard server. It signs in over REST, lists
sessions, loads transcripts, and chats through a JSON-RPC 2.0 WebSocket gateway that streams replies.
There is no backend in this repo. The server is someone else's Hermes install.

## Build and verify

The only toolchain is Xcode 27.2+. There are no scripts, no Makefile, and no package manager besides SwiftPM
(which Xcode resolves itself).

```bash
# Compile-check (no signing needed). Run this after every change.
xcodebuild -project orbit.xcodeproj -scheme orbit \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

- A change is not done until this build prints `** BUILD SUCCEEDED **` with no new warnings in `orbit/`.
- There is no unit test target yet. If you add testable logic (for example JSON parsing, `pageToken(in:)`,
  or URL building), you may propose adding an `orbitTests` target, but ask the user first.
- For UI changes, run the app in a simulator and check the screen yourself when you can.

## Repository map

| Path | What lives there |
|---|---|
| `orbit/App/` | `OrbitApp` (`@main`). Keep it tiny. |
| `orbit/Features/<Feature>/` | One folder per screen. Views and view-local types. |
| `orbit/Hermes/` | Everything that talks to the server: `HermesClient` (REST, sign-in, the shared observable state), `HermesConversation` (one gateway socket per chat), `JSON`, `HermesError`, models. |
| `orbit/Storage/` | `ConversationCache` (per-server folder in Application Support, excluded from backup) and `Keychain`. |
| `orbit/Resources/` | Asset catalog. |
| `Config/Info.plist` | Extra Info.plist keys (local-network ATS exception and usage string). Most keys are generated from build settings. |
| `orbit.xcodeproj/project.xcproj` | Xcode 27 **JSON** project file. See below. |
| `docs/` | Architecture notes. |

## The Xcode project file

- The project uses the Xcode 27 JSON format (`project.xcproj`, not `project.pbxproj`).
- `orbit/` is a **synchronized folder**: any file you add under it joins the `orbit` target automatically.
  **Do not edit the project file to add or move sources.** Just create the file in the right folder.
- Do not put a second `Info.plist`, or any other file that must *not* be in the target, inside `orbit/`.
  Put it in `Config/`.
- Only edit `project.xcproj` for real build-setting or package changes, keep the edit minimal, and rebuild
  to confirm Xcode still parses the file.
- Do not change `DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER`, or deployment targets unless asked.

## Code conventions

- Swift 5 language mode with **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** and approachable concurrency.
  Types are main-actor isolated by default. Mark pure helpers that run off the main actor `nonisolated`.
- State uses the Observation framework (`@Observable`, `@Bindable`), not `ObservableObject`/`@Published`.
- `HermesClient.shared` is the single source of truth for connection state, sessions, and settings.
  Views read it directly. Do not add a parallel store.
- Server JSON goes through the `JSON` enum and its accessors (`["key"]`, `.text`, `.double`, `.flag`, `.list`).
  Parse defensively. Hermes releases differ, so tolerate missing or wrapped fields instead of failing.
- User-facing errors are `HermesError` cases with a short, plain sentence in `errorDescription`.
- Secrets (password, Cloudflare Access secret) go in the **Keychain only**. Non-secret settings go in
  `UserDefaults` under the `hermes.*` keys. Never log secrets or tokens.
- 4-space indentation, no trailing whitespace (see `.editorconfig`). Match the surrounding style. The
  codebase prefers compact code and doc comments (`///`) that explain *why*.
- Keep views small. If a view file grows past about 400 lines, extract subviews into the same feature folder.
- No new third-party dependencies without asking. The only one today is `swift-markdown-ui`.

## Hermes protocol notes

- The REST endpoints and gateway methods used are listed at the top of `orbit/Hermes/HermesClient.swift`.
  Keep that list current when you add calls.
- Auth modes: an open dashboard (token scraped from `__HERMES_SESSION_TOKEN__` in the page, sent as
  `X-Hermes-Session-Token`), basic username/password (session cookie), plus optional Cloudflare Access headers
  on *every* request, including the WebSocket upgrade.
- A single 401 triggers one re-sign-in and a retry (`authorizedRaw`). Do not add retry loops.
- The gateway's first frame must be `gateway.ready`. A heartbeat `gateway.ping` is sent every 15 s.

## Git and pull requests

- Branch from `main`. Use small, focused commits with an imperative subject (for example
  "Render assistant replies with MarkdownUI"), the same style as the existing history.
- Do not commit `xcuserdata/`, `DerivedData/`, `.DS_Store`, or anything with real server addresses or credentials.
- Fill in the PR template. Include screenshots for UI changes. CodeRabbit reviews every PR automatically (`.coderabbit.yaml`); address or reply to its comments.
- Add a line under **Unreleased** in `CHANGELOG.md` for user-visible changes.

## Ask before you

- add a dependency, target, or capability/entitlement;
- change signing, the bundle identifier, deployment targets, or the Info.plist privacy strings;
- change how or where credentials or cached conversations are stored;
- make sweeping formatting or renaming changes.
