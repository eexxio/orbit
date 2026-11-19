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

Attachment tests use the DEBUG-only `-attachment-fixture` launch argument to
prepare a generated image through the normal image pipeline. `-attachment-fixtures`
also adds a text file for manual tray checks. The simulator PhotosPicker is usable
manually, but its out-of-process photo cells expose no stable identifiers for the
identifier-only UI tests. The fixture still exercises the actual gateway staging
and prompt submission paths, including an unsupported-method server scenario.

The staging-stop scenario holds the image RPC until the test releases it, then verifies detach,
zero file staging calls, and zero prompt submissions through `/fixture/state`.
