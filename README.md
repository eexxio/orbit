# orbit

A native SwiftUI client for Hermes Agent. Point it at your
Hermes dashboard (`hermes dashboard`) and chat with your agent from iPhone or iPad. Replies stream in live
and render as Markdown. Your recent conversations stay on the device so they open instantly and can be read offline.

<!-- TODO: add screenshots to docs/images/ and reference them here. -->

## Features

- **Chat list:** see your recent Hermes sessions, search them, and start a new chat.
- **Streaming replies:** responses arrive token by token over the Hermes JSON-RPC gateway WebSocket.
- **Markdown rendering:** assistant messages render through [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui).
- **Offline cache:** the 25 most recently active conversations are prefetched and kept on device.
- **Flexible sign-in:** works with open dashboards, username/password dashboards, and
  [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/) service tokens.
- **Secure storage:** passwords and secrets go in the Keychain, never in `UserDefaults`.

## Requirements

| | |
|---|---|
| Xcode | 27.2 or later |
| iOS / iPadOS | 27.2 or later |
| Server | A reachable Hermes Agent dashboard (local network, Tailscale, Cloudflare Tunnel, …) |

## Getting started

```bash
git clone https://github.com/eexxio/orbit.git
```

```bash
cd orbit && open orbit.xcodeproj
```

1. In Xcode, select the **orbit** target → *Signing & Capabilities* and choose your own
   **Team**. If the bundle identifier is already taken, change it as well.
2. Pick an iOS Simulator or a device and press **⌘R**.
3. In the app, open **Settings** (the gear icon), enter your Hermes dashboard address, for example
   `https://machine.tailnet.ts.net`, plus credentials if you need them, and tap **Connect**.

Swift Package Manager resolves the dependencies automatically the first time you open the project.

### Command-line build

```bash
xcodebuild -project orbit.xcodeproj -scheme orbit -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## Project layout

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
docs/                 Architecture notes
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit together.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before you open a pull request, and follow the
[Code of Conduct](CODE_OF_CONDUCT.md). To report a security problem, follow [SECURITY.md](SECURITY.md) and do not
open a public issue.

If you use AI coding agents, they should read [AGENTS.md](AGENTS.md).

## Acknowledgements

- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) by Guille Gonzalez.

## License

orbit is released under the [MIT License](LICENSE).
