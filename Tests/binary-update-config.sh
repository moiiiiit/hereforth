#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

(
    cd "$repo"
    HEREFORTH_BINARY_UPDATER=1 /usr/bin/swift package dump-package > "$fixture/binary-package.json"
    /usr/bin/env -u HEREFORTH_BINARY_UPDATER /usr/bin/swift package dump-package > "$fixture/source-package.json"
)
python3 - "$fixture" <<'PY'
import json
from pathlib import Path
import sys

fixture = Path(sys.argv[1])
binary = json.loads((fixture / "binary-package.json").read_text())
source = json.loads((fixture / "source-package.json").read_text())
sparkle, = [target for target in binary["targets"] if target["name"] == "Sparkle"]
assert sparkle["type"] == "binary"
assert sparkle["url"] == "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip"
assert sparkle["checksum"] == "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
assert all(target["name"] != "Sparkle" for target in source["targets"])
PY

cat > "$fixture/main.swift" <<'SWIFT'
import Foundation

let fixtureKey = Data((0..<32).map(UInt8.init)).base64EncodedString()
let production: [String: Any] = [
    "HereforthUpdateChannel": "binary",
    "HereforthBinaryUpdateTrack": "production",
    "SUFeedURL": "https://raw.githubusercontent.com/moiiiiit/hereforth/main/updates/appcast.xml",
    "SUPublicEDKey": fixtureKey
]
func replacing(_ key: String, _ value: Any) -> [String: Any] {
    production.merging([key: value]) { _, replacement in replacement }
}

let config = BinaryUpdateConfiguration(info: production)
precondition(config?.track == .production)
precondition(config?.feedURL == production["SUFeedURL"] as? String)
var beta = replacing("HereforthBinaryUpdateTrack", "beta")
beta["SUFeedURL"] = "https://raw.githubusercontent.com/moiiiiit/hereforth/main/updates/appcast-beta.xml"
let betaConfig = BinaryUpdateConfiguration(info: beta)
precondition(betaConfig?.track == .beta && betaConfig?.feedURL != config?.feedURL)

for (key, value) in [
    ("HereforthUpdateChannel", "stable"),
    ("HereforthBinaryUpdateTrack", "experimental"),
    ("SUFeedURL", "http://updates.example.invalid/appcast.xml"),
    ("SUFeedURL", "https://owner:password@updates.example.invalid/appcast.xml"),
    ("SUPublicEDKey", "invalid signing key")
] {
    precondition(BinaryUpdateConfiguration(info: replacing(key, value)) == nil)
}
SWIFT

/usr/bin/swiftc -D HEREFORTH_BINARY_UPDATER "$repo/Sources/HereforthApp/BinaryUpdateConfiguration.swift" \
    "$fixture/main.swift" -o "$fixture/config-smoke"
"$fixture/config-smoke"
printf 'Binary update configuration smoke test passed.\n'
