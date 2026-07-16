# MClash

MClash is a native macOS controller for the
[MetaCubeX mihomo Alpha](https://github.com/MetaCubeX/mihomo/tree/Alpha) core.
The application is written with SwiftUI and AppKit. The Go core remains an
isolated process and is controlled through its authenticated loopback REST and
WebSocket API.

## Current scope

- Native window and menu bar app
- Alpha core discovery, configuration validation, lifecycle supervision, and
  bounded crash recovery
- Keychain-backed local controller secret
- Local and remote profile storage with transactional activation and rollback
- REST/WebSocket API models and client
- Lossless macOS system proxy snapshot, activation, persistence, and restore

TUN mode will be implemented behind a signed, narrow XPC privileged helper. It
is intentionally not handled through arbitrary shell commands or a root-owned
general-purpose launcher.

## Requirements

- macOS 14 or later
- Xcode with the macOS SDK for normal development
- Swift 6

The current machine's standalone Command Line Tools installation has a known
SwiftPM `PackageDescription` interface/dylib mismatch. `scripts/typecheck.sh`
therefore provides a direct compiler verification path until full Xcode is
selected.

## Development

```sh
cd ~/CodingSpace/MClash
./scripts/fetch-mihomo-alpha.sh
./scripts/typecheck.sh
./scripts/test-direct.sh
./scripts/integration-test.sh
./scripts/build-app.sh
open .build/release/MClash.app
```

For development without a bundled core, set `MCLASH_CORE_PATH` or select an
executable in the app.

## Safety invariants

- A profile is checked with `mihomo -t` before activation.
- The control API binds only to `127.0.0.1` and uses a random secret stored in
  Keychain.
- The app owns runtime configuration persistence; API patches are not treated
  as durable state.
- Existing system proxy dictionaries are captured and restored exactly.
- Core updates are delivered with a signed MClash release rather than through
  mihomo's in-place `/upgrade` endpoint.
