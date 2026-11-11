#!/usr/bin/env python3
"""Prints the UDID of a bootable iPhone simulator on the newest iOS runtime.

CI images carry the same device name on several runtimes, so `simctl` can't be
given a bare name without guessing. Runtime labels look like
com.apple.CoreSimulator.SimRuntime.iOS-27-2, so sort them by version.
"""

import json
import re
import subprocess
import sys

DEVICE = "iPhone 18 Pro"


def runtime_version(identifier):
    match = re.search(r"iOS-(\d+)-(\d+)", identifier)
    return (int(match.group(1)), int(match.group(2))) if match else None


def main():
    out = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        check=True, capture_output=True, text=True,
    ).stdout
    candidates = []
    for runtime, devices in json.loads(out)["devices"].items():
        version = runtime_version(runtime)
        if version is None:
            continue
        for device in devices:
            if device["name"] == DEVICE and device.get("isAvailable", True):
                candidates.append((version, device["name"], device["udid"]))
    if not candidates:
        sys.exit("no %s simulator available" % DEVICE)
    version, _, udid = max(candidates)
    print("picked %s on iOS %d.%d: %s" % (DEVICE, version[0], version[1], udid), file=sys.stderr)
    print(udid)


if __name__ == "__main__":
    main()
