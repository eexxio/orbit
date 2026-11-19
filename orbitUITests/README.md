# Chat streaming UI tests

From the repository root, start the loopback Hermes fixture in one terminal:

```sh
python3 orbitUITests/hermes_stub.py
```

In another terminal, substitute an available iOS simulator's ID from
`xcrun simctl list devices available`:

```sh
xcodebuild -project orbit.xcodeproj -scheme orbit \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -resultBundlePath "orbit-streaming-$(uuidgen).xcresult" test CODE_SIGNING_ALLOWED=NO
```

The tests use the app's normal REST sign-in and JSON-RPC WebSocket path. They
advance the fixture after observing each UI state, rather than relying on
fixed streaming delays. Screenshots are attached to the test result bundle.

Onboarding tests use fixture IDs that start with `locked-` (a dashboard that
requires sign-in and rejects every password) and `blocked-` (every request
answered 403, as Cloudflare Access does).
