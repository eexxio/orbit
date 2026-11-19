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

Each test uses its own UUID URL prefix (`http://127.0.0.1:18765/<fixture-id>`).
The fixture paths below are relative to that prefix.

`MessageActionsTests` resets the fixture between tests with `POST /fixture/reset`.
`GET /api/sessions/fixture/messages` exposes the stored transcript used to verify that
regenerating, retrying, and editing append new turns while keeping the earlier history.
