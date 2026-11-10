# Contributing to orbit

Thanks for helping! This guide covers how to get set up and what a good pull request looks like.

## Development setup

1. Install **Xcode 27.2 or later**.
2. Fork and clone the repository, then open `orbit.xcodeproj`.
3. Under the **orbit** target → *Signing & Capabilities*, choose your own Team. If needed, give it a unique
   bundle identifier. **Do not commit these signing changes.** Before you commit, unstage them with
   `git restore --staged orbit.xcodeproj` or `git add -p`.
4. Build and run with **⌘R**. You need a Hermes Agent dashboard to talk to. Run `hermes dashboard` on a
   machine the simulator or device can reach.

Sources live under `orbit/`, which Xcode syncs automatically. To add a file, create it in the right folder.
You don't need to edit the project file. See the repository map in [AGENTS.md](AGENTS.md#repository-map).

## Before you open a pull request

- [ ] The app builds with no new warnings:
  ```bash
  xcodebuild -project orbit.xcodeproj -scheme orbit -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
  ```
- [ ] You tried the change in the simulator or on a device.
- [ ] UI changes include before/after screenshots in the PR.
- [ ] User-visible changes have an entry under **Unreleased** in [CHANGELOG.md](CHANGELOG.md).
- [ ] No credentials, personal server addresses, or `xcuserdata/` are committed.

## Style

Follow the conventions in [AGENTS.md](AGENTS.md#code-conventions): Observation instead of Combine,
main-actor-by-default concurrency, Keychain for secrets, defensive JSON parsing, and small focused views.
Match the style of the code around your change.

## Commits

Write small, focused commits with an imperative subject line under about 72 characters, for example
"Keep the conversation above the keyboard". If the reason isn't obvious, explain it in the body.

## Reporting bugs and requesting features

Use the [issue templates](https://github.com/eexxio/orbit/issues/new/choose). For bugs, include your iOS
version, your Hermes version (Settings shows it once you're connected), and the steps to reproduce.

## Code of Conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
