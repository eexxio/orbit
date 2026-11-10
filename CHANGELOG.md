# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Connect to a Hermes Agent dashboard: open, username/password, and Cloudflare Access sign-in.
- Chat list with search, and new chats.
- Streaming chat over the Hermes gateway WebSocket, with Markdown-rendered replies.
- On-device cache of the most recent conversations for instant and offline reading.
- Redesigned composer that stays pinned above the keyboard.
- Opening the keyboard pushes the conversation up so the latest messages stay visible above it.
- Pixel-art app icon (a planet with an orbiting satellite), with dark and tinted versions.
- Redesigned Settings with the orbit logo, a connection status pill, and an About section.
- Edit the agent's SOUL.md (its personality) from Settings.
- Choose a theme (System, Light, Dark) and an accent color for buttons, links and your chat bubbles.
- New chats open with the message field focused and the keyboard up.
- Each streamed reply shows its generation speed in tokens per second (estimated with ~ when the server doesn't report usage).
- See the agent's thinking as a collapsible block and its tool calls as compact rows, live and in loaded chats.
- A Settings toggle to show or hide the agent's tool calls in chats.
- The "Thinking…" indicator shown while the agent works matches the thinking block, and steps aside while a tool call shows its own spinner.
