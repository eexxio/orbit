# Hermes UI tests

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

`AskHermesTests` exercises the action's execution and output through a
Debug-only probe that can reach only the loopback fixture. It checks that
each accepted request submits once, never interrupts, and releases its
socket; it doesn't exercise Apple's Siri or Shortcuts interface. Check
those native surfaces separately with an installed build.
