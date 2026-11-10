<div align="center">

<img src="docs/brand/social/readme-banner.png" alt="orbit" width="100%">

### Your Hermes agent, in your pocket.

A native SwiftUI client for [Hermes Agent](https://github.com/NousResearch/hermes-agent) on iPhone and iPad.<br>
Live streaming replies, Markdown rendering and offline reading, with no extra backend.

<br>

[![Platform](https://img.shields.io/badge/iOS%20%7C%20iPadOS-27.2%2B-2B2B2B?style=flat-square&logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5-3D3D3D?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-5C5C5C?style=flat-square)](https://developer.apple.com/xcode/swiftui/)
[![Xcode](https://img.shields.io/badge/Xcode-27.2%2B-808080?style=flat-square&logo=xcode&logoColor=white)](https://developer.apple.com/xcode/)
[![License: MIT](https://img.shields.io/badge/License-MIT-B5B5B5?style=flat-square)](LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-EBEBEB?style=flat-square)](CONTRIBUTING.md)

[**Features**](#features) · [**Getting started**](#getting-started) · [**Connecting**](#connecting-to-your-server) · [**Architecture**](#how-it-works) · [**Contributing**](#contributing)

</div>

<br>

<!-- TODO: add iPhone and iPad screenshots to docs/images/ and show them here, for example:
<p align="center">
  <img src="docs/images/chats.png" width="24%" alt="Chat list">
  <img src="docs/images/chat.png" width="24%" alt="Conversation">
  <img src="docs/images/settings.png" width="24%" alt="Settings">
</p>
-->

## About

[Hermes Agent](https://github.com/NousResearch/hermes-agent) runs on your own machine and comes with a web
dashboard (`hermes dashboard`). **orbit** is a native front end for that dashboard. You enter your server's
address, sign in, and your sessions show up as an ordinary chat app. Replies stream in token by token over
the same JSON-RPC gateway the web UI uses.

orbit only talks to the Hermes server you point it at. It has no account, no analytics and no backend of its
own.

## Features

|   |   |
|---|---|
| 💬 **Chat list** | Browse and search your recent Hermes sessions, or start a new chat. |
| ⚡ **Live streaming** | Replies arrive token by token over the Hermes JSON-RPC 2.0 WebSocket gateway. |
| 📝 **Markdown** | Assistant replies render as rich text, with code blocks, lists and tables, through [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui). |
| 📴 **Offline reading** | The 25 most recently active conversations are prefetched, so they open instantly and stay readable without a connection. |
| 🔐 **Flexible sign-in** | Works with open dashboards, username/password dashboards, and [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/) service tokens. |
| 🗝️ **Secure by default** | Passwords and secrets are stored in the Keychain only, and the cache is excluded from iCloud backups. |
| 📱 **iPhone and iPad** | A single native SwiftUI app built on the Observation framework. |

## Requirements

| Component | Version |
|---|---|
| Xcode | 27.2 or later |
| iOS / iPadOS | 27.2 or later |
| Server | A reachable [Hermes Agent](https://github.com/NousResearch/hermes-agent) dashboard (`hermes dashboard`) |

orbit isn't on the App Store yet, so you build it from source. A free Apple developer account is enough to
run it on your own device.

## Getting started

**1. Clone and open the project**

```bash
git clone https://github.com/eexxio/orbit.git
```

```bash
cd orbit && open orbit.xcodeproj
```

Xcode resolves the Swift packages the first time you open the project.

**2. Set up signing**

Select the **orbit** target → **Signing & Capabilities** and pick your own **Team**. If Xcode says the
bundle identifier is taken, change it to something unique, such as `com.yourname.orbit`.

**3. Run**

Pick a simulator or a connected device and press **⌘R**.

<details>
<summary><b>Building from the command line</b></summary>

<br>

This compile check needs no signing. CI runs the same command.

```bash
xcodebuild -project orbit.xcodeproj -scheme orbit -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

</details>

## Connecting to your server

Open **Settings** (the gear icon), enter the address of your Hermes dashboard, and tap **Connect**.

| Your dashboard | What to enter |
|---|---|
| **Open** (no sign-in) | Only the address. orbit picks up the dashboard's session token by itself. |
| **Password protected** | The address, plus your username and password. |
| **Behind Cloudflare Access** | Also the service token's **Client ID** and **Client Secret**. orbit sends them on every request, including the WebSocket upgrade. |

<details>
<summary><b>Reaching your server from your phone</b></summary>

<br>

The dashboard has to be reachable from the device. Common setups:

- **Same Wi-Fi.** Use the machine's LAN address, for example `http://192.168.1.20:<port>`. iOS asks for
  local network access the first time you connect.
- **[Tailscale](https://tailscale.com).** Use the machine's MagicDNS name, for example
  `https://machine.tailnet.ts.net`. This is the easiest way to connect from anywhere.
- **[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/).**
  Publish the dashboard on your own domain and protect it with a Cloudflare Access service token.

Prefer HTTPS whenever the server is reachable from outside your home network.

</details>

## How it works

```
Features (SwiftUI views)
   │  read / observe                       │ one per open chat
   ▼                                       ▼
HermesClient.shared ──────────────▶ HermesConversation
 (REST, sign-in, sessions,            (gateway WebSocket,
  settings, @Observable)               JSON-RPC, streaming)
   │
   ▼
ConversationCache · Keychain · UserDefaults
```

- **`HermesClient`** is the single source of truth. It handles sign-in, the session list, transcripts and
  settings. It retries once on a `401` by signing in again.
- **`HermesConversation`** owns one gateway socket per chat. It creates or resumes the session, sends
  prompts and streams `message.delta` events back to the view, with a 15-second heartbeat.
- **Storage** keeps cached transcripts in a per-server folder in Application Support, secrets in the
  Keychain, and everything else in `UserDefaults`.

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full walkthrough.

<details>
<summary><b>Project layout</b></summary>

<br>

```
orbit/
├── App/              App entry point (@main)
├── Features/
│   ├── Chats/        Chat list (root screen)
│   ├── Chat/         Conversation screen and composer
│   └── Settings/     Server configuration and connection status
├── Hermes/           Hermes Agent API: REST client, gateway socket, models, JSON, errors
├── Storage/          On-device conversation cache and Keychain wrapper
└── Resources/        Asset catalog
Config/               Info.plist and other build configuration
docs/                 Architecture notes and the brand kit
```

</details>

## Privacy and security

- orbit connects **only** to the server you configure. It has no telemetry, no analytics and no third-party
  services.
- Passwords and Cloudflare Access secrets live in the **Keychain**, never in `UserDefaults` or in logs.
- Cached conversations stay on the device and are **excluded from iCloud backups**. **Disconnect** signs
  you out and deletes the cache.

Found a vulnerability? Please follow [SECURITY.md](SECURITY.md) and don't open a public issue.

## Contributing

Contributions are welcome, from bug reports to pull requests.

1. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).
2. Open an [issue](https://github.com/eexxio/orbit/issues/new/choose) to report a bug or discuss a feature.
3. Branch from `main`, keep commits small and focused, and fill in the pull request template.

If you work with AI coding agents, point them at [AGENTS.md](AGENTS.md). Changes are tracked in
[CHANGELOG.md](CHANGELOG.md).

## Acknowledgements

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research, the agent orbit connects to.
- [Hermex](https://github.com/uzairansaruzi/hermex) by Uzair Ansar, a native iPhone app for Hermes Agent. Its
  work on the Hermes backend helped shape how orbit talks to the server.
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) by Guille Gonzalez, for Markdown
  rendering.
- [Monocraft](https://github.com/IdreesInc/Monocraft) by Idrees Hassan, the pixel font behind the
  [brand](docs/brand/README.md).

orbit is an independent community project. It is not affiliated with or endorsed by Nous Research.

## License

orbit is released under the [MIT License](LICENSE).

<div align="center">
<br>
<img src="docs/brand/app-icon/icon-64.png" width="48" alt="">
</div>
