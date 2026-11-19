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

Standalone regression checks (no simulator or running fixture needed):

```sh
python3 -m unittest discover -s orbitUITests -p 'test_hermes_stub.py' -v
xcrun swiftc -swift-version 5 orbit/Features/Chat/LiveChat.swift \
  orbit/Hermes/HermesModels.swift orbit/Hermes/TokenRate.swift \
  orbit/Hermes/JSON.swift orbit/Hermes/HermesError.swift \
  orbitUITests/LiveChatChecks.swift -o "$HOME/orbit-livechat-checks"
"$HOME/orbit-livechat-checks"
```

The Swift checks compile the real `LiveChat` with controlled client/conversation doubles
to exercise history failures and completions arriving after shutdown. The Python checks
verify that fixture resets, histories, and reply counts remain isolated across clients.
