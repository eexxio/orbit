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

`MessageActionsTests` resets the fixture between tests with `POST /fixture/reset/rewind`,
`/fixture/reset/fallback` (no undo support), or `/fixture/reset/fail-undo` (one failed undo).
The fixture also accepts `--no-undo` and `--fail-undo-once` for manual checks.
`GET /api/sessions/fixture/messages` exposes the stored transcript used to verify that
rewinding replaces the server's turn while fallback editing appends a turn.
